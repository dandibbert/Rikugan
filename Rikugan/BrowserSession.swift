import SwiftUI
import WebKit
import Combine

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
    @Published var thumbnails: [UUID: UIImage] = [:]
    @Published var favicons: [UUID: UIImage] = [:]
    @Published var requestedPanel: String?
    @Published var contentRuleError: String?
    var contexts: [UUID: WKWebExtensionContext] = [:]
    var extensionDNRLists: [UUID: WKContentRuleList] = [:]
    @Published var extensionDNRCounts: [UUID: Int] = [:]
    var privateStore: WKWebsiteDataStore = .nonPersistent()
    var contentRuleList: WKContentRuleList?
    var globalCosmetic = ""
    var popupPresenter: PopupPresenter?
    private var scriptRefresh: Task<Void, Never>?
    private var stopped = false
    private var memoryWarning: AnyCancellable?
    // Private GM values live only for the current private browsing session.
    var privateScriptStorage: [UUID: String] = [:]
    let scriptStorage = ScriptStorageHub()
    var profile: BrowserProfile { model?.state.profiles.first { $0.id == profileID } ?? BrowserProfile(name: "个人") }
    var activeTab: BrowserTab? { tabs.first { $0.id == selectedID } ?? tabs.first }
    var isActive: Bool { !stopped && model?.state.activeProfileID == profileID }

    init(model: AppModel, profileID: UUID) {
        self.model = model; self.profileID = profileID
        dataStore = WKWebsiteDataStore(forIdentifier: profileID)
        let config = WKWebExtensionController.Configuration(identifier: profileID)
        config.defaultWebsiteDataStore = dataStore
        // The default store used by extension APIs and their actual web views must agree.
        let extensionWebConfiguration = WKWebViewConfiguration()
        extensionWebConfiguration.websiteDataStore = dataStore
        config.webViewConfiguration = extensionWebConfiguration
        extensionController = WKWebExtensionController(configuration: config)
        super.init()
        extensionController.delegate = self
        let saved = profile.tabs.isEmpty ? [SavedTab()] : profile.tabs
        tabs = saved.map { BrowserTab(saved: $0, session: self) }
        selectedID = saved.contains(where: { $0.id == profile.selectedTabID }) ? profile.selectedTabID : saved.first?.id
        memoryWarning = NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)
            .sink { [weak self] _ in Task { @MainActor in self?.reclaimInactiveTabs() } }
    }
    func start() async {
        for record in profile.extensions where record.enabled {
            guard isActive else { return }
            await loadExtension(record)
        }
        guard isActive else { return }
        extensionController.didOpenWindow(self)
        extensionController.didFocusWindow(self)
        for tab in tabs where !tab.isPrivate { extensionController.didOpenTab(tab) }
        if let tab = activeTab {
            if !tab.isPrivate { extensionController.didActivateTab(tab, previousActiveTab: nil) }
            tab.restoreIfNeeded()
        }
        ready = true; persistTabs()
        Task { [weak self] in
            guard let self else { return }
            await BlockListCoordinator.rebuild(self)
            self.model?.applyPendingShare()
        }
    }
    func shutdown() {
        guard !stopped else { return }
        persistTabs(); stopped = true; scriptRefresh?.cancel()
        model?.downloadCenter.endPrivateSession(profileID)
        memoryWarning = nil; privateScriptStorage.removeAll()
        popupPresenter?.dismiss()
        extensionController.didCloseWindow(self)
        for context in contexts.values { try? extensionController.unload(context) }
        contexts.removeAll()
        extensionDNRLists.removeAll(); extensionDNRCounts.removeAll()
        for tab in tabs { tab.teardown() }
        tabs.removeAll()
        extensionController.delegate = nil
    }
    @discardableResult func addTab(url: URL? = nil, activate: Bool = true, configuration: WKWebViewConfiguration? = nil, isPrivate: Bool = false, groupID: UUID? = nil) -> BrowserTab {
        var saved = SavedTab(groupID: groupID, isPrivate: isPrivate)
        if let groupID { saved.groupID = groupID }
        let tab = BrowserTab(saved: saved, session: self, configuration: configuration)
        tabs.append(tab)
        if !tab.isPrivate { extensionController.didOpenTab(tab) }
        if activate { select(tab) }
        if let url { tab.navigate(url) }
        else if !isPrivate, profile.settings.homepage == "custom", let home = URL(string: profile.settings.homepageURL), !profile.settings.homepageURL.isEmpty { tab.navigate(home) }
        else if !isPrivate, profile.settings.homepage == "blank" { tab.isHome = false; tab.navigate(URL(string: "about:blank")!) }
        if saved.autoRefreshSeconds > 0 { tab.setAutoRefresh(saved.autoRefreshSeconds) }
        persistTabs(); return tab
    }
    func select(_ tab: BrowserTab) {
        let previous = activeTab; selectedID = tab.id
        tab.lastActiveAt = Date()
        if !tab.isPrivate { extensionController.didActivateTab(tab, previousActiveTab: previous?.isPrivate == false ? previous : nil) }
        tab.restoreIfNeeded(); persistTabs()
    }
    func close(_ tab: BrowserTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        if !tab.isPrivate, let url = URL(string: tab.address), ["http", "https"].contains(url.scheme ?? "") {
            let closed = ClosedTab(url: tab.address, title: tab.pageTitle, groupID: tab.groupID)
            model?.updateProfile(profileID) { profile in
                profile.closedTabs.insert(closed, at: 0)
                profile.closedTabs = Array(profile.closedTabs.prefix(30))
            }
        }
        let wasActive = selectedID == tab.id
        let wasPrivate = tab.isPrivate
        tabs.remove(at: index); thumbnails[tab.id] = nil; favicons[tab.id] = nil
        if !tab.isPrivate { extensionController.didCloseTab(tab, windowIsClosing: false) }
        commands.removeAll { $0.tabID == tab.id }; tab.teardown()
        if wasPrivate, !tabs.contains(where: \.isPrivate) {
            model?.downloadCenter.endPrivateSession(profileID)
            privateStore = .nonPersistent(); privateScriptStorage.removeAll()
        }
        if tabs.isEmpty { addTab() }
        else if wasActive { select(tabs[min(index, tabs.count - 1)]) }
        persistTabs()
    }
    func persistTabs() {
        guard !stopped else { return }
        let snapshots = tabs.filter { !$0.isPrivate }.map(\.snapshot)
        let selected = tabs.first { $0.id == selectedID && !$0.isPrivate }?.id ?? snapshots.first?.id
        model?.updateProfile(profileID) { $0.tabs = snapshots.isEmpty ? [SavedTab()] : snapshots; $0.selectedTabID = selected }
    }
    func recordVisit(_ tab: BrowserTab) {
        guard !tab.isPrivate, let url = tab.webView.url, ["http", "https"].contains(url.scheme ?? "") else { return }
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
        for tab in tabs {
            guard let webView = tab.existingWebView else { continue }
            tab.scriptEngine.configure(webView.configuration.userContentController, scripts: profile.scripts)
            PageTools.install(on: webView.configuration.userContentController, cosmeticCSS: globalCosmetic)
            tab.ensurePageHandler()
            tab.syncContentRules()
        }
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
        for tab in tabs { tab.existingWebView?.stopLoading(); tab.discardRecoveryState() }
        await dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        model?.updateProfile(profileID) { $0.history.removeAll() }
        for tab in tabs where !tab.isHome { tab.existingWebView?.reload() }
    }

    /// Keep the selected tab, every visible iPad window and one recently used tab.
    /// Media/capture/download tabs are not evicted. Metadata queries never wake tabs.
    func reclaimInactiveTabs(keepingRecent count: Int = 1) {
        guard isActive else { return }
        thumbnails.removeAll(); favicons.removeAll()
        let candidates = tabs.filter { $0.existingWebView != nil && $0.id != selectedID && $0.visiblePageCount == 0 }
            .sorted { $0.lastActiveAt > $1.lastActiveAt }
        for tab in candidates.dropFirst(max(0, count)) { tab.suspendIfIdle() }
    }
}

