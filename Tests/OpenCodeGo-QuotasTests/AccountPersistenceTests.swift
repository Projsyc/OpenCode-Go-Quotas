import Foundation
import XCTest
@testable import OpenCode_Go_Quotas

// MARK: - 历史分页测试数据生成(结构与 opencode.ai 实际响应一致)

private enum HistoryPage {
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// 生成一页响应体:cursor 页的第 i 条记录 id 为 usg_p{cursor}i{i}(id 只含字母数字,
    /// 与 parseHistoryBody 的锚点正则 id:"usg_[A-Za-z0-9]+" 匹配),
    /// timeCreated 从 baseTime 起按 step 递增;dupID 非空时第 0 条改用该 id(去重测试用)
    static func body(cursor: Int, count: Int, baseTime: Date, step: TimeInterval, dupID: String? = nil) -> String {
        var lines: [String] = []
        for i in 0..<count {
            let id = (i == 0 && dupID != nil) ? dupID! : "usg_p\(cursor)i\(i)"
            let t = baseTime.addingTimeInterval(step * Double(i))
            lines.append(
                "const d\(cursor)_\(i) = { id:\"\(id)\", "
                + "timeCreated:new Date(\"\(iso.string(from: t))\"), "
                + "model:\"claude-opus-4-8\", provider:\"anthropic\", "
                + "inputTokens:\(100 + i), outputTokens:50, reasoningTokens:10, cacheReadTokens:0, "
                + "cacheWrite5mTokens:null, cacheWrite1hTokens:null, cost:0.001, "
                + "keyID:\"key_1\", sessionID:\"ses_1\", plan:\"OpenCode Go\" };")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - 非隔离小工具(供 URLProtocol handler 闭包直接调用,不依赖 MainActor)

private func okResponse(_ url: URL, body: String) -> (HTTPURLResponse, Data) {
    (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
}

/// 从 RPC 请求体里取出 cursor(页码索引):t.a[1].s
private func requestCursor(_ request: URLRequest) -> Int {
    let bodyData = request.httpBody ?? readBodyStream(request)
    guard let body = bodyData.flatMap({ try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any],
          let t = body["t"] as? [String: Any],
          let a = t["a"] as? [[String: Any]],
          a.count > 1,
          let c = a[1]["s"] as? Int
    else { return -1 }
    return c
}

private func readBodyStream(_ request: URLRequest) -> Data? {
    guard let stream = request.httpBodyStream else { return nil }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
        let n = stream.read(&buffer, maxLength: buffer.count)
        if n <= 0 { break }
        data.append(buffer, count: n)
    }
    return data
}

// MARK: - 测试

@MainActor
final class AccountPersistenceTests: XCTestCase {

    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    /// 独立临时目录 + 内存 keychain + mock client 的 store(每个测试独立,不碰真实存储)
    private func makeTempStore() -> (store: AccountStore, keychain: InMemoryKeychain, fileURL: URL, dir: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AccountPersistenceTests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent("accounts.json")
        let keychain = InMemoryKeychain()
        let store = AccountStore(client: makeClient(), keychain: keychain, fileURL: fileURL)
        return (store, keychain, fileURL, dir)
    }

    // MARK: - ① transient 字段不持久化

    func testEncodeAccountExcludesTransientFields() throws {
        let usage = UsageResult(
            rolling: UsageWindow(usagePercent: 12.5, resetInSec: 3600),
            weekly: nil, monthly: nil, plan: "OpenCode Go", fetchedAt: Date())
        let item = UsageHistoryItem(
            id: "usg_abc", timeCreated: Date(), model: "m", provider: "p",
            inputTokens: 1, outputTokens: 2, reasoningTokens: 0, cacheReadTokens: 0,
            cacheWrite5mTokens: nil, cacheWrite1hTokens: nil,
            cost: 0.01, keyID: "k", sessionID: "s", plan: nil)
        let account = Account(
            name: "测试", workspaceId: "wrk_test123", notes: "备注",
            usage: usage, usageError: "旧错误", history: [item], historyError: "旧历史错误", historyLoading: true)

        let data = try JSONEncoder().encode(account)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        // 只含持久化字段
        XCTAssertEqual(
            Set(obj.keys),
            Set(["id", "name", "workspaceId", "notes", "createdAt", "updatedAt", "usage"]))
        // 4 个 transient 字段一律不落 JSON
        XCTAssertNil(obj["history"])
        XCTAssertNil(obj["usageError"])
        XCTAssertNil(obj["historyError"])
        XCTAssertNil(obj["historyLoading"])
        // 持久化字段值保留
        XCTAssertEqual(obj["name"] as? String, "测试")
        XCTAssertEqual(obj["workspaceId"] as? String, "wrk_test123")
        let usageObj = try XCTUnwrap(obj["usage"] as? [String: Any])
        XCTAssertEqual((usageObj["rolling"] as? [String: Any])?["usagePercent"] as? Double, 12.5)
    }

    /// 老格式 accounts.json(含 transient 键)必须照常解码,transient 字段回到默认值
    func testDecodeLegacyJSONWithTransientKeys() throws {
        let legacy = """
        {
          "id": "3B2507B9-8C4A-4A2E-9F0D-1A2B3C4D5E6F",
          "name": "旧账号",
          "workspaceId": "wrk_legacy1",
          "notes": "旧备注",
          "createdAt": 799000000.0,
          "updatedAt": 799000100.0,
          "usage": {
            "rolling": {"usagePercent": 12.5, "resetInSec": 3600},
            "weekly": {"usagePercent": 34, "resetInSec": 7200},
            "plan": "OpenCode Go",
            "fetchedAt": 799000200.0
          },
          "usageError": "旧错误文本",
          "history": [
            {"id": "usg_old1", "timeCreated": 799000000.0, "model": "m", "provider": "p",
             "inputTokens": 1, "outputTokens": 2, "reasoningTokens": 0, "cacheReadTokens": 0,
             "cacheWrite5mTokens": null, "cacheWrite1hTokens": null,
             "cost": 0.01, "keyID": "k", "sessionID": "s", "plan": null}
          ],
          "historyError": "旧历史错误",
          "historyLoading": true
        }
        """

        let account = try JSONDecoder().decode(Account.self, from: Data(legacy.utf8))

        // 元数据 + usage 照常解码
        XCTAssertEqual(account.id.uuidString, "3B2507B9-8C4A-4A2E-9F0D-1A2B3C4D5E6F")
        XCTAssertEqual(account.name, "旧账号")
        XCTAssertEqual(account.workspaceId, "wrk_legacy1")
        XCTAssertEqual(account.notes, "旧备注")
        XCTAssertEqual(account.createdAt, Date(timeIntervalSinceReferenceDate: 799_000_000))
        XCTAssertEqual(account.updatedAt, Date(timeIntervalSinceReferenceDate: 799_000_100))
        XCTAssertEqual(account.usage?.rolling?.usagePercent, 12.5)
        XCTAssertEqual(account.usage?.weekly?.usagePercent, 34)
        XCTAssertEqual(account.usage?.plan, "OpenCode Go")
        XCTAssertEqual(account.usage?.fetchedAt, Date(timeIntervalSinceReferenceDate: 799_000_200))
        // transient 键被忽略 → 内存默认值
        XCTAssertNil(account.usageError)
        XCTAssertNil(account.history)
        XCTAssertNil(account.historyError)
        XCTAssertFalse(account.historyLoading)
    }

    func testAccountEncodeDecodeRoundTrip() throws {
        let usage = UsageResult(
            rolling: UsageWindow(usagePercent: 66.6, resetInSec: 86400),
            weekly: nil, monthly: UsageWindow(usagePercent: 3.3, resetInSec: 2_592_000),
            plan: "OpenCode Go", fetchedAt: Date(timeIntervalSinceReferenceDate: 800_000_000))
        let account = Account(
            id: UUID(), name: "往返", workspaceId: "wrk_roundtrip",
            notes: "备注", createdAt: Date(timeIntervalSinceReferenceDate: 799_000_000),
            updatedAt: Date(timeIntervalSinceReferenceDate: 799_000_100), usage: usage)

        let data = try JSONEncoder().encode(account)
        let decoded = try JSONDecoder().decode(Account.self, from: data)
        XCTAssertEqual(decoded, account)
    }

    /// 完整回归:save() 时内存里已有 history/usageError,写盘文件仍不得含 transient 键;
    /// 重载后 transient 字段回到默认值,usage 快照保留
    func testStoreSaveOmitsTransientFieldsAndReloadIsClean() async throws {
        let t = makeTempStore()
        addTeardownBlock { try? FileManager.default.removeItem(at: t.dir) }
        _ = try t.store.addAccount(
            name: "测试账号", workspaceId: validWorkspace, authCookie: validCookie, notes: "")

        let base = Date(timeIntervalSinceReferenceDate: 800_000_000)

        // 1) 加载历史(仅内存)→ 内存里 history = 2 条
        MockURLProtocol.handler = { request in
            let body = requestCursor(request) == 0
                ? HistoryPage.body(cursor: 0, count: 2, baseTime: base, step: 3600)
                : "no more"
            return okResponse(request.url!, body: body)
        }
        await t.store.loadHistory(t.store.accounts[0])
        XCTAssertEqual(t.store.accounts[0].history?.count, 2)

        // 2) 刷新失败 → usageError 置入内存并 save(此时 history 也在内存)
        MockURLProtocol.handler = { request in
            (HTTPURLResponse(
                url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
        }
        await t.store.refresh(t.store.accounts[0])
        XCTAssertEqual(t.store.accounts[0].usageError, "请求失败 (HTTP 500)")

        // 3) 刷新成功 → usage 快照置入内存并再次 save(history/usageError 仍可能在内存)
        MockURLProtocol.handler = { request in
            okResponse(request.url!, body: quotaHTML)
        }
        await t.store.refresh(t.store.accounts[0])
        XCTAssertNil(t.store.accounts[0].usageError)

        // 校验文件:即便内存态带 history/usageError,JSON 也不得含 transient 键
        let json = String(decoding: try Data(contentsOf: t.fileURL), as: UTF8.self)
        XCTAssertFalse(json.contains("\"history\""))
        XCTAssertFalse(json.contains("\"usageError\""))
        XCTAssertFalse(json.contains("\"historyError\""))
        XCTAssertFalse(json.contains("\"historyLoading\""))
        XCTAssertTrue(json.contains("\"usage\""))
        XCTAssertTrue(json.contains("\"workspaceId\""))

        // 重载:transient 字段回到默认值,usage 快照保留
        let store2 = AccountStore(client: makeClient(), keychain: t.keychain, fileURL: t.fileURL)
        XCTAssertEqual(store2.accounts.count, 1)
        let loaded = store2.accounts[0]
        XCTAssertEqual(loaded.name, "测试账号")
        XCTAssertNil(loaded.history)
        XCTAssertNil(loaded.usageError)
        XCTAssertNil(loaded.historyError)
        XCTAssertFalse(loaded.historyLoading)
        XCTAssertEqual(loaded.usage?.rolling?.usagePercent ?? -1, 34.567, accuracy: 0.0001)
    }

    // MARK: - ② 用量历史分页

    /// 3 整页 × 25 条 + 第 4 页为空:合并 75 条、去掉 1 条跨页重复 → 74 条,整体按时间降序
    func testLoadHistoryMergesDedupesSortsAcrossPages() async throws {
        let t = makeTempStore()
        addTeardownBlock { try? FileManager.default.removeItem(at: t.dir) }
        _ = try t.store.addAccount(name: "分页", workspaceId: validWorkspace, authCookie: validCookie, notes: "")

        let base = Date(timeIntervalSinceReferenceDate: 800_000_000)
        var cursors: [Int] = []
        MockURLProtocol.handler = { request in
            let cursor = requestCursor(request)
            cursors.append(cursor)
            if cursor >= 3 { return okResponse(request.url!, body: "no more") } // 服务端已到底
            let dup = cursor == 2 ? "usg_p0i5" : nil // 第 3 页第 0 条与第 1 页第 5 条重复
            let body = HistoryPage.body(
                cursor: cursor, count: 25,
                baseTime: base.addingTimeInterval(Double(cursor) * 25 * 3600), step: 3600, dupID: dup)
            return okResponse(request.url!, body: body)
        }

        await t.store.loadHistory(t.store.accounts[0])
        let history = try XCTUnwrap(t.store.accounts[0].history)

        XCTAssertEqual(history.count, 74) // 75 - 1 重复
        XCTAssertEqual(Set(history.map(\.id)).count, 74) // 按 id 去重
        let times = history.map(\.timeCreated)
        XCTAssertEqual(times, times.sorted(by: >)) // 整体降序
        XCTAssertEqual(history.first?.id, "usg_p2i24") // 时间最大(最后页末条)
        XCTAssertEqual(history.last?.id, "usg_p0i0")   // 时间最小(首页首条)
        XCTAssertEqual(cursors, [0, 1, 2, 3])          // 逐页递增,空页后终止
        XCTAssertNil(t.store.accounts[0].historyError)
    }

    /// 短页(< 单页窗口)提前终止:25 + 10 → 35 条,不再发第 3 个请求
    func testLoadHistoryShortPageStopsEarly() async throws {
        let t = makeTempStore()
        addTeardownBlock { try? FileManager.default.removeItem(at: t.dir) }
        _ = try t.store.addAccount(name: "短页", workspaceId: validWorkspace, authCookie: validCookie, notes: "")

        let base = Date(timeIntervalSinceReferenceDate: 800_000_000)
        var cursors: [Int] = []
        MockURLProtocol.handler = { request in
            let cursor = requestCursor(request)
            cursors.append(cursor)
            let count = cursor == 0 ? 25 : 10 // 第 2 页只有 10 条 < 窗口 25
            let body = cursor <= 1
                ? HistoryPage.body(cursor: cursor, count: count, baseTime: base, step: 3600)
                : "no more"
            return okResponse(request.url!, body: body)
        }

        await t.store.loadHistory(t.store.accounts[0])
        let history = try XCTUnwrap(t.store.accounts[0].history)
        XCTAssertEqual(history.count, 35) // 25 + 短页 10,短页记录并入结果
        XCTAssertEqual(cursors, [0, 1]) // 短页终止,无第 3 个请求
        XCTAssertNil(t.store.accounts[0].historyError)
    }

    /// 翻页空响应是正常终点:首页有数据、第二页为空 → 返回首页数据且不报错
    func testLoadHistoryLaterEmptyPageTerminatesGracefully() async throws {
        let t = makeTempStore()
        addTeardownBlock { try? FileManager.default.removeItem(at: t.dir) }
        _ = try t.store.addAccount(name: "空尾页", workspaceId: validWorkspace, authCookie: validCookie, notes: "")

        let base = Date(timeIntervalSinceReferenceDate: 800_000_000)
        var cursors: [Int] = []
        MockURLProtocol.handler = { request in
            let cursor = requestCursor(request)
            cursors.append(cursor)
            let body = cursor == 0
                ? HistoryPage.body(cursor: 0, count: 25, baseTime: base, step: 3600)
                : ""
            return okResponse(request.url!, body: body)
        }

        await t.store.loadHistory(t.store.accounts[0])
        XCTAssertEqual(t.store.accounts[0].history?.count, 25)
        XCTAssertNil(t.store.accounts[0].historyError)
        XCTAssertEqual(cursors, [0, 1], "空页后不得继续请求")
    }

    /// 首页空响应仍视为解析故障：页面结构变化不能被误判为“没有历史记录”
    func testLoadHistoryFirstEmptyPageReportsParseFailure() async throws {
        let t = makeTempStore()
        addTeardownBlock { try? FileManager.default.removeItem(at: t.dir) }
        _ = try t.store.addAccount(name: "结构变化", workspaceId: validWorkspace, authCookie: validCookie, notes: "")

        var requests = 0
        MockURLProtocol.handler = { request in
            requests += 1
            return okResponse(request.url!, body: "")
        }

        await t.store.loadHistory(t.store.accounts[0])
        XCTAssertNil(t.store.accounts[0].history)
        XCTAssertEqual(t.store.accounts[0].historyError, "未能解析到使用历史，OpenCode 接口结构可能已变更")
        XCTAssertEqual(requests, 1)
    }

    /// 首页非空但无记录锚点 → 显式解析失败，避免结构变化被误判为“没有历史”
    func testLoadHistoryFirstNonRecordPageReportsParseFailure() async throws {
        let t = makeTempStore()
        addTeardownBlock { try? FileManager.default.removeItem(at: t.dir) }
        _ = try t.store.addAccount(name: "空历史", workspaceId: validWorkspace, authCookie: validCookie, notes: "")

        var requests = 0
        MockURLProtocol.handler = { request in
            requests += 1
            return okResponse(request.url!, body: "no records here")
        }

        await t.store.loadHistory(t.store.accounts[0])
        XCTAssertNil(t.store.accounts[0].history)
        XCTAssertEqual(t.store.accounts[0].historyError, "未能解析到使用历史，OpenCode 接口结构可能已变更")
        XCTAssertEqual(requests, 1)
    }

    /// 非「已到底」的真实失败(第 2 页 401)→ 抛错置 historyError,不吞错
    func testLoadHistoryRealFailureSetsHistoryError() async throws {
        let t = makeTempStore()
        addTeardownBlock { try? FileManager.default.removeItem(at: t.dir) }
        _ = try t.store.addAccount(name: "失败", workspaceId: validWorkspace, authCookie: validCookie, notes: "")

        let base = Date(timeIntervalSinceReferenceDate: 800_000_000)
        MockURLProtocol.handler = { request in
            if requestCursor(request) == 0 {
                return okResponse(request.url!, body: HistoryPage.body(
                    cursor: 0, count: 25, baseTime: base, step: 3600))
            }
            return (HTTPURLResponse(
                url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!, Data())
        }

        await t.store.loadHistory(t.store.accounts[0])
        XCTAssertNil(t.store.accounts[0].history)
        XCTAssertEqual(t.store.accounts[0].historyError, "认证失败，Cookie 可能已过期")
    }

    /// 页数上限截断:maxPages = 2 时只拉 2 页,不发第 3 个请求
    func testFetchAllHistoryPagesTruncatesAtMaxPages() async throws {
        let base = Date(timeIntervalSinceReferenceDate: 800_000_000)
        var requests = 0
        var page = 0
        MockURLProtocol.handler = { request in
            requests += 1
            defer { page += 1 }
            return okResponse(request.url!, body: HistoryPage.body(
                cursor: page, count: 25,
                baseTime: base.addingTimeInterval(Double(page) * 25 * 3600), step: 3600))
        }

        let items = try await AccountStore.fetchAllHistoryPages(
            client: makeClient(), workspaceId: validWorkspace, authCookie: validCookie, maxPages: 2)

        XCTAssertEqual(items.count, 50) // 2 整页
        XCTAssertEqual(requests, 2)     // 上限截断,无第 3 个请求
    }
}
