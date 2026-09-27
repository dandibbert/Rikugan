import Foundation

enum TabPhase: String, Codable, Equatable {
    case active
    case liveBackground
    case suspended
    case restoring
    case terminated
}

enum TabResidence {
    static let liveBudget = 8

    struct Slot: Equatable {
        var id: UUID
        var lastActiveAt: Date
        var terminated = false
    }

    /// Active tab stays resident. The newest background tabs fill the remaining budget.
    /// Older tabs become suspended. Terminated tabs stay terminated and do not take a live slot.
    static func assign(slots: [Slot], activeID: UUID?, budget: Int = liveBudget) -> [UUID: TabPhase] {
        let limit = max(1, budget)
        var result: [UUID: TabPhase] = [:]
        let active = slots.first { $0.id == activeID } ?? slots.max { $0.lastActiveAt < $1.lastActiveAt }
        var live = 0
        if let active {
            if active.terminated {
                result[active.id] = .terminated
            } else {
                result[active.id] = .active
                live = 1
            }
        }
        let rest = slots.filter { $0.id != active?.id }.sorted { $0.lastActiveAt > $1.lastActiveAt }
        for slot in rest {
            if slot.terminated {
                result[slot.id] = .terminated
                continue
            }
            if live < limit {
                result[slot.id] = .liveBackground
                live += 1
            } else {
                result[slot.id] = .suspended
            }
        }
        return result
    }
}

enum TabWebViewBudget {
    enum Action: Equatable { case keep, mount, release }

    /// A tab that already has a web view keeps that same slot. Suspended tabs release it.
    /// Terminated tabs are not given a second view here; the next open reloads the one they have.
    static func actions(liveIDs: Set<UUID>, plan: [UUID: TabPhase]) -> [UUID: Action] {
        var result: [UUID: Action] = [:]
        for (id, phase) in plan {
            switch phase {
            case .suspended:
                result[id] = .release
            case .terminated:
                result[id] = .keep
            case .active, .liveBackground, .restoring:
                result[id] = liveIDs.contains(id) ? .keep : .mount
            }
        }
        return result
    }
}

enum TabRestore {
    enum Action: Equatable { case restoreInteraction, reload, load, idle }

    static func afterProcessTermination() -> TabPhase { .terminated }

    /// interactionState comes back when the blob is present. A terminated process reloads.
    /// Nil blob falls back to load(url).
    static func plan(url: URL?, interaction: Data?, terminated: Bool) -> Action {
        if terminated { return url == nil ? .idle : .reload }
        if let interaction, !interaction.isEmpty { return .restoreInteraction }
        if url != nil { return .load }
        return .idle
    }

    static func reopen(_ closed: ClosedTab) -> SavedTab? {
        guard let url = URL(string: closed.url), ["http", "https"].contains(url.scheme ?? "") else { return nil }
        return SavedTab(url: closed.url, title: closed.title, groupID: closed.groupID)
    }
}

enum TabInteraction {
    static func encode(_ value: Any?) -> Data? {
        guard let value else { return nil }
        let kind: String
        let blob: Data
        if let data = value as? Data, !data.isEmpty {
            kind = "data"
            blob = data
        } else if PropertyListSerialization.propertyList(value, isValidFor: .binary),
                  let data = try? PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0) {
            kind = "plist"
            blob = data
        } else if let data = try? NSKeyedArchiver.archivedData(withRootObject: value, requiringSecureCoding: false), !data.isEmpty {
            kind = "keyed"
            blob = data
        } else {
            return nil
        }
        return try? PropertyListSerialization.data(fromPropertyList: ["kind": kind, "blob": blob], format: .binary, options: 0)
    }

    static func decode(_ data: Data?) -> Any? {
        guard let data, !data.isEmpty,
              let envelope = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let kind = envelope["kind"] as? String,
              let blob = envelope["blob"] as? Data else { return nil }
        switch kind {
        case "data":
            return blob
        case "keyed":
            guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: blob) else { return nil }
            unarchiver.requiresSecureCoding = false
            return unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey)
        default:
            return try? PropertyListSerialization.propertyList(from: blob, options: [], format: nil)
        }
    }
}

