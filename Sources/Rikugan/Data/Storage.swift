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

/// Small Codable file persistence. Writes are debounced but go through one shared writer, so the
/// latest value of every file is written in order, `PersistenceQueue.shared.flush()` can force
/// them out (the app calls it when going to the background), and write / decode errors are
/// reported instead of being dropped.
final class JSONFile<Value: Codable> {
    let url: URL

    init(_ url: URL) { self.url = url }

    private static var encoder: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }

    /// nil when the file does not exist. A file that exists but cannot be decoded is moved aside
    /// (kept for recovery) and reported, rather than silently treated as an empty store.
    func load() -> Value? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(Value.self, from: Data(contentsOf: url))
        } catch {
            PersistenceQueue.quarantine(url, error: error)
            return nil
        }
    }

    func save(_ value: Value, immediately: Bool = false) {
        do {
            PersistenceQueue.shared.schedule(try Self.encoder.encode(value), to: url, immediately: immediately)
        } catch {
            PersistenceQueue.report("编码失败", url: url, error: error)
        }
    }

    /// Synchronous write that throws (for transactions such as archive import).
    func write(_ value: Value) throws {
        try PersistenceQueue.shared.writeNow(try Self.encoder.encode(value), to: url)
    }
}

/// Serialises all JSON file writes (latest value per file wins) and reports failures.
final class PersistenceQueue: @unchecked Sendable {
    static let shared = PersistenceQueue()
    private let queue = DispatchQueue(label: "rikugan.persistence", qos: .utility)
    private let lock = NSLock()
    private var pending: [URL: Data] = [:]

    func schedule(_ data: Data, to url: URL, immediately: Bool) {
        lock.lock(); pending[url] = data; lock.unlock()
        if immediately { flush() } else { queue.asyncAfter(deadline: .now() + 0.4) { self.drain() } }
    }

    /// Writes everything pending now (call from the main thread, never from the writer queue).
    func flush() { queue.sync { drain() } }

    func writeNow(_ data: Data, to url: URL) throws {
        lock.lock(); pending.removeValue(forKey: url); lock.unlock()
        try queue.sync { try Self.write(data, to: url) }
    }

    private func drain() {
        lock.lock(); let work = pending; pending.removeAll(); lock.unlock()
        for (url, data) in work {
            do { try Self.write(data, to: url) } catch { Self.report("写入失败", url: url, error: error) }
        }
    }

    private static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
    }

    static func quarantine(_ url: URL, error: Error) {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let target = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".corrupt-" + stamp)
        try? FileManager.default.moveItem(at: url, to: target)
        report("文件已损坏，已另存为 \(target.lastPathComponent)", url: url, error: error)
    }

    static func report(_ what: String, url: URL, error: Error) {
        let message = "\(url.lastPathComponent)：\(what)（\((error as NSError).domain) \((error as NSError).code)）"
        DispatchQueue.main.async { MainActor.assumeIsolated { ErrorLog.shared.record(message, source: "storage") } }
    }
}

/// Keychain-backed secure storage for autofill (never UserDefaults).
enum Keychain {
    static let service = "com.dandibbert.Rikugan.autofill"

    /// Replaces the item in place (never delete-then-add, which loses the old value if the add fails).
    static func set(_ data: Data, account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(attributes as CFDictionary, nil)
        }
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
        // No passcode set: there is nothing to authenticate with. Secrets are still protected by
        // kSecAttrAccessibleWhenUnlockedThisDeviceOnly; the UI says so (AutofillSettings).
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return true }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }
}
