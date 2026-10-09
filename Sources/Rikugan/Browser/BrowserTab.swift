import Foundation
import WebKit
import UIKit
import Combine

struct ScriptMenuCommand: Identifiable, Hashable {
    let scriptID: UUID
    let commandID: String
    let scriptName: String
    let title: String
    var id: String { scriptID.uuidString + ":" + commandID }
}

struct MediaItem: Identifiable, Hashable {
    var url: URL
    var kind: String          // video, audio, hls, dash, image
    var source: String        // dom, network, fetch, xhr, response
    var width: Int = 0
    var height: Int = 0
    var duration: Double = 0
    var size: Int64 = 0
    var contentType: String = ""
    var id: String { url.absoluteString }
    var fileName: String {
        let name = url.lastPathComponent
        return name.isEmpty || name == "/" ? (url.host ?? "media") : name
    }
}

struct ConsoleEntry: Identifiable, Hashable {
    let id = UUID()
    let level: String
    let text: String
    let date = Date()
}

enum TranslationState: Equatable {
    case idle, translating(progress: Double), translated(showingOriginal: Bool), failed(String)
}

/// One browser tab. The WKWebView is created once and kept alive for the lifetime of the tab, so
/// DOM, scroll position, JS state, media playback and WebSockets survive tab switching (spec §3.1).
@MainActor final class BrowserTab: NSObject, ObservableObject, Identifiable {
    let id: UUID
    let numericID: Int
    let profile: ProfileContext
    let isPrivate: Bool
    weak var manager: TabManager?
    weak var opener: BrowserTab?
    /// The tab has shown a real page (a main-frame document other than about:blank committed, or
    /// it was restored with one). A tab that never has exists only for a download it started and
    /// is closed when that download ends (DownloadManager.closeDownloadOnlyTab).
    private(set) var hasShownPage = false

    @Published var groupID: UUID?
    @Published var title: String
    @Published private(set) var url: URL?
    @Published var favicon: UIImage?
    @Published var thumbnail: UIImage?
    /// Find in page: shown in place of the address bar while active.
    @Published var findActive = false
    @Published var findResult: (count: Int, index: Int) = (0, -1)
    /// Bumped when a main-frame load finishes, so an open find bar searches the new document.
    @Published private(set) var loadsFinished = 0
    func noteLoadFinished() { loadsFinished += 1 }
    @Published private(set) var progress: Double = 0
    @Published private(set) var isLoading = false
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published var desktopMode: Bool
    @Published var lastActiveAt: Date
    @Published var pinned = false
    @Published var menuCommands: [ScriptMenuCommand] = []
    @Published var sniffedMedia: [MediaItem] = []
    @Published var consoleEntries: [ConsoleEntry] = []
    @Published var translation: TranslationState = .idle
    @Published var loadError: String?
    @Published var injectedScripts: Set<UUID> = []
    /// Frames (by per-document token) each userscript runs in, so GM value changes reach every
    /// frame of every tab running the script, not only main frames.
    var scriptFrames: [UUID: [String: WKFrameInfo]] = [:]
    /// Site permission answers that are not stored in site settings: "allow once", and every
    /// answer in a private tab. Keyed "<permission>|<host>"; they live as long as the tab.
    var sessionPermissions: [String: Bool] = [:]
    func sessionPermission(_ key: String, host: String) -> Bool? { sessionPermissions[key + "|" + host.lowercased()] }
    func setSessionPermission(_ key: String, host: String, _ value: Bool) { sessionPermissions[key + "|" + host.lowercased()] = value }
    @Published var autoRefreshInterval: TimeInterval? { didSet { scheduleAutoRefresh() } }
    @Published var storeInstallCandidate: WebStoreItem?
    @Published var hasSecureContent = true
    /// Explicit lifecycle (active / liveBackground / suspended / restoring / terminated).
    @Published private(set) var lifecycle: TabLifecycleState = .suspended
    /// Scroll offset captured at suspension, re-applied after restore.
    private(set) var lastScrollY: Double?
    private var pendingScrollRestore: Double?
    private(set) var suspendCount = 0
    private(set) var restoreCount = 0

    private(set) var webView: WKWebView?
    private var restoreState: Data?
    private var restoreURL: URL?
    private var observers: [NSKeyValueObservation] = []
    private var autoRefreshTimer: Timer?
    private var injectedForURL: URL?
    /// Tab mute set by GM_audio.setMute; re-applied to every document loaded in this tab.
    @Published var audioMuted = false
    var gmTabValue: Any?
    var frames: [WKFrameInfo] = []
    var pendingExternalConfiguration: WKWebViewConfiguration?
    var translationSourceLanguage: String?
    /// Current translation run; a new run, stop or navigation cancels it (see TranslationCoordinator).
    var translationTask: Task<Void, Never>?
    var translationGeneration = 0
    var translationTarget: String?

