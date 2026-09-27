import Foundation
import WebKit
import UIKit
import Combine

/// Chrome MV3 compatibility runtime for one profile (spec §13): installation state, background
/// runtimes, content scripts, extension pages, storage, events, DNR and the chrome.* bridge.
@MainActor final class ExtensionRuntime: ObservableObject {
    unowned let profile: ProfileContext
    @Published private(set) var records: [InstalledExtension] = []
    @Published private(set) var loaded: [String: LoadedExtension] = [:]
    @Published var popup: PopupRequest?
    @Published var permissionRequest: PermissionPrompt?
    private(set) var dnrLists: [WKContentRuleList] = []
    private(set) lazy var bridge = ChromeAPIBridge(runtime: self)
    let scheme: String
    let directory: URL
    private let indexFile: JSONFile<[InstalledExtension]>
    private lazy var schemeHandler = ExtensionSchemeHandler(runtime: self)
    /// Extension pages (popup, options, extension tabs) keyed by webView.
    private var pages: [ObjectIdentifier: (webView: WeakBox<WKWebView>, extID: String, kind: String)] = [:]
    private var started = false

    struct PopupRequest: Identifiable {
        let id = UUID()
        let extID: String
        let url: URL
        let tabID: Int?
        let title: String
    }

    struct PermissionPrompt: Identifiable {
        let id = UUID()
        let extName: String
        let lines: [PermissionDescriber.Line]
        let completion: (Bool) -> Void
    }