enum TabSnapshotGate {
    static func shouldCapture(isHome: Bool, isPrivate: Bool) -> Bool { !isHome && !isPrivate }
}

/// Extension tab actions must not mount an empty WKWebView. A suspended reload loads the
/// saved URL. A snapshot of a tab with no live web view is skipped.
enum ExtensionTabPolicy {
    enum Request: Equatable { case reload, back, forward, zoom, snapshot, duplicate }
    enum Effect: Equatable {
        case navigateSavedURL
        case restoreInteractionThenPerform
        case performOnLiveView
        case skipSnapshot
        case duplicateSavedURL
    }

    static func effect(request: Request, phase: TabPhase, hasLiveWebView: Bool, hasInteraction: Bool) -> Effect {
        switch request {
        case .snapshot:
            return hasLiveWebView ? .performOnLiveView : .skipSnapshot
        case .duplicate:
            return .duplicateSavedURL
        case .reload, .back, .forward, .zoom:
            let needsRestore = phase == .suspended || phase == .terminated || !hasLiveWebView
            guard needsRestore else { return .performOnLiveView }
            if request == .reload && (phase == .terminated || !hasInteraction) { return .navigateSavedURL }
            if hasInteraction && phase != .terminated { return .restoreInteractionThenPerform }
            return .navigateSavedURL
        }
    }

    static func savedURL(_ address: String) -> URL? {
        guard !address.isEmpty, let url = URL(string: address) else { return nil }
        return url
    }

    static func shouldRebalance(_ effect: Effect) -> Bool {
        switch effect {
        case .navigateSavedURL, .restoreInteractionThenPerform: return true
        case .performOnLiveView, .skipSnapshot, .duplicateSavedURL: return false
        }
    }
}

enum DiagnosticsExport {
    static let omitted = ["history", "cookies", "passwords", "page text"]
    static let forbidden = ["history", "cookies", "passwords", "pageText", "cookie", "urls"]

    static func sanitize(_ payload: [String: Any]) -> [String: Any] {
        var copy = payload
        for key in forbidden { copy.removeValue(forKey: key) }
        copy["omitted"] = omitted
        return copy
    }
}

enum TabGroupEdit {
    struct TabRef: Equatable {
        var id: UUID
        var groupID: UUID?
        var isPrivate: Bool
        var order: Int
    }

    enum Deletion: Equatable {
        case ungroup
        case closeTabs
    }

    static func reorder<T>(_ items: [T], from: Int, to: Int) -> [T] {
        guard items.indices.contains(from), items.indices.contains(to), from != to else { return items }
        var copy = items
        let item = copy.remove(at: from)
        copy.insert(item, at: to)
        return copy
    }

    static func move(_ tabs: [TabRef], id: UUID, to groupID: UUID?, groups: [TabGroup]) -> [TabRef]? {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return nil }
        if tabs[index].isPrivate { return nil }
        if let groupID, !groups.contains(where: { $0.id == groupID }) { return nil }
        var copy = tabs
        copy[index].groupID = groupID
        return copy
    }

    static func reorderWithinGroup(_ tabs: [TabRef], id: UUID, direction: Int) -> [TabRef] {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return tabs }
        let group = tabs[index].groupID
        let privateTab = tabs[index].isPrivate
        let peers = tabs.enumerated().filter { $0.element.groupID == group && $0.element.isPrivate == privateTab }
        guard let peerIndex = peers.firstIndex(where: { $0.element.id == id }) else { return tabs }
        let destination = peerIndex + direction
        guard peers.indices.contains(destination) else { return tabs }
        var copy = tabs
        let from = peers[peerIndex].offset
        let to = peers[destination].offset
        let item = copy.remove(at: from)
        copy.insert(item, at: to)
        return copy
    }

    static func delete(groups: [TabGroup], tabs: [TabRef], id: UUID, disposition: Deletion) -> (groups: [TabGroup], tabs: [TabRef]) {
        let nextGroups = groups.filter { $0.id != id }
        let nextTabs: [TabRef]
        switch disposition {
        case .ungroup:
            nextTabs = tabs.map { tab in
                var copy = tab
                if copy.groupID == id { copy.groupID = nil }
                return copy
            }
        case .closeTabs:
            nextTabs = tabs.filter { $0.groupID != id }
        }
        return (nextGroups, nextTabs)
    }
}

