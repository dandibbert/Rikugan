import SwiftUI
import WebKit

@MainActor final class BrowserSession: NSObject, ObservableObject {
    weak var model: AppModel?
    let profileID: UUID
    let dataStore: WKWebsiteDataStore
    let extensionController: WKWebExtensionController
    @Published var tabs: [BrowserTab] = []
    @Published var selectedID: UUID?
    @Published var ready = false
    @Published var extensionErrors: [UUID: String] = [:]
    @Published var commands: [ScriptCommand] = []
    var contexts: [UUID: WKWebExtensionContext] = [:]
    var popupPresenter: PopupPresenter?
    private var scriptRefresh: Task<Void, Never>?
    private var stopped = false
    var profile: BrowserProfile { model?.state.profiles.first { $0.id == profileID } ?? BrowserProfile(name: "个人") }
    var activeTab: BrowserTab? { tabs.first { $0.id == selectedID } ?? tabs.first }
    var isActive: Bool { !stopped && model?.state.activeProfileID == profileID }

    init(model: AppModel, profileID: UUID) {
        self.model = model; self.profileID = profileID
        dataStore = WKWebsiteDataStore(forIdentifier: profileID)
        let config = WKWebExtensionController.Configuration(identifier: profileID)
        config.defaultWebsiteDataStore = dataStore
        extensionController = WKWebExtensionController(configuration: config)
        super.init()
        extensionController.delegate = self
        let saved = profile.tabs.isEmpty ? [SavedTab()] : profile.tabs
        tabs = saved.map { BrowserTab(saved: $0, session: self) }
        selectedID = saved.contains(where: { $0.id == profile.selectedTabID }) ? profile.selectedTabID : saved.first?.id
    }
    func start() async {
        for record in profile.extensions where record.enabled {
            guard isActive else { return }
            await loadExtension(record)
        }
        guard isActive else { return }
        extensionController.didOpenWindow(self)
        extensionController.didFocusWindow(self)
        for tab in tabs { extensionController.didOpenTab(tab) }
        if let tab = activeTab { extensionController.didActivateTab(tab, previousActiveTab: nil); tab.restoreIfNeeded() }
        ready = true; persistTabs()
    }
    func shutdown() {
        guard !stopped else { return }
        persistTabs(); stopped = true; scriptRefresh?.cancel()
        popupPresenter?.dismiss()
        extensionController.didCloseWindow(self)
        for context in contexts.values { try? extensionController.unload(context) }
        contexts.removeAll()
        for tab in tabs { tab.teardown() }
        tabs.removeAll()
        extensionController.delegate = nil
    }
    @discardableResult func addTab(url: URL? = nil, activate: Bool = true, configuration: WKWebViewConfiguration? = nil) -> BrowserTab {
        let tab = BrowserTab(saved: SavedTab(), session: self, configuration: configuration)
        tabs.append(tab); extensionController.didOpenTab(tab)
        if activate { select(tab) }
        if let url { tab.navigate(url) }
        persistTabs(); return tab
    }
    func select(_ tab: BrowserTab) {
        let previous = activeTab; selectedID = tab.id
        extensionController.didActivateTab(tab, previousActiveTab: previous)
        tab.restoreIfNeeded(); persistTabs()
    }
    func close(_ tab: BrowserTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        let wasActive = selectedID == tab.id
        tabs.remove(at: index); extensionController.didCloseTab(tab, windowIsClosing: false)
        commands.removeAll { $0.tabID == tab.id }; tab.teardown()
        if tabs.isEmpty { addTab() }
        else if wasActive { select(tabs[min(index, tabs.count - 1)]) }
        persistTabs()
    }
    func persistTabs() {
        guard !stopped else { return }
        let snapshots = tabs.map(\.snapshot)
        model?.updateProfile(profileID) { $0.tabs = snapshots; $0.selectedTabID = selectedID }
    }
    func recordVisit(_ tab: BrowserTab) {
        guard let url = tab.webView.url, ["http", "https"].contains(url.scheme ?? "") else { return }
        model?.updateProfile(profileID) { profile in
            profile.history.removeAll { $0.url == url.absoluteString }
            profile.history.insert(PageRecord(title: tab.pageTitle, url: url.absoluteString), at: 0)
            profile.history = Array(profile.history.prefix(1000))
        }
        persistTabs()
    }
    func addBookmark() {
        guard let tab = activeTab, let url = tab.webView.url, !tab.isHome else { return }
        model?.updateProfile(profileID) { profile in
            profile.bookmarks.removeAll { $0.url == url.absoluteString }
            profile.bookmarks.insert(PageRecord(title: tab.pageTitle, url: url.absoluteString), at: 0)
        }
        model?.message = "已添加到「\(profile.name)」的书签。"
    }
    func refreshScripts() {
        guard isActive else { return }
        for tab in tabs { tab.scriptEngine.configure(tab.webView.configuration.userContentController, scripts: profile.scripts) }
    }
    func scheduleScriptRefresh() {
        scriptRefresh?.cancel()
        scriptRefresh = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            self?.refreshScripts()
        }
    }
    func runCommand(_ command: ScriptCommand) {
        guard let tab = activeTab, tab.id == command.tabID else { return }
        Task { [weak self] in
            do {
                _ = try await tab.webView.callAsyncJavaScript("globalThis.__rikuganCommands?.[id]?.()", arguments: ["id": command.id], in: nil,
                    contentWorld: .world(name: "rikugan.script." + command.scriptID.uuidString))
            } catch { self?.model?.message = error.localizedDescription }
        }
    }
    func clearWebsiteData() async {
        for tab in tabs { tab.webView.stopLoading() }
        await dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        model?.updateProfile(profileID) { $0.history.removeAll() }
        for tab in tabs where !tab.isHome { tab.webView.reload() }
    }
}

