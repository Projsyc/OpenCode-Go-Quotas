import Foundation
import Observation
import OSLog

/// 批量导入结果摘要:成功导入数 + 被跳过行列表
struct GitHubImportSummary: Equatable, Sendable {
    var imported: Int
    var skipped: [GitHubImportSkip]
}

/// 批量导入中被跳过的行(行号 + 原因)。
/// `id` 用于 SwiftUI 稳定标识：同一输入行可能产生多条跳过记录（例如 Keychain
/// 写入失败与后续整批回滚诊断），仅用 lineNumber 会导致 ForEach ID 冲突。
struct GitHubImportSkip: Equatable, Identifiable, Sendable {
    let id: UUID
    var lineNumber: Int
    var reason: String

    init(lineNumber: Int, reason: String, id: UUID = UUID()) {
        self.id = id
        self.lineNumber = lineNumber
        self.reason = reason
    }
}

/// GitHub 账号存储:元数据(非敏感)落 JSON,密码/凭据只进 Keychain
@MainActor
@Observable
final class GitHubAccountStore {
    private(set) var accounts: [GitHubAccount] = []
    /// 演示模式(启动参数 --demo 或注入):内存 Keychain + 内存存储,不落盘、不碰真实数据
    private(set) var demoMode = false
    /// 数据文件读取/解码失败时的用户可见错误(启动加载时置位,首次成功保存后清空)
    private(set) var loadError: String?

    private static let logger = Logger(subsystem: "com.acccan.opencode-go", category: "github-account-store")

    private let keychain: KeychainStoring
    private let fileURL: URL
    /// JSON 落盘、写前快照、损坏留证和快照恢复统一委托给通用存储。
    private var persistence: JSONFileStore<[GitHubAccount]> {
        JSONFileStore(
            fileURL: fileURL,
            subject: "GitHub 账号",
            sourceName: "github-accounts.json",
            logger: Self.logger)
    }

    /// - Parameters:
    ///   - keychain: nil → KeychainHelper(service: "com.acccan.opencode-go.github")
    ///   - fileURL: nil → Application Support/OpenCodeGo/github-accounts.json
    ///   - demoMode: nil → 按启动参数是否含 --demo 判断
    init(
        keychain: KeychainStoring? = nil,
        fileURL: URL? = nil,
        demoMode: Bool? = nil
    ) {
        let demo = demoMode ?? ProcessInfo.processInfo.arguments.contains("--demo")
        self.demoMode = demo
        self.fileURL = fileURL ?? Self.defaultFileURL()
        if demo {
            let mock = InMemoryKeychain()
            self.keychain = mock
            setupDemo(using: mock)
        } else {
            self.keychain = keychain ?? KeychainHelper(service: "com.acccan.opencode-go.github")
            load()
            // 一次性把既有凭据项迁移为「仅本 app 免提示访问」ACL(后台执行,不阻塞 UI)
            scheduleSelfAccessMigration()
        }
    }

    /// 把既有 GitHub 凭据项(密码/TOTP secret/一次性码)迁移为「仅本 app 免提示访问」
    /// ACL,消除授权弹窗。仅真实 KeychainHelper 时执行(测试注入 mock / demo 内存
    /// Keychain 天然跳过);后台异步,失败由 KeychainHelper 记日志并在下次启动重试。
    private func scheduleSelfAccessMigration() {
        guard let helper = keychain as? KeychainHelper else { return }
        var keys: [String] = []
        for account in accounts {
            keys.append(key("password", account.id))
            keys.append(key("credential", account.id))
        }
        let service = helper.service
        Task.detached(priority: .utility) {
            KeychainHelper.runSelfAccessMigration(service: service, keys: keys)
        }
    }

