import Foundation

/// 单个额度窗口(rolling / weekly / monthly)
struct UsageWindow: Codable, Sendable, Equatable {
    var usagePercent: Double
    var resetInSec: Double
}

/// 一次额度查询的结果
struct UsageResult: Codable, Sendable, Equatable {
    var rolling: UsageWindow?
    var weekly: UsageWindow?
    var monthly: UsageWindow?
    var plan: String?
    var fetchedAt: Date
}

/// 账号:元数据 + 最后一次额度快照(快照便于离线查看,数据本身可能过期)
struct Account: Codable, Identifiable, Sendable, Equatable {
    var id: UUID
    var name: String
    var workspaceId: String
    var notes: String
    var createdAt: Date
    var updatedAt: Date

    /// 最后一次成功抓取的额度(持久化,非实时)
    var usage: UsageResult?
    /// 最近一次刷新的错误(仅内存,不持久化)
    var usageError: String?
    /// 用量历史(仅内存,不持久化)
    var history: [UsageHistoryItem]?
    var historyError: String?
    var historyLoading: Bool

    init(
        id: UUID = UUID(),
        name: String,
        workspaceId: String,
        notes: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        usage: UsageResult? = nil,
        usageError: String? = nil,
        history: [UsageHistoryItem]? = nil,
        historyError: String? = nil,
        historyLoading: Bool = false
    ) {
        self.id = id
        self.name = name
        self.workspaceId = workspaceId
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.usage = usage
        self.usageError = usageError
        self.history = history
        self.historyError = historyError
        self.historyLoading = historyLoading
    }
}

/// 用量历史单条记录(来自 /_server 的 Usage 页面数据)
struct UsageHistoryItem: Codable, Sendable, Identifiable, Equatable {
    var id: String // usg_xxx
    var timeCreated: Date
    var model: String
    var provider: String
    var inputTokens: Int
    var outputTokens: Int
    var reasoningTokens: Int
    var cacheReadTokens: Int
    var cacheWrite5mTokens: Int?
    var cacheWrite1hTokens: Int?
    var cost: Double
    var keyID: String
    var sessionID: String
    var plan: String?

    var totalTokens: Int {
        inputTokens + outputTokens + reasoningTokens + cacheReadTokens
            + (cacheWrite5mTokens ?? 0) + (cacheWrite1hTokens ?? 0)
    }
}

/// GitHub 账号凭据类型:一次性验证码 或 TOTP secret
enum GitHubCredentialKind: String, Codable, Sendable, Equatable {
    case oneTimeCode
    case totpSecret
}

/// GitHub 账号元数据(密码/secret 一律不在本结构,存 Keychain)
struct GitHubAccount: Codable, Identifiable, Sendable, Equatable {
    var id: UUID
    var username: String
    var notes: String
    var createdAt: Date
    var updatedAt: Date
    var credentialKind: GitHubCredentialKind?   // nil = 只有密码
    var lastCodeAt: Date?                       // 最近一次生成/导入验证码的时间(UI 倒计时用)

    init(
        id: UUID = UUID(),
        username: String,
        notes: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        credentialKind: GitHubCredentialKind? = nil,
        lastCodeAt: Date? = nil
    ) {
        self.id = id
        self.username = username
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.credentialKind = credentialKind
        self.lastCodeAt = lastCodeAt
    }
}
