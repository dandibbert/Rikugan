import Foundation

/// Long-term export / import format (spec §39 / §10 of the follow-up).
///
/// Format rules:
/// - `format` must be `"rikugan-archive"`; `formatVersion` is an integer that only increases.
/// - Readers ignore unknown fields (forward compatible); archives with a *newer* formatVersion are
///   rejected rather than half-imported.
/// - Older versions are migrated (v1 `rikugan-export` → v2).
/// - Sensitive data is never exported; the list is written into every archive (`excluded`).
public struct RikuganArchive: Codable, Equatable {
    public static let formatName = "rikugan-archive"
    public static let currentFormatVersion = 2
    public static let excludedAlways = ["passwords", "payment cards", "keychain items", "cookies", "website data (localStorage / IndexedDB / cache)",
                                        "session secrets", "extension packages", "extension storage", "font files", "wallpaper image"]

    public var format: String
    public var formatVersion: Int
    public var exportedAt: Date
    public var appVersion: String
    public var contents: Contents
    public var excluded: [String]
    public var settings: Preferences
    public var activeProfileID: UUID?
    public var profiles: [ProfileArchive]
    public var fonts: [FontMetadata]
    public var contentBlocking: ContentBlockingArchive

    public struct Contents: Codable, Equatable {
        /// Userscript source code is included (true) or only metadata (false).
        public var userscriptSource: Bool
        /// GM_setValue storage of userscripts is included.
        public var userscriptValues: Bool
        /// Extensions are exported as metadata only (id, name, version, store URL); never packages.
        public var extensionPackages: Bool
        public var fontFiles: Bool
        public init(userscriptSource: Bool = true, userscriptValues: Bool = true, extensionPackages: Bool = false, fontFiles: Bool = false) {
            self.userscriptSource = userscriptSource; self.userscriptValues = userscriptValues
            self.extensionPackages = extensionPackages; self.fontFiles = fontFiles
        }
    }

    public init(appVersion: String, settings: Preferences, activeProfileID: UUID?, profiles: [ProfileArchive], fonts: [FontMetadata],
                contentBlocking: ContentBlockingArchive, contents: Contents = Contents(), exportedAt: Date = Date()) {
        format = Self.formatName
        formatVersion = Self.currentFormatVersion
        self.exportedAt = exportedAt
        self.appVersion = appVersion
        self.contents = contents
        excluded = Self.excludedAlways
        self.settings = settings
        self.activeProfileID = activeProfileID
        self.profiles = profiles
        self.fonts = fonts
        self.contentBlocking = contentBlocking
    }

    public struct Summary: Equatable {
        public var profiles = 0, windows = 0, tabs = 0, groups = 0, bookmarks = 0, siteSettings = 0, userscripts = 0, extensions = 0, customRules = 0, fonts = 0
    }

    public var summary: Summary {
        var s = Summary()
        s.profiles = profiles.count
        for p in profiles {
            s.windows += p.windows.count
            s.tabs += p.windows.reduce(0) { $0 + $1.tabs.count }
            s.groups += p.windows.reduce(0) { $0 + $1.groups.count }
            s.bookmarks += p.bookmarks.filter { !$0.isFolder }.count
            s.siteSettings += p.siteSettings.count
            s.userscripts += p.userscripts.count
            s.extensions += p.extensions.count
        }
        s.customRules = contentBlocking.customRules.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
        s.fonts = fonts.count
        return s
    }
}

public struct ProfileArchive: Codable, Equatable {
    public var id: UUID
    public var name: String
    public var symbol: String
    public var isDefault: Bool
    public var siteSettings: [SiteSettings]
    public var bookmarks: [BookmarkNode]
    /// Windows with tab groups, tab order, active group and active tab.
    public var windows: [WindowSessionSnapshot]
    public var userscripts: [ArchivedUserscript]
    public var extensions: [ExtensionMetadata]

