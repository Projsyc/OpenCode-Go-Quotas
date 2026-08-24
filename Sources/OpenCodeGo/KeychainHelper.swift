import Foundation
import Security

/// 轻量 Keychain 封装:用于存放各账号的 auth Cookie(敏感数据不落盘)
struct KeychainHelper {
    let service: String

    private func baseQuery(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }

    func set(_ value: String, forKey key: String) throws {
        let data = Data(value.utf8)
        var query = baseQuery(key)
        var status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecItemNotFound {
            query[kSecValueData as String] = data
            status = SecItemAdd(query as CFDictionary, nil)
        } else if status == errSecSuccess {
            let attrs: [String: Any] = [kSecValueData as String: data]
            status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        }
        guard status == errSecSuccess else {
            throw KeychainError.osStatus(status)
        }
    }

    func get(_ key: String) -> String? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func delete(_ key: String) {
        SecItemDelete(baseQuery(key) as CFDictionary)
    }
}

enum KeychainError: LocalizedError {
    case osStatus(OSStatus)
    var errorDescription: String? {
        switch self {
        case .osStatus(let s): return "Keychain 写入失败 (OSStatus \(s))"
        }
    }
}
