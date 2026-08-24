import Foundation
import OSLog
import Security

/// Keychain 访问协议:供测试注入内存 mock
protocol KeychainStoring {
    func set(_ value: String, forKey key: String) throws
    func get(_ key: String) -> String?
    func delete(_ key: String)
}

// MARK: - 既有项迁移(免提示 ACL)

extension KeychainStoring {
    /// 把既有 Keychain 项重建为「仅本 app 免提示访问」ACL:Keychain 项的访问控制
    /// 创建后无法用 SecItemUpdate 修改,只能「读出值 → 删除 → 重加(携带新 ACL)」。
    /// 幂等:项不存在 → 跳过;已带免提示 ACL 的项重建后行为一致,重复执行无害。
    /// 值在删除前先读入内存;重加失败会重试,仍失败 → 记入返回值由调用方记日志
    /// (不静默丢数据;完成标记未置位,下次启动可再次迁移)。
    @discardableResult
    func migrateKeysToSelfAccess(_ keys: [String]) -> [String] {
        var failed: [String] = []
        for key in keys {
            guard let value = get(key) else { continue } // 项不存在 → 跳过
            delete(key)
            var restored = false
            for _ in 0..<3 {
                if restored { break }
                do {
                    try set(value, forKey: key)
                    restored = true
                } catch {
                    // 瞬时失败 → 重试下一次
                }
            }
            if !restored { failed.append(key) }
        }
        return failed
    }
}

/// 轻量 Keychain 封装:用于存放各账号的 auth Cookie(敏感数据不落盘)
struct KeychainHelper: KeychainStoring {
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
            // 新项配置「仅本 app 免提示访问」ACL,避免每次读取弹授权窗;
            // ACL 取不到(极端环境)则降级为系统默认 ACL(每次询问),保证能写入优先
            if let access = Self.selfAccess() {
                query[kSecAttrAccess as String] = access
            }
            status = SecItemAdd(query as CFDictionary, nil)
        } else if status == errSecSuccess {
            // 已有项只能用 SecItemUpdate 更新数据,ACL 无法用 update 修改;
            // 历史遗留项的免提示迁移见 migrateKeysToSelfAccess(Store init 调度)
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

    // MARK: - 免提示访问 ACL

    /// 仅本 app 可访问的 Keychain 访问控制(免弹授权窗):以「当前可执行文件路径」
    /// 作为可信应用(路径匹配,不依赖易变的 ad-hoc 签名身份 —— 重签名/重建后
    /// 「始终允许」仍有效)。路径取不到/创建失败 → 返回 nil,调用方降级为系统默认
    /// ACL(每次询问),保证能写入优先。
    static func selfAccess() -> SecAccess? {
        guard let path = Bundle.main.executablePath else { return nil }
        var app: SecTrustedApplication?
        guard SecTrustedApplicationCreateFromPath(path, &app) == errSecSuccess,
              let app else { return nil }
        var access: SecAccess?
        let desc = "OpenCodeGo 自身免提示访问" as CFString
        guard SecAccessCreate(desc, [app] as CFArray, &access) == errSecSuccess else { return nil }
        return access
    }

    // MARK: - 既有项免提示访问迁移(启动时一次性)

    /// 完成标记前缀(按 service 存 UserDefaults):置位表示该 service 的既有项已
    /// 重建为免提示 ACL,无需再迁移;迁移有失败时不置位,下次启动重试。
    private static let migrationDoneFlagPrefix = "keychain.selfAccess.migrationDone"

    private static func migrationDoneFlag(for service: String) -> String {
        "\(migrationDoneFlagPrefix).\(service)"
    }

    /// 启动时一次性迁移:对 service 下指定 key 的既有项执行「读出 → 删除 → 重建」,
    /// 使重建项携带「仅本 app 免提示访问」ACL。
    /// - 完成标记已置位 → 直接返回(幂等);
    /// - 全部成功 → 置位标记(此后不再重建;之后新建的项在 set 时自动带新 ACL);
    /// - 存在失败 → 记日志且不置位标记,下次启动重试。
    /// 调用方须在后台任务(Task.detached)中调用,不阻塞 UI;仅真实 Keychain 下由
    /// Store init 调度,测试/内存 mock 不经过此路径。
    static func runSelfAccessMigration(service: String, keys: [String]) {
        let flag = migrationDoneFlag(for: service)
        guard !UserDefaults.standard.bool(forKey: flag) else { return }
        let failed = KeychainHelper(service: service).migrateKeysToSelfAccess(keys)
        if failed.isEmpty {
            UserDefaults.standard.set(true, forKey: flag)
        } else {
            logger.warning("Keychain 免提示 ACL 迁移失败 \(failed.count) 项(\(failed.joined(separator: ","), privacy: .public)),下次启动重试")
        }
    }

    /// 迁移/ACL 日志
    private static let logger = Logger(subsystem: "com.acccan.opencode-go", category: "keychain-access")
}

enum KeychainError: LocalizedError {
    case osStatus(OSStatus)
    var errorDescription: String? {
        switch self {
        case .osStatus(let s): return "Keychain 写入失败 (OSStatus \(s))"
        }
    }
}

/// 内存 Keychain:测试与 --demo 模式复用,进程内有效,不落盘
final class InMemoryKeychain: KeychainStoring {
    private(set) var storage: [String: String] = [:]

    func set(_ value: String, forKey key: String) throws { storage[key] = value }
    func get(_ key: String) -> String? { storage[key] }
    func delete(_ key: String) { storage[key] = nil }
}