@MainActor final class BrowserTab: NSObject, ObservableObject, Identifiable {
    let id: UUID
    weak var session: BrowserSession?
    let webView: WKWebView
    let scriptEngine = UserScriptEngine()
    @Published var pageTitle: String
    @Published var address: String
    @Published var progress: Double = 0
    @Published var isLoading = false
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isHome: Bool
    @Published var pageError: String?
    @Published var desktop: Bool
    private var observations: [NSKeyValueObservation] = []
    private var restored = false
    private var downloads: [ObjectIdentifier: URL] = [:]
    var snapshot: SavedTab { SavedTab(id: id, url: isHome ? "" : address, title: pageTitle, desktop: desktop) }

    init(saved: SavedTab, session: BrowserSession, configuration supplied: WKWebViewConfiguration? = nil) {
        id = saved.id; self.session = session; pageTitle = saved.title; address = saved.url; isHome = saved.url.isEmpty; desktop = saved.desktop
        let configuration = supplied ?? WKWebViewConfiguration()
        configuration.websiteDataStore = session.dataStore
        configuration.webExtensionController = session.extensionController
        configuration.userContentController = WKUserContentController()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = .audio
        configuration.defaultWebpagePreferences.preferredContentMode = saved.desktop ? .desktop : .mobile
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        scriptEngine.tab = self
        scriptEngine.configure(configuration.userContentController, scripts: session.profile.scripts)
        webView.navigationDelegate = self; webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.isInspectable = true
        webView.scrollView.keyboardDismissMode = .onDrag
        observations = [
            webView.observe(\.title, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.syncState(properties: .title) } },
            webView.observe(\.url, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.syncState(properties: .URL) } },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.syncState(properties: .loading) } },
            webView.observe(\.isLoading, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.syncState(properties: .loading) } },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.syncState(properties: []) } },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.syncState(properties: []) } }
        ]
    }
    func syncState(properties: WKWebExtension.TabChangedProperties) {
        progress = webView.estimatedProgress; isLoading = webView.isLoading
        canGoBack = webView.canGoBack; canGoForward = webView.canGoForward
        if let url = webView.url { address = url.absoluteString }
        if let title = webView.title, !title.isEmpty { pageTitle = title }
        if !properties.isEmpty { session?.extensionController.didChangeTabProperties(properties, for: self) }
    }
    func restoreIfNeeded() {
        guard !restored else { return }
        restored = true
        if !address.isEmpty, let url = URL(string: address) { navigate(url) }
    }
    func navigate(_ url: URL) {
        restored = true; isHome = false; pageError = nil; address = url.absoluteString
        webView.load(URLRequest(url: url)); session?.persistTabs()
    }
    func loadInput(_ input: String) {
        if let url = URLRules.inputURL(input, searchEngine: session?.profile.searchEngine ?? "https://www.google.com/search?q=") { navigate(url) }
    }
    func toggleDesktop() {
        desktop.toggle()
        webView.customUserAgent = desktop ? "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.4 Safari/605.1.15" : nil
        webView.reload(); session?.persistTabs()
    }
    func teardown() {
        webView.stopLoading(); observations.removeAll()
        scriptEngine.teardown(webView.configuration.userContentController)
        webView.navigationDelegate = nil; webView.uiDelegate = nil
    }
}

