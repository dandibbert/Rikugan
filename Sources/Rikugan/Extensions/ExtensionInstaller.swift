import Foundation
import SwiftUI

/// Chrome Web Store / Edge Add-ons listing detected in the current tab.
struct WebStoreItem: Equatable, Hashable {
    enum Store: String { case chrome, edge }
    let store: Store
    let extensionID: String
    let pageURL: URL

    static func detect(url: URL?) -> WebStoreItem? {
        guard let url, let host = url.host?.lowercased() else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        if host == "chromewebstore.google.com" || host == "chrome.google.com" {
            if let index = parts.firstIndex(of: "detail"), let id = parts[(index + 1)...].first(where: ExtensionID.isValid) {
                return WebStoreItem(store: .chrome, extensionID: id, pageURL: url)
            }
        }
        if host == "microsoftedge.microsoft.com", let index = parts.firstIndex(of: "detail"),
           let id = parts[(index + 1)...].first(where: ExtensionID.isValid) {
            return WebStoreItem(store: .edge, extensionID: id, pageURL: url)
        }
        return nil
    }

    var downloadURL: URL {
        switch store {
        case .chrome:
            return URL(string: "https://clients2.google.com/service/update2/crx?response=redirect&prodversion=131.0.0.0&acceptformat=crx2,crx3&x=id%3D\(extensionID)%26uc")!
        case .edge:
            return URL(string: "https://edge.microsoft.com/extensionwebstorebase/v1/crx?response=redirect&x=id%3D\(extensionID)%26installsource%3Dondemand%26uc")!
        }
    }

    var storeName: String { store == .chrome ? "Chrome 应用商店" : "Microsoft Edge 加载项" }
}

/// Parsed package waiting for the user's permission confirmation (spec §19 / §20).
struct PendingExtensionInstall: Identifiable {
    let id = UUID()
    let extensionID: String
    let manifest: ExtensionManifest
    let stagingDirectory: URL
    let source: InstalledExtension.Source
    let storeURL: String?
    let existing: InstalledExtension?
    let displayName: String
    let icon: UIImage?

    var requestedPermissions: [String] { manifest.apiPermissions }
    var requestedHosts: [String] { manifest.requestedHostPatterns }

    /// Permissions added compared to the installed version (update prompts).
    var newPermissions: [String] {
        guard let existing else { return requestedPermissions }
        return requestedPermissions.filter { !existing.grantedPermissions.contains($0) }
    }
    var newHosts: [String] {
        guard let existing else { return requestedHosts }
        return requestedHosts.filter { host in !existing.grantedHosts.contains { URLMatcher.pattern($0, covers: host) } }
    }
    var needsConfirmation: Bool { existing == nil || !newPermissions.isEmpty || !newHosts.isEmpty }
    var descriptionLines: [PermissionDescriber.Line] {
        PermissionDescriber.describe(apiPermissions: existing == nil ? requestedPermissions : newPermissions,
                                     hostPatterns: existing == nil ? requestedHosts : newHosts)
    }
}

/// Unpacks ZIP / CRX / directories, validates the manifest and installs (ExtensionInstaller).
@MainActor final class ExtensionInstaller: ObservableObject {
    static let shared = ExtensionInstaller()
    @Published var pending: PendingExtensionInstall?
    @Published var busy: String?

    private var runtime: ExtensionRuntime { AppServices.shared.profile.extensions }

    // MARK: Staging

