import Foundation
import SwiftUI

struct BackupPreview: Identifiable {
    let id = UUID()
    let backup: PortableBackup
    let fileName: String
}

enum BackupImporter {
    static func decode(_ data: Data) throws -> PortableBackup {
        guard data.count <= 8_000_000 else { throw RikuganError.message("备份超过 8 MB，未修改任何数据。") }
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = object["version"] as? Int, [2, 3].contains(version) else {
            throw RikuganError.message("不支持的备份版本，未修改任何数据。支持 v2 自动迁移和 v3。")
        }
        if version == 2 {
            // Migrate only a recognized portable backup, never an arbitrary JSON
            // file or an AppState containing cookies/extension state.
            guard object["tabs"] is [[String: Any]], object["tabGroups"] is [[String: Any]],
                  object["bookmarks"] is [[String: Any]], let settings = object["settings"] as? [String: Any] else {
                throw RikuganError.message("v2 备份缺少必要的标签、分组、书签或设置。")
            }
            let defaults = try JSONSerialization.jsonObject(with: JSONEncoder().encode(PortableBackup())) as! [String: Any]
            for (key, value) in defaults where object[key] == nil { object[key] = value }
            var mergedSettings = defaults["settings"] as! [String: Any]
            mergedSettings.merge(settings) { _, imported in imported }
            object["settings"] = mergedSettings
            object["version"] = 3
            object["format"] = "com.dandibbert.rikugan.backup"
        }
        let backup = try JSONDecoder().decode(PortableBackup.self, from: JSONSerialization.data(withJSONObject: object))
        try validate(backup)
        return backup
    }

