import Foundation
import Observation
import OSLog

/// 账号存储与刷新逻辑:Cookie 存 Keychain,账号元数据 + 上次额度快照存 JSON
@MainActor
@Observable
final class AccountStore {
    private(set) var accounts: [Account] = []
    /// 演示模式(启动参数 --demo):注入假数据,不发起真实请求
    private(set) var demoMode = false
    /// 账号数据文件读取/解码失败时的用户可见错误(启动加载时置位,首次成功保存后清空)
    private(set) var loadError: String?
    /// 是否正在执行 refreshAll(手动刷新按钮据此显示进度 spinner 并禁用重复点击;
    /// 启动等场景无需等待此状态,界面照常渲染)
    private(set) var isRefreshing = false

    private static let logger = Logger(subsystem: "com.acccan.opencode-go", category: "account-store")

    private let keychain: KeychainStoring
    private let client: QuotaClient
    private let fileURL: URL
    /// JSON 落盘、写前快照、损坏留证和快照恢复统一委托给通用存储。
    private var persistence: JSONFileStore<[Account]> {
        JSONFileStore(
            fileURL: fileURL,
            subject: "账号",
            sourceName: "accounts.json",
            logger: Self.logger)
    }

    /// - Parameters:
    ///   - client: 额度客户端(默认 .shared)
    ///   - keychain: nil → KeychainHelper(service: "com.acccan.opencode-go")
    ///   - fileURL: nil → Application Support/OpenCode-Go-Quotas/accounts.json
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
        // 一次性把既有 Cookie 项迁移为「仅本 app 免提示访问」ACL(后台执行,不阻塞 UI)
        scheduleSelfAccessMigration()
    }

    /// 把既有 Keychain 项(auth Cookie)迁移为「仅本 app 免提示访问」ACL,消除每次
    /// 刷新读取 Cookie 的授权弹窗。仅使用真实 KeychainHelper(非测试注入 mock)且非
    /// demo 模式时执行;后台异步,失败由 KeychainHelper 记日志并在下次启动重试。
    private func scheduleSelfAccessMigration() {
        guard !demoMode, let helper = keychain as? KeychainHelper else { return }
        let keys = accounts.map { $0.id.uuidString }
        let service = helper.service
        Task.detached(priority: .utility) {
            KeychainHelper.runSelfAccessMigration(service: service, keys: keys)
        }
    }

    private static func defaultFileURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support
            .appendingPathComponent("OpenCode-Go-Quotas", isDirectory: true)
            .appendingPathComponent("accounts.json")
    }

    // MARK: - 持久化

    private func load() {
        let result = persistence.load()
        accounts = result.model ?? []
        loadError = result.recoveryMessage
    }

    /// 保存失败必须对用户可见：磁盘不可写/编码失败时保留或更新 loadError，
    /// 避免调用方误以为账号元数据已持久化。
    private func save() throws {
        do {
            try persistence.save(accounts)
            // L3:首次成功落盘后清空启动加载错误(损坏红条会话内可消除)。
            loadError = nil
        } catch {
            loadError = error.localizedDescription
            throw error
        }
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
        do {
            try save()
        } catch {
            // Keychain 已写入，但元数据未落盘；回滚内存并删除孤儿凭据。
            accounts.removeAll { $0.id == account.id }
            keychain.delete(account.id.uuidString)
            throw error
        }
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
        let oldAccount = accounts[i]
        accounts[i].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        accounts[i].workspaceId = workspaceId.trimmingCharacters(in: .whitespacesAndNewlines)
        accounts[i].notes = notes
        accounts[i].updatedAt = Date()
        do {
            try save()
        } catch {
            accounts[i] = oldAccount
            throw error
        }
    }

    /// 先持久化“账号已删除”的元数据，成功后再删 Keychain；
    /// 避免磁盘写失败时出现“元数据仍在但凭据已被删”的半更新状态。
    func deleteAccount(_ id: UUID) throws {
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
        keychain.delete(id.uuidString)
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
            try? save()
        } catch {
            guard let i = accounts.firstIndex(where: { $0.id == account.id }) else { return }
            accounts[i].usageError = error.localizedDescription
            try? save()
        }
    }

    /// 并行刷新全部账号:每个账号一个 TaskGroup 子任务并发抓取(总耗时 ≈ 最慢单个账号,
    /// 而非串行之和),聚合后回到主线程统一按 id 写回,且只落盘一次。
    /// 子任务只返回 (id, RefreshOutcome),不触碰 accounts,天然避免跨线程数据竞争。
    /// 只有瞬时失败会自动重试 1 次；输入无效、页面/RPC 结构变化与 Cookie 缺失不重试。
    /// 重试按失败序号错开 250ms × n 短退避;重试成功覆盖首轮错误,仍失败以重试 error 为准。
    /// 整体单轮内每账号最多重试 1 次,不引入跨轮/无限重试。
    func refreshAll() async {
        // 生命周期标记:进入即置位,所有退出路径(demo 提前返回/成功/失败)统一复位。
        // refreshAll 为 @MainActor async,置位与复位都在同一 actor 上下文,不跨线程
        isRefreshing = true
        defer { isRefreshing = false }

        // demo 模式无网络请求,保持原串行行为(逐账号 demoRefresh,不落盘)
        if demoMode {
            for account in accounts { await refresh(account) }
            return
        }

        struct RefreshOutcome {
            let usage: UsageResult?
            let error: Error?
            let canRetry: Bool
            let missingCookie: Bool

            static func success(_ usage: UsageResult) -> RefreshOutcome {
                RefreshOutcome(usage: usage, error: nil, canRetry: false, missingCookie: false)
            }
            static func permanent(_ error: Error, missingCookie: Bool = false) -> RefreshOutcome {
                RefreshOutcome(usage: nil, error: error, canRetry: false, missingCookie: missingCookie)
            }
            static func retryable(_ error: Error) -> RefreshOutcome {
                RefreshOutcome(usage: nil, error: error, canRetry: true, missingCookie: false)
            }
        }

        struct StoreMissingCookieError: LocalizedError {
            var errorDescription: String? { "未找到 Cookie，请重新添加账号" }
        }

        // 主线程先取快照 + 读 Cookie;子任务只持 Sendable 的 client 与值类型快照
        let client = self.client
        let logger = Self.logger
        let snapshot = accounts.map {
            (id: $0.id, workspaceId: $0.workspaceId, cookie: keychain.get($0.id.uuidString))
        }
        var results: [(id: UUID, outcome: RefreshOutcome)] = []
        results.reserveCapacity(snapshot.count)

        await withTaskGroup(of: (UUID, RefreshOutcome).self) { group in
            for item in snapshot {
                group.addTask {
                    guard let cookie = item.cookie else {
                        return (item.id, .permanent(StoreMissingCookieError(), missingCookie: true))
                    }
                    do {
                        let usage = try await client.fetchGoQuota(
                            workspaceId: item.workspaceId, authCookie: cookie)
                        return (item.id, .success(usage))
                    } catch {
                        let outcome: RefreshOutcome
                        if let quotaError = error as? QuotaError, quotaError.isPermanent {
                            outcome = .permanent(quotaError)
                        } else {
                            outcome = .retryable(error)
                        }
                        return (item.id, outcome)
                    }
                }
            }
            for await result in group {
                results.append(result)
            }
        }

        // 只重试瞬时失败；输入无效、页面结构变化和 Cookie 缺失不发起第二次请求。
        var retryItems: [(id: UUID, workspaceId: String, cookie: String, error: Error)] = []
        for result in results {
            guard result.outcome.canRetry,
                  let retryError = result.outcome.error,
                  let item = snapshot.first(where: { $0.id == result.id }),
                  let cookie = item.cookie
            else { continue }
            retryItems.append((id: result.id, workspaceId: item.workspaceId, cookie: cookie, error: retryError))
        }

        if !retryItems.isEmpty {
            var retryResults: [(id: UUID, outcome: RefreshOutcome)] = []
            retryResults.reserveCapacity(retryItems.count)
            await withTaskGroup(of: (UUID, RefreshOutcome).self) { group in
                for (index, item) in retryItems.enumerated() {
                    group.addTask {
                        // 短退避:按失败序号错开 250ms × n(n = 1-based 失败序号),
                        // 让并发重试错峰,避免同一瞬间扎堆;重试期间 isRefreshing 保持 true
                        try? await Task.sleep(
                            nanoseconds: UInt64(250_000_000) * UInt64(index + 1))
                        logger.warning("刷新失败,自动重试账号 \(item.id.uuidString)")
                        do {
                            let usage = try await client.fetchGoQuota(
                                workspaceId: item.workspaceId, authCookie: item.cookie)
                            return (item.id, .success(usage))
                        } catch {
                            logger.error("重试仍失败,账号 \(item.id.uuidString): \(error.localizedDescription)")
                            return (item.id, .retryable(error))
                        }
                    }
                }
                for await result in group {
                    retryResults.append(result)
                }
            }
            // 重试结果覆盖首轮:成功 → usage 写回(usageError 清空);仍失败 → 以重试 error 为准
            for (id, outcome) in retryResults {
                if let idx = results.firstIndex(where: { $0.id == id }) {
                    results[idx] = (id: id, outcome: outcome)
                }
            }
        }

        // 回到主线程:按 id 重查下标统一写回(账号可能已被删除 → 重查失败静默跳过),
        // 全部写回后只 save() 一次,避免 N 次全量写盘;保存失败以 loadError 暴露给 UI。
        for (id, outcome) in results {
            guard let i = accounts.firstIndex(where: { $0.id == id }) else { continue }
            if let usage = outcome.usage {
                accounts[i].usage = usage
                accounts[i].updatedAt = Date()
                accounts[i].usageError = nil
            } else if let error = outcome.error {
                accounts[i].usageError = error.localizedDescription
            }
        }
        try? save()
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
    /// 2. cursor > 0 的空响应抛 QuotaError.emptyPage → 视为正常到底;
    /// 3. 首页解析失败或真实网络/认证错误原样上抛,由调用方置 historyError;
    /// 4. 达到页数上限 maxPages,防止失控;任务取消时立即停止并保留已获取数据。
    /// 各页合并后按 id 去重,再按 timeCreated 降序排列。
    static func fetchAllHistoryPages(
        client: QuotaClient,
        workspaceId: String,
        authCookie: String,
        maxPages: Int = 20
    ) async throws -> [UsageHistoryItem] {
        var all: [UsageHistoryItem] = []
        var windowSize: Int?
        for cursor in 0..<maxPages {
            try Task.checkCancellation()
            let page: [UsageHistoryItem]
            do {
                page = try await client.fetchGoUsageHistory(
                    workspaceId: workspaceId, authCookie: authCookie, cursor: cursor)
            } catch let error as QuotaError {
                if case .emptyPage = error, cursor > 0 { break } // 翻页终点
                throw error
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
