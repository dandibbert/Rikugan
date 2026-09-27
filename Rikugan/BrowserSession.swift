import SwiftUI
import WebKit

@MainActor final class BrowserSession: NSObject, ObservableObject {
    weak var model: AppModel?
    let profileID: UUID
    let dataStore: WKWebsiteDataStore
    var extensionControllerBox: AnyObject?
    var extensionContextBox: [UUID: AnyObject] = [:]
    var popupPresenterBox: AnyObject?
    lazy var extensionPageBridge: ExtensionPageBridge = ExtensionPageBridge(session: self)
    static let extensionOSMessage = "需要 iOS 18.4"
    @Published var tabs: [BrowserTab] = []
    @Published var selectedID: UUID?
    @Published var ready = false
    @Published var extensionErrors: [UUID: String] = [:]
    @Published var extensionPhase: ExtensionRuntime.Phase = .notStarted
    var extensionPhaseError = ""
    @Published var commands: [ScriptCommand] = []
    @Published var thumbnails: [UUID: UIImage] = [:]
    @Published var favicons: [UUID: UIImage] = [:]
    @Published var hostIcons: [String: UIImage] = [:]
    @Published var requestedPanel: String?
    var privateStore: WKWebsiteDataStore = .nonPersistent()
    var contentRuleList: WKContentRuleList?
    var contentRuleLists: [WKContentRuleList] = []
    var globalCosmetic = ""
    var hostCSS: [String: String] = [:]
    var proceduralJSON = "[]"
    var scriptletJSON = "[]"
    var cspJSON = "[]"
    var replaceJSON = "[]"
    var removeParams: [AdBlockEngine.QueryStrip] = []
    var privateScriptValues: [UUID: [String: Any]] = [:]
    private var bridgeTabSerial = 0
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
        super.init()
        loadFaviconCache()
        let saved = profile.tabs.isEmpty ? [SavedTab()] : profile.tabs
        tabs = saved.map { BrowserTab(saved: $0, session: self, mount: false) }
        for tab in tabs { tab.bridgeTabID = allocateBridgeTabID() }
        if saved.contains(where: { $0.id == profile.selectedTabID }) {
            selectedID = profile.selectedTabID
        } else if let group = profile.settings.activeGroupID, let match = saved.first(where: { $0.groupID == group }) {
            selectedID = match.id
        } else {
            selectedID = saved.first?.id
        }
        rebalanceResidence()
    }
    func start() async {
        if #available(iOS 18.4, *) {
            for record in profile.extensions where record.enabled {
                guard isActive else { return }
                await loadExtension(record)
            }
            guard isActive else { return }
            extensionController.didOpenWindow(self)
            extensionController.didFocusWindow(self)
            for tab in tabs { extensionController.didOpenTab(tab) }
            if let tab = activeTab { extensionController.didActivateTab(tab, previousActiveTab: nil); tab.restoreIfNeeded() }
        } else {
            for record in profile.extensions where record.enabled {
                extensionErrors[record.id] = Self.extensionOSMessage
            }
            activeTab?.restoreIfNeeded()
        }
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
        dismissExtensionPopup()
        if #available(iOS 18.4, *) {
            extensionController.didCloseWindow(self)
            for context in allExtensionContexts() { try? extensionController.unload(context) }
            extensionContextBox.removeAll()
            extensionController.delegate = nil
        }
        for tab in tabs { tab.teardown() }
        tabs.removeAll()
        extensionPhase = .suspended
    }
    @discardableResult func addTab(url: URL? = nil, activate: Bool = true, configuration: WKWebViewConfiguration? = nil, isPrivate: Bool = false, groupID: UUID? = nil, windowID: UUID? = nil) -> BrowserTab {
        var saved = SavedTab(groupID: groupID, isPrivate: isPrivate)
        if let groupID { saved.groupID = groupID }
        let tab = BrowserTab(saved: saved, session: self, configuration: configuration)
        tab.windowID = windowID
        tab.bridgeTabID = allocateBridgeTabID()
        tabs.append(tab)
        if #available(iOS 18.4, *) { extensionController.didOpenTab(tab) }
        if let windowID {
            model?.windows.select(tab.id, in: windowID)
            if activate {
                let previous = tabs.first { $0.id == selectedID }
                if #available(iOS 18.4, *) { extensionController.didActivateTab(tab, previousActiveTab: previous) }
            }
        } else if activate { select(tab) }
        installPageTools(on: tab)
        if let url { tab.navigate(url) }
        else if !isPrivate, profile.settings.homepage == "custom", let home = URL(string: profile.settings.homepageURL), !profile.settings.homepageURL.isEmpty { tab.navigate(home) }
        else if !isPrivate, profile.settings.homepage == "blank" { tab.isHome = false; tab.navigate(URL(string: "about:blank")!) }
        if saved.autoRefreshSeconds > 0 { tab.setAutoRefresh(saved.autoRefreshSeconds) }
        rebalanceResidence()
        persistTabs(); return tab
    }
    func select(_ tab: BrowserTab) {
        let previous = activeTab
        tab.lastActiveAt = Date()
        selectedID = tab.id
        if #available(iOS 18.4, *) { extensionController.didActivateTab(tab, previousActiveTab: previous) }
        model?.updateProfile(profileID) { $0.settings.activeGroupID = tab.isPrivate ? $0.settings.activeGroupID : tab.groupID }
        rebalanceResidence()
        tab.restoreIfNeeded()
        persistTabs()
    }
    func rebalanceResidence() {
        let plan = TabResidence.assign(slots: tabs.map {
            TabResidence.Slot(id: $0.id, lastActiveAt: $0.lastActiveAt, terminated: $0.phase == .terminated)
        }, activeID: selectedID)
        let live = Set(tabs.compactMap { $0.webViewIfLive() == nil ? nil : $0.id })
        let actions = TabWebViewBudget.actions(liveIDs: live, plan: plan)
        for tab in tabs {
            let next = plan[tab.id] ?? .suspended
            switch actions[tab.id] ?? .release {
            case .keep:
                if next == .terminated || tab.phase == .terminated {
                    tab.phase = .terminated
                } else {
                    tab.phase = next
                }
            case .mount:
                tab.wake(as: next)
            case .release:
                tab.suspend()
            }
        }
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
        if #available(iOS 18.4, *) { extensionController.didCloseTab(tab, windowIsClosing: false) }
        commands.removeAll { $0.tabID == tab.id }; tab.teardown()
        removeThumbnail(tab.id)
        if wasPrivate, !tabs.contains(where: \.isPrivate) {
            privateStore = .nonPersistent()
            privateScriptValues.removeAll()
        }
        let main = tabs.filter { $0.windowID == nil }
        if let windowID {
            let siblings = tabs.filter { $0.windowID == windowID }
            if model?.windows.selection[windowID] == tab.id { model?.windows.replace(siblings.last?.id, in: windowID) }
            if wasActive, let fallback = main.last { select(fallback) }
        } else {
            if main.isEmpty { addTab() }
            else if wasActive { select(main[min(index, main.count - 1)]) }
        }
        rebalanceResidence()
        persistTabs()
    }
    func persistTabs() {
        guard !stopped else { return }
        let snapshots = tabs.filter { Self.shouldPersistTab(isPrivate: $0.isPrivate, windowID: $0.windowID) }.map(\.snapshot)
        let selected = tabs.first { $0.id == selectedID && Self.shouldPersistTab(isPrivate: $0.isPrivate, windowID: $0.windowID) }?.id ?? snapshots.first?.id
        model?.updateProfile(profileID) { $0.tabs = snapshots.isEmpty ? [SavedTab()] : snapshots; $0.selectedTabID = selected }
    }
    func storeThumbnail(_ image: UIImage, id: UUID) {
        thumbnails[id] = image
        guard let model, let data = image.jpegData(compressionQuality: 0.55) else { return }
        let folder = model.directory(profileID).appendingPathComponent("Thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: folder.appendingPathComponent(id.uuidString + ".jpg"), options: .atomic)
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
        PageTools.install(on: tab.webView.configuration.userContentController, cosmeticCSS: globalCosmetic, hostCSS: hostJSON, procedural: proceduralJSON, scriptlets: scriptletJSON, csp: cspJSON, replacements: replaceJSON)
        if tab.isExtensionPage { ExtensionBridge.attach(to: tab.webView.configuration.userContentController, handler: extensionPageBridge) }
        tab.ensurePageHandler()
        tab.syncContentRules()
    }
    func refreshScripts() {
        guard isActive else { return }
        for tab in tabs {
            guard tab.webViewIfLive() != nil else { continue }
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
        for tab in tabs { tab.webViewIfLive()?.stopLoading() }
        await dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        model?.updateProfile(profileID) { $0.history.removeAll() }
        for tab in tabs where !tab.isHome && tab.webViewIfLive() != nil { tab.webView.reload() }
        rebalanceResidence()
    }
    func extensionLoaded(_ id: UUID) -> Bool { extensionContextBox[id] != nil }
    func dismissExtensionPopup() {
        guard #available(iOS 18.4, *) else { return }
        popupPresenter?.dismiss()
        popupPresenter = nil
    }
    func activateFromWindow(_ tab: BrowserTab) {
        guard #available(iOS 18.4, *) else { return }
        let previous = tabs.first { $0.id == selectedID }
        extensionController.didActivateTab(tab, previousActiveTab: previous)
    }
    func extensionHasOptions(_ id: UUID) -> Bool {
        guard #available(iOS 18.4, *) else { return false }
        return extensionContext(id: id)?.optionsPageURL != nil
    }
    func extensionDiagnostics(_ id: UUID) -> String {
        guard #available(iOS 18.4, *) else { return "" }
        return extensionContext(id: id)?.errors.map(\.localizedDescription).joined(separator: "\n") ?? ""
    }
    func insertExtensionCSS(_ css: String, tab: BrowserTab? = nil) {
        let target = tab ?? activeTab
        guard let target, let expression = ExtensionScripting.insertCSSExpression(css) else {
            if tab == nil { model?.message = "没有可以插入样式的当前标签页。" }
            return
        }
        Task { _ = await PageTools.call(expression, in: target.webView) }
    }
    func executeExtensionScript(_ source: String, tab: BrowserTab? = nil) {
        let target = tab ?? activeTab
        guard let target, !source.isEmpty else {
            if tab == nil { model?.message = "没有可以执行脚本的当前标签页。" }
            return
        }
        target.webView.evaluateJavaScript(source, in: nil, in: .page) { [weak self] result in
            if case .failure(let error) = result, tab == nil { self?.model?.message = error.localizedDescription }
        }
    }
    func injectExtensionCSS(_ css: String, tab: BrowserTab) async -> Bool {
        guard let expression = ExtensionScripting.insertCSSExpression(css) else { return false }
        let value = await PageTools.call(expression, in: tab.webView)
        if let failed = value as? [String: Any], failed["error"] != nil { return false }
        return (value as? Bool) != false
    }
    func evaluateExtensionScript(_ source: String, tab: BrowserTab) async -> Result<Any?, Error> {
        guard !source.isEmpty else { return .failure(RikuganError.message("没有可以执行脚本的当前标签页。")) }
        return await withCheckedContinuation { continuation in
            tab.webView.evaluateJavaScript(source, in: nil, in: .page) { result in
                switch result {
                case .failure(let error): continuation.resume(returning: .failure(error))
                case .success(let value): continuation.resume(returning: .success(value))
                }
            }
        }
    }
    func handleExtensionHost(api: String, details: [String: Any], tab: BrowserTab?) async -> ExtensionHostOutcome {
        guard !extensionContextBox.isEmpty else { return ExtensionHostOutcome(error: "没有已载入的扩展。") }
        if api == "notifications.poll" {
            let extensionID = details["extensionId"] as? String ?? ""
            return ExtensionHostOutcome(result: model?.takeExtensionEvents(extensionID: extensionID) ?? [])
        }
        if api == "notifications.getPermissionLevel" {
            let granted = await SystemNotifications.allowsAlerts()
            return ExtensionHostOutcome(result: ExtensionBridge.permissionLevel(authorized: granted))
        }
        if api.hasPrefix("notifications.") {
            guard let model else { return ExtensionHostOutcome(error: "没有通知记录。") }
            let before = model.extensionNotices
            var records = before
            let outcome = ExtensionBridge.apply(api: api, details: details, records: &records) { record in
                model.deliverExtensionNotice(record)
            }
            model.extensionNotices = records
            if api == "notifications.clear" {
                let removed = Set(before.keys).subtracting(records.keys)
                model.removeExtensionNotices(ids: Array(removed))
                for id in removed {
                    model.queueExtensionEvent(type: "closed", notificationID: id, byUser: false, extensionID: before[id]?.extensionID ?? "")
                }
            }
            return outcome
        }
        let call = ExtensionBridge.command(api: api, details: details)
        if let error = call.error { return ExtensionHostOutcome(error: error) }
        var texts: [String] = []
        if !call.files.isEmpty {
            let runtimeID = details["extensionId"] as? String ?? ""
            let located = extensionPackages(preferring: runtimeID)
            switch ExtensionBridge.loadSources(call.files, packages: located.packages, strict: located.strict) {
            case .success(let sources): texts = sources
            case .failure(let error): return ExtensionHostOutcome(error: error.message)
            }
        }
        if call.isolated {
            var sources = texts
            if let code = call.code, !code.isEmpty { sources.append(code) }
            guard !sources.isEmpty else { return ExtensionHostOutcome(error: "func, code, or files is required") }
            return ExtensionHostOutcome(result: ["sources": sources])
        }
        let named = tabForScripting(call.tabID)
        if !call.tabID.isEmpty && named == nil && tab == nil {
            return ExtensionHostOutcome(error: "没有目标标签页。")
        }
        guard let target = named ?? tab ?? activeTab else { return ExtensionHostOutcome(error: "没有目标标签页。") }
        let fanOut = ExtensionBridge.spansFrames(allFrames: call.allFrames, frameIDs: call.frameIDs)
        if call.kind == "css" {
            var sheets: [String] = []
            if let css = call.css { sheets.append(css) }
            sheets.append(contentsOf: texts)
            if fanOut {
                let script = ExtensionBridge.frameCSS(sheets: sheets, frameIDs: call.frameIDs, allFrames: call.allFrames)
                switch await evaluateExtensionScript(script, tab: target) {
                case .success(let value):
                    if (value as? Bool) == false { return ExtensionHostOutcome(error: "没有插入样式。") }
                    return ExtensionHostOutcome(result: NSNull())
                case .failure(let error): return ExtensionHostOutcome(error: error.localizedDescription)
                }
            }
            for css in sheets {
                let inserted = await injectExtensionCSS(css, tab: target)
                if !inserted { return ExtensionHostOutcome(error: "没有插入样式。") }
            }
            return ExtensionHostOutcome(result: NSNull())
        }
        if fanOut {
            var sources = texts
            if let code = call.code, !code.isEmpty { sources.append(code) }
            guard !sources.isEmpty else { return ExtensionHostOutcome(error: "func, code, or files is required") }
            let script = ExtensionBridge.frameRunner(sources: sources, frameIDs: call.frameIDs, allFrames: call.allFrames)
            switch await evaluateExtensionScript(script, tab: target) {
            case .success(let value): return ExtensionHostOutcome(result: ExtensionBridge.boxed(value))
            case .failure(let error): return ExtensionHostOutcome(error: error.localizedDescription)
            }
        }
        var results: [Any] = []
        for text in texts {
            switch await evaluateExtensionScript(text, tab: target) {
            case .success(let value): results.append(["result": ExtensionBridge.boxed(value)])
            case .failure(let error): return ExtensionHostOutcome(error: error.localizedDescription)
            }
        }
        if let code = call.code, !code.isEmpty {
            switch await evaluateExtensionScript(code, tab: target) {
            case .success(let value): results.append(["result": ExtensionBridge.boxed(value)])
            case .failure(let error): return ExtensionHostOutcome(error: error.localizedDescription)
            }
        }
        guard !results.isEmpty else { return ExtensionHostOutcome(error: "不支持的扩展调用。") }
        return ExtensionHostOutcome(result: results)
    }

    func allocateBridgeTabID() -> Int {
        bridgeTabSerial += 1
        return bridgeTabSerial
    }

    func tabForScripting(_ token: String) -> BrowserTab? {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let uuid = UUID(uuidString: trimmed) { return tabs.first { $0.id == uuid } }
        if let number = Int(trimmed) { return tabs.first { $0.bridgeTabID == number } }
        return nil
    }

    func extensionPackages(preferring runtimeID: String) -> (packages: [(url: URL, directory: Bool)], strict: Bool) {
        guard let model else { return ([], false) }
        func score(_ record: ExtensionRecord) -> Int {
            let id = runtimeID.lowercased()
            if id.isEmpty { return 0 }
            if record.id.uuidString.lowercased() == id { return 3 }
            if !record.storeID.isEmpty, record.storeID.lowercased() == id { return 2 }
            if record.relativePath.lowercased().contains(id) { return 1 }
            return 0
        }
        let ranked = profile.extensions.sorted { score($0) > score($1) }
        let matched = ranked.filter { score($0) > 0 }
        let chosen = matched.isEmpty ? ranked : matched
        let packages = chosen.map { record -> (url: URL, directory: Bool) in
            let url = model.directory(profileID).appendingPathComponent(record.relativePath)
            let directory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            return (url, directory)
        }
        return (packages, !matched.isEmpty)
    }
}

@available(iOS 18.4, *)
extension BrowserSession {
    var extensionController: WKWebExtensionController {
        if let existing = extensionControllerBox as? WKWebExtensionController { return existing }
        let config = WKWebExtensionController.Configuration(identifier: profileID)
        config.defaultWebsiteDataStore = dataStore
        let controller = WKWebExtensionController(configuration: config)
        controller.delegate = self
        extensionControllerBox = controller
        return controller
    }
    var popupPresenter: PopupPresenter? {
        get { popupPresenterBox as? PopupPresenter }
        set { popupPresenterBox = newValue }
    }
    func extensionContext(id: UUID) -> WKWebExtensionContext? { extensionContextBox[id] as? WKWebExtensionContext }
    func storeExtensionContext(_ context: WKWebExtensionContext, id: UUID) { extensionContextBox[id] = context }
    @discardableResult func removeExtensionContext(id: UUID) -> WKWebExtensionContext? {
        extensionContextBox.removeValue(forKey: id) as? WKWebExtensionContext
    }
    func allExtensionContexts() -> [WKWebExtensionContext] { extensionContextBox.values.compactMap { $0 as? WKWebExtensionContext } }
}

@MainActor final class BrowserTab: NSObject, ObservableObject, Identifiable {
    let id: UUID
    weak var session: BrowserSession?
    private var heldWebView: WKWebView?
    private var pendingConfiguration: WKWebViewConfiguration?
    let scriptEngine = UserScriptEngine()
    var phase: TabPhase = .suspended
    var scrollX = 0.0
    var scrollY = 0.0
    var interactionState: Data?
    var webView: WKWebView {
        if let heldWebView { return heldWebView }
        mountWebView()
        return heldWebView!
    }
    func webViewIfLive() -> WKWebView? { heldWebView }
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
    private var scrollApplied = false
    private var downloads: [ObjectIdentifier: URL] = [:]
    var isPrivate: Bool
    var groupID: UUID?
    var windowID: UUID?
    var autoRefreshSeconds: Int
    var contentRulesOn = false
    var installedRuleLists: [WKContentRuleList] = []
    var pageHandlerInstalled = false
    var isExtensionPage = false
    var bridgeTabID = 0
    var scriptState: [String: Any] = [:]
    var refreshTask: Task<Void, Never>?
    var findNeedle = ""
    var findCursor = 0
    @Published var consoleLines: [String] = []
    @Published var liveTexts: [[String: String]] = []
    var webKitDownloadIDs: [ObjectIdentifier: UUID] = [:]
    var lastActiveAt = Date()
    var snapshot: SavedTab { SavedTab(id: id, url: isHome || isPrivate ? "" : address, title: pageTitle, desktop: desktop, groupID: groupID, autoRefreshSeconds: autoRefreshSeconds, scrollX: scrollX, scrollY: scrollY, interactionState: isHome || isPrivate ? nil : interactionState) }
    var userscriptsAllowed: Bool {
        let host = webViewIfLive()?.url?.host ?? URL(string: address)?.host
        return session?.profile.site(for: host)?.userScriptsEnabled ?? true
    }

    init(saved: SavedTab, session: BrowserSession, configuration supplied: WKWebViewConfiguration? = nil, mount: Bool = true) {
        id = saved.id; self.session = session; pageTitle = saved.title; address = saved.url; isHome = saved.url.isEmpty; desktop = saved.desktop
        isPrivate = saved.isPrivate; groupID = saved.groupID; autoRefreshSeconds = saved.autoRefreshSeconds
        scrollX = saved.scrollX; scrollY = saved.scrollY; interactionState = saved.interactionState
        pendingConfiguration = supplied
        if let supplied {
            if #available(iOS 18.4, *) {
                isExtensionPage = session.allExtensionContexts().contains { $0.webViewConfiguration === supplied }
            }
        }
        super.init()
        scriptEngine.tab = self
        if mount { mountWebView() }
    }
    private func mountWebView() {
        guard heldWebView == nil else { return }
        let configuration = pendingConfiguration ?? WKWebViewConfiguration()
        if pendingConfiguration == nil {
            configuration.websiteDataStore = isPrivate ? (session?.privateStore ?? .nonPersistent()) : (session?.dataStore ?? .default())
            if #available(iOS 18.4, *), let session { configuration.webExtensionController = session.extensionController }
            configuration.userContentController = WKUserContentController()
            configuration.allowsInlineMediaPlayback = true
            configuration.allowsPictureInPictureMediaPlayback = true
            configuration.allowsAirPlayForMediaPlayback = true
            configuration.mediaTypesRequiringUserActionForPlayback = .audio
            configuration.defaultWebpagePreferences.preferredContentMode = desktop ? .desktop : .mobile
        }
        let view = WKWebView(frame: .zero, configuration: configuration)
        heldWebView = view
        if let session { scriptEngine.configure(configuration.userContentController, scripts: session.profile.scripts) }
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true
        view.isInspectable = session?.profile.settings.inspectable ?? true
        view.scrollView.keyboardDismissMode = .onDrag
        observations = [
            view.observe(\.title, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.syncState(extensionTitle: true) } },
            view.observe(\.url, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.syncState(extensionURL: true) } },
            view.observe(\.estimatedProgress, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.syncState(extensionLoading: true) } },
            view.observe(\.isLoading, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.syncState(extensionLoading: true) } },
            view.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.syncState() } },
            view.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.syncState() } }
        ]
        if phase == .suspended || phase == .terminated { phase = .liveBackground }
        scrollApplied = false
    }
    func suspend() {
        guard let view = heldWebView else { if phase != .terminated { phase = .suspended }; return }
        scrollX = view.scrollView.contentOffset.x
        scrollY = view.scrollView.contentOffset.y
        if #available(iOS 15, *) {
            interactionState = TabInteraction.encode(view.interactionState)
        }
        if TabSnapshotGate.shouldCapture(isHome: isHome, isPrivate: isPrivate) {
            view.takeSnapshot(with: nil) { [weak self, view] image, _ in
                _ = view
                guard let self, let image else { return }
                Task { @MainActor in self.session?.storeThumbnail(image, id: self.id) }
            }
        }
        if let host = URL(string: address)?.host, let image = session?.favicons[id] {
            session?.storeFavicon(image, host: host)
        }
        releaseView()
        restored = false
        phase = .suspended
    }
    func wake(as next: TabPhase) {
        let reload = phase == .terminated
        if heldWebView == nil {
            phase = .restoring
            mountWebView()
            session?.installPageTools(on: self)
            phase = reload ? .terminated : next
            restoreIfNeeded()
            if phase == .restoring || phase == .terminated { phase = next }
        } else if reload {
            phase = .terminated
            restored = false
            restoreIfNeeded()
            phase = next
        } else {
            phase = next
        }
    }
    private func releaseView() {
        guard let view = heldWebView else { return }
        refreshTask?.cancel()
        view.stopLoading()
        observations.removeAll()
        if pageHandlerInstalled {
            view.configuration.userContentController.removeScriptMessageHandler(forName: "rikuganPage", contentWorld: .page)
            pageHandlerInstalled = false
        }
        scriptEngine.teardown(view.configuration.userContentController)
        view.navigationDelegate = nil
        view.uiDelegate = nil
        heldWebView = nil
    }
    func syncState(extensionTitle: Bool = false, extensionURL: Bool = false, extensionLoading: Bool = false) {
        progress = webView.estimatedProgress; isLoading = webView.isLoading
        canGoBack = webView.canGoBack; canGoForward = webView.canGoForward
        if let url = webView.url {
            address = url.absoluteString
            session?.noteURLChange(self)
        }
        if let title = webView.title, !title.isEmpty { pageTitle = title }
        guard extensionTitle || extensionURL || extensionLoading else { return }
        guard #available(iOS 18.4, *) else { return }
        var properties = WKWebExtension.TabChangedProperties()
        if extensionTitle { properties.insert(.title) }
        if extensionURL { properties.insert(.URL) }
        if extensionLoading { properties.insert(.loading) }
        session?.extensionController.didChangeTabProperties(properties, for: self)
    }
    func extensionEffect(_ request: ExtensionTabPolicy.Request) -> ExtensionTabPolicy.Effect {
        ExtensionTabPolicy.effect(
            request: request,
            phase: phase,
            hasLiveWebView: webViewIfLive() != nil,
            hasInteraction: !(interactionState ?? Data()).isEmpty
        )
    }

    /// Restores a suspended tab before an extension action. Never uses the mounting `webView` getter.
    /// Snapshot and duplicate do not mount. A restore updates `lastActiveAt` and rebalances the live budget.
    func prepareExtensionNavigation(_ request: ExtensionTabPolicy.Request) -> WKWebView? {
        switch extensionEffect(request) {
        case .skipSnapshot, .duplicateSavedURL:
            return nil
        case .performOnLiveView:
            return webViewIfLive()
        case .navigateSavedURL:
            guard let url = ExtensionTabPolicy.savedURL(address) else { return webViewIfLive() }
            let fresh = webViewIfLive() == nil
            lastActiveAt = Date()
            navigate(url)
            if fresh { session?.installPageTools(on: self) }
            session?.rebalanceResidence()
            return webViewIfLive()
        case .restoreInteractionThenPerform:
            lastActiveAt = Date()
            let fresh = webViewIfLive() == nil
            if fresh {
                phase = .restoring
                mountWebView()
                session?.installPageTools(on: self)
            }
            restored = false
            if phase == .terminated {
                if let url = ExtensionTabPolicy.savedURL(address) { navigate(url) }
            } else {
                restoreIfNeeded()
            }
            session?.rebalanceResidence()
            return webViewIfLive()
        }
    }

    func restoreIfNeeded() {
        guard !restored else { return }
        let url = address.isEmpty ? nil : URL(string: address)
        let action = TabRestore.plan(url: url, interaction: interactionState, terminated: phase == .terminated)
        restored = true
        switch action {
        case .restoreInteraction:
            if applyInteraction() { return }
            if let url { navigate(url) }
        case .reload, .load:
            if let url { navigate(url) }
        case .idle:
            break
        }
    }
    private func applyInteraction() -> Bool {
        guard let blob = interactionState, !blob.isEmpty else { return false }
        if #available(iOS 15, *) {
            guard let value = TabInteraction.decode(blob) else { return false }
            webView.interactionState = value
            return true
        }
        return false
    }
    func navigate(_ url: URL) {
        restored = true; isHome = false; pageError = nil; address = url.absoluteString
        if phase == .terminated || phase == .suspended || heldWebView == nil { phase = .restoring }
        webView.load(URLRequest(url: url))
        if phase == .restoring { phase = session?.selectedID == id ? .active : .liveBackground }
        session?.persistTabs()
    }
    func loadInput(_ input: String) {
        let engine = session?.profile.searchEngine ?? "https://www.google.com/search?q="
        let custom = session?.profile.settings.customEngines ?? []
        let shortcuts = session?.profile.settings.urlShortcuts ?? []
        let term = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let shortcutHit = shortcuts.contains { $0.keyword.compare(term, options: .caseInsensitive) == .orderedSame }
        if !isPrivate, URLRules.isSearch(input), !shortcutHit, let session {
            session.model?.updateProfile(session.profileID) { profile in
                profile.searchHistory.removeAll { $0 == term }
                profile.searchHistory.insert(term, at: 0)
                profile.searchHistory = Array(profile.searchHistory.prefix(40))
            }
        }
        if let url = URLRules.inputURL(input, searchEngine: engine, customEngines: custom, shortcuts: shortcuts) { navigate(url) }
    }
    func toggleDesktop() {
        desktop.toggle()
        webView.customUserAgent = desktop ? "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.4 Safari/605.1.15" : nil
        webView.reload(); session?.persistTabs()
    }
    func teardown() {
        refreshTask?.cancel(); refreshTask = nil
        releaseView()
        phase = .terminated
    }
}

