import Foundation

// MARK: - 错误类型(与原项目错误文案一致)

enum QuotaError: LocalizedError {
    case invalidWorkspaceId(String)
    case invalidAuthCookie(String)
    case authFailed            // 401 / 403
    case sessionExpired        // 被重定向到登录页,或响应体包含 /sign-in
    case httpError(Int)
    case endpointGone          // /_server 返回 404
    case parseFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidWorkspaceId(let m): return m
        case .invalidAuthCookie(let m): return m
        case .authFailed: return "认证失败，Cookie 可能已过期"
        case .sessionExpired: return "会话已过期，请重新登录并更新 Cookie"
        case .httpError(let c): return "请求失败 (HTTP \(c))"
        case .endpointGone: return "RPC 端点不可达 (HTTP 404)，OpenCode 服务接口可能已变更"
        case .parseFailed(let m): return m
        }
    }
}

// MARK: - 正则辅助

private enum RX {
    /// 首个匹配并取第 group 个捕获组;失败返回 nil
    static func capture(_ pattern: String, group: Int = 1, in s: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              match.numberOfRanges > group
        else { return nil }
        let range = match.range(at: group)
        guard range.location != NSNotFound, let r = Range(range, in: s) else { return nil }
        return String(s[r])
    }

    /// 所有匹配的 range 列表(UTF-16 坐标,与 JS matchAll 的 index 语义一致)
    static func allRanges(_ pattern: String, in s: String) -> [NSRange] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: s, range: NSRange(s.startIndex..., in: s)).map(\.range)
    }
}

// MARK: - OpenCode Go 额度客户端