    public init(id: UUID, name: String, symbol: String, isDefault: Bool, siteSettings: [SiteSettings] = [], bookmarks: [BookmarkNode] = [],
                windows: [WindowSessionSnapshot] = [], userscripts: [ArchivedUserscript] = [], extensions: [ExtensionMetadata] = []) {
        self.id = id; self.name = name; self.symbol = symbol; self.isDefault = isDefault; self.siteSettings = siteSettings
        self.bookmarks = bookmarks; self.windows = windows; self.userscripts = userscripts; self.extensions = extensions
    }

    public var data: ProfileData {
        ProfileData(siteSettings: siteSettings, bookmarks: bookmarks, windows: windows, userscripts: userscripts)
    }
}

public struct ArchivedUserscript: Codable, Equatable {
    public var name: String
    public var namespace: String
    public var version: String
    public var enabled: Bool
    public var sourceURL: String?
    /// Present when `contents.userscriptSource` is true.
    public var source: String?
    /// JSON-encoded GM values, present when `contents.userscriptValues` is true.
    public var values: [String: String]?

    public init(name: String, namespace: String, version: String, enabled: Bool, sourceURL: String?, source: String?, values: [String: String]?) {
        self.name = name; self.namespace = namespace; self.version = version; self.enabled = enabled
        self.sourceURL = sourceURL; self.source = source; self.values = values
    }
}

public struct ExtensionMetadata: Codable, Equatable {
    public var id: String
    public var name: String
    public var version: String
    public var enabled: Bool
    public var source: String
    public var storeURL: String?
    public init(id: String, name: String, version: String, enabled: Bool, source: String, storeURL: String?) {
        self.id = id; self.name = name; self.version = version; self.enabled = enabled; self.source = source; self.storeURL = storeURL
    }
}

public struct FontMetadata: Codable, Equatable {
    public var family: String
    public var fileName: String
    public init(family: String, fileName: String) { self.family = family; self.fileName = fileName }
}

public struct ContentBlockingArchive: Codable, Equatable {
    public var enabled: Bool
    public var customRules: String
    public var subscriptions: [FilterSubscription]
    public var allowlist: [String]
    public init(enabled: Bool, customRules: String, subscriptions: [FilterSubscription], allowlist: [String]) {
        self.enabled = enabled; self.customRules = customRules; self.subscriptions = subscriptions; self.allowlist = allowlist
    }
}

/// Mutable per-profile data the archive applies to.
public struct ProfileData: Equatable {
    public var siteSettings: [SiteSettings]
    public var bookmarks: [BookmarkNode]
    public var windows: [WindowSessionSnapshot]
    public var userscripts: [ArchivedUserscript]
    public init(siteSettings: [SiteSettings] = [], bookmarks: [BookmarkNode] = [], windows: [WindowSessionSnapshot] = [], userscripts: [ArchivedUserscript] = []) {
        self.siteSettings = siteSettings; self.bookmarks = bookmarks; self.windows = windows; self.userscripts = userscripts
    }
}

public enum ArchiveCodec {
    public enum ImportMode: String, CaseIterable { case merge, replace }

