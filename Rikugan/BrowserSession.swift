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
    @Published var thumbnails: [UUID: UIImage] = [:]
    @Published var favicons: [UUID: UIImage] = [:]
    @Published var hostIcons: [String: UIImage] = [:]
    @Published var requestedPanel: String?
    var contexts: [UUID: WKWebExtensionContext] = [:]
    var privateStore: WKWebsiteDataStore = .nonPersistent()
    var contentRuleList: WKContentRuleList?
    var contentRuleLists: [WKContentRuleList] = []
    var globalCosmetic = ""
    var hostCSS: [String: String] = [:]
    var proceduralJSON = "[]"
    var scriptletJSON = "[]"
    var cspJSON = "[]"
    var removeParams: [AdBlockEngine.QueryStrip] = []
    var privateScriptValues: [UUID: [String: Any]] = [:]
    var popupPresenter: PopupPresenter?
    private var scriptRefresh: Task<Void, Never>?
    private var stopped = false
    var profile: BrowserProfile { model?.state.profiles.first { $0.id == profileID } ?? BrowserProfile(name: "个人") }
    var activeTab: BrowserTab? {
        if let selected = tabs.first(where: { $0.id == selectedID && $0.windowID == nil }) { return selected }
        return tabs.first { $0.windowID == nil }
    }
    static func shouldPersistTab(isPrivate: Bool, windowID: UUID?) -> Bool { !isPrivate && windowID == nil }
    static func faviconKey(_ host: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-"))
        let mapped = host.lowercased().unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        return String(mapped.prefix(180))
    }
    var isActive: Bool { !stopped && model?.state.activeProfileID == profileID }

    init(model: AppModel, profileID: UUID) {
        self.model = model; self.profileID = profileID
        dataStore = WKWebsiteDataStore(forIdentifier: profileID)
        let config = WKWebExtensionController.Configuration(identifier: profileID)
        config.defaultWebsiteDataStore = dataStore
        extensionController = WKWebExtensionController(configuration: config)
        super.init()
        extensionController.delegate = self
        loadFaviconCache()
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
        loadThumbnails()
        for tab in tabs where tab.autoRefreshSeconds > 0 { tab.setAutoRefresh(tab.autoRefreshSeconds) }
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
        popupPresenter?.dismiss()
        extensionController.didCloseWindow(self)
        for context in contexts.values { try? extensionController.unload(context) }
        contexts.removeAll()
        for tab in tabs { tab.teardown() }
        tabs.removeAll()
        extensionController.delegate = nil
    }
    @discardableResult func addTab(url: URL? = nil, activate: Bool = true, configuration: WKWebViewConfiguration? = nil, isPrivate: Bool = false, groupID: UUID? = nil, windowID: UUID? = nil) -> BrowserTab {
        var saved = SavedTab(isPrivate: isPrivate, groupID: groupID)
        if let groupID { saved.groupID = groupID }
        let tab = BrowserTab(saved: saved, session: self, configuration: configuration)
        tab.windowID = windowID
        tabs.append(tab); extensionController.didOpenTab(tab)
        if let windowID {
            model?.windows.select(tab.id, in: windowID)
            if activate {
                let previous = tabs.first { $0.id == selectedID }
                extensionController.didActivateTab(tab, previousActiveTab: previous)
            }
        } else if activate { select(tab) }
        installPageTools(on: tab)
        if let url { tab.navigate(url) }
        else if !isPrivate, profile.settings.homepage == "custom", let home = URL(string: profile.settings.homepageURL), !profile.settings.homepageURL.isEmpty { tab.navigate(home) }
        else if !isPrivate, profile.settings.homepage == "blank" { tab.isHome = false; tab.navigate(URL(string: "about:blank")!) }
        if saved.autoRefreshSeconds > 0 { tab.setAutoRefresh(saved.autoRefreshSeconds) }
        persistTabs(); return tab
    }
    func select(_ tab: BrowserTab) {
        let previous = activeTab; selectedID = tab.id
        extensionController.didActivateTab(tab, previousActiveTab: previous)
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
        let windowID = tab.windowID
        tabs.remove(at: index); thumbnails[tab.id] = nil; favicons[tab.id] = nil
        extensionController.didCloseTab(tab, windowIsClosing: false)
        commands.removeAll { $0.tabID == tab.id }; tab.teardown()
        removeThumbnail(tab.id)
        if wasPrivate, !tabs.contains(where: \.isPrivate) {
            privateStore = .nonPersistent()
            privateScriptValues.removeAll()
        }
        let main = tabs.filter { $0.windowID == nil }
        if windowID == nil {
            if main.isEmpty { addTab() }
            else if wasActive { select(main[min(index, main.count - 1)]) }
        } else {
            let siblings = tabs.filter { $0.windowID == windowID }
            if model?.windows.selection[windowID] == tab.id { model?.windows.replace(siblings.last?.id, in: windowID) }
            if wasActive, let fallback = main.last { select(fallback) }
        }
        persistTabs()
    }
    func persistTabs() {
        guard !stopped else { return }
        let snapshots = tabs.filter { Self.shouldPersistTab(isPrivate: $0.isPrivate, windowID: $0.windowID) }.map(\.snapshot)
        let selected = tabs.first { $0.id == selectedID && Self.shouldPersistTab(isPrivate: $0.isPrivate, windowID: $0.windowID) }?.id ?? snapshots.first?.id
        model?.updateProfile(profileID) { $0.tabs = snapshots.isEmpty ? [SavedTab()] : snapshots; $0.selectedTabID = selected }
    }
    func storeFavicon(_ image: UIImage, host: String) {
        let key = Self.faviconKey(host)
        guard !key.isEmpty else { return }
        hostIcons[key] = image
        guard let model, let data = image.pngData() else { return }
        let folder = model.directory(profileID).appendingPathComponent("Favicons", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: folder.appendingPathComponent(key + ".png"), options: .atomic)
    }
    func loadFaviconCache() {
        guard let model else { return }
        let folder = model.directory(profileID).appendingPathComponent("Favicons", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension.lowercased() == "png" {
            let key = file.deletingPathExtension().lastPathComponent
            if hostIcons[key] == nil, let image = UIImage(contentsOfFile: file.path) { hostIcons[key] = image }
        }
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
    func installPageTools(on tab: BrowserTab) {
        let hostJSON = (try? JSONSerialization.data(withJSONObject: hostCSS)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        PageTools.install(on: tab.webView.configuration.userContentController, cosmeticCSS: globalCosmetic, hostCSS: hostJSON, procedural: proceduralJSON, scriptlets: scriptletJSON, csp: cspJSON)
        tab.ensurePageHandler()
        tab.syncContentRules()
    }
    func refreshScripts() {
        guard isActive else { return }
        for tab in tabs {
            let allowed = tab.userscriptsAllowed
            tab.scriptEngine.configure(tab.webView.configuration.userContentController, scripts: allowed ? profile.scripts : [])
            installPageTools(on: tab)
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
                let world: WKContentWorld = command.isolated ? .world(name: "rikugan.script." + command.scriptID.uuidString) : .page
                _ = try await tab.webView.callAsyncJavaScript("globalThis.__rikuganCommands?.[id]?.()", arguments: ["id": command.id], in: nil, contentWorld: world)
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
    var isPrivate: Bool
    var groupID: UUID?
    var windowID: UUID?
    var autoRefreshSeconds: Int
    var contentRulesOn = false
    var installedRuleLists: [WKContentRuleList] = []
    var pageHandlerInstalled = false
    var refreshTask: Task<Void, Never>?
    var findNeedle = ""
    var findCursor = 0
    @Published var consoleLines: [String] = []
    @Published var liveTexts: [[String: String]] = []
    var webKitDownloadIDs: [ObjectIdentifier: UUID] = [:]
    var lastActiveAt = Date()
    var snapshot: SavedTab { SavedTab(id: id, url: isHome || isPrivate ? "" : address, title: pageTitle, desktop: desktop, groupID: groupID, autoRefreshSeconds: autoRefreshSeconds) }
    var userscriptsAllowed: Bool {
        let host = webView.url?.host ?? URL(string: address)?.host
        return session?.profile.site(for: host)?.userScriptsEnabled ?? true
    }

    init(saved: SavedTab, session: BrowserSession, configuration supplied: WKWebViewConfiguration? = nil) {
        id = saved.id; self.session = session; pageTitle = saved.title; address = saved.url; isHome = saved.url.isEmpty; desktop = saved.desktop
        isPrivate = saved.isPrivate; groupID = saved.groupID; autoRefreshSeconds = saved.autoRefreshSeconds
        let configuration = supplied ?? WKWebViewConfiguration()
        configuration.websiteDataStore = saved.isPrivate ? session.privateStore : session.dataStore
        configuration.webExtensionController = session.extensionController
        configuration.userContentController = WKUserContentController()
        configuration.allowsInlineMediaPlayback = true
        configuration.allowsPictureInPictureMediaPlayback = true
        configuration.allowsAirPlayForMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = .audio
        configuration.defaultWebpagePreferences.preferredContentMode = saved.desktop ? .desktop : .mobile
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        scriptEngine.tab = self
        scriptEngine.configure(configuration.userContentController, scripts: session.profile.scripts)
        webView.navigationDelegate = self; webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.isInspectable = session.profile.settings.inspectable
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
        if let url = webView.url {
            address = url.absoluteString
            session?.noteURLChange(self)
        }
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
        refreshTask?.cancel(); refreshTask = nil
        webView.stopLoading(); observations.removeAll()
        if pageHandlerInstalled {
            webView.configuration.userContentController.removeScriptMessageHandler(forName: "rikuganPage", contentWorld: .page)
            pageHandlerInstalled = false
        }
        scriptEngine.teardown(webView.configuration.userContentController)
        webView.navigationDelegate = nil; webView.uiDelegate = nil
    }
}

extension BrowserTab: WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isHome = false; restored = true
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
        if let kind = InternalPages.kind(url) {
            decisionHandler(.cancel, preferences)
            session?.requestedPanel = kind
            return
        }
        if navigationAction.targetFrame?.isMainFrame == true,
           ["http", "https"].contains(url.scheme ?? ""),
           (session?.profile.settings.contentBlocking ?? true),
           (site?.contentBlocking ?? true),
           let cleaned = session.flatMap({ AdBlockEngine.urlByStripping(url, rules: $0.removeParams) }),
           cleaned.absoluteString != url.absoluteString {
            decisionHandler(.cancel, preferences)
            webView.load(URLRequest(url: cleaned))
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
            downloads[ObjectIdentifier(download)] = url
            let expected = response.expectedContentLength
            let recordID = session?.model?.downloadCenter.noteWebKit(name: safe, fileName: url.lastPathComponent, state: "running", total: expected > 0 ? expected : 0)
            if let recordID {
                webKitDownloadIDs[ObjectIdentifier(download)] = recordID
                session?.model?.downloadCenter.attachWebKit(recordID, download: download, tab: id, file: url)
            }
            completionHandler(url)
        } catch { session?.model?.message = error.localizedDescription; completionHandler(nil) }
    }
    func downloadDidFinish(_ download: WKDownload) {
        let url = downloads.removeValue(forKey: ObjectIdentifier(download))
        if let id = webKitDownloadIDs.removeValue(forKey: ObjectIdentifier(download)) {
            session?.model?.downloadCenter.finishWebKit(id, fileName: url?.lastPathComponent ?? "download")
        }
        session?.model?.message = "下载完成：\(url?.lastPathComponent ?? "文件")。可在「文件 → 我的 iPhone → Rikugan → Downloads」找到。"
    }
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let key = ObjectIdentifier(download)
        let id = webKitDownloadIDs[key]
        if resumeData == nil, let file = downloads.removeValue(forKey: key) { try? FileManager.default.removeItem(at: file) }
        else { downloads.removeValue(forKey: key) }
        if let id {
            session?.model?.downloadCenter.failWebKit(id, resume: resumeData, message: "下载失败：\(error.localizedDescription)")
        } else {
            session?.model?.message = "下载失败：\(error.localizedDescription)"
        }
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let session else { return nil }
        let host = webView.url?.host ?? ""
        let popup = session.profile.site(for: host)?.popups ?? "allow"
        if popup == "block" { return nil }
        if popup == "ask" {
            BrowserPresentation.confirm(title: host.isEmpty ? "弹窗" : host, message: "这个网页想打开新标签页。") { allowed in
                if allowed, let url = navigationAction.request.url { session.addTab(url: url, activate: true, configuration: configuration, windowID: windowID) }
            }
            return nil
        }
        return session.addTab(activate: true, configuration: configuration, windowID: windowID).webView
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
        let kind = type == .camera ? "camera" : type == .microphone ? "microphone" : "camera-microphone"
        decide(kind, host: origin.host, decisionHandler: decisionHandler)
    }
    func webView(_ webView: WKWebView, requestGeolocationPermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decide("location", host: origin.host, decisionHandler: decisionHandler)
    }
    private func decide(_ kind: String, host: String, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        let current = session?.profile.permission(host: host, kind: kind) ?? "ask"
        if current == "allow" { decisionHandler(.grant); return }
        if current == "block" { decisionHandler(.deny); return }
        let title = ["camera": "相机", "microphone": "麦克风", "camera-microphone": "相机和麦克风", "location": "位置"][kind] ?? kind
        BrowserPresentation.choice(title: host, message: "\(title)权限") { [weak self] choice in
            if choice != "ask" {
                self?.session?.model?.updateProfile(self?.session?.profileID ?? UUID()) { profile in
                    profile.webPermissions.removeAll { $0.host == host && $0.kind == kind }
                    if choice != "ask" { profile.webPermissions.append(WebPermission(host: host, kind: kind, decision: choice)) }
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