    /// Set by `goHome` on a tab that already has a web view: it then holds an empty document
    /// (about:blank), which must not count as a page.
    @Published private(set) var showsHome = false
    var isHome: Bool { showsHome || (url == nil && webView?.url == nil) }
    var host: String? { url?.host?.lowercased() }
    var services: AppServices { AppServices.shared }
    var siteSettings: SiteSettings { profile.siteSettings.settings(for: host) }

    init(snapshot: TabSnapshot, profile: ProfileContext, isPrivate: Bool, configuration: WKWebViewConfiguration? = nil) {
        id = snapshot.id
        numericID = TabRegistry.shared.allocateTabID()
        self.profile = profile
        self.isPrivate = isPrivate
        title = snapshot.title
        groupID = snapshot.groupID
        desktopMode = snapshot.desktopMode
        lastActiveAt = snapshot.lastActiveAt
        pinned = snapshot.pinned
        lastScrollY = snapshot.scrollY
        hasShownPage = !snapshot.url.isEmpty
        pendingScrollRestore = snapshot.scrollY
        restoreState = snapshot.interactionState
        restoreURL = URL(string: snapshot.url)
        url = restoreURL
        pendingExternalConfiguration = configuration
        super.init()
        TabRegistry.shared.register(self)
        if !isPrivate { thumbnail = TabThumbnailStore.load(id) }
        if configuration != nil { ensureWebView() }
    }

    var snapshot: TabSnapshot {
        TabSnapshot(id: id, url: (webView?.url ?? url)?.absoluteString ?? "", title: title, groupID: groupID,
                    interactionState: (webView?.interactionState as? Data) ?? restoreState,
                    desktopMode: desktopMode, lastActiveAt: lastActiveAt, pinned: pinned, scrollY: lastScrollY)
    }

    // MARK: WebView lifecycle

    @discardableResult
    func ensureWebView() -> WKWebView {
        if let webView { return webView }
        if lifecycle == .suspended || lifecycle == .terminated || lifecycle == .restoring { lifecycle = .restoring; restoreCount += 1 }
        let webView = WebViewFactory.makeWebView(for: self, configuration: pendingExternalConfiguration)
        pendingExternalConfiguration = nil
        self.webView = webView
        TabRegistry.shared.register(webView: webView, for: self)
        observe(webView)
        if let state = restoreState {
            restoreState = nil
            webView.interactionState = state
            if webView.url == nil, let restoreURL { load(restoreURL) }
        } else if let restoreURL, webView.url == nil {
            load(restoreURL)
        }
        restoreURL = nil
        return webView
    }

    /// Called when the tab becomes visible: lazily restores the saved page.
    func activate() {
        lastActiveAt = Date()
        if webView == nil, url != nil || restoreState != nil {
            // Restore on the next main-loop turn, and only if this tab is still the selected one:
            // rapid switching through many suspended tabs then restores just the final tab
            // instead of creating (and immediately suspending) a web view for each one.
            lifecycle = .restoring
            DispatchQueue.main.async { [weak self] in
                guard let self, self.manager?.activeTabID == self.id, self.webView == nil else { return }
                self.ensureWebView()
            }
            return
        }
        if lifecycle != .restoring || webView?.isLoading == false { lifecycle = .active }
    }

    /// The tab lost focus but keeps its live web view.
    func deactivate() {
        // Capture the scroll position now, while the web view is still on screen: once detached,
        // WebKit may lay it out at zero size and report 0.
        if let scrollView = webView?.scrollView, lifecycle == .active {
            let offset = scrollView.contentOffset.y + scrollView.adjustedContentInset.top
            lastScrollY = max(0, Double(offset / max(scrollView.zoomScale, 0.01)))
        }
        guard lifecycle == .active || lifecycle == .restoring else { return }
        // A start-page tab has no web view: it is not live in the background.
        lifecycle = webView == nil ? .suspended : .liveBackground
    }

    var isLive: Bool { webView != nil }