@MainActor final class BrowserTab: NSObject, ObservableObject, Identifiable {
    let id: UUID
    weak var session: BrowserSession?
    private(set) var existingWebView: WKWebView?
    var webView: WKWebView { restoreIfNeeded(); return makeWebView() }
    @Published private(set) var isSuspended = false
    var visiblePageCount = 0
    // WebKit's opaque state contains history/form/scroll data. Never serialize it
    // to disk or backups (especially not private form contents).
    private var recoveryState: Any?
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
    var isPrivate: Bool
    var groupID: UUID?
    var autoRefreshSeconds: Int
    var contentRulesOn = false
    var appliedExtensionDNR: [UUID: WKContentRuleList] = [:]
    var pageHandlerInstalled = false
    var refreshTask: Task<Void, Never>?
    var lastActiveAt = Date()
    var snapshot: SavedTab { SavedTab(id: id, url: isHome || isPrivate ? "" : address, title: pageTitle, desktop: desktop, groupID: groupID, autoRefreshSeconds: autoRefreshSeconds) }
    var userscriptsAllowed: Bool {
        let host = existingWebView?.url?.host ?? URL(string: address)?.host
        return session?.profile.site(for: host)?.userScriptsEnabled ?? true
    }

    init(saved: SavedTab, session: BrowserSession, configuration supplied: WKWebViewConfiguration? = nil) {
        id = saved.id; self.session = session; pageTitle = saved.title; address = saved.url; isHome = saved.url.isEmpty; desktop = saved.desktop
        isPrivate = saved.isPrivate; groupID = saved.groupID; autoRefreshSeconds = saved.autoRefreshSeconds
        super.init()
        scriptEngine.tab = self
        // A popup configuration must be used immediately; ordinary restored tabs
        // stay metadata-only until selected or actually navigated.
        if let supplied { _ = makeWebView(configuration: supplied) }
    }
    @discardableResult private func makeWebView(configuration supplied: WKWebViewConfiguration? = nil) -> WKWebView {
        if let existingWebView { return existingWebView }
        let configuration = supplied ?? WKWebViewConfiguration()
        configuration.websiteDataStore = isPrivate ? (session?.privateStore ?? .nonPersistent()) : (session?.dataStore ?? .nonPersistent())
        // WebKit caches privacy per extension window, not per mixed browser tab.
        // Private tabs therefore never join the ordinary extension controller.
        configuration.webExtensionController = isPrivate ? nil : session?.extensionController
        configuration.userContentController = WKUserContentController()
        configuration.allowsInlineMediaPlayback = true
        configuration.allowsPictureInPictureMediaPlayback = true
        configuration.allowsAirPlayForMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = .audio
        configuration.defaultWebpagePreferences.preferredContentMode = desktop ? .desktop : .mobile
        let webView = WKWebView(frame: .zero, configuration: configuration)
        existingWebView = webView
        scriptEngine.configure(configuration.userContentController, scripts: session?.profile.scripts ?? [])
        PageTools.install(on: configuration.userContentController, cosmeticCSS: session?.globalCosmetic ?? "")
        ensurePageHandler(); syncContentRules(); syncExtensionDNR()
        webView.navigationDelegate = self; webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.isInspectable = session?.profile.settings.inspectable ?? true
        webView.scrollView.keyboardDismissMode = .onDrag
        observations = [
            webView.observe(\.title, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.syncState(properties: .title) } },
            webView.observe(\.url, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.syncState(properties: .URL) } },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.syncState(properties: .loading) } },
            webView.observe(\.isLoading, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.syncState(properties: .loading) } },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.syncState(properties: []) } },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.syncState(properties: []) } }
        ]
        return webView
    }
    func syncState(properties: WKWebExtension.TabChangedProperties) {
        guard let webView = existingWebView else { return }
        progress = webView.estimatedProgress; isLoading = webView.isLoading
        canGoBack = webView.canGoBack; canGoForward = webView.canGoForward
        if let url = webView.url {
            address = url.absoluteString
            session?.noteURLChange(self)
        }
        if let title = webView.title, !title.isEmpty { pageTitle = title }
        if !isPrivate, !properties.isEmpty { session?.extensionController.didChangeTabProperties(properties, for: self) }
    }
    func restoreIfNeeded() {
        guard !restored else { return }
        restored = true
        guard !isHome else { return }
        let view = makeWebView()
        if let state = recoveryState {
            recoveryState = nil
            view.interactionState = state // WebKit restores and navigates itself.
        } else if let url = URL(string: address), !address.isEmpty {
            view.load(URLRequest(url: url))
        }
        isSuspended = false
        if autoRefreshSeconds > 0 { setAutoRefresh(autoRefreshSeconds) }
    }
    func navigate(_ url: URL) {
        restored = true; isHome = false; pageError = nil; address = url.absoluteString
        recoveryState = nil; isSuspended = false
        makeWebView().load(URLRequest(url: url)); session?.persistTabs()
    }
    func loadInput(_ input: String) {
        let engine = session?.profile.searchEngine ?? "https://www.google.com/search?q="
        let custom = session?.profile.settings.customEngines ?? []
        if !isPrivate, URLRules.isSearch(input), let session {
            let term = input.trimmingCharacters(in: .whitespacesAndNewlines)
            session.model?.updateProfile(session.profileID) { profile in
                profile.searchHistory.removeAll { $0 == term }
                profile.searchHistory.insert(term, at: 0)
                profile.searchHistory = Array(profile.searchHistory.prefix(40))
            }
        }
        if let url = URLRules.inputURL(input, searchEngine: engine, customEngines: custom) { navigate(url) }
    }
    func toggleDesktop() {
        desktop.toggle()
        webView.customUserAgent = desktop ? "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.4 Safari/605.1.15" : nil
        webView.reload(); session?.persistTabs()
    }
    func teardown() {
        releaseWebView(); recoveryState = nil
    }
    private func releaseWebView() {
        refreshTask?.cancel(); refreshTask = nil
        guard let webView = existingWebView else { return }
        webView.stopLoading(); observations.removeAll()
        if pageHandlerInstalled {
            webView.configuration.userContentController.removeScriptMessageHandler(forName: "rikuganPage", contentWorld: .page)
            pageHandlerInstalled = false
        }
        scriptEngine.teardown(webView.configuration.userContentController)
        webView.navigationDelegate = nil; webView.uiDelegate = nil
        webView.removeFromSuperview()
        existingWebView = nil; contentRulesOn = false
        appliedExtensionDNR.removeAll()
    }
    func discardRecoveryState() { recoveryState = nil }
    func suspendIfIdle() {
        guard let view = existingWebView else { return }
        view.requestMediaPlaybackState { [weak self, weak view] state in
            guard let self, let view, self.existingWebView === view,
                  state != .playing, view.cameraCaptureState == .none, view.microphoneCaptureState == .none else { return }
            _ = self.suspend()
        }
    }
    @discardableResult func suspend() -> Bool {
        guard session?.isActive == true, session?.selectedID != id, visiblePageCount == 0,
              !isLoading, session?.model?.downloadCenter.hasActiveDownload(tabID: id) != true,
              let view = existingWebView else { return false }
        // Custom extension configurations cannot safely be reconstructed as an
        // ordinary page. Only suspend standard HTTP(S) browsing documents.
        guard let scheme = URL(string: address)?.scheme, ["http", "https"].contains(scheme) else { return false }
        recoveryState = view.interactionState
        releaseWebView()
        restored = false; isSuspended = true
        session?.commands.removeAll { $0.tabID == id }
        session?.objectWillChange.send()
        return true
    }
}