extension BrowserTab: WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isHome = false; restored = true
        pageError = nil; session?.commands.removeAll { $0.tabID == id }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        syncState(extensionTitle: true, extensionURL: true, extensionLoading: true); session?.recordVisit(self); applyDecorations(); captureThumbnail(); captureIcon()
        if !scrollApplied, scrollX != 0 || scrollY != 0 {
            scrollApplied = true
            webView.scrollView.setContentOffset(CGPoint(x: scrollX, y: scrollY), animated: false)
        }
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { applyDecorations() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { pageError = error.localizedDescription }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { pageError = error.localizedDescription }
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        phase = TabRestore.afterProcessTermination()
        restored = false
        pageError = "页面进程已被系统回收。JavaScript 堆、WebSocket 和未保存的页面状态无法恢复，重新载入会重新请求当前 URL。"
        session?.model?.noteRuntime("WebContent terminated \(address)")
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, preferences: WKWebpagePreferences,
                 decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        let host = navigationAction.request.url?.host
        let site = session?.profile.site(for: host)
        if let forced = site?.desktopMode {
            desktop = forced
            webView.customUserAgent = forced ? "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.4 Safari/605.1.15" : nil
        }
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
        var webExtensionPage = ["http", "https", "about", "blob", "data"].contains(url.scheme ?? "")
        if !webExtensionPage {
            if #available(iOS 18.4, *) {
                webExtensionPage = session?.extensionController.extensionContext(for: url) != nil
            }
        }
        if webExtensionPage {
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
                if allowed, let url = navigationAction.request.url { session.addTab(url: url, activate: true, configuration: configuration, windowID: self.windowID) }
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