    /// Releases the WKWebView while keeping identity, URL, title, favicon, snapshot, group,
    /// history (interactionState) and scroll position. JS state, WebSockets and unsaved form
    /// content are lost and the page reloads on restore — this is accepted, not hidden.
    func suspend() async {
        // A background tab that is still loading (or failed to load) is `.restoring`; it counts
        // against the live budget and can be suspended too — only the selected tab is exempt.
        guard let webView, lifecycle == .liveBackground || lifecycle == .restoring, manager?.activeTabID != id else { return }
        // Prefer the position captured on deactivation; a detached web view can report 0.
        if let y = (try? await webView.rkCall("return window.scrollY || 0;", world: Worlds.tools)) as? Double, y > 0 || lastScrollY == nil { lastScrollY = y }
        // Re-check after the await: the tab may have been selected meanwhile (it is then
        // `.restoring` or `.active` and the current tab) — never release the visible web view.
        guard self.webView === webView, lifecycle == .liveBackground || lifecycle == .restoring, manager?.activeTabID != id else { return }
        captureThumbnail()
        restoreState = (webView.interactionState as? Data) ?? restoreState
        restoreURL = webView.url ?? url
        pendingScrollRestore = lastScrollY
        releaseWebView()
        lifecycle = .suspended
        suspendCount += 1
        manager?.scheduleSave()
    }

    /// WebContent process died: the page cannot be recovered losslessly.
    func contentProcessTerminated() {
        guard let webView else { return }
        if lifecycle == .active {
            markInjected(for: URL(string: "about:terminated")!)
            lifecycle = .restoring
            webView.reload()
            return
        }
        restoreState = (webView.interactionState as? Data) ?? restoreState
        restoreURL = webView.url ?? url
        releaseWebView()
        lifecycle = .terminated
    }

    /// Called after a restored page finished loading.
    func restoreFinished() {
        if lifecycle == .restoring { lifecycle = manager?.activeTabID == id ? .active : .liveBackground }
        guard let y = pendingScrollRestore, y > 0, let webView else { pendingScrollRestore = nil; return }
        pendingScrollRestore = nil
        webView.rkEval("if ((window.scrollY || 0) < 1) window.scrollTo(0, \(y));", world: Worlds.tools)
    }

    private func releaseWebView() {
        guard let webView else { return }
        observers.removeAll()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
        webView.configuration.userContentController.removeAllUserScripts()
        WebViewFactory.forget(webView.configuration.userContentController)
        webView.removeFromSuperview()
        TabRegistry.shared.unregister(webView: webView)
        profile.extensions.tabRemoved(self, closing: false)
        self.webView = nil
        injectedForURL = nil
        frameRecords.removeAll()
        isLoading = false
        progress = 0
    }

