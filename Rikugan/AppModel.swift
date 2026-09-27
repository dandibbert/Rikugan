import SwiftUI
import WebKit

struct ScriptDraft: Identifiable { var id = UUID(); var source: String; var existingID: UUID? }

@MainActor final class AppModel: ObservableObject {
    @Published var state: AppState
    @Published var session: BrowserSession?
    @Published var message: String?
    @Published var scriptDraft: ScriptDraft?
    @Published var preparedExtension: PreparedExtension?
    @Published var working = false
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
                initial = try JSONDecoder().decode(AppState.self, from: Data(contentsOf: file))
                guard initial.schema == 1, !initial.profiles.isEmpty else { throw RikuganError.message("不支持的资料格式") }
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
    func handleFile(_ url: URL) {
        Task {
            working = true; defer { working = false }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                if url.pathExtension.lowercased() == "zip" || values.isDirectory == true {
                    preparedExtension = try await session?.prepareExtension(url)
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
        try UserScriptSyntax.validate(script.dependencies.joined(separator: "\n;\n") + "\n;\n" + script.source)
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
}

@main struct RikuganApp: App {
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(model)
                .task { model.start() }
                .onOpenURL { model.handleFile($0) }
        }
    }
}
