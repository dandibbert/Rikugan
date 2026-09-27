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

    @Published var groupID: UUID?
    @Published var title: String
    @Published private(set) var url: URL?
    @Published var favicon: UIImage?
    @Published var thumbnail: UIImage?
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
    @Published var autoRefreshInterval: TimeInterval? { didSet { scheduleAutoRefresh() } }
    @Published var storeInstallCandidate: WebStoreItem?
    @Published var hasSecureContent = true

    private(set) var webView: WKWebView?
    private var restoreState: Data?
    private var restoreURL: URL?
    private var observers: [NSKeyValueObservation] = []
    private var autoRefreshTimer: Timer?
    private var injectedForURL: URL?
    var gmTabValue: Any?
    var frames: [WKFrameInfo] = []
    var pendingExternalConfiguration: WKWebViewConfiguration?
    var translationSourceLanguage: String?

    var isHome: Bool { url == nil && webView?.url == nil }
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
        restoreState = snapshot.interactionState
        restoreURL = URL(string: snapshot.url)
        url = restoreURL
        pendingExternalConfiguration = configuration
        super.init()
        TabRegistry.shared.register(self)
        if configuration != nil { ensureWebView() }
    }

    var snapshot: TabSnapshot {
        TabSnapshot(id: id, url: (webView?.url ?? url)?.absoluteString ?? "", title: title, groupID: groupID,
                    interactionState: (webView?.interactionState as? Data) ?? restoreState,
                    desktopMode: desktopMode, lastActiveAt: lastActiveAt, pinned: pinned)
    }

    // MARK: WebView lifecycle

    @discardableResult
    func ensureWebView() -> WKWebView {
        if let webView { return webView }
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
        if url != nil || restoreState != nil { ensureWebView() }
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
                    if let u = wv.url { self.url = u }
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
        observers.removeAll()
        if let webView {
            webView.stopLoading()
            webView.navigationDelegate = nil
            webView.uiDelegate = nil
            webView.configuration.userContentController.removeAllScriptMessageHandlers()
            webView.configuration.userContentController.removeAllUserScripts()
            WebViewFactory.forget(webView.configuration.userContentController)
            webView.removeFromSuperview()
        }
        TabRegistry.shared.unregister(self)
        webView = nil
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
            Task { @MainActor in if let image { self?.thumbnail = image } }
        }
    }

    func refreshFavicon() {
        guard let webView, let pageURL = webView.url, let host = pageURL.host else { return }
        if let cached = FaviconCache.shared.image(for: host) { favicon = cached; return }
        Task {
            let script = """
            const links = Array.from(document.querySelectorAll('link[rel~="icon"], link[rel="apple-touch-icon"], link[rel="shortcut icon"]'));
            links.sort((a, b) => (parseInt((b.sizes && b.sizes.value) || '0') || 0) - (parseInt((a.sizes && a.sizes.value) || '0') || 0));
            const best = links.find(l => (l.getAttribute('rel') || '').includes('apple-touch-icon')) || links[0];
            return best ? best.href : null;
            """
            let href = (try? await webView.rkCall(script, world: Worlds.tools)) as? String
            let iconURL = href.flatMap(URL.init(string:)) ?? URL(string: "\(pageURL.scheme ?? "https")://\(host)/favicon.ico")
            guard let iconURL, let image = await FaviconCache.shared.fetch(iconURL, host: host) else { return }
            if self.webView?.url?.host == host { self.favicon = image }
        }
    }

    // MARK: Userscript / tools helpers

    func runMenuCommand(_ command: ScriptMenuCommand) {
        guard let webView, let script = profile.userscripts.script(command.scriptID) else { return }
        let world = script.metadata.runsInPageWorld ? WKContentWorld.page : Worlds.userscript(script.id)
        let fn = "__rikuganGM_" + profile.userscripts.token(for: script.id)
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
        menuCommands.removeAll()
        sniffedMedia.removeAll()
        consoleEntries.removeAll()
        translation = .idle
        frames.removeAll()
        frameRecords.removeAll()
        injectedScripts.removeAll()
        storeInstallCandidate = WebStoreItem.detect(url: webView?.url)
    }

    func markInjected(for url: URL) { injectedForURL = url }
    /// Forces the next navigation to rebuild injected scripts (e.g. after GM values changed).
    func invalidateInjection() { injectedForURL = nil }

    /// Frames reported by the tools world (used by scripting.executeScript allFrames / frameIds).
    private(set) var frameRecords: [LoadedExtension.FrameRecord] = []

    func registerFrame(_ frame: WKFrameInfo) {
        guard !frame.isMainFrame else { return }
        let url = frame.request.url?.absoluteString ?? ""
        if frameRecords.contains(where: { $0.url == url }) { return }
        let id = 1000 + frameRecords.count
        frameRecords.append(.init(frameID: id, frame: frame, url: url))
    }
    var lastInjectedURL: URL? { injectedForURL }
}

/// Small in-memory favicon cache.
@MainActor final class FaviconCache {
    static let shared = FaviconCache()
    private var images: [String: UIImage] = [:]

    func image(for host: String) -> UIImage? { images[host] }

    func fetch(_ url: URL, host: String) async -> UIImage? {
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        guard let (data, _) = try? await URLSession.shared.data(for: request), let image = UIImage(data: data) else { return nil }
        images[host] = image
        return image
    }
}