    static func validate(_ backup: PortableBackup) throws {
        guard backup.version == 3, backup.format == "com.dandibbert.rikugan.backup" else {
            throw RikuganError.message("不是支持的 Rikugan 备份格式。")
        }
        guard backup.tabs.count <= 5000, backup.bookmarks.count <= 10000,
              backup.tabGroups.count <= 500, backup.bookmarkFolders.count <= 1000 else {
            throw RikuganError.message("备份中的标签或分组数量超过限制。")
        }
        guard unique(backup.tabs.map(\.id)), unique(backup.tabGroups.map(\.id)),
              unique(backup.bookmarks.map(\.id)), unique(backup.bookmarkFolders.map(\.id)) else {
            throw RikuganError.message("备份存在重复标识，不能安全导入。")
        }
        let groups = Set(backup.tabGroups.map(\.id))
        let folders = Set(backup.bookmarkFolders.map(\.id))
        guard backup.selectedTabID == nil || backup.tabs.contains(where: { $0.id == backup.selectedTabID }),
              backup.bookmarkFolders.allSatisfy({ $0.parentID == nil || folders.contains($0.parentID!) }) else {
            throw RikuganError.message("备份选中的标签或书签父文件夹不存在。")
        }
        let parents = Dictionary(uniqueKeysWithValues: backup.bookmarkFolders.map { ($0.id, $0.parentID) })
        for folder in backup.bookmarkFolders {
            var seen = Set<UUID>(), next: UUID? = folder.id
            while let id = next {
                guard seen.insert(id).inserted else { throw RikuganError.message("书签文件夹存在循环引用，未导入。") }
                next = parents[id] ?? nil
            }
        }
        guard backup.tabs.allSatisfy({ (0...86400).contains($0.autoRefreshSeconds) }),
              backup.tabGroups.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.name.count <= 200 }),
              backup.siteSettings.count <= 10000, backup.settings.customRules.count <= 10000,
              backup.settings.subscriptions.count <= 100, backup.settings.customEngines.count <= 100,
              backup.settings.importedFonts.count <= 500, backup.searchHistory.count <= 10000,
              unique(backup.settings.customRules.map(\.id)), unique(backup.settings.subscriptions.map(\.id)),
              unique(backup.settings.customEngines.map(\.id)), unique(backup.settings.importedFonts.map(\.id)) else {
            throw RikuganError.message("备份包含重复设置标识、无效分组名称或超出范围的数量/刷新间隔。")
        }
        let settings = backup.settings
        guard ["top", "bottom"].contains(settings.addressBar), ["off", "auto", "on"].contains(settings.darkMode),
              ["favorites", "blank", "custom"].contains(settings.homepage),
              settings.reader.fontSize.isFinite, (8...100).contains(settings.reader.fontSize),
              settings.reader.lineHeight.isFinite, (0.5...5).contains(settings.reader.lineHeight),
              settings.subscriptions.allSatisfy({ URL(string: $0.url)?.scheme == "https" && validURL($0.url) }) else {
            throw RikuganError.message("备份包含不支持的设置值或订阅地址。")
        }
        var hosts = Set<String>()
        for site in backup.siteSettings {
            let host = site.host.lowercased()
            guard !host.isEmpty, hosts.insert(host).inserted, host.count <= 253,
                  !host.contains(where: { $0.isWhitespace }), !host.contains("/"), !host.contains("@"),
                  site.darkMode.map({ ["off", "auto", "on"].contains($0) }) ?? true,
                  site.externalNavigation.map({ ["ask", "allow", "block"].contains($0) }) ?? true,
                  site.popups.map({ ["ask", "allow", "block"].contains($0) }) ?? true else {
                throw RikuganError.message("备份包含重复或无效的站点设置。")
            }
        }
        guard backup.tabs.allSatisfy({ validURL($0.url) && ($0.groupID == nil || groups.contains($0.groupID!)) }),
              backup.bookmarks.allSatisfy({ validURL($0.url) && ($0.folderID == nil || folders.contains($0.folderID!)) }) else {
            throw RikuganError.message("备份含无效网址或不存在的分组。只接受普通网页和空白页。")
        }
        let fileNames = backup.settings.importedFonts.map(\.fileName) + [backup.settings.wallpaperFile]
        guard fileNames.allSatisfy({ $0.isEmpty || safeFileName($0) }) else {
            throw RikuganError.message("备份的资源路径不安全，未导入。")
        }
        guard backup.settings.customEngines.allSatisfy({ validURL($0.template.replacingOccurrences(of: "{query}", with: "test")) }),
              backup.searchEngine.isEmpty || validURL(backup.searchEngine.replacingOccurrences(of: "{query}", with: "test")),
              backup.settings.homepageURL.isEmpty || validURL(backup.settings.homepageURL) else {
            throw RikuganError.message("备份的搜索引擎或首页地址无效。")
        }
    }

    static func applying(_ backup: PortableBackup, to original: BrowserProfile, merge: Bool) -> BrowserProfile {
        var result = original
        if !merge {
            result.tabs = backup.tabs.filter { !$0.isPrivate }
            result.tabGroups = backup.tabGroups
            result.bookmarks = backup.bookmarks
            result.bookmarkFolders = backup.bookmarkFolders
            result.selectedTabID = backup.selectedTabID
        } else {
            var groupMap: [UUID: UUID] = [:]
            for var group in backup.tabGroups {
                let oldID = group.id
                if let existing = result.tabGroups.first(where: { $0.id == group.id && $0.name == group.name }) {
                    groupMap[oldID] = existing.id
                } else {
                    group.id = UUID(); groupMap[oldID] = group.id; result.tabGroups.append(group)
                }
            }
            for var tab in backup.tabs where !tab.isPrivate {
                tab.groupID = tab.groupID.flatMap { groupMap[$0] }
                guard !result.tabs.contains(where: { $0.url == tab.url && $0.groupID == tab.groupID }) else { continue }
                tab.id = UUID(); result.tabs.append(tab)
            }
            var folderMap: [UUID: UUID] = [:]
            for folder in backup.bookmarkFolders { folderMap[folder.id] = UUID() }
            for var folder in backup.bookmarkFolders {
                folder.id = folderMap[folder.id]!
                folder.parentID = folder.parentID.flatMap { folderMap[$0] }
                result.bookmarkFolders.append(folder)
            }
            for var bookmark in backup.bookmarks where !result.bookmarks.contains(where: { $0.url == bookmark.url }) {
                bookmark.id = UUID(); bookmark.folderID = bookmark.folderID.flatMap { folderMap[$0] }
                result.bookmarks.append(bookmark)
            }
        }
        if result.tabs.isEmpty { result.tabs = [SavedTab()] }
        if !result.tabs.contains(where: { $0.id == result.selectedTabID }) { result.selectedTabID = result.tabs.first?.id }
        result.settings = backup.settings
        // JSON exports do not contain font/image bytes. Never adopt a foreign file path.
        result.settings.importedFonts = original.settings.importedFonts
        result.settings.wallpaperFile = original.settings.wallpaperFile
        var seenShortcuts = Set<String>()
        result.settings.shortcuts = Array(backup.settings.shortcuts.filter { value in
            ShortcutCatalog.all.contains { $0.id == value } && seenShortcuts.insert(value).inserted
        }.prefix(4))
        result.siteSettings = backup.siteSettings
        result.searchEngine = backup.searchEngine
        result.searchHistory = Array(backup.searchHistory.prefix(500))
        return result
    }

    private static func unique(_ ids: [UUID]) -> Bool { Set(ids).count == ids.count }
    private static func safeFileName(_ value: String) -> Bool {
        !value.contains("/") && !value.contains("\\") && value != "." && value != ".." && !value.contains("\0")
    }
    private static func validURL(_ value: String) -> Bool {
        if value.isEmpty || value == "about:blank" { return true }
        guard value.utf8.count <= 16000, let url = URL(string: value),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return false }
        return true
    }
}

struct BackupPreviewSheet: View {
    let preview: BackupPreview
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var replace = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Section(preview.fileName) {
                    LabeledContent("备份格式", value: "v\(preview.backup.version)")
                    LabeledContent("普通标签页", value: "\(preview.backup.tabs.filter { !$0.isPrivate }.count)")
                    LabeledContent("标签分组", value: "\(preview.backup.tabGroups.count)")
                    LabeledContent("书签", value: "\(preview.backup.bookmarks.count)")
                }
                Section {
                    Text("只影响当前身份。v2 备份会先迁移到 v3 并校验。Cookie、历史、扩展、脚本和钥匙串不覆盖；字体文件与壁纸不包含在 JSON 中。导入前自动保存当前资料的恢复副本。").font(.footnote)
                    Button("合并标签和书签，导入设置") { perform(merge: true) }
                    Button("替换标签和书签，导入设置", role: .destructive) { replace = true }
                }
            }.navigationTitle("确认导入")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
                .confirmationDialog("替换当前身份的标签、分组和书签？", isPresented: $replace, titleVisibility: .visible) {
                    Button("替换", role: .destructive) { perform(merge: false) }
                }
                .alert("未能导入", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                    Button("好") { error = nil }
                } message: { Text(error ?? "") }
        }
    }
    private func perform(merge: Bool) {
        do { try model.applyBackup(preview.backup, merge: merge); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}
