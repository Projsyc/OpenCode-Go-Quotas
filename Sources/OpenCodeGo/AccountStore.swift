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
    /// 写前滚动快照路径(单份):每次 save 前把当前 accounts.json 复制到这里
    private var snapshotURL: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("accounts.json.bak")
    }

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
            // 主文件损坏:优先尝试从写前快照 accounts.json.bak 恢复
            // (仅换「读哪个文件」,不改任何账号字段/解码语义)
            if let recovered = try? JSONDecoder().decode(
                [Account].self, from: Data(contentsOf: snapshotURL)
            ) {
                accounts = recovered
                // 先尽力把损坏原件复制留证(不动主文件),再把恢复内容写回主文件:
                // 若只留在内存,下次启动会因主文件缺失被当成「首次运行」,恢复结果丢失
                let backupName = stashCorruptedFile(move: false)
                restoreMainFileFromSnapshot()
                if let backupName {
                    loadError = "账号数据文件损坏，已从备份恢复数据（原文件已备份为 \(backupName)）"
                } else {
                    loadError = "账号数据文件损坏，已从备份恢复数据"
                }
                Self.logger.error("accounts.json 解码失败，已从快照 accounts.json.bak 恢复数据")
                return
            }
            // 快照缺失或同样损坏 → 维持原行为:备份原文件后置空,绝不静默清空
            // (否则下次 save() 全量原子覆盖会永久丢失真实账号元数据)
            accounts = []
            if let backupName = stashCorruptedFile(move: true) {
                loadError = "账号数据文件损坏，已备份为 \(backupName)，请检查后重新添加"
            } else {
                loadError = "账号数据文件损坏，且备份失败，请检查后重新添加"
            }
        }
    }

    /// 把损坏的 accounts.json 移动/复制备份为 accounts.json.bak-<时间戳>(同秒冲突自动加序号)。
    /// 返回备份文件名;失败返回 nil(备份是保险不是依赖,调用方不阻断)。
    /// - Parameter move: true → 移动(原文件消失,主路径不可读);false → 复制(原文件保留)
    @discardableResult
    private func stashCorruptedFile(move: Bool) -> String? {
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

    /// 恢复后把主文件写回可用状态:用快照内容覆盖损坏的 accounts.json(字节一致)。
    /// 失败仅记日志 —— 内存中的恢复结果仍在,且会话内任意一次 save() 会重新落盘。
    private func restoreMainFileFromSnapshot() {
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
            try FileManager.default.copyItem(at: snapshotURL, to: fileURL)
        } catch {
            Self.logger.error("从快照写回 accounts.json 失败: \(error.localizedDescription)")
        }
    }

    private func save() {
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        snapshotBeforeWrite()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(accounts) else { return }
        do {
            try data.write(to: fileURL, options: .atomic)
            // L3:首次成功落盘后清空启动加载错误(损坏红条会话内可消除);写盘失败时保留
            loadError = nil
        } catch {
            // 写盘失败 → 保留 loadError(数据仍不可靠,红条继续提示)
        }
    }

    /// 写盘前把当前 accounts.json 复制为滚动快照 accounts.json.bak(单份,每次写前覆盖):
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
            Self.logger.error("写前快照 accounts.json.bak 失败: \(error.localizedDescription)")
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

    /// 并行刷新全部账号:每个账号一个 TaskGroup 子任务并发抓取(总耗时 ≈ 最慢单个账号,
    /// 而非串行之和),聚合后回到主线程统一按 id 写回,且只落盘一次。
    /// 子任务只返回 (id, usage, error) 元组,不触碰 accounts,天然避免跨线程数据竞争。
    /// 首轮失败的账号(除 cookie 缺失等本地错误外)自动重试 1 次:按失败序号错开
    /// 250ms × n 短退避,重试同样并发;重试成功覆盖首轮错误,仍失败以重试 error 为准。
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

        // 主线程先取快照 + 读 Cookie;子任务只持 Sendable 的 client 与值类型快照
        let client = self.client
        let logger = Self.logger
        let snapshot = accounts.map {
            (id: $0.id, workspaceId: $0.workspaceId, cookie: keychain.get($0.id.uuidString))
        }
        var results: [(id: UUID, usage: UsageResult?, error: String?)] = []
        results.reserveCapacity(snapshot.count)

        await withTaskGroup(of: (UUID, UsageResult?, String?).self) { group in
            for item in snapshot {
                group.addTask {
                    guard let cookie = item.cookie else {
                        return (item.id, nil, "未找到 Cookie，请重新添加账号")
                    }
                    do {
                        let usage = try await client.fetchGoQuota(
                            workspaceId: item.workspaceId, authCookie: cookie)
                        return (item.id, usage, nil)
                    } catch {
                        return (item.id, nil, error.localizedDescription)
                    }
                }
            }
            for await result in group {
                results.append(result)
            }
        }

        // 收集首轮失败且持有 Cookie 的账号 → 第二波重试(每账号最多重试 1 次)。
        // cookie 缺失类错误重试无意义,直接跳过,保留首轮错误写回
        var retryItems: [(id: UUID, workspaceId: String, cookie: String, error: String)] = []
        for result in results {
            guard let error = result.error,
                  let item = snapshot.first(where: { $0.id == result.id }),
                  let cookie = item.cookie
            else { continue }
            retryItems.append((id: result.id, workspaceId: item.workspaceId, cookie: cookie, error: error))
        }

        if !retryItems.isEmpty {
            var retryResults: [(id: UUID, usage: UsageResult?, error: String?)] = []
            retryResults.reserveCapacity(retryItems.count)
            await withTaskGroup(of: (UUID, UsageResult?, String?).self) { group in
                for (index, item) in retryItems.enumerated() {
                    group.addTask {
                        // 短退避:按失败序号错开 250ms × n(n = 1-based 失败序号),
                        // 让并发重试错峰,避免同一瞬间扎堆;重试期间 isRefreshing 保持 true
                        try? await Task.sleep(
                            nanoseconds: UInt64(250_000_000) * UInt64(index + 1))
                        logger.warning("刷新失败,自动重试账号 \(item.id.uuidString): \(item.error)")
                        do {
                            let usage = try await client.fetchGoQuota(
                                workspaceId: item.workspaceId, authCookie: item.cookie)
                            return (item.id, usage, nil)
                        } catch {
                            logger.error("重试仍失败,账号 \(item.id.uuidString): \(error.localizedDescription)")
                            return (item.id, nil, error.localizedDescription)
                        }
                    }
                }
                for await result in group {
                    retryResults.append(result)
                }
            }
            // 重试结果覆盖首轮:成功 → usage 写回(usageError 清空);仍失败 → 以重试 error 为准
            for (id, usage, error) in retryResults {
                if let idx = results.firstIndex(where: { $0.id == id }) {
                    results[idx] = (id: id, usage: usage, error: error)
                }
            }
        }

        // 回到主线程:按 id 重查下标统一写回(账号可能已被删除 → 重查失败静默跳过),
        // 全部写回后只 save() 一次,避免 N 次全量写盘
        for (id, usage, error) in results {
            guard let i = accounts.firstIndex(where: { $0.id == id }) else { continue }
            if let usage {
                accounts[i].usage = usage
                accounts[i].updatedAt = Date()
                accounts[i].usageError = nil
            } else if let error {
                accounts[i].usageError = error
            }
        }
        save()
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
