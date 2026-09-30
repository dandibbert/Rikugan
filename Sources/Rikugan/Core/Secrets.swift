import Foundation
#if canImport(Security)
import Security
#endif

/// Small Keychain wrapper for credentials that belong to settings (e.g. the translation service
/// API key). They are never part of `Preferences`' JSON, so they cannot end up in
/// preferences.json, backups or exported archives.
public enum Secrets {
    static let service = "com.dandibbert.Rikugan.secrets"

    public static func get(_ account: String) -> String? {
        #if canImport(Security)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
        #else
        return nil
        #endif
    }

    /// Stores `value` (an empty value deletes the item). Returns false when the Keychain refused.
    @discardableResult
    public static func set(_ value: String, for account: String) -> Bool {
        #if canImport(Security)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        if value.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let data = Data(value.utf8)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(attributes as CFDictionary, nil)
        }
        return status == errSecSuccess
        #else
        return false
        #endif
    }
}
