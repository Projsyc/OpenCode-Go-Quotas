import Foundation
import Observation
import OSLog

/// 批量导入结果摘要:成功导入数 + 被跳过行列表
struct GitHubImportSummary: Equatable, Sendable {
    var imported: Int
    var skipped: [GitHubImportSkip]
}

/// 批量导入中被跳过的行(行号 + 原因)
struct GitHubImportSkip: Equatable, Sendable {
    var lineNumber: Int
    var reason: String
}

/// GitHub 账号存储错误
enum GitHubAccountStoreError: LocalizedError, Equatable {
    case emptyUsername
    case passwordTooShort
    case duplicateUsername(String)
    case credentialWithoutKind

    var errorDescription: String? {
        switch self {
        case .emptyUsername: return "用户名不能为空"
        case .passwordTooShort: return "密码至少 6 个字符"
        case .duplicateUsername(let name): return "用户名 \(name) 已存在"
        case .credentialWithoutKind: return "提供验证码/TOTP secret 时必须指定凭据类型"
        }
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
    /// 写前滚动快照路径(单份):每次 save 前把当前 github-accounts.json 复制到这里
    private var snapshotURL: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("github-accounts.json.bak")
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

    /// 幂等加载:JSON 不存在或解码失败时静默为空数组;demo 模式不读盘(数据为预置假账号)。
    /// 主文件存在但解码失败(损坏)时,优先从写前快照 github-accounts.json.bak 恢复;
    /// 快照同样不可用才按原行为(空数组),绝不静默清空。
    private func load() {
        guard !demoMode else { return }
        guard let data = try? Data(contentsOf: fileURL) else { return } // 不存在/不可读 → 首次运行
        do {
            accounts = try JSONDecoder().decode([GitHubAccount].self, from: data)
        } catch {
            if let backupData = try? Data(contentsOf: snapshotURL),
               let recovered = try? JSONDecoder().decode([GitHubAccount].self, from: backupData) {
                // 从快照恢复:仅换「读哪个文件」,不改账号字段/解码语义
                accounts = recovered
                // 先尽力把损坏原件复制留证,再把恢复内容写回主文件(否则下次启动会因
                // 主文件缺失/损坏被当成首次运行,恢复结果丢失)
                let backupName = stashCorruptedFile(move: false)
                restoreMainFileFromSnapshot()
                if let backupName {
                    loadError = "GitHub 账号数据文件损坏，已从备份恢复数据（原文件已备份为 \(backupName)）"
                } else {
                    loadError = "GitHub 账号数据文件损坏，已从备份恢复数据"
                }
                Self.logger.error("github-accounts.json 解码失败，已从快照恢复数据")
            } else {
                // 快照缺失或同样损坏 → 尽量移动损坏原件留证后置空(否则下次 save()
                // 的全量覆盖会永久丢弃它,且写前快照会抄到损坏内容)
                accounts = []
                if let backupName = stashCorruptedFile(move: true) {
                    loadError = "GitHub 账号数据文件损坏，已备份为 \(backupName)，请检查后重新添加"
                } else {
                    loadError = "GitHub 账号数据文件损坏，且备份失败，请检查后重新添加"
                }
                Self.logger.error("github-accounts.json 解码失败且快照不可用，已置空")
            }
        }
    }

    /// 把损坏的 github-accounts.json 移动/复制备份为 github-accounts.json.bak-<时间戳>
    /// (同秒冲突自动加序号)。返回备份名;失败返回 nil(备份是保险不是依赖,调用方不阻断)。
    @discardableResult
    private func stashCorruptedFile(move: Bool) -> String? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        let dir = fileURL.deletingLastPathComponent()
        var backupName = "github-accounts.json.bak-\(stamp)"
        var backupURL = dir.appendingPathComponent(backupName)
        var suffix = 2
        while FileManager.default.fileExists(atPath: backupURL.path) {
            backupName = "github-accounts.json.bak-\(stamp)-\(suffix)"
            backupURL = dir.appendingPathComponent(backupName)
            suffix += 1
        }
        do {
            if move {
                try FileManager.default.moveItem(at: fileURL, to: backupURL)
            } else {
                try FileManager.default.copyItem(at: fileURL, to: backupURL)
            }
            return backupName
        } catch {
            return nil
        }
    }

