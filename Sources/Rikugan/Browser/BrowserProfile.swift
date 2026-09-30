import Foundation
import WebKit
import Combine

struct ProfileInfo: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var symbol: String
    var createdAt = Date()
    /// The first profile uses the default website data store.
    var isDefault: Bool

    static let defaultID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
}

/// Everything that belongs to one browsing environment (spec §36): cookies / localStorage / cache
/// (website data store), history, bookmarks, userscripts, extension settings and site settings.
@MainActor final class ProfileContext: ObservableObject, Identifiable {
    let info: ProfileInfo
    let directory: URL
    let dataStore: WKWebsiteDataStore
    let history: HistoryStore
    let bookmarks: BookmarkStore
    let siteSettings: SiteSettingsStore
    let userscripts: UserScriptStore
    private(set) var extensions: ExtensionRuntime!
    private(set) var bridge: ScriptBridge!
    private var privateStore: WKWebsiteDataStore?
    private var cancellables: Set<AnyCancellable> = []

    var id: UUID { info.id }

    init(info: ProfileInfo) {
        self.info = info
        directory = AppPaths.directory(info.id.uuidString, in: AppPaths.directory("Profiles"))
        dataStore = info.isDefault ? .default() : WKWebsiteDataStore(forIdentifier: info.id)
        history = HistoryStore(directory: directory)
        bookmarks = BookmarkStore(directory: directory)
        siteSettings = SiteSettingsStore(directory: directory)
        userscripts = UserScriptStore(directory: AppPaths.directory("Userscripts", in: directory))
        extensions = ExtensionRuntime(profile: self)
        bridge = ScriptBridge(profile: self)
        // chrome.history / chrome.bookmarks events.
        history.onVisited = { [weak self] entry in self?.extensions.historyVisited(entry) }
        history.onRemoved = { [weak self] all, urls in self?.extensions.historyRemoved(all: all, urls: urls) }
        bookmarks.onChange = { [weak self] change in self?.extensions.bookmarkChanged(change) }
        // Forward nested store changes so SwiftUI views observing the profile refresh.
        for publisher in [history.objectWillChange, bookmarks.objectWillChange, siteSettings.objectWillChange, userscripts.objectWillChange] {
            publisher.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        }
    }

    /// Shared non-persistent store for private tabs; released once no private tab remains.
    func privateDataStore() -> WKWebsiteDataStore {
        if let privateStore { return privateStore }
        let store = WKWebsiteDataStore.nonPersistent()
        privateStore = store
        return store
    }

    func releasePrivateStoreIfUnused() {
        let anyPrivate = TabRegistry.shared.allTabs.contains { $0.isPrivate && $0.profile === self }
        if !anyPrivate {
            privateStore = nil
            FaviconCache.privateSession.clear()
        }
    }

    func start() {
        extensions.start()
    }

    func shutdown() {
        extensions.shutdown()
    }

    func clearWebsiteData() async {
        await dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }
}

/// Manages profiles (spec P2 "Profiles / 独立浏览环境").
@MainActor final class ProfileManager: ObservableObject {
    @Published private(set) var profiles: [ProfileInfo]
    @Published private(set) var active: ProfileContext
    private let file = JSONFile<[ProfileInfo]>(AppPaths.support.appendingPathComponent("profiles.json"))
    private let activeKey = "rikugan.activeProfile"

    init() {
        var list = file.load() ?? []
        if list.isEmpty {
            list = [ProfileInfo(id: ProfileInfo.defaultID, name: "个人", symbol: "person.crop.circle", isDefault: true)]
        }
        profiles = list
        let activeID = UserDefaults.standard.string(forKey: activeKey).flatMap(UUID.init(uuidString:))
        let info = list.first { $0.id == activeID } ?? list[0]
        active = ProfileContext(info: info)
        file.save(list)
    }

    func create(name: String, symbol: String) {
        profiles.append(ProfileInfo(id: UUID(), name: name, symbol: symbol, isDefault: false))
        file.save(profiles)
    }

    /// Registers a profile with a known ID (used by archive import so data directories line up).
    func adopt(_ info: ProfileInfo) {
        guard !profiles.contains(where: { $0.id == info.id }) else { return }
        profiles.append(info)
        file.save(profiles)
    }

