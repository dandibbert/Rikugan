import Foundation
import SwiftUI

/// Drives the userscript install page (spec §6.1): opening `.user.js`, Files / Share Sheet import,
/// URL install, pasted source and new scripts all end up here.
@MainActor final class UserscriptInstallCoordinator: ObservableObject {
    static let shared = UserscriptInstallCoordinator()

    struct Pending: Identifiable {
        let id = UUID()
        var source: String
        var sourceURL: URL?
        var result: MetadataParser.Result
        var existing: InstalledUserScript?
        weak var tab: BrowserTab?
    }

    @Published var pending: Pending?
    @Published var loading: URL?

    var store: UserScriptStore { AppServices.shared.profile.userscripts }

    func beginInstall(from url: URL, tab: BrowserTab?) {
        loading = url
        Task {
            defer { loading = nil }
            do {
                var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
                request.setValue("text/javascript, text/plain, */*", forHTTPHeaderField: "Accept")
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    throw RikuganError("下载脚本失败（HTTP \(http.statusCode)）")
                }
                let source = String(decoding: data, as: UTF8.self)
                present(source: source, sourceURL: response.url ?? url, tab: tab, fallbackToPage: true)
            } catch {
                ToastCenter.shared.show("无法获取脚本：\(error.localizedDescription)", symbol: "exclamationmark.triangle")
            }
        }
    }

    func present(source: String, sourceURL: URL?, tab: BrowserTab? = nil, fallbackToPage: Bool = false) {
        let result = MetadataParser.parse(source)
        if fallbackToPage, result.issues.contains(where: { $0.message.contains("==UserScript==") }), let url = sourceURL, let tab {
            // Not a userscript after all – just show the file.
            tab.ensureWebView().load(URLRequest(url: url))
            return
        }
        let existing = store.existingIndex(for: result.metadata).map { store.scripts[$0] }
        pending = Pending(source: source, sourceURL: sourceURL, result: result, existing: existing, tab: tab)
    }

    func importFile(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let source = try? String(contentsOf: url, encoding: .utf8) else {
            ToastCenter.shared.show("无法读取脚本文件", symbol: "exclamationmark.triangle"); return
        }
        present(source: source, sourceURL: nil)
    }

    func confirm(enabled: Bool = true) async throws {
        guard let pending else { return }
        if let error = pending.result.firstError { throw RikuganError(error) }
        let deps = try await UserscriptDependencies.fetch(for: pending.result.metadata)
        let script = try store.install(source: pending.source, sourceURL: pending.sourceURL?.absoluteString,
                                       requires: deps.requires, resources: deps.resources, enabled: enabled)
        self.pending = nil
        let matching = TabRegistry.shared.allTabs.filter { $0.webView?.url.map(script.metadata.matches) ?? false }
        if matching.isEmpty {
            ToastCenter.shared.show("已安装「\(script.name)」", symbol: "checkmark.circle")
        } else {
            ToastCenter.shared.show("已安装「\(script.name)」", symbol: "checkmark.circle", actionTitle: "刷新匹配网页") {
                for tab in matching { tab.reload() }
            }
        }
    }
}

/// Update checks via @updateURL / @downloadURL (spec §9 UpdateManager).
@MainActor enum UserscriptUpdater {
    enum Outcome { case upToDate, updated(String), noUpdateURL, failed(String) }

    static func check(_ script: InstalledUserScript, in store: UserScriptStore, force: Bool = false) async -> Outcome {
        guard let metaURL = script.updateURL else { return .noUpdateURL }
        func fetch(_ url: URL) async throws -> Data {
            let (data, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw RikuganError("\(url.host ?? "服务器") 返回 HTTP \(http.statusCode)")
            }
            return data
        }
        do {
            // An error page is not "no update": the check fails visibly.
            let remoteParsed = MetadataParser.parse(String(decoding: try await fetch(metaURL), as: UTF8.self))
            if let error = remoteParsed.firstError { return .failed("更新信息无效：\(error)") }
            let remote = remoteParsed.metadata
            guard !remote.version.isEmpty else { return .failed("更新信息中没有 @version") }
            var updated = script
            updated.lastUpdateCheck = Date()
            store.update(updated)
            guard force || MetadataParser.compareVersions(remote.version, script.metadata.version) == .orderedDescending else { return .upToDate }
            guard let downloadURL = script.downloadURL else { return .failed("缺少 @downloadURL") }
            let source = String(decoding: try await fetch(downloadURL), as: UTF8.self)
            let parsed = MetadataParser.parse(source)
            if let error = parsed.firstError { return .failed(error) }
            let deps = try await UserscriptDependencies.fetch(for: parsed.metadata)
            try store.updateSource(script.id, source: source, dependencies: deps)
            if var fresh = store.script(script.id) {
                fresh.lastUpdateCheck = Date()
                store.update(fresh)
            }
            return .updated(parsed.metadata.version)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    static func checkAll(_ store: UserScriptStore) async -> (updated: Int, failed: Int) {
        var updated = 0, failed = 0
        for script in store.scripts {
            switch await check(script, in: store) {
            case .updated: updated += 1
            case .failed: failed += 1
            default: break
            }
        }
        return (updated, failed)
    }
}