extension BrowserTab: WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isHome = false; restored = true
        pageError = nil; session?.commands.removeAll { $0.tabID == id }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { syncState(properties: [.loading, .URL, .title]); session?.recordVisit(self) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { pageError = error.localizedDescription }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { pageError = error.localizedDescription }
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { pageError = "页面进程已被系统回收，点击重新载入。" }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, preferences: WKWebpagePreferences,
                 decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        preferences.preferredContentMode = desktop ? .desktop : .mobile
        guard let url = navigationAction.request.url else { decisionHandler(.cancel, preferences); return }
        if navigationAction.shouldPerformDownload { decisionHandler(.download, preferences); return }
        if ["http", "https"].contains(url.scheme ?? ""), url.path.hasSuffix(".user.js"), navigationAction.targetFrame?.isMainFrame != false {
            decisionHandler(.cancel, preferences)
            Task { await session?.model?.importScriptURL(url.absoluteString) }; return
        }
        if ["http", "https", "about", "blob", "data"].contains(url.scheme ?? "") || session?.extensionController.extensionContext(for: url) != nil {
            decisionHandler(.allow, preferences); return
        }
        decisionHandler(.cancel, preferences)
        if navigationAction.navigationType == .linkActivated {
            BrowserPresentation.confirm(title: "打开外部 App？", message: url.absoluteString) { allowed in if allowed { UIApplication.shared.open(url) } }
        }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { download.delegate = self }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { download.delegate = self }
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) {
        do {
            let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Downloads", isDirectory: true)
                .appendingPathComponent(session?.profileID.uuidString ?? "default", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let name = (suggestedFilename as NSString).lastPathComponent
            let safe = name.isEmpty || name == "." || name == ".." ? "download" : name
            var url = dir.appendingPathComponent(safe)
            if FileManager.default.fileExists(atPath: url.path) { url = dir.appendingPathComponent(UUID().uuidString.prefix(8) + "-" + safe) }
            downloads[ObjectIdentifier(download)] = url; completionHandler(url)
        } catch { session?.model?.message = error.localizedDescription; completionHandler(nil) }
    }
    func downloadDidFinish(_ download: WKDownload) {
        let url = downloads.removeValue(forKey: ObjectIdentifier(download))
        session?.model?.message = "下载完成：\(url?.lastPathComponent ?? "文件")。可在「文件 → 我的 iPhone → Rikugan → Downloads」找到。"
    }
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        if let file = downloads.removeValue(forKey: ObjectIdentifier(download)) { try? FileManager.default.removeItem(at: file) }
        session?.model?.message = "下载失败：\(error.localizedDescription)"
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let session else { return nil }
        return session.addTab(activate: true, configuration: configuration).webView
    }
    func webViewDidClose(_ webView: WKWebView) { session?.close(self) }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping () -> Void) {
        BrowserPresentation.alert(title: frame.securityOrigin.host, message: message, completion: completionHandler)
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (Bool) -> Void) {
        BrowserPresentation.confirm(title: frame.securityOrigin.host, message: message, completion: completionHandler)
    }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        BrowserPresentation.input(title: frame.securityOrigin.host, message: prompt, initial: defaultText, completion: completionHandler)
    }
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) { decisionHandler(.prompt) }
}

@MainActor enum BrowserPresentation {
    static var presenter: UIViewController? {
        let root = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController
        var top = root
        while let next = top?.presentedViewController, !next.isBeingDismissed { top = next }
        return top
    }
    static func alert(title: String, message: String, completion: @escaping () -> Void) {
        guard let presenter, !(presenter is UIAlertController) else { completion(); return }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default) { _ in completion() })
        presenter.present(alert, animated: true)
    }
    static func confirm(title: String, message: String, completion: @escaping (Bool) -> Void) {
        guard let presenter, !(presenter is UIAlertController) else { completion(false); return }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completion(false) })
        alert.addAction(UIAlertAction(title: "允许", style: .default) { _ in completion(true) })
        presenter.present(alert, animated: true)
    }
    static func input(title: String, message: String, initial: String?, completion: @escaping (String?) -> Void) {
        guard let presenter, !(presenter is UIAlertController) else { completion(nil); return }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addTextField { $0.text = initial }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completion(nil) })
        alert.addAction(UIAlertAction(title: "确定", style: .default) { _ in completion(alert.textFields?.first?.text) })
        presenter.present(alert, animated: true)
    }
}
