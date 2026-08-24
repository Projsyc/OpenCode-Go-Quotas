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

    /// 候选可执行路径:当前运行路径 + /Applications 安装路径(dmg 安装后 ACL 仍匹配)。
    /// 路径匹配而非签名身份(ad-hoc 重签名/重建后「始终允许」仍有效);多路径同时
    /// 覆盖 dev 运行与 /Applications 安装版。
    static func trustedExecutablePaths() -> [String] {
        var paths = [String]()
        if let cur = Bundle.main.executablePath { paths.append(cur) }
        let apps = "/Applications/OpenCodeGo.app/Contents/MacOS/OpenCodeGo"
        if !paths.contains(apps) { paths.append(apps) }
        return paths
    }

    /// 仅本 app 可访问的 Keychain 访问控制(免弹授权窗):把 trustedExecutablePaths()
    /// 中每个候选路径都作为可信应用 —— 经 dmg 安装到 /Applications 后,ACL 里的
    /// 项与当前运行路径同属候选列表,免提示访问仍匹配。单项创建失败 → 跳过;
    /// 全部失败 → 返回 nil,调用方降级为系统默认 ACL(每次询问),保证能写入优先。
    static func selfAccess() -> SecAccess? {
        var trustedApps: [SecTrustedApplication] = []
        for path in trustedExecutablePaths() {
            var app: SecTrustedApplication?
            guard SecTrustedApplicationCreateFromPath(path, &app) == errSecSuccess,
                  let app else { continue }
            trustedApps.append(app)
        }
        guard !trustedApps.isEmpty else { return nil }
        var access: SecAccess?
        let desc = "OpenCodeGo 自身免提示访问" as CFString
        guard SecAccessCreate(desc, trustedApps as CFArray, &access) == errSecSuccess else { return nil }
        return access
    }

    // MARK: - 既有项免提示访问迁移(启动时一次性)

    /// 完成标记前缀(按 service 存 UserDefaults):键为 `keychain.selfAccess.migrationDone.<service>`,
    /// 值不再是 Bool,而是「迁移时的可执行路径列表指纹」。路径变化(如 dev 运行 →
    /// /Applications 安装)后标记与当前指纹不一致,启动时重新迁移,保证新路径的
    /// ACL 项也覆盖;b17 遗留的 Bool 标记(如 "1"/"true")与指纹必然不等,同样
    /// 触发一次重迁移后覆盖为指纹。迁移有失败时不更新标记,下次启动重试。
    private static let migrationDoneFlagPrefix = "keychain.selfAccess.migrationDone"

    private static func migrationDoneFlag(for service: String) -> String {
        "\(migrationDoneFlagPrefix).\(service)"
    }

    /// 当前可执行路径列表指纹(存 UserDefaults;与 trustedExecutablePaths() 同构,
    /// 顺序固定,join 分隔符不会出现在路径中)
    static func currentMigrationFingerprint() -> String {
        trustedExecutablePaths().joined(separator: "|")
    }

    /// 迁移判定(纯函数,可测):已存指纹 ≠ 当前指纹(含未存/旧版 Bool 标记)→
    /// 需要迁移。一致 → 不需要。
    static func migrationNeeded(storedFingerprint: String?, currentFingerprint: String) -> Bool {
        storedFingerprint != currentFingerprint
    }

    /// 启动时一次性迁移:对 service 下指定 key 的既有项执行「读出 → 删除 → 重建」,
    /// 使重建项携带「仅本 app 免提示访问」ACL。
    /// - 完成标记指纹与当前路径指纹一致 → 直接返回(幂等);
    /// - 不一致(未置位/Bool 遗留/路径变化)→ 迁移;全部成功 → 覆盖标记为当前指纹;
    /// - 存在失败 → 记日志且不更新标记,下次启动重试。
    /// 调用方须在后台任务(Task.detached)中调用,不阻塞 UI;仅真实 Keychain 下由
    /// Store init 调度,测试注入内存 mock + 独立 defaults,不经过真实存储。
    static func runSelfAccessMigration(
        service: String,
        keys: [String],
        keychain: KeychainStoring? = nil,
        defaults: UserDefaults = .standard
    ) {
        let flag = migrationDoneFlag(for: service)
        let current = currentMigrationFingerprint()
        guard migrationNeeded(
            storedFingerprint: defaults.string(forKey: flag),
            currentFingerprint: current) else { return }
        let failed = (keychain ?? KeychainHelper(service: service)).migrateKeysToSelfAccess(keys)
        if failed.isEmpty {
            defaults.set(current, forKey: flag)
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
