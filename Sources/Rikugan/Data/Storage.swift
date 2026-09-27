import Foundation
import Security
import LocalAuthentication

/// File locations used by the app.
enum AppPaths {
    static let fm = FileManager.default

    static var support: URL {
        let url = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Rikugan", isDirectory: true)
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// User-visible downloads folder (Files → On My iPhone → Rikugan → Downloads).
    static var downloads: URL {
        let url = fm.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Downloads", isDirectory: true)
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static var fonts: URL { directory("Fonts") }
    static var filters: URL { directory("Filters") }
    static var wallpapers: URL { directory("Wallpapers") }

    static func directory(_ name: String, in base: URL? = nil) -> URL {
        let url = (base ?? support).appendingPathComponent(name, isDirectory: true)
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func uniqueFile(in directory: URL, name: String) -> URL {
        let cleaned = sanitize(name.isEmpty ? "download" : name)
        var candidate = directory.appendingPathComponent(cleaned)
        let base = (cleaned as NSString).deletingPathExtension
        let ext = (cleaned as NSString).pathExtension
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent(ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)")
            n += 1
        }
        return candidate
    }

    static func sanitize(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>\0")
        let cleaned = name.components(separatedBy: invalid).joined(separator: "_").trimmingCharacters(in: .whitespaces)
        return String(cleaned.prefix(180)).isEmpty ? "file" : String(cleaned.prefix(180))
    }
}

/// Small Codable file persistence with debounced writes.
final class JSONFile<Value: Codable> {
    let url: URL
    private var pending: DispatchWorkItem?
    private let queue = DispatchQueue(label: "rikugan.jsonfile", qos: .utility)

    init(_ url: URL) { self.url = url }

    func load() -> Value? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Value.self, from: data)
    }

    func save(_ value: Value, immediately: Bool = false) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return }
        pending?.cancel()
        let url = self.url
        let work = DispatchWorkItem {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: [.atomic])
        }
        pending = work
        if immediately { queue.sync(execute: work) } else { queue.asyncAfter(deadline: .now() + 0.4, execute: work) }
    }
}

/// Keychain-backed secure storage for autofill (never UserDefaults).
enum Keychain {
    static let service = "com.dandibbert.Rikugan.autofill"

    static func set(_ data: Data, account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw RikuganError("钥匙串写入失败（\(status)）") }
    }

    static func get(account: String) -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func delete(account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }

    /// Asks for Face ID / passcode before revealing secrets.
    static func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return true }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }
}
