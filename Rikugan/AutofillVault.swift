import Foundation
import Security

struct AutofillItem: Codable, Identifiable, Equatable {
    var id = UUID()
    var kind: String
    var title: String
    var host: String
    var username: String
    var secret: String
    var name = ""
    var email = ""
    var phone = ""
    var address = ""
    var paymentLabel = ""
    var paymentLast4 = ""
}

enum AutofillVault {
    private static let service = "com.dandibbert.Rikugan.autofill"
    static func load(profile: UUID) -> [AutofillItem] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profile.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data,
              let decoded = try? JSONDecoder().decode([AutofillItem].self, from: data) else { return [] }
        return decoded
    }
    static func save(profile: UUID, items: [AutofillItem]) throws {
        let data = try JSONEncoder().encode(items)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profile.uuidString
        ]
        SecItemDelete(base as CFDictionary)
        var insert = base
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(insert as CFDictionary, nil)
        guard status == errSecSuccess else { throw RikuganError.message("钥匙串拒绝保存自动填充数据（\(status)）。数据没有写入 UserDefaults。") }
    }
}
