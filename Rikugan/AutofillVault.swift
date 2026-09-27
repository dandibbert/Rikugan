import CloudKit
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
    /// Writes the keychain payload into the private CloudKit database. Unsigned builds have no
    /// iCloud container, so this returns the system error and leaves the keychain copy in place.
    static func pushToCloud(profile: UUID, items: [AutofillItem]) async -> String {
        let container = CKContainer(identifier: "iCloud.com.dandibbert.Rikugan")
        do {
            let status = try await container.accountStatus()
            guard status == .available else { return "iCloud 账号不可用。自动填充仍只在这台设备的钥匙串里。" }
            let record = CKRecord(recordType: "AutofillVault", recordID: CKRecord.ID(recordName: "autofill-" + profile.uuidString))
            record.setObject(profile.uuidString as NSString, forKey: "profile")
            let data = try JSONEncoder().encode(items)
            record.setObject(String(decoding: data, as: UTF8.self) as NSString, forKey: "payload")
            _ = try await container.privateCloudDatabase.save(record)
            return "已写入 iCloud 私有数据库。"
        } catch {
            return "iCloud 没有接上：\(error.localizedDescription)。自动填充仍只在钥匙串，没有写入 UserDefaults。"
        }
    }
    static func pullFromCloud(profile: UUID) async -> [AutofillItem]? {
        let container = CKContainer(identifier: "iCloud.com.dandibbert.Rikugan")
        do {
            let status = try await container.accountStatus()
            guard status == .available else { return nil }
            let record = try await container.privateCloudDatabase.record(for: CKRecord.ID(recordName: "autofill-" + profile.uuidString))
            guard let payload = record["payload"] as? String, let data = payload.data(using: .utf8) else { return nil }
            return try JSONDecoder().decode([AutofillItem].self, from: data)
        } catch {
            return nil
        }
    }
    static func merge(local: [AutofillItem], remote: [AutofillItem]) -> [AutofillItem] {
        var map = Dictionary(uniqueKeysWithValues: local.map { ($0.id, $0) })
        for item in remote { map[item.id] = item }
        return map.values.sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
    }
    static func fillPayload(_ item: AutofillItem) -> [String: String] {
        [
            "username": item.username,
            "password": item.kind == "password" ? item.secret : "",
            "name": item.name,
            "email": item.email,
            "phone": item.phone,
            "address": item.address,
            "cardNumber": item.kind == "payment" ? item.secret : "",
            "paymentLast4": item.paymentLast4
        ]
    }
}
