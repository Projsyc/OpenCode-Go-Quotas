import Foundation
import Observation

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

    private let keychain: KeychainStoring
    private let fileURL: URL

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

    /// 幂等加载:JSON 不存在或解码失败时静默为空数组;demo 模式不读盘(数据为预置假账号)
    private func load() {
        guard !demoMode,
              let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([GitHubAccount].self, from: data)
        else { return }
        accounts = decoded
    }

    /// demo 模式不落盘(内存存储)
    private func save() {
        guard !demoMode else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(accounts) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: - Keychain key 约定:<uuid>-password / <uuid>-credential

    private func key(_ suffix: String, _ id: UUID) -> String {
        "\(id.uuidString)-\(suffix)"
    }

    // MARK: - 账号增删改

    @discardableResult
    func add(
        username: String,
        notes: String = "",
        password: String,
        credential: String? = nil,
        kind: GitHubCredentialKind? = nil
    ) throws -> GitHubAccount {
        let name = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw GitHubAccountStoreError.emptyUsername }
        let pwd = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard pwd.count >= 6 else { throw GitHubAccountStoreError.passwordTooShort }
        guard credential == nil || kind != nil else { throw GitHubAccountStoreError.credentialWithoutKind }
        guard !accounts.contains(where: { $0.username.lowercased() == name.lowercased() }) else {
            throw GitHubAccountStoreError.duplicateUsername(name)
        }
        let account = GitHubAccount(
            username: name,
            notes: notes,
            credentialKind: kind,
            lastCodeAt: kind == .oneTimeCode ? Date() : nil)
        // Keychain 写入前置:任一 set 失败即回滚已写入项并抛错,内存/磁盘均不变,
        // 不留孤儿 Keychain 条目
        let passwordKey = key("password", account.id)
        do {
            try keychain.set(pwd, forKey: passwordKey)
            if let credential {
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

    /// 更新账号;password/credential/kind 传 nil 表示不修改(credential 更新时 kind 留 nil 沿用现有类型)
    func update(
        _ id: UUID,
        username: String,
        notes: String,
        password: String? = nil,
        credential: String? = nil,
        kind: GitHubCredentialKind? = nil
    ) throws {
        guard let i = accounts.firstIndex(where: { $0.id == id }) else { return }
        let name = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw GitHubAccountStoreError.emptyUsername }
        if let pwd = password?.trimmingCharacters(in: .whitespacesAndNewlines), pwd.count < 6 {
            throw GitHubAccountStoreError.passwordTooShort
        }
        if accounts.contains(where: { $0.id != id && $0.username.lowercased() == name.lowercased() }) {
            throw GitHubAccountStoreError.duplicateUsername(name)
        }
        // Keychain 写入前置:写失败时内存/磁盘均未变更(避免"内存已变但 Keychain 抛错"的半更新态);
        // credential 写失败时回滚已写入的 password(用旧值还原或删除)
        let oldPassword = keychain.get(key("password", id))
        do {
            if let pwd = password?.trimmingCharacters(in: .whitespacesAndNewlines) {
                try keychain.set(pwd, forKey: key("password", id))
            }
            if let cred = credential {
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
        accounts[i].notes = notes
        accounts[i].updatedAt = Date()
        if credential != nil {
            if let kind { accounts[i].credentialKind = kind }
            if accounts[i].credentialKind == .oneTimeCode { accounts[i].lastCodeAt = Date() }
        } else if let kind {
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
