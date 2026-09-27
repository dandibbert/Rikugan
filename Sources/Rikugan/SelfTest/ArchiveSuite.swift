import Foundation

/// Import / export end-to-end with the real stores (spec §10): export → reset → import (replace)
/// restores the state; merge is idempotent; corrupt / too-new files are rejected without touching
/// anything; a v1 file migrates; a backup is written before every import.
@MainActor enum ArchiveSuite {
    struct Fingerprint: Equatable, CustomStringConvertible {
        var bookmarks: [String]
        var sites: [String]
        var scripts: [String]
        var tabs: [String]
        var groups: [String]
        var rules: String
        var description: String { "bm=\(bookmarks) sites=\(sites) scripts=\(scripts) tabs=\(tabs.count) groups=\(groups)" }
    }

    static func fingerprint(_ ctx: SelfTestContext) -> Fingerprint {
        let p = ctx.profile
        return Fingerprint(bookmarks: p.bookmarks.nodes.filter { !$0.isFolder }.map(\.title).sorted(),
                           sites: p.siteSettings.sites.keys.sorted(),
                           scripts: p.userscripts.scripts.map(\.metadata.name).sorted(),
                           tabs: ctx.manager.tabs.filter { !$0.isPrivate }.map { $0.url?.absoluteString ?? "" },
                           groups: ctx.manager.groups.map(\.name),
                           rules: ctx.services.adBlock.customRules)
    }