    /// 恢复后把主文件写回可用状态:用快照内容覆盖损坏的 github-accounts.json(字节一致)。
    /// 失败仅记日志 —— 内存中的恢复结果仍在,且会话内任意一次 save() 会重新落盘。
    private func restoreMainFileFromSnapshot() {
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
            try FileManager.default.copyItem(at: snapshotURL, to: fileURL)
        } catch {
            Self.logger.error("从快照写回 github-accounts.json 失败: \(error.localizedDescription)")
        }
    }

    /// demo 模式不落盘(内存存储)
    private func save() {
        guard !demoMode else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        snapshotBeforeWrite()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(accounts) else { return }
        do {
            try data.write(to: fileURL, options: .atomic)
            // 首次成功落盘后清空启动加载错误;写盘失败时保留
            loadError = nil
        } catch {
            // 写盘失败 → 保留 loadError(数据仍不可靠)
            Self.logger.error("github-accounts.json 写盘失败: \(error.localizedDescription)")
        }
    }

    /// 写盘前把当前 github-accounts.json 复制为滚动快照 github-accounts.json.bak(单份):
    /// 仅当写前文件已存在才快照(首次写入无旧文件 → 跳过);失败不阻断保存,只记日志
    /// (备份是保险不是依赖)。
    private func snapshotBeforeWrite() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            if FileManager.default.fileExists(atPath: snapshotURL.path) {
                try FileManager.default.removeItem(at: snapshotURL)
            }
            try FileManager.default.copyItem(at: fileURL, to: snapshotURL)
        } catch {
            Self.logger.error("写前快照 github-accounts.json.bak 失败: \(error.localizedDescription)")
        }
    }

    // MARK: - Keychain key 约定:<uuid>-password / <uuid>-credential

    private func key(_ suffix: String, _ id: UUID) -> String {
        "\(id.uuidString)-\(suffix)"
    }

    // MARK: - 账号增删改

    @discardableResult
    func add(_ input: GitHubAccountInput) throws -> GitHubAccount {
        let name = input.username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw GitHubAccountStoreError.emptyUsername }
        let pwd = input.password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard pwd.count >= 6 else { throw GitHubAccountStoreError.passwordTooShort }
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
        save()
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
        let name = input.username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw GitHubAccountStoreError.emptyUsername }
        if passwordChanged,
           input.password.trimmingCharacters(in: .whitespacesAndNewlines).count < 6 {
            throw GitHubAccountStoreError.passwordTooShort
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
        save()
    }

    func delete(_ id: UUID) {
        guard let i = accounts.firstIndex(where: { $0.id == id }) else { return }
        keychain.delete(key("password", id))
        keychain.delete(key("credential", id))
        accounts.remove(at: i)
        save()
    }

    /// 清除已存的凭据(TOTP secret 或一次性验证码);密码不受影响
    func clearCredential(_ id: UUID) throws {
        guard let i = accounts.firstIndex(where: { $0.id == id }) else { return }
        keychain.delete(key("credential", id))
        accounts[i].credentialKind = nil
        accounts[i].lastCodeAt = nil
        accounts[i].updatedAt = Date()
        save()
    }

    func password(for account: GitHubAccount) -> String? {
        keychain.get(key("password", account.id))
    }

    func credential(for account: GitHubAccount) -> String? {
        keychain.get(key("credential", account.id))
    }

    // MARK: - 批量导入

    /// 批量导入:行级独立校验,无效行不阻塞有效行;同一 username 已存在则跳过(不覆盖,防止手滑覆盖现有账号)
    func importBatch(_ rows: [GitHubImportRow]) throws -> GitHubImportSummary {
        var imported = 0
        var skipped: [GitHubImportSkip] = []
        var seenUsernames = Set(accounts.map { $0.username.lowercased() })

        for row in rows {
            let name = row.username.trimmingCharacters(in: .whitespacesAndNewlines)
            let pwd = row.password.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty {
                skipped.append(GitHubImportSkip(lineNumber: row.lineNumber, reason: "用户名不能为空"))
                continue
            }
            if pwd.count < 6 {
                skipped.append(GitHubImportSkip(lineNumber: row.lineNumber, reason: "密码至少 6 个字符"))
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
        save()
        return GitHubImportSummary(imported: imported, skipped: skipped)
    }
}
