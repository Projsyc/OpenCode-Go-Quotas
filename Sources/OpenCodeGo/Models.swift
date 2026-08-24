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
/// 持久化范围:仅元数据 + usage 快照;usageError/history/historyError/historyLoading 仅内存
struct Account: Codable, Identifiable, Sendable, Equatable {
    var id: UUID
    var name: String
    var workspaceId: String
    var notes: String
    var createdAt: Date
    var updatedAt: Date

    /// 最后一次成功抓取的额度快照(持久化,非实时;便于离线查看)
    var usage: UsageResult?
    /// 最近一次刷新的错误(仅内存;CodingKeys 未列入,不参与 JSON 编解码)
    var usageError: String?
    /// 用量历史(仅内存;CodingKeys 未列入,不参与 JSON 编解码)
    var history: [UsageHistoryItem]?
    /// 用量历史加载错误(仅内存;CodingKeys 未列入,不参与 JSON 编解码)
    var historyError: String?
    /// 用量历史加载中(仅内存;CodingKeys 未列入,不参与 JSON 编解码)
    var historyLoading: Bool

    /// 只持久化元数据 + usage 快照;4 个 transient 字段不参与 encode,
    /// decode 时老 JSON 中残留的 transient 键被自动忽略(字段回到内存默认值)
    enum CodingKeys: String, CodingKey {
        case id, name, workspaceId, notes, createdAt, updatedAt, usage
    }

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

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        workspaceId = try c.decode(String.self, forKey: .workspaceId)
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        usage = try c.decodeIfPresent(UsageResult.self, forKey: .usage)
        // 仅内存字段:老格式 JSON 即使含这些键也忽略,一律回到默认值
        usageError = nil
        history = nil
        historyError = nil
        historyLoading = false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(workspaceId, forKey: .workspaceId)
        try c.encode(notes, forKey: .notes)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encodeIfPresent(usage, forKey: .usage)
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