    static func run(_ ctx: SelfTestContext) async {
        let manager = ctx.manager
        let profile = ctx.profile
        let services = ctx.services

        // 1. Known state.
        manager.switchToGroup(nil)
        for tab in manager.tabs where tab.id != manager.activeTabID { manager.close(tab) }
        _ = profile.bookmarks.add(title: "Archive BM", url: "https://archive.example/", parent: nil)
        profile.siteSettings.update("archive.example") { $0.desktopMode = true }
        services.adBlock.addCustomRule("archive.example##.archive-ad")
        var scriptID: UUID?
        do {
            let script = try ctx.installScript("pageworld/none.user.js")
            profile.userscripts.replaceValues(["k": "\"v\""], for: script.id)
            scriptID = script.id
        } catch { ctx.record("安装测试脚本", false, error.localizedDescription) }
        let t1 = manager.newTab(url: ctx.url("/lifecycle/page.html?n=arch1"), isPrivate: false)
        let group = manager.createGroup(name: "Archive G")
        let t2 = manager.newTab(url: ctx.url("/lifecycle/page.html?n=arch2"), isPrivate: false)
        manager.move(t2, toGroup: group.id)
        manager.select(t2)
        _ = await ctx.waitLoaded(t1, path: "/lifecycle/page.html")
        _ = await ctx.waitLoaded(t2, path: "/lifecycle/page.html")
        let original = fingerprint(ctx)

        // 2. Export.
        let exported: Data
        do { exported = try ArchiveCodec.encode(ImportExport.buildArchive()) } catch { ctx.record("导出", false, error.localizedDescription); return }
        let archive: RikuganArchive
        do { archive = try ArchiveCodec.decode(exported) } catch { ctx.record("导出文件可重新解析", false, error.localizedDescription); return }
        let text = String(decoding: exported, as: UTF8.self)
        ctx.record("导出：formatVersion / exportedAt / appVersion / excluded / contents", archive.formatVersion == RikuganArchive.currentFormatVersion &&
                   !archive.appVersion.isEmpty && archive.excluded == RikuganArchive.excludedAlways && archive.contents.userscriptSource,
                   "v\(archive.formatVersion) app=\(archive.appVersion) bytes=\(exported.count) excluded=\(archive.excluded.joined(separator: ","))")
        ctx.record("导出不含 Cookie / 密码字段", !text.contains("\"cookies\"") && !text.contains("\"password\"") && !text.contains("\"credentials\""))
        ctx.extras["exportSummary"] = ["profiles": archive.summary.profiles, "tabs": archive.summary.tabs, "groups": archive.summary.groups,
                                       "bookmarks": archive.summary.bookmarks, "userscripts": archive.summary.userscripts, "bytes": exported.count]

        // 3. Reset: replace with an empty archive.
        var empty = archive
        for i in empty.profiles.indices {
            empty.profiles[i].bookmarks = []
            empty.profiles[i].siteSettings = []
            empty.profiles[i].userscripts = []
            empty.profiles[i].windows = [WindowSessionSnapshot()]
        }
        empty.contentBlocking.customRules = ""
        await ImportExport.apply(empty, mode: .replace, into: manager)
        let reset = fingerprint(ctx)
        ctx.record("重置（替换为空归档）", reset.bookmarks.isEmpty && reset.sites.isEmpty && !reset.scripts.contains("PW grant none") &&
                   !reset.tabs.contains { $0.contains("arch") } && !reset.rules.contains("archive-ad"), reset.description)

        // 4. Import (replace) restores the state.
        await ImportExport.apply(archive, mode: .replace, into: manager)
        let restored = fingerprint(ctx)
        ctx.record("导入（替换）恢复书签 / 网站设置 / 脚本 / 规则", restored.bookmarks == original.bookmarks && restored.sites == original.sites &&
                   restored.scripts == original.scripts && restored.rules.contains("archive-ad"), "\(restored) vs \(original)")
        ctx.record("导入（替换）恢复标签页顺序与分组", restored.tabs == original.tabs && restored.groups == original.groups,
                   "tabs=\(restored.tabs.map { URL(string: $0)?.query ?? "home" }) groups=\(restored.groups)")
        ctx.record("导入（替换）恢复当前组与当前标签页", manager.activeTab?.url?.query == "n=arch2" && manager.groups.first { $0.id == manager.currentGroupID }?.name == "Archive G",
                   "active=\(manager.activeTab?.url?.query ?? "nil") group=\(manager.groups.first { $0.id == manager.currentGroupID }?.name ?? "default")")
        let restoredScript = profile.userscripts.scripts.first { $0.metadata.name == "PW grant none" }
        ctx.record("导入恢复脚本存储值", restoredScript.map { profile.userscripts.values(for: $0.id)["k"] == "\"v\"" } == true,
                   restoredScript.map { "\(profile.userscripts.values(for: $0.id))" } ?? "script missing")
        ctx.record("网站设置内容正确", profile.siteSettings.sites["archive.example"]?.desktopMode == true)

        // 5. Merge is idempotent.
        await ImportExport.apply(archive, mode: .merge, into: manager)
        await ImportExport.apply(archive, mode: .merge, into: manager)
        let merged = fingerprint(ctx)
        ctx.record("合并两次：书签 / 网站 / 脚本不重复", merged.bookmarks == original.bookmarks && merged.sites == original.sites && merged.scripts == original.scripts,
                   merged.description)
        // Merge appends every tab that has a URL (empty start-page tabs are not imported).
        let withURL = { (f: Fingerprint) in f.tabs.filter { !$0.isEmpty }.count }
        ctx.record("合并：组按名称合并、有网址的标签页追加", merged.groups == original.groups && withURL(merged) == withURL(original) * 3,
                   "groups=\(merged.groups) tabs=\(withURL(merged)) expected=\(withURL(original) * 3)")

        // 6. Corrupt / too-new files never touch existing data.
        let before = fingerprint(ctx)
        var rejected: [String] = []
        for (label, data) in [("截断", exported.prefix(exported.count / 2)),
                              ("非 JSON", Data("not json".utf8)),
                              ("未来版本", Data(text.replacingOccurrences(of: "\"formatVersion\" : \(RikuganArchive.currentFormatVersion)", with: "\"formatVersion\" : 999").utf8)),
                              ("其他格式", Data(#"{"format":"something-else","formatVersion":1}"#.utf8))] {
            do { _ = try ArchiveCodec.decode(Data(data)); rejected.append("\(label): accepted!") } catch { rejected.append("\(label): \(error.localizedDescription)") }
        }
        ctx.record("损坏 / 未来版本 / 非本应用文件被拒绝", !rejected.contains { $0.contains("accepted!") }, rejected.joined(separator: " | "))
        ctx.record("拒绝后现有数据不变", fingerprint(ctx) == before)

        // 7. v1 migration.
        do {
            let v1 = try ArchiveCodec.decode(Data(contentsOf: ctx.root.appendingPathComponent("archive/v1-export.json")))
            await ImportExport.apply(v1, mode: .merge, into: manager)
            let after = fingerprint(ctx)
            ctx.record("v1 文件迁移后合并导入", after.bookmarks.contains("V1 Bookmark") && after.groups.contains("V1 Group") && after.scripts.contains("V1 Script") &&
                       profile.siteSettings.sites["v1.example"]?.desktopMode == true, after.description)
        } catch { ctx.record("v1 文件迁移", false, error.localizedDescription) }

        // 8. Backups.
        let backups = (try? FileManager.default.contentsOfDirectory(at: AppPaths.directory("Backups"), includingPropertiesForKeys: nil)) ?? []
        ctx.record("每次导入前写入备份", backups.filter { $0.lastPathComponent.hasPrefix("pre-import-") }.count >= 1, "\(backups.count) backup file(s)")

        // Cleanup.
        for script in profile.userscripts.scripts where ["PW grant none", "V1 Script"].contains(script.metadata.name) { profile.userscripts.delete(script.id) }
        if let scriptID { profile.userscripts.delete(scriptID) }
        services.adBlock.removeCustomRule("archive.example##.archive-ad")
        services.adBlock.removeCustomRule("v1.example##.v1-ad")
        manager.closeAll(inCurrentSpace: false)
    }
}
