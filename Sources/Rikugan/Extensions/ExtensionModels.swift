import Foundation
import UIKit
import WebKit

/// Persistent record of an installed extension.
struct InstalledExtension: Codable, Identifiable, Hashable {
    enum Source: String, Codable { case file, chromeWebStore, edgeAddons, bundled }
    enum HostAccess: String, Codable { case granted, onClick }

    var id: String
    var name: String
    var version: String
    var description: String
    var enabled: Bool
    var installedAt: Date
    var updatedAt: Date
    var source: Source
    var storeURL: String?
    var grantedPermissions: [String]
    var grantedHosts: [String]
    var hostAccess: HostAccess = .granted
    var enabledRulesets: [String]?
    var dynamicScripts: [ContentScriptEntry] = []
    var dynamicRulesJSON: String = "[]"
    var lastErrors: [String] = []
}

/// Toolbar action state (per extension, optionally per tab).
struct ActionState {
    var title: String?
    var popup: String?
    var badgeText = ""
    var badgeColor: UIColor = .systemRed
    var badgeTextColor: UIColor = .white
    var icon: UIImage?
    var enabled = true
}

/// Tab-specific action settings: nil means "not set for this tab" (the global value applies);
/// an empty badge text or `enabled == false` are real overrides.
struct ActionOverride {
    var title: String?
    var popup: String?
    var badgeText: String?
    var badgeColor: UIColor?
    var badgeTextColor: UIColor?
    var icon: UIImage?
    var enabled: Bool?
}

struct ExtensionMenuItem: Hashable {
    var id: String
    var title: String
    var contexts: [String]
    var parentID: String?
    var type: String
    var checked: Bool
    var enabled: Bool
    var visible: Bool
    var documentURLPatterns: [String]
    var targetURLPatterns: [String]
}

struct ExtensionAlarm {
    var name: String
    var scheduledTime: Date
    var periodInMinutes: Double?
    var timer: Timer?
}

/// Runtime state of an enabled extension.
@MainActor final class LoadedExtension: ObservableObject, Identifiable {
    @Published var record: InstalledExtension
    let manifest: ExtensionManifest
    let directory: URL
    let localization: ExtensionLocalization
    let baseURL: String
    var id: String { record.id }
    var background: BackgroundHost?
    @Published var action = ActionState()
    var tabActions: [Int: ActionOverride] = [:]
    @Published var menuItems: [ExtensionMenuItem] = []
    var alarms: [String: ExtensionAlarm] = [:]
    var sessionStorage: [String: String] = [:]
    var sessionRules: [[String: Any]] = []
    var activeTabGrants: Set<Int> = []
    /// Origin each activeTab grant was made for: like Chrome, the grant survives reloads and
    /// same-origin navigations of the tab and ends when the tab leaves that origin or closes.
    var activeTabGrantOrigins: [Int: String] = [:]

    func grantActiveTab(_ tab: BrowserTab) {
        guard !tab.isPrivate else { return }
        activeTabGrants.insert(tab.numericID)
        activeTabGrantOrigins[tab.numericID] = tab.webView?.url.map(Self.origin) ?? ""
    }

    /// Called when a tab commits a new document: grants for another origin end.
    func tabCommitted(_ tabID: Int, url: URL) {
        if let origin = activeTabGrantOrigins[tabID], !origin.isEmpty, origin == Self.origin(url) { return }
        activeTabGrants.remove(tabID)
        activeTabGrantOrigins[tabID] = nil
    }

    func revokeActiveTab(_ tabID: Int) {
        activeTabGrants.remove(tabID)
        activeTabGrantOrigins[tabID] = nil
    }

    static func origin(_ url: URL) -> String {
        "\(url.scheme?.lowercased() ?? "")://\(url.host?.lowercased() ?? "")\(url.port.map { ":\($0)" } ?? "")"
    }
    var contentFrames: [Int: [FrameRecord]] = [:]
    private var fileCache: [String: String] = [:]
    lazy var icon: UIImage? = loadIcon()

    struct FrameRecord {
        let frameID: Int
        let frame: WKFrameInfo
        let url: String
        var token: String = ""
    }

    init(record: InstalledExtension, manifest: ExtensionManifest, directory: URL, scheme: String) {
        self.record = record
        self.manifest = manifest
        self.directory = directory
        localization = ExtensionLocalization.load(from: directory, defaultLocale: manifest.defaultLocale, preferred: Locale.preferredLanguages)
        baseURL = "\(scheme)://\(record.id)/"
        action.title = localization.localize(manifest.actionTitle, extensionID: record.id) ?? displayName
        action.popup = manifest.actionPopup
    }

    var displayName: String { localization.localize(manifest.name, extensionID: record.id) ?? manifest.name }
    var displayDescription: String { localization.localize(manifest.description, extensionID: record.id) ?? manifest.description }

    func fileURL(_ path: String) -> URL? {
        let clean = path.split(separator: "?").first.map(String.init) ?? path
        let relative = clean.hasPrefix("/") ? String(clean.dropFirst()) : clean
        let decoded = relative.removingPercentEncoding ?? relative
        // Lexical check (see ZipArchive.safeRelativePath): filesystem-normalised prefixes differ
        // between existing and not-yet-existing paths under /private on devices.
        guard let safe = ZipArchive.safeRelativePath(decoded) else { return nil }
        let url = directory.appendingPathComponent(safe)
        // Never serve a symbolic link (it could point outside the package).
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true { return nil }
        return url
    }

    func text(_ path: String) -> String? {
        if let hit = fileCache[path] { return hit }
        guard let url = fileURL(path), let data = try? Data(contentsOf: url) else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        fileCache[path] = text
        return text
    }

    func clearCache() { fileCache.removeAll() }

    func loadIcon(path: String? = nil) -> UIImage? {
        guard let path = path ?? manifest.bestIcon(prefer: 64), let url = fileURL(path), let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    func actionState(for tabID: Int?) -> ActionState {
        guard let tabID, let override = tabActions[tabID] else { return action }
        var merged = action
        if let title = override.title { merged.title = title }
        if let popup = override.popup { merged.popup = popup }
        if let text = override.badgeText { merged.badgeText = text }
        if let color = override.badgeColor { merged.badgeColor = color }
        if let color = override.badgeTextColor { merged.badgeTextColor = color }
        if let icon = override.icon { merged.icon = icon }
        if let enabled = override.enabled { merged.enabled = enabled }
        return merged
    }

    // MARK: Permissions

    var apiPermissions: Set<String> { Set(record.grantedPermissions) }

    func has(_ permission: String) -> Bool { apiPermissions.contains(permission) }

    func hostAllowed(_ url: URL?, tabID: Int? = nil) -> Bool {
        guard let url else { return false }
        if let tabID, activeTabGrants.contains(tabID) { return true }
        if url.absoluteString.hasPrefix(baseURL) { return true }
        guard record.hostAccess == .granted else { return false }
        return URLMatcher.anyMatch(record.grantedHosts.compactMap { try? URLMatcher.matchPattern($0) }, url)
    }

    var dynamicRules: [[String: Any]] {
        (try? JSONSerialization.jsonObject(with: Data(record.dynamicRulesJSON.utf8)) as? [[String: Any]]) ?? []
    }

    var enabledRulesetIDs: [String] { record.enabledRulesets ?? manifest.ruleResources.filter(\.enabled).map(\.id) }
}