    init(profile: ProfileContext) {
        self.profile = profile
        scheme = WKWebView.handlesURLScheme("chrome-extension") ? "rikugan-extension" : "chrome-extension"
        directory = AppPaths.directory("Extensions", in: profile.directory)
        indexFile = JSONFile(directory.appendingPathComponent("extensions.json"))
        records = indexFile.load() ?? []
    }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        for record in records where record.enabled { load(record, reason: "startup") }
        compileDNR()
    }

    func shutdown() {
        for ext in loaded.values { unload(ext) }
        loaded.removeAll()
        started = false
    }

    private func extensionDirectory(_ id: String) -> URL { directory.appendingPathComponent(id, isDirectory: true) }

    @discardableResult
    private func load(_ record: InstalledExtension, reason: String, previousVersion: String? = nil) -> LoadedExtension? {
        let dir = extensionDirectory(record.id)
        do {
            let manifest = try ExtensionManifest(data: Data(contentsOf: dir.appendingPathComponent("manifest.json")))
            let ext = LoadedExtension(record: record, manifest: manifest, directory: dir, scheme: scheme)
            loaded[record.id] = ext
            if manifest.backgroundKind != "none" {
                let host = BackgroundHost(ext: ext, runtime: self)
                ext.background = host
                host.start {
                    switch reason {
                    case "install": self.dispatch(ext, "runtime.onInstalled", [["reason": "install"]])
                    case "update": self.dispatch(ext, "runtime.onInstalled", [["reason": "update", "previousVersion": previousVersion ?? ""]])
                    case "startup": self.dispatch(ext, "runtime.onStartup", [])
                    default: break
                    }
                }
            }
            updateRecord(record.id) { $0.lastErrors = [] }
            return ext
        } catch {
            updateRecord(record.id) { $0.lastErrors = [error.localizedDescription] }
            return nil
        }
    }

    private func unload(_ ext: LoadedExtension) {
        ext.background?.stop()
        ext.background = nil
        for alarm in ext.alarms.values { alarm.timer?.invalidate() }
        ext.alarms.removeAll()
    }

    /// Observed chrome.* traffic per extension (calls / errors per API and context). Used by the
    /// Diagnostics page and the real-extension compatibility report — evidence, not claims.
    struct APIStat: Codable { var calls = 0; var errors = 0; var contexts: Set<String> = []; var lastError: String? }
    private(set) var apiStats: [String: [String: APIStat]] = [:]

    func recordAPICall(_ extID: String, api: String, context: String, error: String?) {
        guard !extID.isEmpty, !api.isEmpty else { return }
        var stat = apiStats[extID, default: [:]][api, default: APIStat()]
        stat.calls += 1
        stat.contexts.insert(context)
        if let error { stat.errors += 1; stat.lastError = String(error.prefix(200)) }
        apiStats[extID, default: [:]][api] = stat
    }

    /// Unsupported chrome.* calls per extension (shown in Diagnostics / compatibility reports).
    @Published private(set) var unsupportedCalls: [String: [String: Int]] = [:]

    func recordUnsupported(_ ext: LoadedExtension, _ api: String) {
        unsupportedCalls[ext.id, default: [:]][api, default: 0] += 1
    }

    func recordRuntimeError(_ ext: LoadedExtension, _ message: String) {
        updateRecord(ext.id) { record in
            record.lastErrors.append(message)
            if record.lastErrors.count > 20 { record.lastErrors.removeFirst(record.lastErrors.count - 20) }
        }
        ErrorLog.shared.record(message, source: ext.displayName)
    }

    func updateRecord(_ id: String, _ change: (inout InstalledExtension) -> Void) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        change(&records[index])
        loaded[id]?.record = records[index]
        indexFile.save(records)
    }

    // MARK: Install / remove / enable (spec §18)

    func install(_ pending: PendingExtensionInstall) throws {
        let destination = extensionDirectory(pending.extensionID)
        let previous = records.first { $0.id == pending.extensionID }
        if let ext = loaded[pending.extensionID] { unload(ext); loaded.removeValue(forKey: pending.extensionID) }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: pending.stagingDirectory, to: destination)
        let now = Date()
        let record = InstalledExtension(
            id: pending.extensionID, name: pending.displayName, version: pending.manifest.version,
            description: loadedDescription(pending), enabled: previous?.enabled ?? true,
            installedAt: previous?.installedAt ?? now, updatedAt: now, source: pending.source, storeURL: pending.storeURL ?? previous?.storeURL,
            grantedPermissions: pending.requestedPermissions,
            grantedHosts: Array(Set(pending.requestedHosts + (previous?.grantedHosts.filter { h in pending.manifest.optionalHostPermissions.contains(h) } ?? []))),
            hostAccess: previous?.hostAccess ?? .granted, enabledRulesets: previous?.enabledRulesets,
            dynamicScripts: previous?.dynamicScripts ?? [], dynamicRulesJSON: previous?.dynamicRulesJSON ?? "[]")
        if let index = records.firstIndex(where: { $0.id == record.id }) { records[index] = record } else { records.append(record) }
        indexFile.save(records)
        if record.enabled { load(record, reason: previous == nil ? "install" : "update", previousVersion: previous?.version) }
        compileDNR()
        WebViewFactory.invalidateAllTabs()
    }

    private func loadedDescription(_ pending: PendingExtensionInstall) -> String {
        ExtensionLocalization.load(from: pending.stagingDirectory, defaultLocale: pending.manifest.defaultLocale, preferred: Locale.preferredLanguages)
            .localize(pending.manifest.description, extensionID: pending.extensionID) ?? pending.manifest.description
    }

    func setEnabled(_ id: String, _ enabled: Bool) {
        updateRecord(id) { $0.enabled = enabled }
        if enabled, let record = records.first(where: { $0.id == id }) { load(record, reason: "enable") }
        else if let ext = loaded.removeValue(forKey: id) { unload(ext) }
        compileDNR()
        WebViewFactory.invalidateAllTabs()
    }

    func remove(_ id: String) {
        if let ext = loaded.removeValue(forKey: id) { unload(ext) }
        records.removeAll { $0.id == id }
        indexFile.save(records)
        try? FileManager.default.removeItem(at: extensionDirectory(id))
        for area in ["local", "sync"] { try? FileManager.default.removeItem(at: storageURL(id, area)) }
        compileDNR()
        WebViewFactory.invalidateAllTabs()
    }

    func reload(_ id: String) {
        guard let record = records.first(where: { $0.id == id }) else { return }
        if let ext = loaded.removeValue(forKey: id) { unload(ext) }
        if record.enabled { load(record, reason: "reload") }
        WebViewFactory.invalidateAllTabs()
    }

    func setHostAccess(_ id: String, _ access: InstalledExtension.HostAccess) {
        updateRecord(id) { $0.hostAccess = access }
        WebViewFactory.invalidateAllTabs()
    }

    func revokeHost(_ id: String, pattern: String) {
        updateRecord(id) { $0.grantedHosts.removeAll { $0 == pattern } }
        WebViewFactory.invalidateAllTabs()
    }

    func grantHost(_ id: String, pattern: String) {
        updateRecord(id) { if !$0.grantedHosts.contains(pattern) { $0.grantedHosts.append(pattern) } }
        WebViewFactory.invalidateAllTabs()
    }

    var enabledExtensions: [LoadedExtension] {
        records.filter(\.enabled).compactMap { loaded[$0.id] }
    }

    /// Extensions with a toolbar action.
    var toolbarExtensions: [LoadedExtension] { enabledExtensions }

    // MARK: Scheme handler / extension pages

    func installSchemeHandler(on configuration: WKWebViewConfiguration) {
        if configuration.urlSchemeHandler(forURLScheme: scheme) == nil {
            configuration.setURLSchemeHandler(schemeHandler, forURLScheme: scheme)
        }
    }

    func extensionID(of url: URL?) -> String? {
        guard let url, url.scheme == scheme else { return nil }
        return url.host
    }

    func canNavigate(to url: URL, from current: URL?) -> Bool {
        guard let id = url.host, let ext = loaded[id] else { return false }
        if current?.scheme == scheme || current == nil { return true }
        return ext.manifest.isWebAccessible(url.path, from: current) || url.path.hasSuffix(".html")
    }

    /// Configuration for popup / options / background pages.
    func extensionPageConfiguration(for ext: LoadedExtension, kind: String) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = profile.dataStore
        configuration.userContentController = WKUserContentController()
        installSchemeHandler(on: configuration)
        configuration.applicationNameForUserAgent = WebViewFactory.safariUserAgentSuffix
        configuration.allowsInlineMediaPlayback = true
        configuration.userContentController.addUserScript(WKUserScript(source: shimSource(ext, ctx: kind == "background" ? "background" : "page"),
                                                                       injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
        configuration.userContentController.addScriptMessageHandler(profile.bridge, contentWorld: .page, name: Worlds.messageHandlerName)
        return configuration
    }

    func registerPage(_ webView: WKWebView, extID: String, kind: String) {
        pages[ObjectIdentifier(webView)] = (WeakBox(webView), extID, kind)
    }

    func unregisterPage(_ webView: WKWebView) { pages.removeValue(forKey: ObjectIdentifier(webView)) }

    func pageKind(of webView: WKWebView?) -> String? {
        guard let webView else { return nil }
        if let entry = pages[ObjectIdentifier(webView)] { return entry.kind }
        if let tab = TabRegistry.shared.tab(for: webView), tab.webView?.url?.scheme == scheme { return "tab" }
        return nil
    }

    /// All live extension page web views of `ext` (background, popup, options, tabs).
    func extensionPages(of ext: LoadedExtension) -> [(WKWebView, String)] {
        var result: [(WKWebView, String)] = []
        if let bg = ext.background?.webView, ext.background?.isReady == true { result.append((bg, "background")) }
        for entry in pages.values where entry.extID == ext.id {
            if let wv = entry.webView.value { result.append((wv, entry.kind)) }
        }
        for tab in TabRegistry.shared.allTabs where tab.webView?.url?.scheme == scheme && tab.webView?.url?.host == ext.id {
            if let wv = tab.webView { result.append((wv, "tab")) }
        }
        return result
    }

    func shimSource(_ ext: LoadedExtension, ctx: String) -> String {
        var manifest = ext.manifest.raw
        manifest.removeValue(forKey: "key")
        let languages = Locale.preferredLanguages
        let config: [String: Any] = [
            "extId": ext.id, "ctx": ctx, "handler": Worlds.messageHandlerName, "baseURL": ext.baseURL,
            "manifest": manifest, "messages": ext.localization.jsonMessages, "uiLanguage": languages.first ?? "en",
            "uiLocale": ext.localization.locale, "acceptLanguages": languages,
            "unsupported": ChromeAPIMatrix.unsupportedNamespaces,
        ]
        return JSResource.fill("ChromeRuntime", marker: "__RK_CHROME_CONFIG__", config: config)
    }

    // MARK: Content scripts (spec §14)

    struct ContentScriptItem {
        let source: String
        let time: WKUserScriptInjectionTime
        let mainFrameOnly: Bool
        let world: WKContentWorld
    }

    func contentScripts(for url: URL, tab: BrowserTab) -> [ContentScriptItem] {
        var items: [ContentScriptItem] = []
        if url.scheme == scheme {
            if let id = url.host, let ext = loaded[id], ext.record.enabled {
                items.append(ContentScriptItem(source: shimSource(ext, ctx: "page"), time: .atDocumentStart, mainFrameOnly: false, world: .page))
            }
            return items
        }
        if tab.isPrivate { return items } // Extensions are not allowed in private tabs by default (Chrome "Allow in Incognito" off).
        for ext in enabledExtensions {
            let entries = ext.manifest.contentScripts + ext.record.dynamicScripts
            guard !entries.isEmpty else { continue }
            let isolated = Worlds.extensionWorld(ext.id)
            var mainEntries: [ContentScriptEntry] = []
            var frameEntries: [ContentScriptEntry] = []
            for entry in entries {
                if entry.matches(url), ext.hostAllowed(url, tabID: tab.numericID) { mainEntries.append(entry) }
                if entry.allFrames { frameEntries.append(entry) }
            }
            guard !mainEntries.isEmpty || !frameEntries.isEmpty else { continue }
            // chrome.* shim in the isolated world first.
            let needsShimMain = mainEntries.contains { $0.world != "MAIN" }
            let needsShimFrames = frameEntries.contains { $0.world != "MAIN" }
            if needsShimMain || needsShimFrames {
                items.append(ContentScriptItem(source: shimSource(ext, ctx: "content"), time: .atDocumentStart,
                                               mainFrameOnly: !needsShimFrames, world: isolated))
            }
            for entry in mainEntries {
                let world = entry.world == "MAIN" ? WKContentWorld.page : isolated
                let time: WKUserScriptInjectionTime = entry.runAt == "document_start" ? .atDocumentStart : .atDocumentEnd
                if !entry.css.isEmpty {
                    let css = entry.css.compactMap { ext.text($0) }.joined(separator: "\n")
                    items.append(ContentScriptItem(source: Self.cssInjector(css, guardJS: nil), time: .atDocumentStart, mainFrameOnly: true, world: world))
                }
                for file in entry.js {
                    guard let code = ext.text(file) else { continue }
                    items.append(ContentScriptItem(source: code + "\n//# sourceURL=\(ext.baseURL)\(file)", time: time, mainFrameOnly: true, world: world))
                }
            }
            for entry in frameEntries {
                let world = entry.world == "MAIN" ? WKContentWorld.page : isolated
                let time: WKUserScriptInjectionTime = entry.runAt == "document_start" ? .atDocumentStart : .atDocumentEnd
                let include = entry.includeRules().map { "[\($0.regex.jsLiteral),\($0.caseInsensitive ? "'i'" : "''")]" }.joined(separator: ",")
                let exclude = entry.excludeRules().map { "[\($0.regex.jsLiteral),\($0.caseInsensitive ? "'i'" : "''")]" }.joined(separator: ",")
                let guardJS = "(function(){try{if(window.top===window)return false;}catch(e){}var h=String(location.href).split('#')[0];" +
                    "var inc=[\(include)].map(function(r){return new RegExp(r[0],r[1])});var exc=[\(exclude)].map(function(r){return new RegExp(r[0],r[1])});" +
                    "return inc.some(function(r){return r.test(h)})&&!exc.some(function(r){return r.test(h)});})()"
                if !entry.css.isEmpty {
                    let css = entry.css.compactMap { ext.text($0) }.joined(separator: "\n")
                    items.append(ContentScriptItem(source: Self.cssInjector(css, guardJS: guardJS), time: .atDocumentStart, mainFrameOnly: false, world: world))
                }
                for file in entry.js {
                    guard let code = ext.text(file) else { continue }
                    items.append(ContentScriptItem(source: "if (\(guardJS)) {\n\(code)\n}\n//# sourceURL=\(ext.baseURL)\(file)",
                                                   time: time, mainFrameOnly: false, world: world))
                }
            }
        }
        return items
    }

    static func cssInjector(_ css: String, guardJS: String?) -> String {
        """
        (function(){\(guardJS.map { "if(!\($0))return;" } ?? "")var css=\(css.jsLiteral);var apply=function(){try{var s=new CSSStyleSheet();s.replaceSync(css);document.adoptedStyleSheets=document.adoptedStyleSheets.concat([s]);}catch(e){var st=document.createElement('style');st.textContent=css;(document.head||document.documentElement).appendChild(st);}};
        if(document.documentElement){apply();}else{new MutationObserver(function(m,o){if(document.documentElement){o.disconnect();apply();}}).observe(document,{childList:true});}})();
        """
    }

    // MARK: Events

    /// Dispatches a chrome event to the background runtime and extension pages (and optionally content scripts).
    func dispatch(_ ext: LoadedExtension, _ event: String, _ args: [Any], toContent: Bool = false) {
        let js = "globalThis.__rikuganChrome && globalThis.__rikuganChrome.dispatch(\(event.jsLiteral), \(JSONText.encode(args)))"
        if let bg = ext.background {
            bg.deliverEvent(event, js: js)
        }
        for (webView, kind) in extensionPages(of: ext) where kind != "background" {
            webView.rkEval(js, world: .page)
        }
        if toContent {
            let world = Worlds.extensionWorld(ext.id)
            for (tabID, frames) in ext.contentFrames {
                guard let webView = TabRegistry.shared.tab(tabID)?.webView else { continue }
                for record in frames { webView.rkEval(js, frame: record.frame, world: world) }
            }
        }
    }

    func dispatchAll(_ event: String, permission: String? = nil, _ argsFor: (LoadedExtension) -> [Any]?) {
        for ext in enabledExtensions {
            if let permission, !ext.has(permission) { continue }
            guard let args = argsFor(ext) else { continue }
            dispatch(ext, event, args)
        }
    }

    // MARK: Tab / navigation hooks

    enum NavigationEvent: String {
        case beforeNavigate = "onBeforeNavigate", committed = "onCommitted", domContentLoaded = "onDOMContentLoaded",
             completed = "onCompleted", errorOccurred = "onErrorOccurred", historyStateUpdated = "onHistoryStateUpdated",
             createdNavigationTarget = "onCreatedNavigationTarget"
    }

    func webNavigation(_ event: NavigationEvent, tab: BrowserTab, url: URL, frameID: Int, sourceTab: BrowserTab? = nil) {
        guard !tab.isPrivate, !loaded.isEmpty else { return }
        if event == .committed {
            for ext in loaded.values { ext.contentFrames[tab.numericID] = nil; ext.activeTabGrants.remove(tab.numericID); ext.tabActions[tab.numericID] = nil }
        }
        var details: [String: Any] = ["tabId": tab.numericID, "url": url.absoluteString, "frameId": frameID, "parentFrameId": -1,
                                      "timeStamp": Date().timeIntervalSince1970 * 1000, "processId": -1, "documentLifecycle": "active",
                                      "frameType": "outermost_frame"]
        if event == .committed || event == .historyStateUpdated { details["transitionType"] = "link"; details["transitionQualifiers"] = [] }
        if event == .createdNavigationTarget, let sourceTab {
            details = ["sourceTabId": sourceTab.numericID, "sourceProcessId": -1, "sourceFrameId": 0, "tabId": tab.numericID,
                       "url": url.absoluteString, "timeStamp": Date().timeIntervalSince1970 * 1000]
        }
        dispatchAll("webNavigation.\(event.rawValue)", permission: "webNavigation") { _ in [details] }
    }

    func tabCreated(_ tab: BrowserTab) {
        guard !tab.isPrivate, !loaded.isEmpty else { return }
        dispatchAll("tabs.onCreated") { ext in [self.bridge.tabJSON(tab, for: ext)] }
    }

    func tabUpdated(_ tab: BrowserTab, changes: [String: Any]) {
        guard !tab.isPrivate, !loaded.isEmpty else { return }
        dispatchAll("tabs.onUpdated") { ext in
            var info = changes
            if !self.bridge.canSeeTabDetails(tab, ext: ext) { info.removeValue(forKey: "url"); info.removeValue(forKey: "title") }
            return [tab.numericID, info, self.bridge.tabJSON(tab, for: ext)]
        }
    }

    func tabActivated(_ tab: BrowserTab, previous: BrowserTab?) {
        guard !tab.isPrivate, !loaded.isEmpty else { return }
        dispatchAll("tabs.onActivated") { _ in [["tabId": tab.numericID, "windowId": tab.manager?.numericID ?? 1]] }
    }

    /// `closing == false` means the tab's web view was suspended (content scripts are gone, the tab remains).
    func tabRemoved(_ tab: BrowserTab, closing: Bool = true) {
        for ext in loaded.values { ext.contentFrames[tab.numericID] = nil; if closing { ext.activeTabGrants.remove(tab.numericID) } }
        bridge.endpointsGone(tabID: tab.numericID)
        guard closing, !tab.isPrivate, !loaded.isEmpty else { return }
        dispatchAll("tabs.onRemoved") { _ in [tab.numericID, ["windowId": tab.manager?.numericID ?? 1, "isWindowClosing": false]] }
    }

    func registerContentFrame(ext: LoadedExtension, tab: BrowserTab, frame: WKFrameInfo) -> Int {
        var frames = ext.contentFrames[tab.numericID] ?? []
        let url = frame.request.url?.absoluteString ?? ""
        let id = frame.isMainFrame ? 0 : (frames.first { !$0.frame.isMainFrame && $0.url == url }?.frameID ?? ((frames.map(\.frameID).max() ?? 0) + 1))
        frames.removeAll { $0.frameID == id }
        frames.append(.init(frameID: id, frame: frame, url: url))
        ext.contentFrames[tab.numericID] = frames
        return id
    }

    // MARK: Toolbar action (spec §17)

    func performAction(_ ext: LoadedExtension, tab: BrowserTab?) {
        if let tab { ext.activeTabGrants.insert(tab.numericID) }
        let state = ext.actionState(for: tab?.numericID)
        guard state.enabled else { return }
        if let popup = state.popup, !popup.isEmpty, let url = URL(string: ext.baseURL + popup.trimmingCharacters(in: CharacterSet(charactersIn: "/"))) {
            self.popup = PopupRequest(extID: ext.id, url: url, tabID: tab?.numericID, title: state.title ?? ext.displayName)
        } else if let tab {
            dispatch(ext, "action.onClicked", [bridge.tabJSON(tab, for: ext)])
            ToastCenter.shared.show("已运行「\(ext.displayName)」", symbol: "puzzlepiece.extension")
        }
    }

    func openOptions(_ ext: LoadedExtension, from tab: BrowserTab?) {
        guard let page = ext.manifest.optionsPage, let url = URL(string: ext.baseURL + page) else {
            ToastCenter.shared.show("此扩展没有选项页", symbol: "info.circle"); return
        }
        if ext.manifest.optionsOpenInTab, let manager = tab?.manager ?? TabRegistry.shared.focusedWindow {
            manager.newTab(url: url, isPrivate: false)
        } else {
            popup = PopupRequest(extID: ext.id, url: url, tabID: tab?.numericID, title: ext.displayName + " 选项")
        }
    }

    /// Runs content scripts on the current site after a user click when host access is "on click".
    func runOnCurrentSite(_ ext: LoadedExtension, tab: BrowserTab) {
        ext.activeTabGrants.insert(tab.numericID)
        tab.markInjected(for: URL(string: "about:invalid")!)
        tab.reload()
    }

    // MARK: Context menus

    struct MenuEntry {
        let title: String
        let image: UIImage?
        let enabled: Bool
        let checked: Bool
        let run: () -> Void
    }

    func contextMenuEntries(for contexts: Set<String>, tab: BrowserTab, linkURL: URL?) -> [MenuEntry] {
        var entries: [MenuEntry] = []
        for ext in enabledExtensions where ext.has("contextMenus") && !ext.menuItems.isEmpty {
            let visible = ext.menuItems.filter { item in
                item.visible && item.type != "separator" && item.parentID == nil &&
                    (item.contexts.isEmpty ? contexts.contains("page") : !Set(item.contexts).isDisjoint(with: contexts.union(["all"])))
            }
            for item in visible {
                entries.append(MenuEntry(title: item.title, image: ext.icon.map { $0.preparingThumbnail(of: CGSize(width: 20, height: 20)) ?? $0 },
                                         enabled: item.enabled, checked: item.checked) { [weak self, weak tab] in
                    guard let self, let tab else { return }
                    var info: [String: Any] = ["menuItemId": item.id, "editable": false, "pageUrl": tab.webView?.url?.absoluteString ?? ""]
                    if let linkURL { info["linkUrl"] = linkURL.absoluteString }
                    if item.type == "checkbox" { info["wasChecked"] = item.checked; info["checked"] = !item.checked }
                    ext.activeTabGrants.insert(tab.numericID)
                    Task {
                        if let selection = await tab.webView?.rkTools("selection") as? String, !selection.isEmpty { info["selectionText"] = selection }
                        self.dispatch(ext, "contextMenus.onClicked", [info, self.bridge.tabJSON(tab, for: ext)])
                    }
                })
            }
        }
        return entries
    }

    func contextMenuItems(for contexts: Set<String>, tab: BrowserTab, linkURL: URL?) -> [UIMenuElement] {
        contextMenuEntries(for: contexts, tab: tab, linkURL: linkURL).map { entry in
            UIAction(title: entry.title, image: entry.image, attributes: entry.enabled ? [] : .disabled, state: entry.checked ? .on : .off) { _ in entry.run() }
        }
    }

    // MARK: Storage (spec §13 ExtensionStorage – per extension, never page storage)

    func storageURL(_ id: String, _ area: String) -> URL { directory.appendingPathComponent("\(id).storage-\(area).json") }

    private var storageCache: [String: [String: String]] = [:]

    func storage(_ ext: LoadedExtension, area: String) -> [String: String] {
        if area == "session" { return ext.sessionStorage }
        if area == "managed" { return [:] }
        let key = ext.id + ":" + area
        if let hit = storageCache[key] { return hit }
        let value = JSONFile<[String: String]>(storageURL(ext.id, area)).load() ?? [:]
        storageCache[key] = value
        return value
    }

    func setStorage(_ ext: LoadedExtension, area: String, _ values: [String: String]) {
        if area == "session" { ext.sessionStorage = values; return }
        storageCache[ext.id + ":" + area] = values
        JSONFile<[String: String]>(storageURL(ext.id, area)).save(values)
    }

    func storageChanged(_ ext: LoadedExtension, area: String, changes: [String: [String: Any]]) {
        guard !changes.isEmpty else { return }
        dispatch(ext, "storage.\(area).onChanged", [changes], toContent: true)
    }

    // MARK: DNR (spec P1)

    struct DNRStatus {
        /// Actions Rikugan converts. Only enabled when WebKit is known to *execute* them.
        var capabilities = DNRConverter.Capabilities()
        /// Whether WebKit merely *compiles* the action (diagnostics only; compiling ≠ executing).
        var compiles = DNRConverter.Capabilities()
        var probed = false
        var convertedRules = 0
        var skipped: [String: [String]] = [:]
        var lists = 0
        var compiling = false
        var lastCompiled: Date?
        var lastDuration: TimeInterval = 0
        var compileCount = 0
    }
    @Published private(set) var dnrStatus = DNRStatus()
    private var dnrDirty = false
    private var dnrCompileRunning = false

    /// Actions WebKit executes for app-level WKContentRuleLists. Measured in CI by the dnr
    /// self-test suite (which fails if this claim and WebKit's behaviour disagree): on the iOS 26
    /// simulator `redirect` compiles but is not executed and `modify-headers` does not compile, so
    /// both stay off and such rules are reported as skipped instead of silently doing nothing.
    static let executedDNRActions = DNRConverter.Capabilities(redirect: false, modifyHeaders: false)

    /// Probes whether this WebKit build *compiles* `redirect` / `modify-headers` content-rule actions.
    static func probeDNRCapabilities() async -> DNRConverter.Capabilities {
        guard let store = WKContentRuleListStore.default() else { return DNRConverter.Capabilities() }
        let redirect = #"[{"trigger":{"url-filter":"^rikugan-probe://"},"action":{"type":"redirect","redirect":{"url":"https://example.com/"}}}]"#
        let headers = #"[{"trigger":{"url-filter":"^rikugan-probe://"},"action":{"type":"modify-headers","request-headers":[{"header":"X-Rikugan","operation":"set","value":"1"}]}}]"#
        let r = await store.rkCompile("rikugan-probe-redirect", redirect) != nil
        let h = await store.rkCompile("rikugan-probe-headers", headers) != nil
        await store.rkRemove("rikugan-probe-redirect")
        await store.rkRemove("rikugan-probe-headers")
        return DNRConverter.Capabilities(redirect: r, modifyHeaders: h)
    }

    /// Requests a recompilation of all extensions' DNR rules. Calls that arrive while a compile is
    /// running coalesce into one follow-up compile (extensions such as uBOL issue hundreds of rule
    /// updates at start-up); every finished compile is applied, so rules are never starved.
    func compileDNR() {
        dnrDirty = true
        dnrStatus.compiling = true
        guard !dnrCompileRunning else { return }
        dnrCompileRunning = true
        Task { await runDNRCompiles() }
    }

    private struct DNRInput: @unchecked Sendable {
        let extID: String
        let baseURL: String
        let rulesetFiles: [URL]
        let extraRules: Data
    }

    private func runDNRCompiles() async {
        if !dnrStatus.probed {
            let compiles = await Self.probeDNRCapabilities()
            dnrStatus.compiles = compiles
            dnrStatus.capabilities = DNRConverter.Capabilities(redirect: compiles.redirect && Self.executedDNRActions.redirect,
                                                               modifyHeaders: compiles.modifyHeaders && Self.executedDNRActions.modifyHeaders)
            dnrStatus.probed = true
        }
        while dnrDirty {
            dnrDirty = false
            // Snapshot inputs on the main actor (cheap); parse / convert / build JSON off it.
            let inputs = enabledExtensions.filter { $0.has("declarativeNetRequest") || $0.has("declarativeNetRequestWithHostAccess") }.map { ext in
                DNRInput(extID: ext.id, baseURL: ext.baseURL,
                         rulesetFiles: ext.manifest.ruleResources.filter { ext.enabledRulesetIDs.contains($0.id) }.compactMap { ext.fileURL($0.path) },
                         extraRules: (try? JSONSerialization.data(withJSONObject: ext.dynamicRules + ext.sessionRules)) ?? Data("[]".utf8))
            }
            let capabilities = dnrStatus.capabilities
            let started = Date()
            let (jsonLists, convertedCount, skipped) = await Task.detached(priority: .userInitiated) { () -> ([String], Int, [String: [String]]) in
                var converted: [NetworkRule] = []
                var skipped: [String: [String]] = [:]
                for input in inputs {
                    var rules: [[String: Any]] = []
                    for file in input.rulesetFiles {
                        if let data = try? Data(contentsOf: file), let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] { rules += list }
                    }
                    rules += (try? JSONSerialization.jsonObject(with: input.extraRules) as? [[String: Any]]) ?? []
                    let output = DNRConverter.convert(rules, capabilities: capabilities, baseURL: input.baseURL)
                    converted += output.rules
                    if !output.skipped.isEmpty { skipped[input.extID] = output.skipped.map { "DNR 规则 \($0.id)：\($0.reason)" } }
                }
                let json = converted.isEmpty ? [] : ContentBlockerCompiler.compile(converted, allowlistedHosts: [])
                return (json, converted.count, skipped)
            }.value
            var lists: [WKContentRuleList] = []
            for (index, json) in jsonLists.enumerated() {
                let identifier = "dnr-\(profile.id.uuidString)-\(index)"
                if let list = await WKContentRuleListStore.default().rkCompile(identifier, json) {
                    lists.append(list)
                } else if let fallback = await ContentBlockerCompilerRuntime.compileBisecting(json: json, identifier: identifier) {
                    lists.append(fallback)
                    ErrorLog.shared.record("DNR list \(index) contained rules WebKit rejected; they were dropped", source: "DNR")
                }
            }
            dnrLists = lists
            dnrStatus.convertedRules = convertedCount
            dnrStatus.skipped = skipped
            dnrStatus.lists = lists.count
            dnrStatus.lastCompiled = Date()
            dnrStatus.lastDuration = Date().timeIntervalSince(started)
            dnrStatus.compileCount += 1
            WebViewFactory.refreshAllContentRuleLists()
        }
        dnrStatus.compiling = false
        dnrCompileRunning = false
    }
}