enum ExtensionRuntime {
    enum Phase: String, Equatable {
        case notStarted
        case starting
        case ready
        case idle
        case suspended
        case waking
        case failed
    }

    static func beginLoad(from phase: Phase) -> Phase {
        switch phase {
        case .ready, .idle, .suspended: return .waking
        default: return .starting
        }
    }

    /// Xcode 16.4 WebKit drops `runtime.sendMessage` while the background listener set is empty.
    /// `wakeUpBackgroundContentIfNecessaryToFireEvents` treats that as unhandled and does not start
    /// the service worker (fixed later in WebKit 7682d9817b, 2026-06-28). Load background content
    /// once before any content-script message.
    static func mustWarmBackground(hasBackgroundContent: Bool) -> Bool {
        hasBackgroundContent
    }

    static func backgroundMessageDropped(hasLoadedOnce: Bool, listenerCount: Int) -> Bool {
        !hasLoadedOnce && listenerCount == 0
    }
}

enum ProfileArchive {
    static let currentVersion = 3
    static let omitted = ["passwords", "keychain", "cookies", "session secrets", "extension binaries", "font file bytes"]

    enum Mode: String, Equatable { case merge, replace }

    struct Document: Codable, Equatable {
        var formatVersion = currentVersion
        var exportedAt = Date()
        var appVersion = "0.2.0"
        var includesUserscriptSource = true
        var includesExtensionBinaries = false
        var omitted = ProfileArchive.omitted
        var settings = BrowserSettings()
        var siteSettings: [SiteSettings] = []
        var tabGroups: [TabGroup] = []
        var tabs: [SavedTab] = []
        var activeGroupID: UUID?
        var activeTabID: UUID?
        var userscripts: [UserScript]?
        var bookmarks: [PageRecord] = []
        var bookmarkFolders: [BookmarkFolder] = []
        var searchEngine = "https://www.google.com/search?q="
        var searchHistory: [String] = []
    }

    struct Preview: Equatable {
        var formatVersion: Int
        var appVersion: String
        var tabCount: Int
        var groupCount: Int
        var scriptCount: Int?
        var includesUserscriptSource: Bool
        var includesExtensionBinaries: Bool
        var omitted: [String]
    }

    static func export(profile: BrowserProfile, appVersion: String, now: Date = Date()) -> Document {
        var settings = profile.settings
        settings.activeGroupID = profile.settings.activeGroupID
        return Document(
            formatVersion: currentVersion,
            exportedAt: now,
            appVersion: appVersion,
            includesUserscriptSource: true,
            includesExtensionBinaries: false,
            omitted: omitted,
            settings: settings,
            siteSettings: profile.siteSettings,
            tabGroups: profile.tabGroups,
            tabs: profile.tabs.filter { !$0.isPrivate },
            activeGroupID: profile.settings.activeGroupID,
            activeTabID: profile.selectedTabID,
            userscripts: profile.scripts,
            bookmarks: profile.bookmarks,
            bookmarkFolders: profile.bookmarkFolders,
            searchEngine: profile.searchEngine,
            searchHistory: profile.searchHistory
        )
    }

