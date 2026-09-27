import Foundation

/// chrome.* compatibility matrix loaded from `chrome-api-matrix.json` — the single source of truth
/// that is also verified against the JS shim and the native bridge in CI.
public enum ChromeAPIMatrix {
    public struct Method: Hashable, Identifiable {
        public let name: String
        public let level: SupportLevel
        public let note: String
        /// Implemented entirely in the JS runtime (no native bridge call).
        public let jsOnly: Bool
        public var id: String { name }
    }

    public struct Entry: Hashable, Identifiable {
        public let namespace: String
        public let level: SupportLevel
        public let reason: String
        public let differences: [String]
        public let methods: [Method]
        public let actions: [Method]
        public var id: String { namespace }
        public var note: String { reason }

        public var implemented: [Method] { methods.filter { $0.level != .unsupported } }
        public var missing: [Method] { methods.filter { $0.level == .unsupported } }
    }

    /// Override for tests / tools; the app loads the bundled JSON.
    public static var jsonOverride: Data?
    private static var cached: [Entry]?

    public static var entries: [Entry] {
        if let cached { return cached }
        let data = jsonOverride ?? Bundle.main.url(forResource: "chrome-api-matrix", withExtension: "json").flatMap { try? Data(contentsOf: $0) }
        let parsed = data.map(parse) ?? []
        cached = parsed
        return parsed
    }

    public static func reload() { cached = nil }

    public static func parse(_ data: Data) -> [Entry] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let namespaces = root["namespaces"] as? [String: [String: Any]] else { return [] }
        func methods(_ value: Any?) -> [Method] {
            guard let dict = value as? [String: [Any]] else { return [] }
            return dict.map { name, spec in
                Method(name: name, level: SupportLevel(rawValue: spec.first as? String ?? "") ?? .unsupported,
                       note: spec.count > 1 ? (spec[1] as? String ?? "") : "", jsOnly: spec.count > 2 ? (spec[2] as? Bool ?? false) : false)
            }.sorted { ($0.name.hasPrefix("on") ? 1 : 0, $0.name) < ($1.name.hasPrefix("on") ? 1 : 0, $1.name) }
        }
        let order = ["runtime", "storage", "scripting", "tabs", "permissions", "action", "contextMenus", "cookies", "downloads",
                     "webNavigation", "declarativeNetRequest", "webRequest", "i18n", "alarms", "notifications", "windows", "commands", "extension"]
        return namespaces.map { name, spec in
            Entry(namespace: name, level: SupportLevel(rawValue: spec["level"] as? String ?? "") ?? .unsupported,
                  reason: spec["reason"] as? String ?? "", differences: spec["differences"] as? [String] ?? [],
                  methods: methods(spec["methods"]), actions: methods(spec["actions"]))
        }.sorted { (order.firstIndex(of: $0.namespace) ?? 999, $0.namespace) < (order.firstIndex(of: $1.namespace) ?? 999, $1.namespace) }
    }

    public static func level(of namespace: String) -> SupportLevel {
        entries.first { $0.namespace == namespace }?.level ?? .unsupported
    }

    public static func method(_ namespace: String, _ name: String) -> Method? {
        entries.first { $0.namespace == namespace }?.methods.first { $0.name == name }
    }

    public static var unsupportedNamespaces: [String] { entries.filter { $0.level == .unsupported }.map(\.namespace) }

    public static func permissionLevel(_ permission: String) -> SupportLevel {
        switch permission {
        case "storage", "unlimitedStorage", "scripting", "activeTab", "tabs", "i18n", "background": return .supported
        case "declarativeNetRequest", "declarativeNetRequestWithHostAccess", "declarativeNetRequestFeedback",
             "contextMenus", "cookies", "downloads", "notifications", "webNavigation", "alarms", "commands",
             "clipboardWrite", "clipboardRead", "favicon": return .partial
        default:
            if permission.contains("://") || permission == "<all_urls>" { return .supported }
            return level(of: permission)
        }
    }
}