/// Background runtime lifecycle.
enum BackgroundState: String {
    case notStarted, starting, ready, idle, suspended, waking, failed
}

/// Hidden JS runtime for an extension background / service worker (spec §16), modelled as an
/// explicit state machine so no message or event is lost during start-up:
///
///     notStarted ─start→ starting ─ready signal→ ready ⇄ idle ─idle timeout→ suspended
///     suspended ─message/event/port→ waking ─ready signal→ ready
///     starting/waking ─load failure / no commit in 60 s / no ready 15 s after commit→ failed ─next request→ starting (max 2 restarts)
///
/// Callers use `awaitReady()`: requests made while starting / waking are queued and delivered once
/// ready, or fail with an explicit error — never silently dropped.
@MainActor final class BackgroundHost: NSObject, WKNavigationDelegate {
    unowned let ext: LoadedExtension
    unowned let runtime: ExtensionRuntime
    private(set) var webView: WKWebView?
    private(set) var state: BackgroundState = .notStarted { didSet { transitions.append((Date(), state)); if transitions.count > 50 { transitions.removeFirst() } } }
    private(set) var transitions: [(Date, BackgroundState)] = []
    private(set) var failureReason: String?
    private(set) var startCount = 0
    private(set) var restartsAfterFailure = 0
    /// Navigation / resource timeline of the current start attempt (for diagnostics of stalls).
    private(set) var timeline: [String] = []
    private var launchedAt = Date()
    /// Navigations of a fresh background web view that WebKit never started (observed
    /// intermittently in the iOS 26 simulator). Each one is recovered once with a new web view and
    /// counted here — visible in Diagnostics and the self-test reports, never silent.
    private(set) var stuckStartRecoveries = 0
    private var navigationStarted = false
    private var recoveredThisAttempt = false
    private var startWatchdog: Task<Void, Never>?
    static let navigationStartTimeout: TimeInterval = 10
    func note(_ event: String) {
        timeline.append(String(format: "+%.2fs %@", Date().timeIntervalSince(launchedAt), event))
        if timeline.count > 40 { timeline.removeFirst(timeline.count - 40) }
    }
    private var queue: [String] = []
    private var waiters: [CheckedContinuation<Bool, Never>] = []
    private var pendingLifecycleEvent: (() -> Void)?
    private var startupDeadline: Task<Void, Never>?
    private var idleTimer: Timer?
    private var lastActivity = Date()
    /// Events the background registered listeners for (kept across suspension, like Chrome).
    private(set) var subscribedEvents: Set<String> = []
    static let startupTimeout: TimeInterval = 15
    static let commitTimeout: TimeInterval = 60

