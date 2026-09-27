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
            bg.evaluateWhenReady(js)
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

    func tabRemoved(_ tab: BrowserTab) {
        for ext in loaded.values { ext.contentFrames[tab.numericID] = nil; ext.activeTabGrants.remove(tab.numericID) }
        guard !tab.isPrivate, !loaded.isEmpty else { return }
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

    func compileDNR() {
        var rules: [[String: Any]] = []
        for ext in enabledExtensions where ext.has("declarativeNetRequest") || ext.has("declarativeNetRequestWithHostAccess") {
            for resource in ext.manifest.ruleResources where ext.enabledRulesetIDs.contains(resource.id) {
                if let text = ext.text(resource.path), let list = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]] {
                    rules += list
                }
            }
            rules += ext.dynamicRules + ext.sessionRules
        }
        guard !rules.isEmpty else {
            dnrLists = []
            WebViewFactory.refreshAllContentRuleLists()
            return
        }
        let output = DNRConverter.convert(rules)
        for ext in enabledExtensions where !output.skipped.isEmpty {
            updateRecord(ext.id) { $0.lastErrors = output.skipped.prefix(20).map { "DNR 规则 \($0.id)：\($0.reason)" } }
            break
        }
        let documents = ContentBlockerCompiler.compile(output.rules, allowlistedHosts: [])
        Task {
            var lists: [WKContentRuleList] = []
            for (index, json) in documents.enumerated() {
                let identifier = "dnr-\(profile.id.uuidString)-\(index)"
                if let list = await WKContentRuleListStore.default().rkCompile(identifier, json) {
                    lists.append(list)
                } else if let fallback = await ContentBlockerCompilerRuntime.compileBisecting(json: json, identifier: identifier) {
                    lists.append(fallback)
                }
            }
            self.dnrLists = lists
            WebViewFactory.refreshAllContentRuleLists()
        }
    }
}

/// Hidden, long-lived JS runtime for an extension background / service worker (spec §16).
/// It does not depend on any page WKWebView being alive.
@MainActor final class BackgroundHost: NSObject, WKNavigationDelegate {
    unowned let ext: LoadedExtension
    unowned let runtime: ExtensionRuntime
    private(set) var webView: WKWebView?
    private(set) var isReady = false
    private var queue: [String] = []
    private var onReady: (() -> Void)?
    private var restarts = 0

    init(ext: LoadedExtension, runtime: ExtensionRuntime) {
        self.ext = ext
        self.runtime = runtime
    }

    func start(onReady: @escaping () -> Void) {
        self.onReady = onReady
        let configuration = runtime.extensionPageConfiguration(for: ext, kind: "background")
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: configuration)
        webView.navigationDelegate = self
        webView.isInspectable = true
        self.webView = webView
        runtime.registerPage(webView, extID: ext.id, kind: "background")
        BackgroundHostContainer.shared.attach(webView)
        if let url = URL(string: ext.baseURL + ExtensionSchemeHandler.backgroundPagePath) { webView.load(URLRequest(url: url)) }
    }

    func stop() {
        if let webView {
            runtime.unregisterPage(webView)
            webView.configuration.userContentController.removeAllScriptMessageHandlers()
            webView.removeFromSuperview()
        }
        webView = nil
        isReady = false
    }

    func markReady() {
        guard !isReady else { return }
        isReady = true
        let pending = queue
        queue.removeAll()
        for js in pending { webView?.rkEval(js, world: .page) }
        onReady?()
        onReady = nil
    }

    func evaluateWhenReady(_ js: String) {
        if isReady { webView?.rkEval(js, world: .page) } else { queue.append(js) }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        isReady = false
        restarts += 1
        guard restarts < 5 else { return }
        webView.reload()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Do not rely only on the JS ready signal: once the page (and its scripts) finished loading
        // and the chrome shim is present, the background runtime can receive events.
        Task {
            for _ in 0..<20 {
                let present = (try? await webView.rkCall("return typeof globalThis.__rikuganChrome === 'object' && document.readyState === 'complete';", world: .page)) as? Bool ?? false
                if present { markReady(); return }
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
            runtime.updateRecord(ext.id) { $0.lastErrors.append("后台运行时未初始化 chrome API") }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        runtime.updateRecord(ext.id) { $0.lastErrors.append("后台页面加载失败：\(error.localizedDescription)") }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        runtime.updateRecord(ext.id) { $0.lastErrors.append("后台页面加载失败：\(error.localizedDescription)") }
    }

    /// Diagnostic description used by the self-test.
    var diagnostics: String {
        "url=\(webView?.url?.absoluteString ?? "nil") loading=\(webView?.isLoading ?? false) ready=\(isReady) window=\(webView?.window != nil) errors=\(runtime.records.first { $0.id == ext.id }?.lastErrors.joined(separator: "|") ?? "")"
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