    private func observe(_ webView: WKWebView) {
        observers = [
            webView.observe(\.title, options: [.new]) { [weak self] wv, _ in
                Task { @MainActor in
                    guard let self else { return }
                    let t = wv.title ?? ""
                    if !t.isEmpty { self.title = t } else if let host = wv.url?.host { self.title = host }
                    if !self.isPrivate, let url = wv.url { self.profile.history.updateTitle(url: url, title: t) }
                }
            },
            webView.observe(\.url, options: [.new]) { [weak self] wv, _ in
                Task { @MainActor in
                    guard let self else { return }
                    if let u = wv.url, !(self.showsHome && u.absoluteString == "about:blank") { self.url = u; self.showsHome = false }
                    // Both web stores are single-page apps: opening a listing from the store's home
                    // changes the URL without a new document, so the install bar follows the URL.
                    let candidate = WebStoreItem.detect(url: wv.url)
                    if candidate != self.storeInstallCandidate { self.storeInstallCandidate = candidate }
                    self.manager?.scheduleSave()
                }
            },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] wv, _ in
                Task { @MainActor in self?.progress = wv.estimatedProgress }
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self] wv, _ in
                Task { @MainActor in self?.isLoading = wv.isLoading }
            },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] wv, _ in
                Task { @MainActor in self?.canGoBack = wv.canGoBack }
            },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] wv, _ in
                Task { @MainActor in self?.canGoForward = wv.canGoForward }
            },
            webView.observe(\.hasOnlySecureContent, options: [.new]) { [weak self] wv, _ in
                Task { @MainActor in self?.hasSecureContent = wv.hasOnlySecureContent }
            },
        ]
    }

    func teardown() {
        autoRefreshTimer?.invalidate()
        releaseWebView()
        TabRegistry.shared.unregister(self)
        lifecycle = .suspended
    }

    // MARK: Navigation

    func load(_ target: URL) {
        loadError = nil
        let webView = ensureWebView()
        if target.isFileURL {
            webView.loadFileURL(target, allowingReadAccessTo: target.deletingLastPathComponent())
        } else {
            WebViewFactory.prepareContent(for: self, url: target)
            webView.load(URLRequest(url: target))
        }
        url = target
        showsHome = false
    }

    func loadInput(_ text: String) {
        let prefs = services.prefs
        switch Omnibox.classify(text, shortcuts: prefs.shortcuts) {
        case .url(let target): load(target)
        case .internalPage(let page): InternalPages.open(page, from: self)
        case .search(let query):
            guard !query.isEmpty, let target = prefs.searchEngine.searchURL(for: query) else { return }
            if !isPrivate { profile.history.recordSearch(query) }
            load(target)
        }
    }

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }
    func reload() {
        loadError = nil
        guard let webView else { if let url { load(url) }; return }
        if webView.url == nil, let url { load(url) } else { webView.reload() }
    }
    func stop() { webView?.stopLoading() }
    func goHome() {
        webView?.stopLoading()
        let mode = services.prefs.homepageMode
        if mode == .custom, let target = URL(string: services.prefs.homepageURL), target.scheme != nil {
            load(target)
        } else if let webView {
            webView.loadHTMLString("", baseURL: nil)
            url = nil
            showsHome = true
            title = "起始页"
        }
    }

    func toggleDesktopMode() {
        desktopMode.toggle()
        if let host {
            let value = desktopMode
            profile.siteSettings.update(host) { $0.desktopMode = value == services.prefs.defaultDesktopMode ? nil : value }
        }
        if let webView {
            webView.customUserAgent = nil
            if let current = webView.url { WebViewFactory.prepareContent(for: self, url: current) }
            webView.reloadFromOrigin()
        }
    }

    /// Re-applies dark mode / fonts to the current page without reload.
    func applyLiveStyles() {
        guard let webView, let host else { return }
        let dark = WebViewFactory.darkModeConfig(host: host, profile: profile)
        let font = WebViewFactory.fontConfig(host: host, profile: profile)
        Task {
            _ = await webView.rkTools("applyDarkMode", [dark as Any])
            _ = await webView.rkTools("applyFont", [font ?? NSNull()])
        }
    }

    func setPageDarkMode(_ value: TriState?) {
        guard let host else { return }
        profile.siteSettings.update(host) { $0.darkMode = value }
        applyLiveStyles()
    }

    // MARK: Auto refresh (spec §32) – only while the app is active.

    private func scheduleAutoRefresh() {
        autoRefreshTimer?.invalidate()
        autoRefreshTimer = nil
        guard let interval = autoRefreshInterval, interval >= 1 else { return }
        autoRefreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, UIApplication.shared.applicationState == .active, !(self.webView?.isLoading ?? true) else { return }
                self.webView?.reload()
            }
        }
    }

    // MARK: Snapshots / favicon

    func captureThumbnail() {
        guard let webView, webView.window != nil, webView.bounds.width > 0 else { return }
        let config = WKSnapshotConfiguration()
        config.snapshotWidth = 360
        webView.takeSnapshot(with: config) { [weak self] image, _ in
            Task { @MainActor in
                guard let self, let image else { return }
                self.thumbnail = image
                if !self.isPrivate { TabThumbnailStore.save(image, for: self.id) }
            }
        }
    }

    func refreshFavicon() {
        guard let webView, let pageURL = webView.url, let host = pageURL.host else { return }
        let cache = isPrivate ? FaviconCache.privateSession : FaviconCache.shared
        if let cached = cache.image(for: host) { favicon = cached; return }
        Task {
            let script = """
            const links = Array.from(document.querySelectorAll('link[rel~="icon"], link[rel="apple-touch-icon"], link[rel="shortcut icon"]'));
            links.sort((a, b) => (parseInt((b.sizes && b.sizes.value) || '0') || 0) - (parseInt((a.sizes && a.sizes.value) || '0') || 0));
            const best = links.find(l => (l.getAttribute('rel') || '').includes('apple-touch-icon')) || links[0];
            return best ? best.href : null;
            """
            let href = (try? await webView.rkCall(script, world: Worlds.tools)) as? String
            let iconURL = href.flatMap(URL.init(string:)) ?? URL(string: "\(pageURL.scheme ?? "https")://\(host)/favicon.ico")
            guard let iconURL, let image = await cache.fetch(iconURL, host: host) else { return }
            if self.webView?.url?.host == host { self.favicon = image }
        }
    }

    // MARK: Userscript / tools helpers

    func runMenuCommand(_ command: ScriptMenuCommand) {
        guard let webView, let script = profile.userscripts.script(command.scriptID), !script.usesPageWorld else { return }
        let world = Worlds.userscript(script.id)
        let fn = UserScriptStore.dispatchFunctionName(script.id)
        webView.rkEval("window[\(fn.jsLiteral)] && window[\(fn.jsLiteral)]({type:'menu', id:\(command.commandID.jsLiteral)})", world: world)
    }

    func appendConsole(level: String, text: String) {
        consoleEntries.append(ConsoleEntry(level: level, text: text))
        if consoleEntries.count > 500 { consoleEntries.removeFirst(consoleEntries.count - 500) }
    }

    func addSniffedMedia(_ item: MediaItem) {
        guard !sniffedMedia.contains(where: { $0.url == item.url }) else { return }
        sniffedMedia.append(item)
    }

    /// Clears per-document state when a new main-frame document commits.
    func documentDidCommit() {
        if let scheme = webView?.url?.scheme?.lowercased(), scheme != "about" { hasShownPage = true }
        if findActive { findResult = (0, -1) }
        menuCommands.removeAll()
        sniffedMedia.removeAll()
        consoleEntries.removeAll()
        translationTask?.cancel()
        translationGeneration += 1
        translationTarget = nil
        translation = .idle
        frames.removeAll()
        frameRecords.removeAll()
        injectedScripts.removeAll()
        scriptFrames.removeAll()
        storeInstallCandidate = WebStoreItem.detect(url: webView?.url)
    }

    func markInjected(for url: URL) { injectedForURL = url }
    /// Forces the next navigation to rebuild injected scripts (e.g. after GM values changed).
    func invalidateInjection() { injectedForURL = nil }

    /// Frames reported by the tools world (used by scripting.executeScript allFrames / frameIds).
    private(set) var frameRecords: [LoadedExtension.FrameRecord] = []

    /// Identified by the per-document token the tools world generates, not by URL.
    func registerFrame(_ frame: WKFrameInfo, token: String?) {
        guard !frame.isMainFrame else { return }
        let url = frame.request.url?.absoluteString ?? ""
        let token = token ?? UUID().uuidString
        if frameRecords.contains(where: { $0.token == token }) { return }
        let id = 1000 + (frameRecords.map(\.frameID).max().map { $0 - 999 } ?? 0)
        frameRecords.append(.init(frameID: id, frame: frame, url: url, token: token))
    }

    func unregisterFrame(token: String) { frameRecords.removeAll { $0.token == token } }
    var lastInjectedURL: URL? { injectedForURL }
}