    var isReady: Bool { state == .ready || state == .idle }

    init(ext: LoadedExtension, runtime: ExtensionRuntime) {
        self.ext = ext
        self.runtime = runtime
    }

    // MARK: Transitions

    /// Cold start. `lifecycle` runs once ready (runtime.onInstalled / onStartup).
    func start(onReady lifecycle: (() -> Void)? = nil) {
        pendingLifecycleEvent = lifecycle
        launch(as: .starting)
    }

    private func launch(as newState: BackgroundState) {
        guard state != .starting && state != .waking else { return }
        state = newState
        failureReason = nil
        startCount += 1
        launchedAt = Date()
        timeline.removeAll()
        note("launch \(newState.rawValue)")
        let configuration = runtime.extensionPageConfiguration(for: ext, kind: "background")
        let webView = RikuganWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: configuration, purpose: "background")
        webView.navigationDelegate = self
        webView.isInspectable = true
        self.webView = webView
        runtime.registerPage(webView, extID: ext.id, kind: "background")
        BackgroundHostContainer.shared.attach(webView)
        guard let url = URL(string: ext.baseURL + ExtensionSchemeHandler.backgroundPagePath) else { fail("invalid background URL"); return }
        recoveredThisAttempt = false
        loadPage(webView, url: url)
        armDeadline(Self.commitTimeout, phase: "page did not commit (WebContent process launch / main thread busy)")
    }

    private func loadPage(_ webView: WKWebView, url: URL) {
        navigationStarted = false
        webView.load(URLRequest(url: url))
        startWatchdog?.cancel()
        startWatchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.navigationStartTimeout * 1_000_000_000))
            guard let self, !Task.isCancelled, self.webView === webView, !self.navigationStarted,
                  self.state == .starting || self.state == .waking else { return }
            self.recoverStuckStart(url: url)
        }
    }

    /// WebKit never started the navigation: replace the web view once (bounded, counted, logged).
    private func recoverStuckStart(url: URL) {
        guard !recoveredThisAttempt else {
            fail("navigation of the background page never started (also after one fresh web view)")
            return
        }
        recoveredThisAttempt = true
        stuckStartRecoveries += 1
        note("navigation not started after \(Int(Self.navigationStartTimeout)) s → fresh web view (recovery #\(stuckStartRecoveries))")
        ErrorLog.shared.record("background navigation did not start; replaced the web view (recovery #\(stuckStartRecoveries))", source: ext.displayName)
        tearDownWebView()
        let configuration = runtime.extensionPageConfiguration(for: ext, kind: "background")
        let webView = RikuganWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: configuration, purpose: "background")
        webView.navigationDelegate = self
        webView.isInspectable = true
        self.webView = webView
        runtime.registerPage(webView, extID: ext.id, kind: "background")
        BackgroundHostContainer.shared.attach(webView)
        loadPage(webView, url: url)
    }

    /// Two explicit phases: the background page must commit within `commitTimeout`, then its
    /// scripts must signal ready within `startupTimeout` of the commit. Failing either is an
    /// explicit failure with the phase named — nothing is retried silently.
    private func armDeadline(_ seconds: TimeInterval, phase: String) {
        startupDeadline?.cancel()
        startupDeadline = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self, !Task.isCancelled, self.state == .starting || self.state == .waking else { return }
            self.fail("background not ready: \(phase) within \(Int(seconds)) s")
        }
    }

    /// Ready signal: `runtime._ready` from the shim after the background scripts ran, or the
    /// didFinish check. Idempotent; ignored unless starting / waking.
    func markReady() {
        note("ready signal (state=\(state.rawValue))")
        guard state == .starting || state == .waking else { return }
        startupDeadline?.cancel()
        state = .ready
        lastActivity = Date()
        let pending = queue
        queue.removeAll()
        for js in pending { webView?.rkEval(js, world: .page) }
        let lifecycle = pendingLifecycleEvent
        pendingLifecycleEvent = nil
        lifecycle?()
        let resumed = waiters
        waiters.removeAll()
        for waiter in resumed { waiter.resume(returning: true) }
        scheduleIdleCheck()
    }

    private func fail(_ reason: String) {
        note("fail: \(reason)")
        startupDeadline?.cancel()
        startWatchdog?.cancel()
        state = .failed
        failureReason = reason
        runtime.updateRecord(ext.id) { $0.lastErrors.append("后台运行时启动失败：\(reason)") }
        ErrorLog.shared.record(reason, source: "background \(ext.displayName)")
        tearDownWebView()
        let resumed = waiters
        waiters.removeAll()
        for waiter in resumed { waiter.resume(returning: false) }
        queue.removeAll()
    }

    /// Suspends an idle background (like an MV3 service worker being terminated). Listeners are
    /// re-registered by the scripts on the next wake.
    func suspend(reason: String = "idle") {
        guard isReady else { return }
        webView?.rkEval("globalThis.__rikuganChrome && globalThis.__rikuganChrome.dispatch('runtime.onSuspend', [])", world: .page)
        idleTimer?.invalidate()
        tearDownWebView()
        state = .suspended
    }

    func stop() {
        startupDeadline?.cancel()
        startWatchdog?.cancel()
        idleTimer?.invalidate()
        tearDownWebView()
        let resumed = waiters
        waiters.removeAll()
        for waiter in resumed { waiter.resume(returning: false) }
        queue.removeAll()
        state = .notStarted
    }

    private func tearDownWebView() {
        if let webView {
            runtime.unregisterPage(webView)
            runtime.bridge.endpointsGone(webView: webView)
            webView.navigationDelegate = nil
            webView.stopLoading()
            webView.configuration.userContentController.removeAllScriptMessageHandlers()
            webView.removeFromSuperview()
        }
        webView = nil
    }

    // MARK: Requests

    /// Waits until the runtime can receive messages, waking it if suspended. Returns false when it
    /// failed to start (the caller reports an explicit error).
    func awaitReady() async -> Bool {
        noteActivity()
        switch state {
        case .ready, .idle: return true
        case .suspended, .notStarted: launch(as: .waking)
        case .failed:
            guard restartsAfterFailure < 2 else { return false }
            restartsAfterFailure += 1
            launch(as: .starting)
        case .starting, .waking: break
        }
        if isReady { return true }
        if state == .failed { return false }
        return await withCheckedContinuation { waiters.append($0) }
    }

    /// Delivers an event, waking a suspended runtime only if it listens for that event.
    func deliverEvent(_ name: String, js: String) {
        switch state {
        case .ready, .idle:
            noteActivity()
            webView?.rkEval(js, world: .page)
        case .starting, .waking:
            queue.append(js)
        case .suspended, .notStarted:
            guard subscribedEvents.contains(name) else { return }
            queue.append(js)
            launch(as: .waking)
        case .failed:
            break
        }
    }

    func noteSubscription(_ event: String) { subscribedEvents.insert(event) }

    func noteActivity() {
        lastActivity = Date()
        if state == .idle { state = .ready }
    }

    private func scheduleIdleCheck() {
        idleTimer?.invalidate()
        let interval = max(1, Double(AppServices.shared.prefs.backgroundIdleSeconds) / 3)
        idleTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.idleTick() }
        }
    }

    private func idleTick() {
        guard isReady else { return }
        let idleFor = Date().timeIntervalSince(lastActivity)
        let limit = Double(AppServices.shared.prefs.backgroundIdleSeconds)
        if runtime.bridge.hasOpenPorts(extID: ext.id) { noteActivity(); return }
        if idleFor >= limit { suspend() } else if idleFor >= limit / 2 { state = .idle }
    }

    // MARK: Navigation delegate

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        note("didStartProvisional")
        if self.webView === webView { navigationStarted = true; startWatchdog?.cancel() }
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        note("didCommit")
        guard self.webView === webView, state == .starting || state == .waking else { return }
        armDeadline(Self.startupTimeout, phase: "scripts did not signal ready after the page committed")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        note("didFinish")
        // Second ready signal: once the page and its scripts finished loading and the chrome shim exists.
        Task {
            let present = (try? await webView.rkCall("return typeof globalThis.__rikuganChrome === 'object' && document.readyState === 'complete';", world: .page)) as? Bool ?? false
            if present, self.webView === webView { markReady() }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if self.webView === webView { fail("background page failed to load: \(error.localizedDescription)") }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if self.webView === webView { fail("background page failed to load: \(error.localizedDescription)") }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard self.webView === webView else { return }
        ErrorLog.shared.record("background WebContent process terminated", source: ext.displayName)
        tearDownWebView()
        state = .suspended   // next message / subscribed event wakes it
    }

    /// Diagnostic description used by the self-test and the Diagnostics page.
    var diagnostics: String {
        let history = transitions.suffix(8).map { $0.1.rawValue }.joined(separator: "→")
        return "state=\(state.rawValue) starts=\(startCount) stuckStartRecoveries=\(stuckStartRecoveries) url=\(webView?.url?.lastPathComponent ?? "nil") loading=\(webView?.isLoading ?? false) window=\(webView?.window != nil) history=\(history)" +
            (failureReason.map { " failure=\($0)" } ?? "") + " timeline=[" + timeline.joined(separator: "; ") + "]"
    }
}

/// Keeps background web views inside a window so WebKit does not throttle them aggressively.
@MainActor final class BackgroundHostContainer {
    static let shared = BackgroundHostContainer()
    private var pending: [WKWebView] = []

    func attach(_ webView: WKWebView) {
        webView.alpha = 0.01
        webView.isUserInteractionEnabled = false
        if let window = Presenter.keyWindow {
            window.insertSubview(webView, at: 0)
        } else {
            pending.append(webView)
        }
    }

    func flush() {
        guard let window = Presenter.keyWindow else { return }
        for webView in pending where webView.superview == nil { window.insertSubview(webView, at: 0) }
        pending.removeAll()
    }
}