    func stage(fileURL: URL) {
        let access = fileURL.startAccessingSecurityScopedResource()
        defer { if access { fileURL.stopAccessingSecurityScopedResource() } }
        do {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDir)
            if isDir.boolValue {
                pending = try prepareDirectory(fileURL, source: .file, storeURL: nil, seed: fileURL.lastPathComponent)
            } else {
                let data = try Data(contentsOf: fileURL)
                pending = try preparePackage(data, source: .file, storeURL: nil, seed: fileURL.lastPathComponent)
            }
        } catch {
            ToastCenter.shared.show("无法导入扩展：\(error.localizedDescription)", symbol: "exclamationmark.triangle", duration: 5)
        }
    }

    func stage(store item: WebStoreItem) {
        busy = "正在从\(item.storeName)下载…"
        Task {
            defer { busy = nil }
            do {
                var request = URLRequest(url: item.downloadURL, timeoutInterval: 60)
                request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
                                 forHTTPHeaderField: "User-Agent")
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    throw RikuganError("下载失败（HTTP \(http.statusCode)），该扩展可能不可用或需要登录")
                }
                pending = try preparePackage(data, source: item.store == .chrome ? .chromeWebStore : .edgeAddons,
                                             storeURL: item.pageURL.absoluteString, seed: item.extensionID, expectedID: item.extensionID)
            } catch {
                ToastCenter.shared.show("安装失败：\(error.localizedDescription)", symbol: "exclamationmark.triangle", duration: 5)
            }
        }
    }

    func preparePackage(_ data: Data, source: InstalledExtension.Source, storeURL: String?, seed: String,
                        expectedID: String? = nil) throws -> PendingExtensionInstall {
        var zipData = data
        var crxID: String?
        if data.prefix(4) == Data("Cr24".utf8) {
            let crx = try CRXPackage(data: data)
            zipData = crx.zipData
            crxID = crx.crxID
        }
        let archive = try ZipArchive(data: zipData)
        guard let root = archive.rootPrefix(containing: "manifest.json") else {
            throw RikuganError("包中没有 manifest.json")
        }
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("ext-staging-\(UUID().uuidString)", isDirectory: true)
        try archive.extractAll(to: staging, stripPrefix: root)
        return try prepareDirectory(staging, source: source, storeURL: storeURL, seed: seed, crxID: crxID ?? expectedID, isStaging: true)
    }

    func prepareDirectory(_ directory: URL, source: InstalledExtension.Source, storeURL: String?, seed: String,
                          crxID: String? = nil, isStaging: Bool = false) throws -> PendingExtensionInstall {
        var staging = directory
        if !isStaging {
            staging = FileManager.default.temporaryDirectory.appendingPathComponent("ext-staging-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.copyItem(at: directory, to: staging)
        }
        let manifestURL = staging.appendingPathComponent("manifest.json")
        guard let manifestData = try? Data(contentsOf: manifestURL) else { throw RikuganError("找不到 manifest.json") }
        let manifest = try ExtensionManifest(data: manifestData)
        let id = manifest.key.flatMap(ExtensionID.fromManifestKey) ?? crxID ?? ExtensionID.fromSeed("rikugan:" + manifest.name + ":" + seed)
        for script in manifest.contentScripts {
            for pattern in script.matches where !URLMatcher.isValidMatchPattern(pattern) {
                throw RikuganError("content_scripts 中的匹配规则无效：\(pattern)")
            }
        }
        if let sw = manifest.serviceWorker, !FileManager.default.fileExists(atPath: staging.appendingPathComponent(sw).path) {
            throw RikuganError("background.service_worker 指向的文件不存在：\(sw)")
        }
        let localization = ExtensionLocalization.load(from: staging, defaultLocale: manifest.defaultLocale, preferred: Locale.preferredLanguages)
        let iconPath = manifest.bestIcon(prefer: 128)
        let icon = iconPath.flatMap { UIImage(contentsOfFile: staging.appendingPathComponent($0).path) }
        return PendingExtensionInstall(extensionID: id, manifest: manifest, stagingDirectory: staging, source: source, storeURL: storeURL,
                                       existing: runtime.records.first { $0.id == id },
                                       displayName: localization.localize(manifest.name, extensionID: id) ?? manifest.name, icon: icon)
    }

    // MARK: Install

    func confirm(_ install: PendingExtensionInstall) {
        do {
            try runtime.install(install)
            pending = nil
            ToastCenter.shared.show(install.existing == nil ? "已安装「\(install.displayName)」" : "已更新「\(install.displayName)」",
                                    symbol: "puzzlepiece.extension")
        } catch {
            ToastCenter.shared.show("安装失败：\(error.localizedDescription)", symbol: "exclamationmark.triangle", duration: 5)
        }
    }

    func cancel() {
        if let pending { try? FileManager.default.removeItem(at: pending.stagingDirectory) }
        pending = nil
    }

    /// Update check for store-installed extensions (spec P1 "Extension 更新" + permission change prompt).
    func checkUpdate(_ record: InstalledExtension) async -> String {
        guard let storeURL = record.storeURL.flatMap(URL.init(string:)), let item = WebStoreItem.detect(url: storeURL) else {
            return "此扩展来自本地文件，请重新导入新版本的 ZIP / CRX 以更新"
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: item.downloadURL)
            let candidate = try preparePackage(data, source: record.source, storeURL: record.storeURL, seed: record.id, expectedID: record.id)
            guard MetadataParser.compareVersions(candidate.manifest.version, record.version) == .orderedDescending else {
                try? FileManager.default.removeItem(at: candidate.stagingDirectory)
                return "已是最新版本（\(record.version)）"
            }
            if candidate.needsConfirmation {
                pending = candidate
                return "新版本 \(candidate.manifest.version) 需要新的权限，请确认"
            }
            confirm(candidate)
            return "已更新到 \(candidate.manifest.version)"
        } catch {
            return "检查更新失败：\(error.localizedDescription)"
        }
    }
}
