import Foundation
import Security

struct DeviceProfile: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var meshName: String
    var meshPassword: String
    var protocolAddress: Data
}

enum DeviceStore {
    private static let service = "com.github.bohdandn.awox-mesh-controller.devices"

    static func loadAll() -> [DeviceProfile] {
        loadAll(service: service).sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private static func loadAll(service: String) -> [DeviceProfile] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return [] }
        let items: [[String: Any]]
        if let values = result as? [[String: Any]] {
            items = values
        } else if let value = result as? [String: Any] {
            items = [value]
        } else {
            items = []
        }
        return items.compactMap { item in
            guard let account = item[kSecAttrAccount as String] as? String,
                  let id = UUID(uuidString: account)
            else { return nil }
            return load(id, service: service)
        }
    }

    private static func load(_ id: UUID, service: String) -> DeviceProfile? {
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
        return try? JSONDecoder().decode(DeviceProfile.self, from: data)
    }

    static func save(_ profile: DeviceProfile) -> Bool {
        guard let data = try? JSONEncoder().encode(profile) else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profile.id.uuidString,
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        let saved: Bool
        if updateStatus == errSecSuccess {
            saved = true
        } else if updateStatus == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            saved = SecItemAdd(item as CFDictionary, nil) == errSecSuccess
        } else {
            saved = false
        }
        return saved
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
}

enum AppSettings {
    private static let refreshIntervalKey = "status-refresh-interval"
    private static let maximumLogSizeKey = "maximum-log-size-mb"
    private static let minimumLogLevelKey = "minimum-log-level"
    static let defaultRefreshInterval: TimeInterval = 60
    static let defaultMaximumLogSizeMB = 5

    static var refreshInterval: TimeInterval {
        get {
            let value = UserDefaults.standard.double(forKey: refreshIntervalKey)
            return value > 0 ? value : defaultRefreshInterval
        }
        set {
            UserDefaults.standard.set(max(10, newValue), forKey: refreshIntervalKey)
        }
    }

    static var maximumLogSizeMB: Int {
        get {
            let value = UserDefaults.standard.integer(forKey: maximumLogSizeKey)
            guard value > 0 else { return defaultMaximumLogSizeMB }
            return min(50, max(5, Int((Double(value) / 5).rounded()) * 5))
        }
        set {
            UserDefaults.standard.set(min(50, max(5, newValue)), forKey: maximumLogSizeKey)
        }
    }

    static var minimumLogLevel: AppLogLevel {
        get {
            guard let value = UserDefaults.standard.string(forKey: minimumLogLevelKey),
                  let level = AppLogLevel(rawValue: value),
                  level != .unknown
            else { return .debug }
            return level
        }
        set {
            guard newValue != .unknown else { return }
            UserDefaults.standard.set(newValue.rawValue, forKey: minimumLogLevelKey)
        }
    }
}