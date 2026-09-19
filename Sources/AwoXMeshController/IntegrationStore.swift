import Foundation
import Security

struct MQTTIntegrationProfile: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var host: String
    var port: UInt16
    var username: String
    var password: String
    var topic: String
    var usesTLS: Bool
}

enum IntegrationStore {
    private static let service = "com.github.bohdandn.awox-mesh-controller.integrations.mqtt"

    static func loadAll() -> [MQTTIntegrationProfile] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return [] }
        let items = (result as? [[String: Any]]) ?? (result as? [String: Any]).map { [$0] } ?? []
        return items.compactMap { item in
            guard let account = item[kSecAttrAccount as String] as? String,
                  let id = UUID(uuidString: account)
            else { return nil }
            return load(id)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func save(_ profile: MQTTIntegrationProfile) -> Bool {
        guard let data = try? JSONEncoder().encode(profile) else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profile.id.uuidString,
        ]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func delete(_ id: UUID) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private static func load(_ id: UUID) -> MQTTIntegrationProfile? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return try? JSONDecoder().decode(MQTTIntegrationProfile.self, from: data)
    }
}