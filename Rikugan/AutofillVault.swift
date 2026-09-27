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

    func validated() throws -> AutofillItem {
        guard ["password", "identity", "payment"].contains(kind) else { throw RikuganError.message("未知的自动填充类型。") }
        let fields = [title, host, username, secret, name, email, phone, address, paymentLabel, paymentLast4]
        guard fields.allSatisfy({ $0.utf8.count <= 16_384 }), fields.reduce(0, { $0 + $1.utf8.count }) <= 64_000 else {
            throw RikuganError.message("单个自动填充条目过大。")
        }
        var result = self
        result.host = AutofillPolicy.normalizedHost(host)
        if result.kind == "payment", result.paymentLast4.isEmpty {
            result.paymentLast4 = String(result.secret.filter(\.isNumber).suffix(4))
        }
        return result
    }
}

enum AutofillPolicy {
    static func normalizedHost(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let url = URL(string: trimmed.contains("://") ? trimmed : "https://" + trimmed), let host = url.host?.lowercased() { return host }
        return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }
    static func canFill(_ item: AutofillItem, pageURL: URL?) -> Bool {
        let rule = normalizedHost(item.host)
        guard !rule.isEmpty else { return true } // Explicit global, still requires a user tap.
        guard let host = pageURL?.host?.lowercased() else { return false }
        return host == rule || host.hasSuffix("." + rule)
    }
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
        guard items.count <= 200 else { throw RikuganError.message("每个身份最多保存 200 个自动填充条目。") }
        let clean = try items.map { try $0.validated() }
        let data = try JSONEncoder().encode(clean)
        guard data.count <= 1_000_000 else { throw RikuganError.message("自动填充钥匙串数据超过 1 MB。") }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profile.uuidString
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        var status = SecItemUpdate(base as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = base
            for (key, value) in attributes { insert[key] = value }
            status = SecItemAdd(insert as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw RikuganError.message("钥匙串拒绝保存自动填充数据（\(status)）。数据没有写入 UserDefaults。") }
    }
}
