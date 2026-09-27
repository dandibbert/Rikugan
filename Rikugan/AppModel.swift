import SwiftUI
import UserNotifications
import WebKit

struct ScriptDraft: Identifiable { var id = UUID(); var source: String; var existingID: UUID? }

struct PageNotice: Identifiable, Equatable {
    var id = UUID()
    var host: String
    var title: String
    var body: String
    var date = Date()
    var extensionNotificationID = ""
    var extensionRuntimeID = ""
    var buttons: [String] = []
    var iconURL = ""
    var imageURL = ""
    var progress: Int? = nil
    var iconData: Data? = nil
    var imageData: Data? = nil
}

@MainActor final class AppModel: ObservableObject {
    @Published var state: AppState
    @Published var session: BrowserSession?
    @Published var message: String?
    @Published var scriptDraft: ScriptDraft?
    @Published var preparedExtension: PreparedExtension?
    @Published var working = false
    @Published var pendingShare: (action: String, value: String)?
    @Published var notices: [PageNotice] = []
    @Published var noticeToast: PageNotice?
    var extensionNotices: [String: ExtensionNoticeRecord] = [:]
    var pendingExtensionEvents: [ExtensionNotificationEvent] = []
    let downloadCenter = DownloadCenter()
    let windows = WindowRegistry()
    let root: URL
    let isTesting = ProcessInfo.processInfo.arguments.contains("--uitesting")
    var profile: BrowserProfile { state.profiles.first { $0.id == state.activeProfileID } ?? state.profiles[0] }

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        root = base.appendingPathComponent(isTesting ? "Rikugan-UITests" : "Rikugan", isDirectory: true)
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
    }

    func deliverNotice(host: String, title: String, body: String, extensionNotificationID: String = "", extensionRuntimeID: String = "", buttons: [String] = []) {
        let notice = PageNotice(host: host, title: title, body: body, extensionNotificationID: extensionNotificationID, extensionRuntimeID: extensionRuntimeID, buttons: buttons)
        notices.insert(notice, at: 0)
        if notices.count > 40 { notices.removeLast(notices.count - 40) }
        noticeToast = notice
        SystemNotifications.deliver(title: title, body: body.isEmpty ? host : body, identifier: extensionNotificationID)
    }
    func deliverExtensionNotice(_ record: ExtensionNoticeRecord) {
        if let index = notices.firstIndex(where: { $0.extensionNotificationID == record.id && !$0.extensionNotificationID.isEmpty }) {
            let sameIcon = notices[index].iconURL == record.iconURL
            let sameImage = notices[index].imageURL == record.imageURL
            notices[index].title = record.title
            notices[index].body = record.message
            notices[index].buttons = record.buttons
            notices[index].extensionRuntimeID = record.extensionID
            notices[index].iconURL = record.iconURL
            notices[index].imageURL = record.imageURL
            notices[index].progress = record.progress
            if !sameIcon { notices[index].iconData = nil }
            if !sameImage { notices[index].imageData = nil }
            noticeToast = notices[index]
        } else {
            let notice = PageNotice(host: "extension", title: record.title, body: record.message, extensionNotificationID: record.id, extensionRuntimeID: record.extensionID, buttons: record.buttons, iconURL: record.iconURL, imageURL: record.imageURL, progress: record.progress)
            notices.insert(notice, at: 0)
            if notices.count > 40 { notices.removeLast(notices.count - 40) }
            noticeToast = notice
        }
        queueExtensionEvent(type: "shown", notificationID: record.id, byUser: false, extensionID: record.extensionID)
        let packages = session?.extensionPackages(preferring: record.extensionID).packages ?? []
        Task { await self.attachExtensionNotice(record, packages: packages) }
    }
    private func attachExtensionNotice(_ record: ExtensionNoticeRecord, packages: [(url: URL, directory: Bool)]) async {
        let icon = await ExtensionBridge.notificationBytes(record.iconURL, packages: packages)
        let picture = await ExtensionBridge.notificationBytes(record.imageURL, packages: packages)
        if let index = notices.firstIndex(where: { $0.extensionNotificationID == record.id }) {
            notices[index].iconData = icon
            notices[index].imageData = picture
            if noticeToast?.extensionNotificationID == record.id { noticeToast = notices[index] }
        }
        SystemNotifications.deliver(title: record.title, body: record.message.isEmpty ? record.id : record.message, identifier: record.id, image: picture ?? icon) { [weak self] in
            self?.queueExtensionEvent(type: "shown", notificationID: record.id, byUser: false, extensionID: record.extensionID)
        }
    }
    func removeExtensionNotices(ids: [String]) {
        let chosen = Set(ids.filter { !$0.isEmpty })
        guard !chosen.isEmpty else { return }
        notices.removeAll { chosen.contains($0.extensionNotificationID) }
        if let toast = noticeToast, chosen.contains(toast.extensionNotificationID) { noticeToast = nil }
        SystemNotifications.withdraw(Array(chosen))
    }
    func activateExtensionNotice(_ notice: PageNotice, button: Int? = nil) {
        guard !notice.extensionNotificationID.isEmpty else { return }
        pendingExtensionEvents.append(ExtensionNotificationEvent(type: button == nil ? "clicked" : "button", notificationID: notice.extensionNotificationID, buttonIndex: button ?? -1, extensionID: notice.extensionRuntimeID))
        if pendingExtensionEvents.count > 40 { pendingExtensionEvents.removeFirst(pendingExtensionEvents.count - 40) }
    }
    func queueExtensionEvent(type: String, notificationID: String, byUser: Bool, extensionID: String) {
        guard !notificationID.isEmpty else { return }
        pendingExtensionEvents.append(ExtensionNotificationEvent(type: type, notificationID: notificationID, byUser: byUser, extensionID: extensionID))
        if pendingExtensionEvents.count > 40 { pendingExtensionEvents.removeFirst(pendingExtensionEvents.count - 40) }
    }
    func dismissExtensionNotice(_ notice: PageNotice, byUser: Bool) {
        let id = notice.extensionNotificationID
        let extensionID = notice.extensionRuntimeID
        if id.isEmpty {
            notices.removeAll { $0.id == notice.id }
            if noticeToast?.id == notice.id { noticeToast = nil }
            return
        }
        extensionNotices.removeValue(forKey: id)
        removeExtensionNotices(ids: [id])
        queueExtensionEvent(type: "closed", notificationID: id, byUser: byUser, extensionID: extensionID)
    }
    func showExtensionNotificationSettings(_ notice: PageNotice) {
        queueExtensionEvent(type: "settings", notificationID: notice.extensionNotificationID, byUser: true, extensionID: notice.extensionRuntimeID)
    }
    func takeExtensionEvents(extensionID: String) -> [[String: Any]] {
        let chosen = pendingExtensionEvents.enumerated().filter { _, event in
            extensionID.isEmpty || event.extensionID.isEmpty || event.extensionID == extensionID
        }
        for item in chosen.reversed() { pendingExtensionEvents.remove(at: item.offset) }
        return chosen.map { _, event in
            var payload: [String: Any] = ["type": event.type, "notificationId": event.notificationID]
            if event.type == "button" { payload["buttonIndex"] = event.buttonIndex }
            if event.type == "closed" { payload["byUser"] = event.byUser }
            return payload
        }
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
        if url.host == "pending" || items.first(where: { $0.name == "action" }) == nil && url.host == "pending" {
            consumeShareFile(); return
        }
        if let value = items.first(where: { $0.name == "url" })?.value ?? items.first(where: { $0.name == "text" })?.value {
            pendingShare = (action, value); applyPendingShare(); return
        }
        consumeShareFile()
    }
    func consumeShareFile() {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppGroupID.suite) else { return }
        let file = container.appendingPathComponent("share-inbox.json")
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return }
        try? FileManager.default.removeItem(at: file)
        let action = json["action"] ?? "open"
        let value = json["url"] ?? json["text"] ?? ""
        guard !value.isEmpty else { return }
        pendingShare = (action, value)
        applyPendingShare()
    }
    func applyPendingShare() {
        guard let pending = pendingShare, let session else { return }
        pendingShare = nil
        if pending.action == "search" { session.activeTab?.loadInput(pending.value) }
        else if let url = URL(string: pending.value) ?? URLRules.inputURL(pending.value, searchEngine: profile.searchEngine, customEngines: profile.settings.customEngines, shortcuts: profile.settings.urlShortcuts) {
            if session.activeTab?.isHome == true { session.activeTab?.navigate(url) } else { session.addTab(url: url) }
        }
    }
    func handleFile(_ url: URL) {
        Task {
            working = true; defer { working = false }
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
                    scriptDraft = ScriptDraft(source: text)
                }
            } catch { message = error.localizedDescription }
        }
    }
    func importScriptURL(_ value: String) async {
        guard let url = URL(string: value), url.scheme?.lowercased() == "https" || (isTesting && url.scheme == "http") else {
            message = "请输入 HTTPS 用户脚本直链。"; return
        }
        working = true; defer { working = false }
        do {
            let text = try await ScriptNetwork.downloadText(url)
            _ = try UserScript.parse(text)
            scriptDraft = ScriptDraft(source: text)
        } catch { message = error.localizedDescription }
    }
    func installScript(_ source: String, existingID: UUID? = nil) async throws {
        let profileID = state.activeProfileID
        var script = try UserScript.parse(source)
        if let old = profile.scripts.first(where: { $0.id == existingID }) {
            script.id = old.id; script.storageJSON = old.storageJSON; script.enabled = old.enabled
        }
        for dependency in script.requires {
            guard let url = URL(string: dependency), url.scheme?.lowercased() == "https" else { throw RikuganError.message("@require 只接受 HTTPS 地址。") }
            script.dependencies.append(try await ScriptNetwork.downloadText(url))
        }
        for index in script.resources.indices {
            guard let url = URL(string: script.resources[index].url) else { throw RikuganError.message("@resource 地址无效。") }
            guard url.scheme?.lowercased() == "https" || (isTesting && url.scheme == "http") else { throw RikuganError.message("@resource 只接受 HTTPS 地址。") }
            let (data, mime) = try await ScriptNetwork.download(url, limit: 1_000_000)
            script.resources[index].dataBase64 = data.base64EncodedString()
            script.resources[index].mime = mime
        }
        script.updatedAt = Date()
        updateProfile(profileID) { profile in
            if let i = profile.scripts.firstIndex(where: { $0.id == script.id }) { profile.scripts[i] = script }
            else { profile.scripts.append(script) }
        }
        if session?.profileID == profileID { session?.refreshScripts() }
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
                try session.installExtension(prepared)
            }
            message = "自检组件已安装。打开 example.com 测试页，可看到扩展和用户脚本的运行结果。"
        } catch { message = error.localizedDescription }
    }
    func checkScriptUpdate(_ script: UserScript) async -> String? {
        let address = script.updateURL.isEmpty ? script.downloadURL : script.updateURL
        guard let url = URL(string: address), url.scheme == "https" else { message = "这个脚本没有 HTTPS 更新地址。"; return nil }
        do {
            let text = try await ScriptNetwork.downloadText(url)
            let remote = try UserScript.parse(text)
            guard VersionComparator.isNewer(remote.version, than: script.version) else { message = "已是最新版本 \(script.version)。"; return nil }
            message = "发现 \(remote.version)，请确认后保存。"
            return text
        } catch { message = error.localizedDescription; return nil }
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
    func importBackup(_ data: Data) throws {
        let backup = try JSONDecoder().decode(PortableBackup.self, from: data)
        guard backup.version <= 2 else { throw RikuganError.message("这份备份来自更新的 Rikugan，当前版本不能导入。") }
        updateProfile(state.activeProfileID) { profile in
            profile.tabs = backup.tabs.filter { !$0.isPrivate }
            profile.tabGroups = backup.tabGroups
            profile.selectedTabID = backup.selectedTabID
            profile.bookmarks = backup.bookmarks
            profile.bookmarkFolders = backup.bookmarkFolders
            profile.settings = backup.settings
            profile.siteSettings = backup.siteSettings
            profile.searchEngine = backup.searchEngine
            profile.searchHistory = backup.searchHistory
        }
        message = "已导入标签页、分组和自定义设置。扩展二进制和钥匙串没有包含在备份里。"
        activate(state.activeProfileID)
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
        try FontLibrary.rejectUnsupported(data, ext: url.pathExtension)
        let folder = directory(profile.id).appendingPathComponent("Fonts", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fileName = UUID().uuidString + "." + (url.pathExtension.isEmpty ? "ttf" : url.pathExtension)
        let destination = folder.appendingPathComponent(fileName)
        try data.write(to: destination, options: .atomic)
        let family = try FontLibrary.register(destination)
        updateProfile(profile.id) { $0.settings.importedFonts.append(ImportedFont(family: family, fileName: fileName)); $0.settings.webFontFamily = family }
        session?.refreshScripts()
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

enum SystemNotifications {
    static func authorize(_ done: @escaping () -> Void = {}) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            if settings.authorizationStatus == .notDetermined {
                center.requestAuthorization(options: [.alert, .sound]) { _, _ in DispatchQueue.main.async(execute: done) }
            } else {
                DispatchQueue.main.async(execute: done)
            }
        }
    }
    static func deliver(title: String, body: String, identifier: String = "", image: Data? = nil, submitted: (() -> Void)? = nil) {
        let center = UNUserNotificationCenter.current()
        let requestID = identifier.isEmpty ? UUID().uuidString : identifier
        center.getNotificationSettings { settings in
            let post = {
                let content = UNMutableNotificationContent()
                content.title = String(title.prefix(120))
                content.body = String(body.prefix(500))
                if let image, let attachment = attachment(image, identifier: requestID) { content.attachments = [attachment] }
                center.add(UNNotificationRequest(identifier: requestID, content: content, trigger: nil)) { error in
                    if error == nil { DispatchQueue.main.async { submitted?() } }
                }
            }
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                post()
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in if granted { post() } }
            default:
                break
            }
        }
    }
    static func allowsAlerts() async -> Bool {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                switch settings.authorizationStatus {
                case .authorized, .provisional, .ephemeral: continuation.resume(returning: true)
                default: continuation.resume(returning: false)
                }
            }
        }
    }
    static func attachment(_ data: Data, identifier: String) -> UNNotificationAttachment? {
        let ext: String
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { ext = "png" }
        else if data.starts(with: [0xFF, 0xD8]) { ext = "jpg" }
        else if data.starts(with: [0x47, 0x49, 0x46]) { ext = "gif" }
        else { ext = "png" }
        let safe = identifier.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "-" }.map { String($0) }.joined()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent((safe.isEmpty ? UUID().uuidString : safe) + "." + ext)
        do {
            try data.write(to: url, options: .atomic)
            return try UNNotificationAttachment(identifier: identifier, url: url, options: nil)
        } catch { return nil }
    }
    static func withdraw(_ identifiers: [String]) {
        let ids = identifiers.filter { !$0.isEmpty }
        guard !ids.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ids)
        center.removeDeliveredNotifications(withIdentifiers: ids)
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
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("新标签页") { model.session?.addTab() }.keyboardShortcut("t")
                Button("关闭标签页") { if let tab = model.session?.activeTab { model.session?.close(tab) } }.keyboardShortcut("w")
            }
        }
        WindowGroup(for: UUID.self) { $windowID in
            AuxiliaryBrowserView(windowID: windowID).environmentObject(model)
        }
    }
}