/// Small in-memory favicon cache.
/// Favicons are fetched without cookies and without any shared URL cache, so loading an icon
/// never writes to (or reads from) a cookie jar or disk cache. Private tabs use their own
/// in-memory cache, cleared when the private session ends.
@MainActor final class FaviconCache {
    static let shared = FaviconCache()
    static let privateSession = FaviconCache()
    private var images: [String: UIImage] = [:]
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    func image(for host: String) -> UIImage? { images[host] }

    func fetch(_ url: URL, host: String) async -> UIImage? {
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        guard let (data, _) = try? await session.data(for: request), let image = UIImage(data: data) else { return nil }
        images[host] = image
        return image
    }

    func clear() {
        images.removeAll()
        session.invalidateAndCancel()
        session = { let c = URLSessionConfiguration.ephemeral; c.httpShouldSetCookies = false; c.httpCookieAcceptPolicy = .never
                    c.httpCookieStorage = nil; c.urlCache = nil; return URLSession(configuration: c) }()
    }
}


/// Tab thumbnails on disk (Caches/TabThumbnails/<tab id>.jpg) so the tab switcher still has them
/// after the app is relaunched. Private tabs are never written. Removed when the tab is closed.
@MainActor enum TabThumbnailStore {
    private static var directory: URL {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("TabThumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private static func file(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".jpg") }

    static func load(_ id: UUID) -> UIImage? {
        guard AppServices.shared.prefs.persistTabThumbnails else { return nil }
        return UIImage(contentsOfFile: file(id).path)
    }

    static func save(_ image: UIImage, for id: UUID) {
        guard AppServices.shared.prefs.persistTabThumbnails, let data = image.jpegData(compressionQuality: 0.6) else { return }
        let target = file(id)
        DispatchQueue.global(qos: .utility).async { try? data.write(to: target, options: .atomic) }
    }

    static func remove(_ id: UUID) { try? FileManager.default.removeItem(at: file(id)) }

}
