import SwiftUI
import WebKit

struct ScriptDraft: Identifiable {
    var id = UUID()
    var source: String
    var existingID: UUID?
    var profileID: UUID?
}

@MainActor final class AppModel: ObservableObject {
    @Published var state: AppState
    @Published var session: BrowserSession?
    @Published var message: String?
    @Published var scriptDraft: ScriptDraft?
    @Published var preparedExtension: PreparedExtension?
    @Published var working = false
    @Published var pendingShareCount = 0
    private var presentedShareID: UUID?
    private var shareQueuePaused = false
    var shareInbox: ShareInbox { ShareInbox(container: root) }
    let downloadCenter = DownloadCenter()
    let root: URL
    let isTesting = ProcessInfo.processInfo.arguments.contains("--uitesting")
    var profile: BrowserProfile { state.profiles.first { $0.id == state.activeProfileID } ?? state.profiles[0] }

    init(storageRoot: URL? = nil) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        root = storageRoot ?? base.appendingPathComponent(isTesting ? "Rikugan-UITests" : "Rikugan", isDirectory: true)
        if isTesting { try? FileManager.default.removeItem(at: root) }
        var initial = AppState.fresh(), warning: String?
        let file = root.appendingPathComponent("state.json")
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: file.path) {
                initial = try StateMigration.decode(Data(contentsOf: file))
            }
        } catch {
            if FileManager.default.fileExists(atPath: file.path) {
                let backup = root.appendingPathComponent("state-recovery-\(Int(Date().timeIntervalSince1970)).json")
                try? FileManager.default.copyItem(at: file, to: backup)
            }
            warning = "无法读取资料，已保留恢复副本：\(error.localizedDescription)"
            initial = .fresh()
        }
        state = initial
        message = warning
        downloadCenter.activate(self)
        registerFonts()
        pendingShareCount = (try? shareInbox.items().count) ?? 0
        #if DEBUG
        if isTesting && ProcessInfo.processInfo.arguments.contains("--share-queue-fixture") {
            let items = (1...2).map { index in
                SharedItem(kind: .script, value: "// ==UserScript==\n// @name Share queued \(index)\n// @match https://example.com/*\n// @grant none\n// ==/UserScript==\ndocument.body.dataset.shared = '\(index)';")
            }
            try? shareInbox.enqueue(SharedBatch(items: items)); refreshShareCount()
        }
        #endif
    }

    func start() {
        guard session == nil else { return }
        activate(state.activeProfileID)
    }
    func save(_ newState: AppState) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(newState).write(to: root.appendingPathComponent("state.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        state = newState
    }
    func updateProfile(_ id: UUID, _ mutate: (inout BrowserProfile) -> Void) {
        guard let index = state.profiles.firstIndex(where: { $0.id == id }) else { return }
        var next = state; mutate(&next.profiles[index])
        do { try save(next) } catch { message = "保存失败：\(error.localizedDescription)" }
    }
    func activate(_ id: UUID) {
        guard state.profiles.contains(where: { $0.id == id }) else { return }
        session?.shutdown()
        var next = state; next.activeProfileID = id
        do { try save(next) } catch { message = error.localizedDescription }
        registerFonts()
        let newSession = BrowserSession(model: self, profileID: id)
        session = newSession
        Task { await newSession.start() }
    }
    func addProfile(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let icons = ["person.crop.circle", "briefcase", "sparkles", "leaf", "moon.stars", "flask"]
        let profile = BrowserProfile(name: String(trimmed.prefix(40)), symbol: icons[state.profiles.count % icons.count])
        var next = state; next.profiles.append(profile)
        do { try save(next); activate(profile.id) } catch { message = error.localizedDescription }
    }
    func deleteProfile(_ id: UUID) {
        guard state.profiles.count > 1 else { message = "至少保留一个身份空间。"; return }
        downloadCenter.removeProfile(id)
        if state.activeProfileID == id, let other = state.profiles.first(where: { $0.id != id }) { activate(other.id) }
        var next = state; next.profiles.removeAll { $0.id == id }
        do { try save(next) } catch { message = error.localizedDescription; return }
        try? FileManager.default.removeItem(at: directory(id))
        WKWebsiteDataStore.remove(forIdentifier: id) { [weak self] error in
            if let error { Task { @MainActor in self?.message = "身份已删除，网站存储清理未完成：\(error.localizedDescription)" } }
        }
    }
    func directory(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    func handleIncomingURL(_ url: URL) {
        guard url.scheme?.lowercased() == "rikugan" else { handleFile(url); return }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let action = items.first { $0.name == "action" }?.value ?? (url.host == "search" ? "search" : "open")
        if url.host == "pending" {
            consumeShareFile(); return
        }
        if let value = items.first(where: { $0.name == "url" })?.value ?? items.first(where: { $0.name == "text" })?.value {
            do {
                var item = try ShareInputReader.text(value)
                if action == "search" { item.kind = .search }
                try shareInbox.enqueue(SharedBatch(items: [item]))
                refreshShareCount(); presentPendingShares()
            } catch { message = error.localizedDescription }
            return
        }
        consumeShareFile()
    }
    func consumeShareFile() {
        do {
            if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppGroupID.suite) {
                try ShareInbox(container: container).transfer(to: shareInbox)
                let legacy = container.appendingPathComponent("share-inbox.json")
                if FileManager.default.fileExists(atPath: legacy.path) {
                    guard (try legacy.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 32_000,
                          let json = try JSONSerialization.jsonObject(with: Data(contentsOf: legacy)) as? [String: String] else {
                        throw ShareInboxError.invalid("旧版分享内容无效，未删除原文件。")
                    }
                    let value = json["action"] == "search" || (json["url"] ?? "").isEmpty ? (json["text"] ?? "") : (json["url"] ?? "")
                    var item = try ShareInputReader.text(value)
                    if json["action"] == "search" { item.kind = .search }
                    try shareInbox.enqueue(SharedBatch(items: [item]))
                    try FileManager.default.removeItem(at: legacy)
                }
            }
            refreshShareCount(); presentPendingShares()
        } catch { message = "接收分享失败，原内容保留：\(error.localizedDescription)" }
    }
    func applyPendingShare() {
        guard !shareQueuePaused, !working, scriptDraft == nil, presentedShareID == nil,
              preparedExtension == nil, let session, session.ready else { return }
        do {
            for item in try shareInbox.items() {
                if item.kind == .script {
                    _ = try UserScript.parse(item.value)
                    presentedShareID = item.id
                    scriptDraft = ScriptDraft(source: item.value, profileID: session.profileID)
                    return // No script is installed until the editor confirms it.
                }
                let url = item.kind == .search ? URLRules.searchURL(item.value, template: profile.searchEngine) : URL(string: item.value)
                guard let url, ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { throw ShareInboxError.invalid("分享内容不能作为网页打开。") }
                if session.activeTab?.isHome == true { session.activeTab?.navigate(url) }
                else { session.addTab(url: url) }
                try shareInbox.acknowledge(item.id)
                refreshShareCount()
            }
        } catch {
            shareQueuePaused = true
            message = "分享队列已暂停，内容仍保留。可在设置的「待处理分享」继续或移除：\(error.localizedDescription)"
        }
    }
    func scriptEditorDidDismiss() {
        if let id = presentedShareID {
            do { try shareInbox.acknowledge(id) } catch { message = error.localizedDescription; shareQueuePaused = true }
            presentedShareID = nil; refreshShareCount()
        }
        // The prior sheet is now actually dismissed; presenting the next one
        // earlier lets SwiftUI replace or lose the user's confirmation sheet.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            self?.applyPendingShare()
        }
    }
    func presentPendingShares() {
        guard pendingShareCount > 0, !shareQueuePaused, scriptDraft == nil else { return }
        session?.requestedPanel = "dismiss"
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            self?.applyPendingShare()
        }
    }
    func resumeShareQueue() { shareQueuePaused = false; presentPendingShares() }
    func discardShare(_ id: UUID) throws { try shareInbox.acknowledge(id); refreshShareCount() }
    func refreshShareCount() { pendingShareCount = (try? shareInbox.items().count) ?? 0 }
    func handleFile(_ url: URL) {
        Task {
            working = true; defer { working = false; presentPendingShares() }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                let ext = url.pathExtension.lowercased()
                if ext == "zip" || ext == "crx" || values.isDirectory == true {
                    preparedExtension = try await session?.prepareExtension(url)
                } else if ["ttf", "otf", "ttc", "woff", "woff2"].contains(ext) {
                    try importFont(url)
                } else {
                    guard (values.fileSize ?? 0) <= 2_000_000 else { throw RikuganError.message("脚本不得超过 2 MB。") }
                    let text = try String(contentsOf: url, encoding: .utf8)
                    _ = try UserScript.parse(text)
                    try shareInbox.enqueue(SharedBatch(items: [SharedItem(kind: .script, value: text, name: String(url.lastPathComponent.prefix(120)))]))
                    refreshShareCount()
                }
            } catch { message = error.localizedDescription }
        }
    }
    func importScriptURL(_ value: String) async {
        guard let url = URL(string: value), url.scheme?.lowercased() == "https" || (isTesting && url.scheme == "http") else {
            message = "请输入 HTTPS 用户脚本直链。"; return
        }
        working = true; defer { working = false; presentPendingShares() }
        do {
            let text = try await ScriptNetwork.downloadText(url)
            _ = try UserScript.parse(text)
            try shareInbox.enqueue(SharedBatch(items: [SharedItem(kind: .script, value: text, name: String(url.lastPathComponent.prefix(120)))]))
            refreshShareCount()
        } catch { message = error.localizedDescription }
    }
    func installScript(_ source: String, existingID: UUID? = nil, expectedProfileID: UUID? = nil) async throws {
        let profileID = state.activeProfileID
        guard expectedProfileID == nil || expectedProfileID == profileID else { throw RikuganError.message("确认安装期间身份已切换，请关闭后在目标身份重新导入。") }
        var script = try UserScript.parse(source)
        if let old = profile.scripts.first(where: { $0.id == existingID }) {
            script.id = old.id; script.storageJSON = old.storageJSON; script.enabled = old.enabled
        }
        for dependency in script.requires {
            guard let url = URL(string: dependency), url.scheme?.lowercased() == "https" else { throw RikuganError.message("@require 只接受 HTTPS 地址。") }
            script.dependencies.append(try await ScriptNetwork.downloadText(url))
        }
        try UserScriptSyntax.validate(script.dependencies.joined(separator: "\n;\n") + "\n;\n" + script.source)
        for index in script.resources.indices {
            guard let url = URL(string: script.resources[index].url) else { throw RikuganError.message("@resource 地址无效。") }
            guard url.scheme?.lowercased() == "https" || (isTesting && url.scheme == "http") else { throw RikuganError.message("@resource 只接受 HTTPS 地址。") }
            let (data, mime) = try await ScriptNetwork.download(url, limit: 1_000_000)
            script.resources[index].dataBase64 = data.base64EncodedString()
            script.resources[index].mime = mime
        }
        script.updatedAt = Date()
        try commitScript(script, profileID: profileID, replacing: existingID)
        if session?.profileID == profileID { session?.refreshScripts() }
    }
    func commitScript(_ prepared: UserScript, profileID: UUID, replacing existingID: UUID?) throws {
        guard let p = state.profiles.firstIndex(where: { $0.id == profileID }) else {
            throw RikuganError.message("安装期间身份已删除，未保存脚本。")
        }
        var next = state, script = prepared
        if let existingID {
            guard let i = next.profiles[p].scripts.firstIndex(where: { $0.id == existingID }) else {
                throw RikuganError.message("安装期间原脚本已删除，没有创建重复副本。")
            }
            let current = next.profiles[p].scripts[i]
            script.id = current.id; script.enabled = current.enabled; script.storageJSON = current.storageJSON
            next.profiles[p].scripts[i] = script
        } else { next.profiles[p].scripts.append(script) }
        // Fetching dependencies can take time. Read the latest GM data and enabled
        // state only at commit, and propagate disk errors rather than claiming success.
        try save(next)
    }
    func installDemos() async {
        guard let session else { return }
        working = true; defer { working = false }
        do {
            if !profile.scripts.contains(where: { $0.name == "Rikugan Demo Script" }),
               let file = Bundle.main.url(forResource: "Demo", withExtension: "user.js") {
                try await installScript(String(contentsOf: file, encoding: .utf8))
            }
            if !profile.extensions.contains(where: { $0.name == "Rikugan Demo" }),
               let file = Bundle.main.url(forResource: "DemoExtension", withExtension: "zip") {
                let prepared = try await session.prepareExtension(file)
                try await session.installExtension(prepared)
            }
            message = "自检组件已安装。打开 example.com 测试页，可看到扩展和用户脚本的运行结果。"
        } catch { message = error.localizedDescription }
    }
    func checkScriptUpdate(_ script: UserScript) async -> String? {
        let owner = profile.id
        do {
            let text = try await ScriptUpdateResolver.source(for: script)
            guard profile.id == owner else { throw RikuganError.message("检查更新期间身份已切换，未打开安装确认。") }
            guard let text else { message = "已是最新版本 \(script.version)。"; return nil }
            return text
        } catch { message = error.localizedDescription; return nil }
    }
    func reinstallScript(_ script: UserScript) async {
        let owner = profile.id
        do {
            let text = try await ScriptUpdateResolver.source(for: script, checkVersion: false)
            guard profile.id == owner else { throw RikuganError.message("重新安装期间身份已切换，未修改脚本。") }
            if let text { scriptDraft = ScriptDraft(source: text, existingID: script.id) }
        } catch { message = error.localizedDescription }
    }
    func exportBackup() throws -> URL {
        let backup = PortableBackup(tabs: profile.tabs, tabGroups: profile.tabGroups, selectedTabID: profile.selectedTabID,
                                    bookmarks: profile.bookmarks, bookmarkFolders: profile.bookmarkFolders, settings: profile.settings,
                                    siteSettings: profile.siteSettings, searchEngine: profile.searchEngine, searchHistory: profile.searchHistory)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Rikugan-backup.json")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(backup).write(to: url, options: .atomic)
        return url
    }
    func importBackup(_ data: Data) throws { try applyBackup(BackupImporter.decode(data), merge: false) }
    func applyBackup(_ backup: PortableBackup, merge: Bool) throws {
        // Reject invalid direct callers too, before stopping the current session.
        try BackupImporter.validate(backup)
        // Persist and stop the OLD session first, so shutdown cannot overwrite imported tabs.
        session?.shutdown()
        let previous = state
        do {
            let recovery = root.appendingPathComponent("before-import-\(UUID().uuidString).json")
            try JSONEncoder().encode(previous).write(to: recovery, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            guard let index = state.profiles.firstIndex(where: { $0.id == state.activeProfileID }) else {
                throw RikuganError.message("当前身份不存在。")
            }
            var next = state
            next.profiles[index] = BackupImporter.applying(backup, to: next.profiles[index], merge: merge)
            try save(next)
            activate(next.activeProfileID)
            registerFonts()
            message = "已导入标签页、分组和设置，原资料已保留恢复副本。"
        } catch {
            state = previous
            activate(previous.activeProfileID)
            throw error
        }
    }
    func registerFonts() {
        for font in profile.settings.importedFonts {
            let url = directory(profile.id).appendingPathComponent("Fonts").appendingPathComponent(font.fileName)
            if FileManager.default.fileExists(atPath: url.path) { try? FontLibrary.register(url) }
        }
    }
    func importFont(_ url: URL) throws {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        guard data.count <= 2_500_000 else { throw RikuganError.message("字体文件不能超过 2.5 MB。") }
        let folder = directory(profile.id).appendingPathComponent("Fonts", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fileName = UUID().uuidString + "." + (url.pathExtension.isEmpty ? "ttf" : url.pathExtension)
        let destination = folder.appendingPathComponent(fileName)
        try data.write(to: destination, options: .atomic)
        let family: String
        do { family = try FontLibrary.register(destination) }
        catch { try? FileManager.default.removeItem(at: destination); throw error }
        updateProfile(profile.id) { $0.settings.importedFonts.append(ImportedFont(family: family, fileName: fileName)); $0.settings.webFontFamily = family }
        session?.refreshScripts()
        session?.tabs.forEach { $0.applyDecorations() }
    }
    func importWallpaper(_ url: URL) throws {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        guard (1...8_000_000).contains(data.count) else { throw RikuganError.message("壁纸图片需要小于 8 MB。") }
        let ext = url.pathExtension.lowercased()
        let fileName = "wallpaper." + (["jpg", "jpeg", "png", "heic", "webp"].contains(ext) ? ext : "img")
        let folder = directory(profile.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: folder.appendingPathComponent(fileName), options: .atomic)
        updateProfile(profile.id) { $0.settings.wallpaperFile = fileName }
    }
    func clearWallpaper() {
        let name = profile.settings.wallpaperFile
        updateProfile(profile.id) { $0.settings.wallpaperFile = "" }
        if !name.isEmpty { try? FileManager.default.removeItem(at: directory(profile.id).appendingPathComponent(name)) }
    }
}

@main struct RikuganApp: App {
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(model)
                .task { model.start() }
                .onOpenURL { model.handleIncomingURL($0) }
                .onAppear { model.consumeShareFile() }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in model.consumeShareFile() }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("新标签页") { model.session?.addTab() }.keyboardShortcut("t")
                Button("关闭标签页") { if let tab = model.session?.activeTab { model.session?.close(tab) } }.keyboardShortcut("w")
            }
        }
        WindowGroup(for: UUID.self) { $tabID in
            if let tabID, let session = model.session, let tab = session.tabs.first(where: { $0.id == tabID }) {
                BrowserPage(tab: tab, session: session, openPanel: { _ in }).environmentObject(model)
            } else {
                ContentUnavailableView("标签已关闭", systemImage: "macwindow")
            }
        }
    }
}