    func rename(_ id: UUID, name: String, symbol: String) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].name = name
        profiles[index].symbol = symbol
        file.save(profiles)
    }

    func switchTo(_ id: UUID) {
        guard id != active.id, let info = profiles.first(where: { $0.id == id }) else { return }
        NotificationCenter.default.post(name: .rikuganProfileWillChange, object: nil)
        active.shutdown()
        active = ProfileContext(info: info)
        UserDefaults.standard.set(id.uuidString, forKey: activeKey)
        active.start()
        NotificationCenter.default.post(name: .rikuganProfileDidChange, object: nil)
    }

    func delete(_ id: UUID) async {
        guard id != active.id, let info = profiles.first(where: { $0.id == id }), !info.isDefault else { return }
        profiles.removeAll { $0.id == id }
        file.save(profiles)
        try? FileManager.default.removeItem(at: AppPaths.directory("Profiles").appendingPathComponent(id.uuidString))
        try? await WKWebsiteDataStore.remove(forIdentifier: id)
    }
}

extension Notification.Name {
    static let rikuganProfileWillChange = Notification.Name("rikugan.profileWillChange")
    static let rikuganProfileDidChange = Notification.Name("rikugan.profileDidChange")
    static let rikuganContentChanged = Notification.Name("rikugan.contentChanged")
    /// userInfo["tabId"]: numeric ID of a tab that was just closed.
    static let rikuganTabClosed = Notification.Name("rikugan.tabClosed")
    /// object: the host whose settings changed (nil = all).
    static let rikuganSiteSettingsChanged = Notification.Name("rikugan.siteSettingsChanged")
}

/// Global registry of tabs / windows with stable integer IDs for the chrome.* API.
@MainActor final class TabRegistry {
    static let shared = TabRegistry()
    private var nextTabID = 1
    private var nextWindowID = 1
    private var tabs: [Int: WeakBox<BrowserTab>] = [:]
    private var webViews: [ObjectIdentifier: WeakBox<BrowserTab>] = [:]
    private var windows: [Int: WeakBox<TabManager>] = [:]
    private(set) var lastFocusedWindowID: Int?

    func allocateTabID() -> Int { defer { nextTabID += 1 }; return nextTabID }
    func allocateWindowID() -> Int { defer { nextWindowID += 1 }; return nextWindowID }

    func register(_ tab: BrowserTab) { tabs[tab.numericID] = WeakBox(tab) }
    func register(webView: WKWebView, for tab: BrowserTab) { webViews[ObjectIdentifier(webView)] = WeakBox(tab) }
    func unregister(_ tab: BrowserTab) {
        tabs.removeValue(forKey: tab.numericID)
        if let webView = tab.webView { webViews.removeValue(forKey: ObjectIdentifier(webView)) }
    }
    func unregister(webView: WKWebView) { webViews.removeValue(forKey: ObjectIdentifier(webView)) }
    var liveWebViewCount: Int { webViews.values.filter { $0.value != nil }.count }
    func register(_ window: TabManager) { windows[window.numericID] = WeakBox(window) }
    func unregister(_ window: TabManager) { windows.removeValue(forKey: window.numericID) }
    func focus(_ window: TabManager) { lastFocusedWindowID = window.numericID }

    func tab(_ id: Int) -> BrowserTab? { tabs[id]?.value }
    func tab(for webView: WKWebView?) -> BrowserTab? { webView.flatMap { webViews[ObjectIdentifier($0)]?.value } }
    func window(_ id: Int) -> TabManager? { windows[id]?.value }
    var allTabs: [BrowserTab] { tabs.values.compactMap(\.value).sorted { $0.numericID < $1.numericID } }
    var allWindows: [TabManager] { windows.values.compactMap(\.value).sorted { $0.numericID < $1.numericID } }
    var focusedWindow: TabManager? { lastFocusedWindowID.flatMap(window) ?? allWindows.first }
}

final class WeakBox<T: AnyObject> {
    weak var value: T?
    init(_ value: T) { self.value = value }
}
