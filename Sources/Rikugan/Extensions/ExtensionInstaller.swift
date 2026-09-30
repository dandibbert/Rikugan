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

    /// Store listing URL (any form `detect` accepts) or a bare 32-character ID (Chrome Web Store).
    static func parse(_ text: String) -> WebStoreItem? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if ExtensionID.isValid(trimmed), let page = URL(string: "https://chromewebstore.google.com/detail/\(trimmed)") {
            return WebStoreItem(store: .chrome, extensionID: trimmed, pageURL: page)
        }
        return detect(url: URL(string: trimmed))
    }

    var downloadURL: URL {
        switch store {
        case .chrome:
            return URL(string: "https://clients2.google.com/service/update2/crx?response=redirect&prodversion=138.0.0.0&acceptformat=crx2,crx3&x=id%3D\(extensionID)%26installsource%3Dondemand%26uc")!
        case .edge:
            return URL(string: "https://edge.microsoft.com/extensionwebstorebase/v1/crx?response=redirect&prodversion=138.0.0.0&x=id%3D\(extensionID)%26installsource%3Dondemand%26uc")!
        }
    }

    var storeName: String { store == .chrome ? "Chrome 应用商店" : "Microsoft Edge 加载项" }
}

/// Downloads a store package. The Edge endpoint redirects to a plain-HTTP Microsoft CDN URL:
/// redirects are upgraded to HTTPS first; only if the HTTPS copy cannot be fetched is the original
/// HTTP URL used. Integrity does not depend on the transport: `preparePackage` accepts only a CRX
/// whose signature verifies against the key of the listing's extension ID.
enum StoreDownload {
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36"

    final class UpgradeRedirects: NSObject, URLSessionTaskDelegate {
        let upgrade: Bool
        private(set) var insecureRedirect: URL?
        init(upgrade: Bool) { self.upgrade = upgrade }
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            guard upgrade, let url = request.url, url.scheme?.lowercased() == "http",
                  var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { completionHandler(request); return }
            insecureRedirect = url
            parts.scheme = "https"
            var upgraded = request
            upgraded.url = parts.url
            completionHandler(upgraded)
        }
    }

    static func fetch(_ url: URL) async throws -> Data {
        do {
            return try await get(url, upgrade: true)
        } catch let error as URLError where [.secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                                             .serverCertificateHasUnknownRoot, .cannotConnectToHost, .timedOut].contains(error.code) {
            await ErrorLog.shared.record("HTTPS copy of store package unavailable (\(error.code.rawValue)); using the store's HTTP redirect", source: "extension install")
            return try await get(url, upgrade: false)
        }
    }

    private static func get(_ url: URL, upgrade: Bool) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let delegate = UpgradeRedirects(upgrade: upgrade)
        let (data, response) = try await URLSession.shared.data(for: request, delegate: delegate)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw RikuganError("下载失败（HTTP \(http.statusCode)），该扩展可能不可用或需要登录")
        }
        return data
    }
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
                let data = try await StoreDownload.fetch(item.downloadURL)
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
            // The signature proves the payload was signed by the key the extension ID is derived
            // from, whatever transport delivered it. An unsigned / tampered CRX is refused.
            guard let verified = crx.verifiedID() else {
                throw RikuganError("扩展包签名无效或缺失，已拒绝安装（文件可能被篡改）")
            }
            zipData = crx.zipData
            crxID = verified
            // A store download must be the package of the listing that was opened.
            if let expectedID, verified != expectedID {
                throw RikuganError("下载的扩展包与商店页面不符（ID \(verified) ≠ \(expectedID)），已拒绝安装")
            }
        } else if expectedID != nil {
            // Stores always deliver signed CRX files; anything else is not the store's package.
            throw RikuganError("商店返回的不是签名扩展包（CRX），已拒绝安装")
        }
        let archive = try ZipArchive(data: zipData)
        guard let root = archive.rootPrefix(containing: "manifest.json") else {
            throw RikuganError("包中没有 manifest.json")
        }
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("ext-staging-\(UUID().uuidString)", isDirectory: true)
        try archive.extractAll(to: staging, stripPrefix: root)
        return try prepareDirectory(staging, source: source, storeURL: storeURL, seed: seed, crxID: crxID, isStaging: true)
    }

    func prepareDirectory(_ directory: URL, source: InstalledExtension.Source, storeURL: String?, seed: String,
                          crxID: String? = nil, isStaging: Bool = false) throws -> PendingExtensionInstall {
        var staging = directory
        if !isStaging {
            // A folder import must not contain symbolic links (a resource could point outside the
            // extension); ZIP extraction already refuses them.
            let keys: [URLResourceKey] = [.isSymbolicLinkKey]
            if let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys) {
                for case let file as URL in walker where (try? file.resourceValues(forKeys: Set(keys)))?.isSymbolicLink == true {
                    throw RikuganError("扩展文件夹中包含符号链接（\(file.lastPathComponent)），已拒绝导入")
                }
            }
            staging = FileManager.default.temporaryDirectory.appendingPathComponent("ext-staging-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.copyItem(at: directory, to: staging)
        }
        let manifestURL = staging.appendingPathComponent("manifest.json")
        guard let manifestData = try? Data(contentsOf: manifestURL) else { throw RikuganError("找不到 manifest.json") }
        let manifest = try ExtensionManifest(data: manifestData)
        let keyID = manifest.key.flatMap(ExtensionID.fromManifestKey)
        if let keyID, let crxID, keyID != crxID {
            throw RikuganError("manifest.json 的 key 与扩展包签名不一致（\(keyID) ≠ \(crxID)），已拒绝安装")
        }
        let id = crxID ?? keyID ?? ExtensionID.fromSeed("rikugan:" + manifest.name + ":" + seed)
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

    /// Returns true only when the new package is on disk and loaded.
    @discardableResult
    func confirm(_ install: PendingExtensionInstall) -> Bool {
        do {
            try runtime.install(install)
            pending = nil
            ToastCenter.shared.show(install.existing == nil ? "已安装「\(install.displayName)」" : "已更新「\(install.displayName)」",
                                    symbol: "puzzlepiece.extension")
            return true
        } catch {
            try? FileManager.default.removeItem(at: install.stagingDirectory)
            ToastCenter.shared.show("安装失败：\(error.localizedDescription)", symbol: "exclamationmark.triangle", duration: 5)
            return false
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
            let data = try await StoreDownload.fetch(item.downloadURL)
            let candidate = try preparePackage(data, source: record.source, storeURL: record.storeURL, seed: record.id, expectedID: record.id)
            guard MetadataParser.compareVersions(candidate.manifest.version, record.version) == .orderedDescending else {
                try? FileManager.default.removeItem(at: candidate.stagingDirectory)
                return "已是最新版本（\(record.version)）"
            }
            if candidate.needsConfirmation {
                pending = candidate
                return "新版本 \(candidate.manifest.version) 需要新的权限，请确认"
            }
            return confirm(candidate) ? "已更新到 \(candidate.manifest.version)" : "更新失败，仍在使用版本 \(record.version)"
        } catch {
            return "检查更新失败：\(error.localizedDescription)"
        }
    }
}