extension BrowserTab: WKNavigationDelegate, WKUIDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isHome = false; restored = true
        scriptEngine.resetDocument()
        pageError = nil; session?.commands.removeAll { $0.tabID == id }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        syncState(properties: [.loading, .URL, .title]); session?.recordVisit(self); applyDecorations(); captureThumbnail(); captureIcon()
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { applyDecorations() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { pageError = error.localizedDescription }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { pageError = error.localizedDescription }
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { pageError = "页面进程已被系统回收，点击重新载入。" }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, preferences: WKWebpagePreferences,
                 decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        let host = navigationAction.request.url?.host
        let site = session?.profile.site(for: host)
        if let forced = site?.desktopMode { desktop = forced }
        preferences.preferredContentMode = desktop ? .desktop : .mobile
        preferences.allowsContentJavaScript = site?.javascriptEnabled ?? true
        guard let url = navigationAction.request.url else { decisionHandler(.cancel, preferences); return }
        if navigationAction.targetFrame?.isMainFrame == true, ["http", "https"].contains(url.scheme ?? "") {
            syncContentRules(forHost: url.host)
        }
        if let kind = InternalPages.kind(url) {
            decisionHandler(.cancel, preferences)
            session?.requestedPanel = kind
            return
        }
        if navigationAction.shouldPerformDownload { decisionHandler(.download, preferences); return }
        if ["http", "https"].contains(url.scheme ?? ""), url.path.hasSuffix(".user.js"), navigationAction.targetFrame?.isMainFrame != false {
            decisionHandler(.cancel, preferences)
            Task { await session?.model?.importScriptURL(url.absoluteString) }; return
        }
        if ["http", "https", "about", "blob", "data"].contains(url.scheme ?? "") || session?.extensionController.extensionContext(for: url) != nil {
            decisionHandler(.allow, preferences); return
        }
        decisionHandler(.cancel, preferences)
        guard navigationAction.navigationType == .linkActivated || navigationAction.navigationType == .other else { return }
        let scheme = url.scheme?.lowercased() ?? ""
        let settings = session?.profile.settings
        let external = site?.externalNavigation ?? "ask"
        if ["itms-apps", "itms", "itmss", "macappstore"].contains(scheme), settings?.preventAppStoreRedirect != false || external == "block" {
            session?.model?.message = "已拦截 App Store 跳转。"; return
        }
        if settings?.preventExternalAppRedirect == true || external == "block" {
            session?.model?.message = "已拦截外部 App 跳转。"; return
        }
        if external == "allow" { UIApplication.shared.open(url); return }
        BrowserPresentation.confirm(title: "\(host ?? url.scheme ?? "网页") 想打开外部 App", message: url.absoluteString) { allowed in if allowed { UIApplication.shared.open(url) } }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        session?.model?.downloadCenter.adopt(download, from: self)
    }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        session?.model?.downloadCenter.adopt(download, from: self)
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let session else { return nil }
        let host = webView.url?.host ?? ""
        let popup = session.profile.site(for: host)?.popups ?? "ask"
        if popup == "block" { return nil }
        if popup == "ask" {
            BrowserPresentation.confirm(title: host.isEmpty ? "弹窗" : host, message: "这个网页想打开新标签页。") { allowed in
                if allowed, let url = navigationAction.request.url { session.addTab(url: url, activate: true, configuration: configuration, isPrivate: self.isPrivate, groupID: self.groupID) }
            }
            return nil
        }
        return session.addTab(activate: true, configuration: configuration, isPrivate: isPrivate, groupID: groupID).webView
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
                 type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        if type == .camera { decide(["camera"], host: origin.host, title: "相机", decisionHandler: decisionHandler) }
        else if type == .microphone { decide(["microphone"], host: origin.host, title: "麦克风", decisionHandler: decisionHandler) }
        else { decide(["camera", "microphone"], host: origin.host, title: "相机和麦克风", decisionHandler: decisionHandler) }
    }
    func webView(_ webView: WKWebView, requestGeolocationPermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decide(["location"], host: origin.host, title: "位置", decisionHandler: decisionHandler)
    }
    private func decide(_ kinds: [String], host: String, title: String, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        let current = WebPermissionPolicy.aggregate(kinds.map { session?.profile.permission(host: host, kind: $0) ?? "ask" })
        if current == "allow" { decisionHandler(.grant); return }
        if current == "block" { decisionHandler(.deny); return }
        BrowserPresentation.choice(title: host, message: "\(title)权限") { [weak self] choice in
            if choice != "ask" {
                self?.session?.model?.updateProfile(self?.session?.profileID ?? UUID()) { profile in
                    let normalizedHost = host.lowercased()
                    for kind in kinds {
                        profile.webPermissions.removeAll { $0.host.lowercased() == normalizedHost && $0.kind == kind }
                        profile.webPermissions.append(WebPermission(host: normalizedHost, kind: kind, decision: choice))
                    }
                }
            }
            decisionHandler(choice == "allow" ? .grant : choice == "block" ? .deny : .prompt)
        }
    }
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
    static func choice(title: String, message: String, completion: @escaping (String) -> Void) {
        guard let presenter, !(presenter is UIAlertController) else { completion("ask"); return }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "允许", style: .default) { _ in completion("allow") })
        alert.addAction(UIAlertAction(title: "禁止", style: .destructive) { _ in completion("block") })
        alert.addAction(UIAlertAction(title: "仅此一次询问", style: .cancel) { _ in completion("ask") })
        presenter.present(alert, animated: true)
    }
    static func share(_ items: [Any]) {
        guard let presenter else { return }
        let sheet = UIActivityViewController(activityItems: items, applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = presenter.view
        sheet.popoverPresentationController?.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.maxY - 60, width: 1, height: 1)
        presenter.present(sheet, animated: true)
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
