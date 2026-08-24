import Foundation
import Observation

/// 账号存储与刷新逻辑:Cookie 存 Keychain,账号元数据 + 上次额度快照存 JSON
@MainActor
@Observable
final class AccountStore {
    private(set) var accounts: [Account] = []
    /// 演示模式(启动参数 --demo):注入假数据,不发起真实请求
    private(set) var demoMode = false
    /// 账号数据文件读取/解码失败时的用户可见错误(仅启动加载时置位)
    private(set) var loadError: String?

    private let keychain: KeychainStoring
    private let client: QuotaClient
    private let fileURL: URL

    /// - Parameters:
    ///   - client: 额度客户端(默认 .shared)
    ///   - keychain: nil → KeychainHelper(service: "com.acccan.opencode-go")
    ///   - fileURL: nil → Application Support/OpenCodeGo/accounts.json
    init(
        client: QuotaClient = QuotaClient(),
        keychain: KeychainStoring? = nil,
        fileURL: URL? = nil
    ) {
        self.client = client
        self.keychain = keychain ?? KeychainHelper(service: "com.acccan.opencode-go")
        self.fileURL = fileURL ?? Self.defaultFileURL()
        load()
        if ProcessInfo.processInfo.arguments.contains("--demo") {
            demoMode = true
            loadDemo()
        }
    }