    static func decode(_ data: Data) throws -> Document {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RikuganError.message("备份不是 JSON 对象，当前资料没有改动。")
        }
        let format = (object["formatVersion"] as? Int) ?? (object["version"] as? Int)
        guard let format else { throw RikuganError.message("备份缺少 formatVersion，已拒绝。") }
        guard format == 2 || format == currentVersion else { throw RikuganError.message("不支持的备份格式 \(format)。") }
        let decoder = JSONDecoder()
        if format == 2 {
            let legacy = try decoder.decode(PortableBackup.self, from: data)
            return Document(
                formatVersion: 2,
                exportedAt: legacy.exportedAt,
                appVersion: "0.2.0",
                includesUserscriptSource: false,
                includesExtensionBinaries: false,
                omitted: omitted,
                settings: legacy.settings,
                siteSettings: legacy.siteSettings,
                tabGroups: legacy.tabGroups,
                tabs: legacy.tabs.filter { !$0.isPrivate },
                activeGroupID: legacy.settings.activeGroupID,
                activeTabID: legacy.selectedTabID,
                userscripts: nil,
                bookmarks: legacy.bookmarks,
                bookmarkFolders: legacy.bookmarkFolders,
                searchEngine: legacy.searchEngine,
                searchHistory: legacy.searchHistory
            )
        }
        let document = try decoder.decode(Document.self, from: data)
        guard document.formatVersion == currentVersion else { throw RikuganError.message("不支持的备份格式 \(document.formatVersion)。") }
        guard document.tabs.allSatisfy({ !$0.isPrivate }) else { throw RikuganError.message("备份里不能带无痕标签。") }
        return document
    }

    static func preview(_ data: Data) throws -> Preview {
        let document = try decode(data)
        return Preview(
            formatVersion: document.formatVersion,
            appVersion: document.appVersion,
            tabCount: document.tabs.count,
            groupCount: document.tabGroups.count,
            scriptCount: document.userscripts?.count,
            includesUserscriptSource: document.includesUserscriptSource,
            includesExtensionBinaries: document.includesExtensionBinaries,
            omitted: document.omitted
        )
    }

    static func apply(_ document: Document, onto profile: BrowserProfile, mode: Mode) -> BrowserProfile {
        var next = profile
        switch mode {
        case .replace:
            next.tabs = document.tabs
            next.tabGroups = document.tabGroups
            next.selectedTabID = document.activeTabID
            next.settings = document.settings
            next.settings.activeGroupID = document.activeGroupID
            next.siteSettings = document.siteSettings
            next.bookmarks = document.bookmarks
            next.bookmarkFolders = document.bookmarkFolders
            next.searchEngine = document.searchEngine
            next.searchHistory = document.searchHistory
            if let scripts = document.userscripts { next.scripts = scripts }
        case .merge:
            var groups = next.tabGroups
            for group in document.tabGroups where !groups.contains(where: { $0.id == group.id }) { groups.append(group) }
            next.tabGroups = groups
            var tabs = next.tabs
            for tab in document.tabs where !tabs.contains(where: { $0.id == tab.id }) { tabs.append(tab) }
            next.tabs = tabs
            var sites = next.siteSettings
            for site in document.siteSettings where !sites.contains(where: { $0.host == site.host }) { sites.append(site) }
            next.siteSettings = sites
            var bookmarks = next.bookmarks
            for page in document.bookmarks where !bookmarks.contains(where: { $0.url == page.url }) { bookmarks.append(page) }
            next.bookmarks = bookmarks
            var folders = next.bookmarkFolders
            for folder in document.bookmarkFolders where !folders.contains(where: { $0.id == folder.id }) { folders.append(folder) }
            next.bookmarkFolders = folders
            if let scripts = document.userscripts {
                var kept = next.scripts
                for script in scripts where !kept.contains(where: { $0.id == script.id }) { kept.append(script) }
                next.scripts = kept
            }
            if next.settings.webFontFamily.isEmpty { next.settings.webFontFamily = document.settings.webFontFamily }
            if next.settings.headingFontFamily.isEmpty { next.settings.headingFontFamily = document.settings.headingFontFamily }
            if next.settings.monospaceFontFamily.isEmpty { next.settings.monospaceFontFamily = document.settings.monospaceFontFamily }
            if next.settings.activeGroupID == nil { next.settings.activeGroupID = document.activeGroupID }
            var rules = next.settings.customRules
            for rule in document.settings.customRules where !rules.contains(where: { $0.id == rule.id }) { rules.append(rule) }
            next.settings.customRules = rules
            var subs = next.settings.subscriptions
            for item in document.settings.subscriptions where !subs.contains(where: { $0.id == item.id }) { subs.append(item) }
            next.settings.subscriptions = subs
            var engines = next.settings.customEngines
            for engine in document.settings.customEngines where !engines.contains(where: { $0.id == engine.id }) { engines.append(engine) }
            next.settings.customEngines = engines
            var fonts = next.settings.importedFonts
            for font in document.settings.importedFonts where !fonts.contains(where: { $0.id == font.id }) { fonts.append(font) }
            next.settings.importedFonts = fonts
        }
        next.tabs.removeAll { $0.isPrivate }
        return next
    }
}