    private static func defaultFileURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support
            .appendingPathComponent("OpenCodeGo", isDirectory: true)
            .appendingPathComponent("github-accounts.json")
    }

    /// 演示数据:3 个假账号(不同凭据类型),密码/凭据只进内存 mock
    private func setupDemo(using mock: InMemoryKeychain) {
        let totp = GitHubAccount(username: "demo-totp", notes: "演示账号(TOTP)", credentialKind: .totpSecret)
        let code = GitHubAccount(username: "demo-code", notes: "演示账号(一次性验证码)", credentialKind: .oneTimeCode, lastCodeAt: Date())
        let pwd = GitHubAccount(username: "demo-pwd", notes: "演示账号(仅密码)", credentialKind: nil)
        for account in [totp, code, pwd] {
            try? mock.set("demo-pass-123456", forKey: key("password", account.id))
        }
        try? mock.set("JBSWY3DPEHPK3PXP", forKey: key("credential", totp.id))
        try? mock.set("123456", forKey: key("credential", code.id))
        accounts = [totp, code, pwd]
    }

    // MARK: - 持久化

    private func load() {
        let result = persistence.load()
        accounts = result.model ?? []
        loadError = result.recoveryMessage
    }

    /// 保存失败必须可见：磁盘不可写/编码失败时更新 loadError，调用方可据此回滚内存状态。
    private func save() throws {
        guard !demoMode else { return }
        do {
            try persistence.save(accounts)
            // 首次成功落盘后清空启动加载错误。
            loadError = nil
        } catch {
            loadError = error.localizedDescription
            throw error
        }
    }

    // MARK: - Keychain key 约定:<uuid>-password / <uuid>-credential

    private func key(_ suffix: String, _ id: UUID) -> String {
        "\(id.uuidString)-\(suffix)"
    }

    // MARK: - 账号增删改

    @discardableResult
    func add(_ input: GitHubAccountInput) throws -> GitHubAccount {
        let name = try GitHubAccountStoreError.validatedUsername(input.username)
        let pwd = try GitHubAccountStoreError.validatedPassword(input.password)
        guard input.credential == nil || input.kind != nil else { throw GitHubAccountStoreError.credentialWithoutKind }
        guard !accounts.contains(where: { $0.username.lowercased() == name.lowercased() }) else {
            throw GitHubAccountStoreError.duplicateUsername(name)
        }
        let account = GitHubAccount(
            username: name,
            notes: input.notes,
            credentialKind: input.kind,
            lastCodeAt: input.kind == .oneTimeCode ? Date() : nil)
        // Keychain 写入前置:任一 set 失败即回滚已写入项并抛错,内存/磁盘均不变,
        // 不留孤儿 Keychain 条目
        let passwordKey = key("password", account.id)
        do {
            try keychain.set(pwd, forKey: passwordKey)
            if let credential = input.credential {
                try keychain.set(credential, forKey: key("credential", account.id))
            }
        } catch {
            keychain.delete(passwordKey)   // 回滚第一项(失败时此项可能已写入)
            throw error
        }
        accounts.append(account)
        do {
            try save()
        } catch {
            accounts.removeAll { $0.id == account.id }
            keychain.delete(passwordKey)
            if input.credential != nil { keychain.delete(key("credential", account.id)) }
            throw error
        }
        return account
    }

    /// 更新账号。input 提供完整字段,应用语义:
    /// - `passwordChanged == false` → 密码不修改(沿用旧值)
    /// - `input.credential == nil` → 凭据不修改;非 nil 时写入(此时 `input.kind` 为 nil 则沿用现有类型)
    /// - `input.kind` 非 nil 且 credential 为 nil → 仅修改类型
    func update(
        _ id: UUID,
        input: GitHubAccountInput,
        passwordChanged: Bool
    ) throws {
        guard let i = accounts.firstIndex(where: { $0.id == id }) else { return }
        let name = try GitHubAccountStoreError.validatedUsername(input.username)
        if passwordChanged {
            _ = try GitHubAccountStoreError.validatedPassword(input.password)
        }
        if accounts.contains(where: { $0.id != id && $0.username.lowercased() == name.lowercased() }) {
            throw GitHubAccountStoreError.duplicateUsername(name)
        }
        // Keychain 写入前置:写失败时内存/磁盘均未变更(避免"内存已变但 Keychain 抛错"的半更新态);
        // credential 写失败时回滚已写入的 password(用旧值还原或删除)
        let oldPassword = keychain.get(key("password", id))
        do {
            if passwordChanged {
                try keychain.set(
                    input.password.trimmingCharacters(in: .whitespacesAndNewlines),
                    forKey: key("password", id))
            }
            if let cred = input.credential {
                try keychain.set(cred, forKey: key("credential", id))
            }
        } catch {
            if let oldPassword {
                try? keychain.set(oldPassword, forKey: key("password", id))
            } else {
                keychain.delete(key("password", id))
            }
            throw error
        }
        let oldAccount = accounts[i]
        // Keychain 全部写入成功后才改内存
        accounts[i].username = name
        accounts[i].notes = input.notes
        accounts[i].updatedAt = Date()
        if input.credential != nil {
            if let kind = input.kind { accounts[i].credentialKind = kind }
            if accounts[i].credentialKind == .oneTimeCode { accounts[i].lastCodeAt = Date() }
        } else if let kind = input.kind {
            accounts[i].credentialKind = kind
        }
        do {
            try save()
        } catch {
            accounts[i] = oldAccount
            throw error
        }
    }

    /// 先持久化“账号已删除”，成功后再删除 Keychain；写盘失败时保留账号和凭据。
    func delete(_ id: UUID) throws {
        guard let i = accounts.firstIndex(where: { $0.id == id }) else { return }
        var updatedAccounts = accounts
        updatedAccounts.remove(at: i)
        let oldAccounts = accounts
        accounts = updatedAccounts
        do {
            try save()
        } catch {
            accounts = oldAccounts
            throw error
        }
        keychain.delete(key("password", id))
        keychain.delete(key("credential", id))
    }

    /// 清除已存的凭据(TOTP secret 或一次性验证码);密码不受影响
    func clearCredential(_ id: UUID) throws {
        guard let i = accounts.firstIndex(where: { $0.id == id }) else { return }
        let oldCredential = keychain.get(key("credential", id))
        keychain.delete(key("credential", id))
        let oldAccount = accounts[i]
        accounts[i].credentialKind = nil
        accounts[i].lastCodeAt = nil
        accounts[i].updatedAt = Date()
        do {
            try save()
        } catch {
            try? keychain.set(oldCredential ?? "", forKey: key("credential", id))
            accounts[i] = oldAccount
            throw error
        }
    }

    func password(for account: GitHubAccount) -> String? {
        keychain.get(key("password", account.id))
    }

    func credential(for account: GitHubAccount) -> String? {
        keychain.get(key("credential", account.id))
    }

    // MARK: - 批量导入

    /// 批量导入:行级独立校验,无效行不阻塞有效行;同一 username 已存在则跳过(不覆盖,防止手滑覆盖现有账号)。
    /// Keychain 已写入的行先暂存；只有元数据整体落盘成功才提交，写盘失败时回滚全部新账号与凭据。
    func importBatch(_ rows: [GitHubImportRow]) throws -> GitHubImportSummary {
        var imported = 0
        var skipped: [GitHubImportSkip] = []
        var writtenKeys: [String] = []
        let originalAccounts = accounts
        var seenUsernames = Set(accounts.map { $0.username.lowercased() })

        for row in rows {
            do {
                _ = try GitHubAccountStoreError.validatedUsername(row.username)
                _ = try GitHubAccountStoreError.validatedPassword(row.password)
            } catch let error as GitHubAccountStoreError {
                skipped.append(GitHubImportSkip(
                    lineNumber: row.lineNumber,
                    reason: error.errorDescription ?? "账号数据无效"))
                continue
            }
            let name = row.username.trimmingCharacters(in: .whitespacesAndNewlines)
            let pwd = row.password.trimmingCharacters(in: .whitespacesAndNewlines)
            if let cred = row.credential, cred.trimmingCharacters(in: .whitespaces).isEmpty {
                // 空串凭据 + 非空 kind 会命中 (credential?, kind?) 分支写出空凭据
                // → 卡片 TOTP 永远显示「—」;行级跳过(防御,解析器正常不会产出)
                skipped.append(GitHubImportSkip(lineNumber: row.lineNumber, reason: "凭据数据缺失"))
                continue
            }
            if seenUsernames.contains(name.lowercased()) {
                skipped.append(GitHubImportSkip(lineNumber: row.lineNumber, reason: "用户名已存在"))
                continue
            }
            let account: GitHubAccount
            switch (row.credential, row.kind) {
            case let (credential?, kind?):
                account = GitHubAccount(
                    username: name,
                    notes: "",
                    credentialKind: kind,
                    lastCodeAt: kind == .oneTimeCode ? Date() : nil)
                do {
                    try keychain.set(pwd, forKey: key("password", account.id))
                    do {
                        try keychain.set(credential, forKey: key("credential", account.id))
                    } catch {
                        // 第二项写失败时回滚第一项,不留孤儿 Keychain 条目
                        keychain.delete(key("password", account.id))
                        throw error
                    }
                    writtenKeys.append(key("password", account.id))
                    writtenKeys.append(key("credential", account.id))
                } catch {
                    skipped.append(GitHubImportSkip(
                        lineNumber: row.lineNumber,
                        reason: "凭据写入失败: \(error.localizedDescription)"))
                    continue
                }
            case (nil, nil):
                account = GitHubAccount(username: name, notes: "", credentialKind: nil, lastCodeAt: nil)
                do {
                    try keychain.set(pwd, forKey: key("password", account.id))
                    writtenKeys.append(key("password", account.id))
                } catch {
                    skipped.append(GitHubImportSkip(
                        lineNumber: row.lineNumber,
                        reason: "凭据写入失败: \(error.localizedDescription)"))
                    continue
                }
            default:
                skipped.append(GitHubImportSkip(lineNumber: row.lineNumber, reason: "凭据数据缺失"))
                continue
            }
            accounts.append(account)
            seenUsernames.insert(name.lowercased())
            imported += 1
        }

        guard imported > 0 else {
            return GitHubImportSummary(imported: 0, skipped: skipped)
        }

        do {
            try save()
        } catch {
            accounts = originalAccounts
            for keyPath in writtenKeys { keychain.delete(keyPath) }
            throw error
        }
        return GitHubImportSummary(imported: imported, skipped: skipped)
    }
}