    private static func defaultFileURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support
            .appendingPathComponent("OpenCodeGo", isDirectory: true)
            .appendingPathComponent("accounts.json")
    }

    // MARK: - 持久化

    private func load() {
        // 文件不存在 → 首次运行,空列表正常,不报错
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            accounts = try JSONDecoder().decode([Account].self, from: Data(contentsOf: fileURL))
        } catch {
            // 文件存在但读取/解码失败 → 备份原文件后置空,绝不静默清空
            // (否则下次 save() 全量原子覆盖会永久丢失真实账号元数据)
            accounts = []
            if let backupName = backupCorruptedFile() {
                loadError = "账号数据文件损坏，已备份为 \(backupName)，请检查后重新添加"
            } else {
                loadError = "账号数据文件损坏，且备份失败，请检查后重新添加"
            }
        }
    }

    /// 把损坏的 accounts.json 移动备份为 accounts.json.bak-<时间戳>(同秒冲突自动加序号)。
    /// 返回备份文件名;备份失败返回 nil。
    @discardableResult
    private func backupCorruptedFile() -> String? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        let dir = fileURL.deletingLastPathComponent()
        var backupName = "accounts.json.bak-\(stamp)"
        var backupURL = dir.appendingPathComponent(backupName)
        var suffix = 2
        while FileManager.default.fileExists(atPath: backupURL.path) {
            backupName = "accounts.json.bak-\(stamp)-\(suffix)"
            backupURL = dir.appendingPathComponent(backupName)
            suffix += 1
        }
        do {
            try FileManager.default.moveItem(at: fileURL, to: backupURL)
            return backupName
        } catch {
            return nil
        }
    }

    private func save() {
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(accounts) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: - 账号增删改

    @discardableResult
    func addAccount(name: String, workspaceId: String, authCookie: String, notes: String) throws -> Account {
        let account = Account(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            workspaceId: workspaceId.trimmingCharacters(in: .whitespacesAndNewlines),
            notes: notes)
        try keychain.set(authCookie.trimmingCharacters(in: .whitespacesAndNewlines),
                         forKey: account.id.uuidString)
        accounts.append(account)
        save()
        return account
    }

    func updateAccount(
        _ id: UUID,
        name: String,
        workspaceId: String,
        authCookie: String?,
        notes: String
    ) throws {
        guard let i = accounts.firstIndex(where: { $0.id == id }) else { return }
        // 先写 Keychain,成功后再改内存 + save:set 抛错时内存/磁盘保持原状,不产生不一致
        if let cookie = authCookie?.trimmingCharacters(in: .whitespacesAndNewlines), !cookie.isEmpty {
            try keychain.set(cookie, forKey: id.uuidString)
        }
        accounts[i].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        accounts[i].workspaceId = workspaceId.trimmingCharacters(in: .whitespacesAndNewlines)
        accounts[i].notes = notes
        accounts[i].updatedAt = Date()
        save()
    }

    func deleteAccount(_ id: UUID) {
        guard let i = accounts.firstIndex(where: { $0.id == id }) else { return }
        keychain.delete(id.uuidString)
        accounts.remove(at: i)
        save()
    }

    func cookie(for account: Account) -> String? {
        keychain.get(account.id.uuidString)
    }

    // MARK: - 刷新额度

    func refresh(_ account: Account) async {
        guard let i = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        if demoMode { demoRefresh(&accounts[i]); return }
        accounts[i].usageError = nil
        guard let cookie = keychain.get(account.id.uuidString) else {
            accounts[i].usageError = "未找到 Cookie，请重新添加账号"
            return
        }
        do {
            let usage = try await client.fetchGoQuota(
                workspaceId: account.workspaceId, authCookie: cookie)
            // await 期间账号可能被删除/前移 → 恢复后必须按 id 重查下标;
            // 已删除则静默返回(不写、不报错)
            guard let i = accounts.firstIndex(where: { $0.id == account.id }) else { return }
            accounts[i].usage = usage
            accounts[i].updatedAt = Date()
            accounts[i].usageError = nil
            save()
        } catch {
            guard let i = accounts.firstIndex(where: { $0.id == account.id }) else { return }
            accounts[i].usageError = error.localizedDescription
            save()
        }
    }

    func refreshAll() async {
        for account in accounts { await refresh(account) }
    }

    // MARK: - 用量历史

    func loadHistory(_ account: Account) async {
        guard let i = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        if demoMode {
            accounts[i].history = demoHistory
            accounts[i].historyError = nil
            return
        }
        accounts[i].historyLoading = true
        accounts[i].historyError = nil
        guard let cookie = keychain.get(account.id.uuidString) else {
            accounts[i].historyError = "未找到 Cookie，请重新添加账号"
            accounts[i].historyLoading = false
            return
        }
        do {
            let history = try await Self.fetchAllHistoryPages(
                client: client, workspaceId: account.workspaceId, authCookie: cookie)
            // await 期间账号可能被删除 → 按 id 重查;已删除则无需清理 loading(账号已不在数组)
            guard let i = accounts.firstIndex(where: { $0.id == account.id }) else { return }
            accounts[i].history = history
            accounts[i].historyError = nil
            accounts[i].historyLoading = false
        } catch {
            guard let i = accounts.firstIndex(where: { $0.id == account.id }) else { return }
            accounts[i].historyError = error.localizedDescription
            accounts[i].historyLoading = false
        }
    }

    /// 分页拉取全部用量历史(服务端每页返回定长窗口,cursor 为页码索引):
    /// 逐页递增 cursor,直到满足任一终止条件 ——
    /// 1. 某页解析出的记录数 < 单页窗口(以首页实际解析条数为准)→ 已到底;
    /// 2. 解析抛错(空页会抛 QuotaError.parseFailed)→ 视为已到底;
    /// 3. 达到页数上限 maxPages,防止失控。
    /// 各页合并后按 id 去重,再按 timeCreated 降序排列。
    /// 其余真实失败(认证失败/会话过期/HTTP 错误)原样上抛,由调用方置 historyError。
    static func fetchAllHistoryPages(
        client: QuotaClient,
        workspaceId: String,
        authCookie: String,
        maxPages: Int = 20
    ) async throws -> [UsageHistoryItem] {
        var all: [UsageHistoryItem] = []
        var windowSize: Int?
        for cursor in 0..<maxPages {
            let page: [UsageHistoryItem]
            do {
                page = try await client.fetchGoUsageHistory(
                    workspaceId: workspaceId, authCookie: authCookie, cursor: cursor)
            } catch let error as QuotaError {
                // 空页以 parseFailed 上抛 → 已到底;其余真实失败上抛
                guard case .parseFailed = error else { throw error }
                break
            }
            all.append(contentsOf: page)
            if let windowSize {
                if page.count < windowSize { break } // 短页(< 单页窗口)→ 已到底,该页并入结果
            } else {
                windowSize = page.count // 首页条数即单页窗口(以实际解析条数为准)
            }
        }
        var seen = Set<String>()
        let deduped = all.filter { seen.insert($0.id).inserted }
        return deduped.sorted { $0.timeCreated > $1.timeCreated }
    }

    // MARK: - 演示数据(仅 --demo 模式)

    private func loadDemo() {
        accounts = [
            Account(
                name: "主账号", workspaceId: "wrk_demo123",
                notes: "演示数据", usage: demoUsage(percent: 12.5)),
            Account(
                name: "副账号", workspaceId: "wrk_demo456",
                notes: "演示数据", usage: demoUsage(percent: 47.2)),
            Account(
                name: "备用账号", workspaceId: "wrk_demo789",
                notes: "演示数据", usage: demoUsage(percent: 88.8)),
        ]
    }

    private func demoRefresh(_ account: inout Account) {
        account.usage = demoUsage(percent: Double.random(in: 0...95))
        account.updatedAt = Date()
        account.usageError = nil
    }

    private func demoUsage(percent: Double) -> UsageResult {
        UsageResult(
            rolling: UsageWindow(usagePercent: percent, resetInSec: 5 * 3600 * (0.2 + percent / 200)),
            weekly: UsageWindow(usagePercent: percent * 1.8, resetInSec: 2.7 * 86400),
            monthly: UsageWindow(usagePercent: percent * 0.9, resetInSec: 21.5 * 86400),
            plan: "OpenCode Go",
            fetchedAt: Date())
    }

    private var demoHistory: [UsageHistoryItem] {
        let models = ["claude-opus-4-8", "claude-sonnet-4-5", "gemini-2.5-pro"]
        return (0..<40).map { i in
            let t = Date().addingTimeInterval(-Double(i) * 5400) // 每 1.5 小时一条
            return UsageHistoryItem(
                id: "usg_demo\(i)",
                timeCreated: t,
                model: models[i % models.count],
                provider: ["anthropic", "anthropic", "google"][i % 3],
                inputTokens: Int.random(in: 800...8000),
                outputTokens: Int.random(in: 300...3000),
                reasoningTokens: Int.random(in: 0...1500),
                cacheReadTokens: Int.random(in: 0...12000),
                cacheWrite5mTokens: Int.random(in: 0...300),
                cacheWrite1hTokens: Int.random(in: 0...200),
                cost: Double.random(in: 0.001...0.35),
                keyID: "key_demo",
                sessionID: "ses_demo\(i % 7)",
                plan: "OpenCode Go")
        }
    }
}