    static func isoFormatter(fractional: Bool) -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = fractional ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        return formatter
    }

    public static func encode(_ archive: RikuganArchive) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(ArchiveCodec.isoFormatter(fractional: true).string(from: date))
        }
        encoder.dataEncodingStrategy = .base64
        return try encoder.encode(archive)
    }

    /// Decodes, migrates and validates an archive. Throws a user-facing error for corrupt,
    /// foreign or too-new files. Never partially applies anything.
    public static func decode(_ data: Data) throws -> RikuganArchive {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RikuganError("文件不是有效的 JSON，可能已损坏")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            // v1 exports used Foundation's default (seconds since 2001) numbers.
            if let seconds = try? container.decode(Double.self) { return Date(timeIntervalSinceReferenceDate: seconds) }
            let text = try container.decode(String.self)
            if let date = ArchiveCodec.isoFormatter(fractional: true).date(from: text) ?? ArchiveCodec.isoFormatter(fractional: false).date(from: text) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "无效日期：\(text)")
        }
        decoder.dataDecodingStrategy = .base64
        let format = object["format"] as? String
        if format == "rikugan-export" {
            // v1 migration.
            let legacy: ExportBundle
            do { legacy = try ExportBundle.decode(data) } catch { throw RikuganError("旧版导出文件已损坏：\(error.localizedDescription)") }
            guard legacy.version == 1 else { throw RikuganError("不支持的旧版导出格式版本 \(legacy.version)") }
            let migrated = migrateV1(legacy)
            let problems = validate(migrated) + settingsTypeProblems(object["preferences"])
            guard problems.isEmpty else { throw RikuganError("导出文件校验失败：" + problems.prefix(5).joined(separator: "；")) }
            return migrated
        }
        guard format == RikuganArchive.formatName else { throw RikuganError("不是 Rikugan 导出文件") }
        guard let version = object["formatVersion"] as? Int else { throw RikuganError("缺少 formatVersion") }
        guard version >= 1 else { throw RikuganError("无效的格式版本 \(version)") }
        guard version <= RikuganArchive.currentFormatVersion else {
            throw RikuganError("该文件由更新版本的 Rikugan 导出（格式版本 \(version)），请先升级 App")
        }
        let archive: RikuganArchive
        do { archive = try decoder.decode(RikuganArchive.self, from: data) } catch {
            throw RikuganError("导出文件结构无效：\(error.localizedDescription)")
        }
        let problems = validate(archive) + settingsTypeProblems(object["settings"])
        guard problems.isEmpty else { throw RikuganError("导出文件校验失败：" + problems.prefix(5).joined(separator: "；")) }
        return archive
    }

    /// Known settings with a value of the wrong JSON type are an error (the tolerant decoder would
    /// silently fall back to the default and report a successful import). Unknown keys are ignored.
    static func settingsTypeProblems(_ raw: Any?) -> [String] {
        guard let settings = raw as? [String: Any],
              let defaults = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(Preferences()))) as? [String: Any] else { return [] }
        func kind(_ value: Any) -> String {
            if value is NSNull { return "null" }
            if let number = value as? NSNumber { return CFGetTypeID(number as CFTypeRef) == CFBooleanGetTypeID() ? "bool" : "number" }
            if value is String { return "string" }
            if value is [Any] { return "array" }
            if value is [String: Any] { return "object" }
            return "other"
        }
        return settings.compactMap { key, value in
            guard let expected = defaults[key], !(value is NSNull) else { return nil }
            return kind(expected) == kind(value) ? nil : "设置项 \(key) 的类型无效（应为 \(kind(expected))）"
        }.sorted()
    }

    public static func validate(_ archive: RikuganArchive) -> [String] {
        var problems: [String] = []
        if Set(archive.profiles.map(\.id)).count != archive.profiles.count { problems.append("重复的身份 ID") }
        for profile in archive.profiles {
            for (i, window) in profile.windows.enumerated() {
                problems += SessionOps.validate(window).map { "身份「\(profile.name)」窗口 \(i + 1)：\($0)" }
            }
            problems += BookmarkTree.problems(profile.bookmarks).map { "身份「\(profile.name)」：\($0)" }
            if archive.contents.userscriptSource, profile.userscripts.contains(where: { $0.source == nil }) {
                problems.append("声明包含脚本源码但缺少 source")
            }
            for script in profile.userscripts {
                if let source = script.source, MetadataParser.parse(source).hasErrors {
                    problems.append("脚本「\(script.name)」的元数据无效：\(MetadataParser.parse(source).firstError ?? "")")
                }
            }
            let tabIDs = profile.windows.flatMap { $0.tabs.map(\.id) }
            if Set(tabIDs).count != tabIDs.count { problems.append("身份「\(profile.name)」中有重复的标签页 ID") }
            for window in profile.windows {
                for tab in window.tabs where !tab.url.isEmpty && URL(string: tab.url)?.scheme == nil {
                    problems.append("身份「\(profile.name)」中有无效的标签页网址")
                    break
                }
            }
        }
        if archive.profiles.filter(\.isDefault).count > 1 { problems.append("有多个默认身份") }
        if let active = archive.activeProfileID, !archive.profiles.contains(where: { $0.id == active }) {
            problems.append("当前身份 ID 不在身份列表中")
        }
        return problems
    }

    public static func migrateV1(_ v1: ExportBundle) -> RikuganArchive {
        let profile = ProfileArchive(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "个人", symbol: "person.crop.circle", isDefault: true,
            siteSettings: v1.siteSettings, bookmarks: v1.bookmarks,
            windows: v1.sessions.map { var w = $0; SessionOps.repair(&w); return w },
            userscripts: v1.userscripts.map { script in
                let meta = MetadataParser.parse(script.source).metadata
                return ArchivedUserscript(name: meta.name, namespace: meta.namespace, version: meta.version, enabled: script.enabled,
                                          sourceURL: nil, source: script.source, values: script.values)
            })
        var archive = RikuganArchive(appVersion: "migrated-from-v1", settings: v1.preferences, activeProfileID: profile.id, profiles: [profile], fonts: [],
                                     contentBlocking: ContentBlockingArchive(enabled: v1.preferences.adBlockEnabled, customRules: v1.adBlockCustomRules,
                                                                             subscriptions: v1.adBlockSubscriptions, allowlist: v1.adBlockAllowlist),
                                     exportedAt: v1.exportedAt)
        archive.formatVersion = RikuganArchive.currentFormatVersion
        return archive
    }

    /// Applies one archived profile to existing profile data.
    /// - merge: site settings by host (incoming wins), bookmarks deduplicated by URL within a folder,
    ///   windows appended (tab / group IDs are re-generated so nothing collides), userscripts
    ///   replaced by name + namespace.
    /// - replace: incoming data replaces current data entirely.
    public static func apply(_ incoming: ProfileArchive, to current: ProfileData, mode: ImportMode) -> ProfileData {
        switch mode {
        case .replace:
            var data = incoming.data
            for i in data.windows.indices { SessionOps.repair(&data.windows[i]) }
            return data
        case .merge:
            var result = current
            var sites = Dictionary(current.siteSettings.map { ($0.host, $0) }, uniquingKeysWith: { a, _ in a })
            for site in incoming.siteSettings { sites[site.host] = site }
            result.siteSettings = sites.values.sorted { $0.host < $1.host }
            var nodes = current.bookmarks
            var idMap: [UUID: UUID] = [:]
            // Parents before children, so every folder's parent mapping is known when it is placed.
            for node in BookmarkTree.foldersParentFirst(incoming.bookmarks) {
                let parent = node.parentID.flatMap { idMap[$0] ?? $0 }
                if let existing = nodes.first(where: { $0.isFolder && ($0.id == node.id || ($0.title == node.title && $0.parentID == parent)) }) {
                    idMap[node.id] = existing.id
                } else {
                    var copy = node
                    copy.parentID = parent
                    nodes.append(copy)
                    idMap[node.id] = node.id
                }
            }
            for node in incoming.bookmarks where !node.isFolder {
                let parent = node.parentID.flatMap { idMap[$0] ?? $0 }
                if nodes.contains(where: { !$0.isFolder && $0.url == node.url && $0.parentID == parent }) { continue }
                var copy = node
                if nodes.contains(where: { $0.id == copy.id }) { copy.id = UUID() }
                copy.parentID = parent
                nodes.append(copy)
            }
            result.bookmarks = nodes
            for window in incoming.windows {
                var copy = window
                var groupMap: [UUID: UUID] = [:]
                for i in copy.groups.indices { let fresh = UUID(); groupMap[copy.groups[i].id] = fresh; copy.groups[i].id = fresh }
                var tabMap: [UUID: UUID] = [:]
                for i in copy.tabs.indices {
                    let fresh = UUID(); tabMap[copy.tabs[i].id] = fresh; copy.tabs[i].id = fresh
                    copy.tabs[i].groupID = copy.tabs[i].groupID.flatMap { groupMap[$0] }
                }
                copy.selectedGroupID = copy.selectedGroupID.flatMap { groupMap[$0] }
                copy.selectedTabID = copy.selectedTabID.flatMap { tabMap[$0] }
                SessionOps.repair(&copy)
                result.windows.append(copy)
            }
            for script in incoming.userscripts {
                result.userscripts.removeAll { $0.name == script.name && $0.namespace == script.namespace }
                result.userscripts.append(script)
            }
            return result
        }
    }
}