/// 1:1 移植自 Ruinique/opencode-go-dashboard 的 src/worker/quota.ts
struct QuotaClient: Sendable {
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:148.0) Gecko/20100101 Firefox/148.0"

    // 校验规则(与原项目一致)
    static let workspaceIDRegex: NSRegularExpression =
        try! NSRegularExpression(pattern: #"^wrk_[a-zA-Z0-9]+$"#)
    static let cookiePrefix = "Fe26."

    static func validateWorkspaceId(_ workspaceId: String) -> String? {
        let ws = workspaceId.trimmingCharacters(in: .whitespacesAndNewlines)
        if ws.isEmpty { return "Workspace ID 不能为空" }
        if Self.workspaceIDRegex.firstMatch(
            in: ws, range: NSRange(ws.startIndex..., in: ws)) == nil {
            return "Workspace ID 格式无效（应为 wrk_xxx）"
        }
        return nil
    }

    static func validateAuthCookie(_ cookie: String) -> String? {
        let c = cookie.trimmingCharacters(in: .whitespacesAndNewlines)
        if c.isEmpty { return "Auth Cookie 不能为空" }
        if !c.hasPrefix(cookiePrefix) { return "Auth Cookie 格式无效（应以 Fe26. 开头）" }
        return nil
    }

    // MARK: - 额度查询

    /// 抓取 opencode.ai/workspace/{ws}/go 页面并解析滚动/周/月三个额度窗口与套餐名
    func fetchGoQuota(workspaceId: String, authCookie: String) async throws -> UsageResult {
        let ws = workspaceId.trimmingCharacters(in: .whitespacesAndNewlines)
        let cookie = authCookie.trimmingCharacters(in: .whitespacesAndNewlines)
        if let e = Self.validateWorkspaceId(ws) { throw QuotaError.invalidWorkspaceId(e) }
        if let e = Self.validateAuthCookie(cookie) { throw QuotaError.invalidAuthCookie(e) }

        let encoded = ws.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? ws
        let url = URL(string: "https://opencode.ai/workspace/\(encoded)/go")!

        var req = URLRequest(url: url)
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(
            "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            forHTTPHeaderField: "Accept")
        req.setValue("auth=\(cookie)", forHTTPHeaderField: "Cookie")

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw QuotaError.httpError(-1) }

        if http.statusCode == 401 || http.statusCode == 403 {
            throw QuotaError.authFailed
        }
        guard (200..<300).contains(http.statusCode) else {
            throw QuotaError.httpError(http.statusCode)
        }

        // 重定向到登录页 = 会话失效
        if let finalURL = http.url?.absoluteString,
           finalURL.contains("/sign-in") || finalURL.contains("/login") {
            throw QuotaError.sessionExpired
        }

        let html = String(data: data, encoding: .utf8) ?? ""
        if html.contains("/sign-in") && !html.contains("rollingUsage") {
            throw QuotaError.sessionExpired
        }

        var result = UsageResult(rolling: nil, weekly: nil, monthly: nil, plan: nil, fetchedAt: Date())

        if let raw = RX.capture(#"rollingUsage:\$R\[\d+\]=(\{[^}]+\})"#, in: html) {
            result.rolling = Self.parseUsageObject(raw)
        }
        if let raw = RX.capture(#"weeklyUsage:\$R\[\d+\]=(\{[^}]+\})"#, in: html) {
            result.weekly = Self.parseUsageObject(raw)
        }
        if let raw = RX.capture(#"monthlyUsage:\$R\[\d+\]=(\{[^}]+\})"#, in: html) {
            result.monthly = Self.parseUsageObject(raw)
        }
        if let plan = RX.capture(#"plan:\$R\[\d+\]="([^"]+)""#, in: html) {
            result.plan = plan
        }

        if result.rolling == nil && result.weekly == nil && result.monthly == nil {
            throw QuotaError.parseFailed("无法从页面解析额度数据，OpenCode 页面结构可能已变更")
        }
        return result
    }

    /// 解析 JS 对象字面量 {usagePercent:34.5,resetInSec:123} → UsageWindow
    static func parseUsageObject(_ raw: String) -> UsageWindow? {
        // 给未加引号的键补引号,使其成为合法 JSON
        guard let fixup = try? NSRegularExpression(
            pattern: #"([{,]\s*)([a-zA-Z_][a-zA-Z0-9_]*)(\s*:)"#
        ).stringByReplacingMatches(
            in: raw, range: NSRange(raw.startIndex..., in: raw), withTemplate: #"$1"$2"$3"#),
            let data = fixup.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let usagePercent = obj["usagePercent"] as? Double,
            let resetInSec = obj["resetInSec"] as? Double
        else { return nil }
        return UsageWindow(usagePercent: usagePercent, resetInSec: resetInSec)
    }

    // MARK: - 用量历史

    /// 调用 opencode.ai/_server RPC 抓取 Usage 页面数据,解析出逐请求用量记录
    func fetchGoUsageHistory(
        workspaceId: String,
        authCookie: String,
        cursor: Int = 0
    ) async throws -> [UsageHistoryItem] {
        let ws = workspaceId.trimmingCharacters(in: .whitespacesAndNewlines)
        let cookie = authCookie.trimmingCharacters(in: .whitespacesAndNewlines)
        if let e = Self.validateWorkspaceId(ws) { throw QuotaError.invalidWorkspaceId(e) }
        if let e = Self.validateAuthCookie(cookie) { throw QuotaError.invalidAuthCookie(e) }

        let payload: [String: Any] = [
            "t": [
                "t": 9, "i": 0, "l": 2,
                "a": [["t": 1, "s": ws], ["t": 0, "s": cursor]],
                "o": 0,
            ],
            "f": 31,
            "m": [],
        ]

        var req = URLRequest(url: URL(string: "https://opencode.ai/_server")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("*/*", forHTTPHeaderField: "Accept")
        req.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        req.setValue("auth=\(cookie)", forHTTPHeaderField: "Cookie")
        req.setValue("https://opencode.ai", forHTTPHeaderField: "Origin")
        req.setValue("https://opencode.ai/workspace/\(ws)/usage", forHTTPHeaderField: "Referer")
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("server-fn:2", forHTTPHeaderField: "x-server-instance")
        req.setValue(
            "bfd684bfc2e4eed05cd0b518f5e4eafd3f3376e3938abb9e536e7c03df831e5c",
            forHTTPHeaderField: "x-server-id")
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw QuotaError.httpError(-1) }

        if http.statusCode == 401 || http.statusCode == 403 {
            throw QuotaError.authFailed
        }
        if http.statusCode == 404 { throw QuotaError.endpointGone }
        guard (200..<300).contains(http.statusCode) else {
            throw QuotaError.httpError(http.statusCode)
        }

        let body = String(data: data, encoding: .utf8) ?? ""
        if body.contains("/sign-in") && !body.contains("usg_") {
            throw QuotaError.sessionExpired
        }

        let items = Self.parseHistoryBody(body)
        if items.isEmpty {
            throw QuotaError.parseFailed("未能解析到使用历史，OpenCode 接口结构可能已变更")
        }
        return items.sorted { $0.timeCreated > $1.timeCreated }
    }

    /// 响应体是 SolidStart 序列化数据:每条记录以 id:"usg_xxx" 为锚点切块,逐字段正则提取
    static func parseHistoryBody(_ body: String) -> [UsageHistoryItem] {
        let anchorPattern = #"id:\s*"usg_[A-Za-z0-9]+""#
        let anchors = RX.allRanges(anchorPattern, in: body)
        guard !anchors.isEmpty else { return [] }

        var items: [UsageHistoryItem] = []
        for (i, anchor) in anchors.enumerated() {
            let start = anchor.location
            let boundary = i + 1 < anchors.count ? anchors[i + 1].location : body.utf16.count
            let recordEnd = min(boundary, start + 4000) // 单条记录扫描上限
            guard recordEnd > start,
                  let r = Range(NSRange(location: start, length: recordEnd - start), in: body)
            else { continue }
            let slice = String(body[r])

            guard let idRaw = RX.capture(#"id:\s*"usg_([A-Za-z0-9]+)""#, in: slice) else { continue }

            let timeCreated = Self.historyTimeCreated(in: slice) ?? Date.distantPast
            let model = RX.capture(#"model:\s*"([^"]*)""#, in: slice) ?? ""
            let provider = RX.capture(#"provider:\s*"([^"]*)""#, in: slice) ?? ""
            let inputTokens = Self.historyInt("inputTokens", in: slice)
            let outputTokens = Self.historyInt("outputTokens", in: slice)
            let reasoningTokens = Self.historyInt("reasoningTokens", in: slice)
            let cacheReadTokens = Self.historyInt("cacheReadTokens", in: slice)
            let cost = Self.historyDouble("cost", in: slice)
            let keyID = RX.capture(#"keyID:\s*"([^"]*)""#, in: slice) ?? ""
            let sessionID = RX.capture(#"sessionID:\s*"([^"]*)""#, in: slice) ?? ""
            let plan = RX.capture(#"plan:\s*"([^"]*)""#, in: slice)

            items.append(UsageHistoryItem(
                id: "usg_\(idRaw)",
                timeCreated: timeCreated,
                model: model,
                provider: provider,
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                reasoningTokens: reasoningTokens,
                cacheReadTokens: cacheReadTokens,
                cacheWrite5mTokens: Self.historyNullableInt("cacheWrite5mTokens", in: slice),
                cacheWrite1hTokens: Self.historyNullableInt("cacheWrite1hTokens", in: slice),
                cost: cost,
                keyID: keyID,
                sessionID: sessionID,
                plan: plan))
        }
        return items
    }

    /// timeCreated:\s*(?:$R[N]=)?new Date("...")
    private static func historyTimeCreated(in slice: String) -> Date? {
        guard let raw = RX.capture(
            #"timeCreated:\s*(?:\$R\[\s*\d+\s*\]\s*=\s*)?new Date\("([^"]+)"\)"#, in: slice)
        else { return nil }
        return Self.parseDate(raw)
    }

    private static func historyInt(_ key: String, in slice: String) -> Int {
        RX.capture("\(key):\\s*(\\d+)", in: slice).flatMap(Int.init) ?? 0
    }

    private static func historyNullableInt(_ key: String, in slice: String) -> Int? {
        guard let raw = RX.capture("\(key):\\s*(\\d+|null)", in: slice), raw != "null" else {
            return nil
        }
        return Int(raw)
    }

    private static func historyDouble(_ key: String, in slice: String) -> Double {
        RX.capture("\(key):\\s*(\\d+(?:\\.\\d+)?)", in: slice).flatMap(Double.init) ?? 0
    }

    private static func parseDate(_ s: String) -> Date? {
        // 先试带毫秒的 ISO8601,再试不带毫秒的
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = fractional.date(from: s) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: s)
    }
}
