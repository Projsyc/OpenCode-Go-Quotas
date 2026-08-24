import Foundation
import XCTest
@testable import OpenCodeGo

// MARK: - Mock URLProtocol

final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (URLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

func makeClient() -> QuotaClient {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    return QuotaClient(session: URLSession(configuration: config))
}

// MARK: - 测试数据(结构与 opencode.ai 实际响应一致)

/// 额度页 HTML:内嵌 SolidStart 序列化的 rollingUsage/weeklyUsage/monthlyUsage/plan
let quotaHTML = """
<!doctype html>
<html><head><script>
const rollingUsage:$R[13]={usagePercent:34.567,resetInSec:12345};
const weeklyUsage:$R[14]={usagePercent:72.1,resetInSec:432100};
const monthlyUsage:$R[15]={usagePercent:89.9,resetInSec:1209600};
const plan:$R[16]="OpenCode Go Pro";
</script></head>
<body><div>dashboard</div></body></html>
"""

/// 用量历史响应体:SolidStart 序列化,每条记录以 id:"usg_xxx" 为锚。
/// cost 为平台 ×10⁸ 定点原始值(1230000 × 10⁻⁸ = $0.0123,4500000 × 10⁻⁸ = $0.045),
/// 解析层缩放后即美元。
let historyBody = """
{"$SNIPPET":"usage list"}
const data1 = { id:"usg_AbCd123", timeCreated:new Date("2026-08-20T10:00:00.000Z"), model:"claude-opus-4-8", provider:"anthropic", inputTokens:1200, outputTokens:500, reasoningTokens:200, cacheReadTokens:300, cacheWrite5mTokens:null, cacheWrite1hTokens:50, cost:1230000, keyID:"key_1", sessionID:"ses_1", plan:"OpenCode Go Pro" };
const data2 = { id:"usg_EfGh456", timeCreated:$R[3]=new Date("2026-08-21T08:30:00.000Z"), model:"gemini-2.5-pro", provider:"google", inputTokens:900, outputTokens:600, reasoningTokens:100, cacheReadTokens:0, cacheWrite5mTokens:75, cacheWrite1hTokens:null, cost:4500000, keyID:"key_2", sessionID:"ses_2", plan:null };
"""

let validWorkspace = "wrk_test123"
let validCookie = "Fe26.2**abc"

// MARK: - 测试

final class QuotaClientTests: XCTestCase {

    override func tearDown() {
        MockURLProtocol.handler = nil
        super.tearDown()
    }

    // MARK: 额度解析

    func testFetchGoQuotaParsesAllWindowsAndPlan() async throws {
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/workspace/\(validWorkspace)/go")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertTrue(request.value(forHTTPHeaderField: "Cookie")?.hasPrefix("auth=") ?? false)
            return (HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(quotaHTML.utf8))
        }

        let result = try await makeClient().fetchGoQuota(
            workspaceId: validWorkspace, authCookie: validCookie)

        XCTAssertEqual(result.rolling?.usagePercent ?? -1, 34.567, accuracy: 0.0001)
        XCTAssertEqual(result.rolling?.resetInSec ?? -1, 12345, accuracy: 0.0001)
        XCTAssertEqual(result.weekly?.usagePercent ?? -1, 72.1, accuracy: 0.0001)
        XCTAssertEqual(result.weekly?.resetInSec ?? -1, 432100, accuracy: 0.0001)
        XCTAssertEqual(result.monthly?.usagePercent ?? -1, 89.9, accuracy: 0.0001)
        XCTAssertEqual(result.monthly?.resetInSec ?? -1, 1209600, accuracy: 0.0001)
        XCTAssertEqual(result.plan, "OpenCode Go Pro")
    }

    func testFetchGoQuotaHandlesIntegerPercentValues() async throws {
        MockURLProtocol.handler = { request in
            let html = """
            <script>rollingUsage:$R[1]={usagePercent:0,resetInSec:3600};</script>
            """
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(html.utf8))
        }
        let result = try await makeClient().fetchGoQuota(
            workspaceId: validWorkspace, authCookie: validCookie)
        XCTAssertEqual(result.rolling?.usagePercent, 0)
        XCTAssertEqual(result.rolling?.resetInSec, 3600)
        XCTAssertNil(result.weekly)
        XCTAssertNil(result.monthly)
    }

    func testFetchGoQuota401ThrowsAuthFailed() async {
        MockURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!,
             Data())
        }
        do {
            _ = try await makeClient().fetchGoQuota(workspaceId: validWorkspace, authCookie: validCookie)
            XCTFail("应当抛出错误")
        } catch let e as QuotaError {
            guard case .authFailed = e else { return XCTFail("期望 authFailed,实际 \(e)") }
        } catch {
            XCTFail("意外错误类型 \(error)")
        }
    }

    func testFetchGoQuotaRedirectToSignInThrowsSessionExpired() async {
        MockURLProtocol.handler = { request in
            (HTTPURLResponse(
                url: URL(string: "https://opencode.ai/sign-in")!,
                statusCode: 200, httpVersion: nil, headerFields: nil)!,
             Data("<html>sign in</html>".utf8))
        }
        do {
            _ = try await makeClient().fetchGoQuota(workspaceId: validWorkspace, authCookie: validCookie)
            XCTFail("应当抛出错误")
        } catch let e as QuotaError {
            guard case .sessionExpired = e else { return XCTFail("期望 sessionExpired,实际 \(e)") }
        } catch {
            XCTFail("意外错误类型 \(error)")
        }
    }

    func testFetchGoQuotaUnparseableThrowsParseFailed() async {
        MockURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             Data("<html><body>oops</body></html>".utf8))
        }
        do {
            _ = try await makeClient().fetchGoQuota(workspaceId: validWorkspace, authCookie: validCookie)
            XCTFail("应当抛出错误")
        } catch let e as QuotaError {
            guard case .parseFailed = e else { return XCTFail("期望 parseFailed,实际 \(e)") }
        } catch {
            XCTFail("意外错误类型 \(error)")
        }
    }

    func testFetchGoQuotaNonHTTPResponseThrowsHttpError() async {
        // 非 HTTP 响应不应触发强制转换崩溃,而是转为 httpError(-1)
        MockURLProtocol.handler = { request in
            (URLResponse(url: request.url!, mimeType: nil, expectedContentLength: 0, textEncodingName: nil),
             Data(quotaHTML.utf8))
        }
        do {
            _ = try await makeClient().fetchGoQuota(workspaceId: validWorkspace, authCookie: validCookie)
            XCTFail("应当抛出错误")
        } catch let e as QuotaError {
            guard case .httpError(-1) = e else { return XCTFail("期望 httpError(-1),实际 \(e)") }
        } catch {
            XCTFail("意外错误类型 \(error)")
        }
    }

    // MARK: 用量历史

    func testFetchGoUsageHistoryParsesRecordsAndSortsDesc() async throws {
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/_server")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertNotNil(request.value(forHTTPHeaderField: "x-server-instance"))
            XCTAssertNotNil(request.value(forHTTPHeaderField: "x-server-id"))
            // URLProtocol 拦截时 body 可能被挪到 httpBodyStream,两者都取
            let bodyData = request.httpBody ?? Self.readBodyStream(request)
            let body = bodyData.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
            XCTAssertNotNil(body?["t"])
            XCTAssertEqual(body?["f"] as? Int, 31)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(historyBody.utf8))
        }

        let items = try await makeClient().fetchGoUsageHistory(
            workspaceId: validWorkspace, authCookie: validCookie)

        XCTAssertEqual(items.count, 2)
        // 按时间倒序:EfGh456 (08-21) 在前
        XCTAssertEqual(items[0].id, "usg_EfGh456")
        XCTAssertEqual(items[0].model, "gemini-2.5-pro")
        XCTAssertEqual(items[0].provider, "google")
        XCTAssertEqual(items[0].inputTokens, 900)
        XCTAssertEqual(items[0].outputTokens, 600)
        XCTAssertEqual(items[0].reasoningTokens, 100)
        XCTAssertEqual(items[0].cacheReadTokens, 0)
        XCTAssertEqual(items[0].cacheWrite5mTokens, 75)
        XCTAssertNil(items[0].cacheWrite1hTokens)
        XCTAssertEqual(items[0].cost, 0.045, accuracy: 1e-12, "4500000 × 10⁻⁸ = $0.045")
        XCTAssertNil(items[0].plan)

        XCTAssertEqual(items[1].id, "usg_AbCd123")
        XCTAssertEqual(items[1].model, "claude-opus-4-8")
        XCTAssertNil(items[1].cacheWrite5mTokens)
        XCTAssertEqual(items[1].cacheWrite1hTokens, 50)
        XCTAssertEqual(items[1].plan, "OpenCode Go Pro")
        XCTAssertEqual(items[1].cost, 0.0123, accuracy: 1e-12, "1230000 × 10⁻⁸ = $0.0123")
        XCTAssertEqual(items[1].totalTokens, 1200 + 500 + 200 + 300 + 50)
    }

    /// URLProtocol 拦截时 request.httpBody 可能为空,body 在 httpBodyStream 里
    private static func readBodyStream(_ request: URLRequest) -> Data? {
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

    func testFetchGoUsageHistoryEmptyThrowsParseFailed() async {
        MockURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             Data("no records here".utf8))
        }
        do {
            _ = try await makeClient().fetchGoUsageHistory(
                workspaceId: validWorkspace, authCookie: validCookie)
            XCTFail("应当抛出错误")
        } catch let e as QuotaError {
            guard case .parseFailed = e else { return XCTFail("期望 parseFailed,实际 \(e)") }
        } catch {
            XCTFail("意外错误类型 \(error)")
        }
    }

    func testFetchGoUsageHistorySignInLeakThrowsSessionExpired() async {
        MockURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             Data("<html><a href=\"/sign-in\">login</a></html>".utf8))
        }
        do {
            _ = try await makeClient().fetchGoUsageHistory(
                workspaceId: validWorkspace, authCookie: validCookie)
            XCTFail("应当抛出错误")
        } catch let e as QuotaError {
            guard case .sessionExpired = e else { return XCTFail("期望 sessionExpired,实际 \(e)") }
        } catch {
            XCTFail("意外错误类型 \(error)")
        }
    }

    func testFetchGoUsageHistoryNonHTTPResponseThrowsHttpError() async {
        MockURLProtocol.handler = { request in
            (URLResponse(url: request.url!, mimeType: nil, expectedContentLength: 0, textEncodingName: nil),
             Data(historyBody.utf8))
        }
        do {
            _ = try await makeClient().fetchGoUsageHistory(
                workspaceId: validWorkspace, authCookie: validCookie)
            XCTFail("应当抛出错误")
        } catch let e as QuotaError {
            guard case .httpError(-1) = e else { return XCTFail("期望 httpError(-1),实际 \(e)") }
        } catch {
            XCTFail("意外错误类型 \(error)")
        }
    }

    // MARK: 成本诊断(historyDiag)

    /// 每个测试独立的临时目录(自动建,teardown 删除;绝不碰 ~/Library/Logs)
    private func makeTempDir(_ name: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuotaDiagTests-\(name)-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testDiagContextSlicesBothSidesWithRadius() {
        // needle 两侧各取 radius 字符
        let text = "aaaaaaCOST:123bbbbbb"
        let r = text.range(of: "COST:123")!
        let ctx = QuotaClient.diagContext(in: text, around: r, radius: 3)
        XCTAssertEqual(ctx, "aaaCOST:123bbb")
    }

    func testDiagContextClampsAtTextBounds() {
        // 左侧越界 → 收敛到开头;右侧越界 → 收敛到结尾
        let text = "COST:123\nrest"
        let r = text.range(of: "COST:123")!
        let ctx = QuotaClient.diagContext(in: text, around: r, radius: 10)
        XCTAssertEqual(ctx, "COST:123\\nrest", "换行应转义为字面 \\n")
    }

    func testDiagContextEscapesCRAndLF() {
        let text = "before\r\nCOST:123\nafter"
        let r = text.range(of: "COST:123")!
        let ctx = QuotaClient.diagContext(in: text, around: r, radius: 60)
        XCTAssertFalse(ctx.contains("\n"), "原始换行不应残留在上下文中")
        XCTAssertFalse(ctx.contains("\r"))
        XCTAssertTrue(ctx.contains("\\n"))
        XCTAssertTrue(ctx.contains("\\r"))
    }

    func testHistoryDiagMatchSkipsSubstringCostField() {
        // 复现 98M 之谜的原始 slice 保留为回归证据:total_cost 先于 cost 出现。
        // 词边界锚定后,首个 cost: 匹配应来自真实 cost 字段(与 historyDouble 同一正则)
        let slice = #"..., total_cost:98711933, cost:0.0123, ..."#
        let diag = QuotaClient.historyDiagMatch(in: slice)
        XCTAssertNotNil(diag)
        XCTAssertEqual(diag?.match, "cost:0.0123", "词边界锚定后不应再从 total_cost 抢值")
        XCTAssertTrue(diag?.ctx.contains("total_") ?? false, "上下文应保留 total_cost 现场")
        XCTAssertTrue(diag?.ctx.contains("0.0123") ?? false)
    }

    func testParseHistoryBodyReproductionFixtureParsesTrueCost() throws {
        let dir = makeTempDir("b29-fixture")
        // b29 复现 98M 的原始 fixture 原样保留:total_cost 在 cost 之前。
        // 修复前 cost 正则抢匹配 total_cost → 98,711,933;
        // 词边界锚定后应解析真实 cost 字段 = 0.0123(平台 ×10⁸ 定点原始值),
        // 按 ×10⁻⁸ 缩放到美元 → 1.23e-10(≤ $5 阈值 → 不写诊断日志)。
        let body = """
        const data1 = { id:"usg_Cross1", timeCreated:new Date("2026-08-23T00:00:00.000Z"), model:"gpt-test", provider:"openai", inputTokens:1, outputTokens:1, reasoningTokens:0, cacheReadTokens:0, total_cost:98711933, cost:0.0123, keyID:"key_1", sessionID:"ses_1", plan:null };
        """

        let items = QuotaClient.parseHistoryBody(body, diag: HistoryDiagSink(directory: dir))

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].cost, 0.0123 * QuotaClient.historyCostScale, accuracy: 1e-14,
                       "词边界锚定后 total_cost 不再抢匹配;cost 按 ×10⁻⁸ 缩放为美元")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: dir.appendingPathComponent("history.log").path),
            "缩放后低于 $5 阈值,不应写诊断日志")
    }

    func testParseHistoryBodyDiagStillWritesForGenuineAnomalousCost() throws {
        let dir = makeTempDir("genuine-anomaly")
        // 诊断旁路覆盖保留:真实独立的 cost 字段(非子串)超过阈值 → 照常写日志。
        // 阈值比较用缩放后美元值(> $5);诊断日志记录平台原始未缩放值并标注 costRaw。
        // 两条记录:98711933 × 10⁻⁸ = $0.99(98M 之谜原始值,低于阈值不写、
        // 断言缩放结果);9871193300 × 10⁻⁸ = $98.71(真异常 → 写日志)
        let body = """
        const data1 = { id:"usg_Anom", timeCreated:new Date("2026-08-24T00:00:00.000Z"), model:"gpt-test", provider:"openai", inputTokens:1, outputTokens:1, reasoningTokens:0, cacheReadTokens:0, cost:9871193300, keyID:"key_1", sessionID:"ses_1", plan:null };
        const data2 = { id:"usg_Norm", timeCreated:new Date("2026-08-24T01:00:00.000Z"), model:"gpt-test", provider:"openai", inputTokens:1, outputTokens:1, reasoningTokens:0, cacheReadTokens:0, cost:98711933, keyID:"key_2", sessionID:"ses_2", plan:null };
        """

        let items = QuotaClient.parseHistoryBody(body, diag: HistoryDiagSink(directory: dir))

        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].cost, 98.711933, accuracy: 1e-9, "9871193300 × 10⁻⁸ = $98.71,超阈值")
        XCTAssertEqual(items[1].cost, 0.98711933, accuracy: 1e-12, "98711933 × 10⁻⁸ = $0.99,低于阈值")

        let logURL = dir.appendingPathComponent("history.log")
        XCTAssertTrue(FileManager.default.fileExists(atPath: logURL.path))
        let content = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertTrue(content.contains("id=usg_Anom"))
        XCTAssertTrue(content.contains("model=gpt-test"))
        XCTAssertTrue(content.contains("costRaw=9871193300.0"), "诊断记录原始值并标注 raw(未缩放)")
        XCTAssertTrue(content.contains("match=cost:9871193300"), "应记录原始匹配串")
        XCTAssertFalse(content.contains("usg_Norm"), "缩放后低于 $5 阈值的记录不写诊断")
    }

    func testParseHistoryBodySkipsDiagBelowThreshold() throws {
        let dir = makeTempDir("normal")
        // historyBody 两条记录 cost 分别为 0.0123 / 0.045,均低于阈值 → 不写日志
        let items = QuotaClient.parseHistoryBody(historyBody, diag: HistoryDiagSink(directory: dir))

        XCTAssertEqual(items.count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("history.log").path))
    }

    // MARK: cost ×10⁻⁸ 定点缩放(98M 真因:平台单位变更)

    func testParseHistoryBodyCostFixedPointScaling() throws {
        let dir = makeTempDir("cost-scale")
        // 平台把 history 的 cost 字段从「美元」改为 ×10⁸ 定点单位(cost × 10⁻⁸ = 美元)。
        // 回归:0 → 0;323852 → 0.00323852(与真实 $0.0019 ↔ 194958 同量级);
        // 8 位小数精度无丢失。
        let body = """
        const data1 = { id:"usg_Scale0", timeCreated:new Date("2026-08-25T00:00:00.000Z"), model:"gpt-test", provider:"openai", inputTokens:1, outputTokens:1, reasoningTokens:0, cacheReadTokens:0, cost:0, keyID:"key_1", sessionID:"ses_1", plan:null };
        const data2 = { id:"usg_Scale1", timeCreated:new Date("2026-08-25T01:00:00.000Z"), model:"gpt-test", provider:"openai", inputTokens:1, outputTokens:1, reasoningTokens:0, cacheReadTokens:0, cost:323852, keyID:"key_2", sessionID:"ses_2", plan:null };
        """

        let items = QuotaClient.parseHistoryBody(body, diag: HistoryDiagSink(directory: dir))

        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].cost, 0, "cost:0 缩放后仍为 0")
        XCTAssertEqual(items[1].cost, 0.00323852, accuracy: 1e-12,
                       "323852 × 10⁻⁸ = $0.00323852")
        XCTAssertEqual(String(format: "%.8f", items[1].cost), "0.00323852",
                       "定点值 × 10⁻⁸ 后 8 位小数精度无丢失")
    }

    // MARK: 词边界锚定(98M 病根修复回归)

    /// 构造含 cost 子串前置字段的 fixture,断言真实 cost 字段不被抢匹配
    func testParseHistoryBodyIgnoresSubstringCostPrefixedFields() throws {
        let dir = makeTempDir("substring-cost")
        // 核心回归:b29 实锤形态 —— total_cost 在 cost 之前且值巨大。
        // 词边界锚定前 cost 正则抢匹配 → 80 万级错值;锚定后应取真实 cost(定点原始值
        // 190000/270000/350000 × 10⁻⁸ = $0.0019/$0.0027/$0.0035)。
        // 变体:totalCost(camelCase,大小写敏感本就不匹配)不误伤、
        //       totalcost(全小写子串)同样被边界拦截
        let body = """
        const data1 = { id:"usg_Cost1", timeCreated:new Date("2026-08-23T00:00:00.000Z"), model:"gpt-test", provider:"openai", inputTokens:1, outputTokens:1, reasoningTokens:0, cacheReadTokens:0, total_cost:98711933, cost:190000, keyID:"key_1", sessionID:"ses_1", plan:null };
        const data2 = { id:"usg_Cost2", timeCreated:new Date("2026-08-23T01:00:00.000Z"), model:"gpt-test", provider:"openai", inputTokens:1, outputTokens:1, reasoningTokens:0, cacheReadTokens:0, totalCost:98711933, cost:270000, keyID:"key_2", sessionID:"ses_2", plan:null };
        const data3 = { id:"usg_Cost3", timeCreated:new Date("2026-08-23T02:00:00.000Z"), model:"gpt-test", provider:"openai", inputTokens:1, outputTokens:1, reasoningTokens:0, cacheReadTokens:0, totalcost:98711933, cost:350000, keyID:"key_3", sessionID:"ses_3", plan:null };
        """

        let items = QuotaClient.parseHistoryBody(body, diag: HistoryDiagSink(directory: dir))

        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items[0].cost, 0.0019, accuracy: 1e-12, "total_cost 不应抢匹配")
        XCTAssertEqual(items[1].cost, 0.0027, accuracy: 1e-12, "camelCase totalCost 不误伤")
        XCTAssertEqual(items[2].cost, 0.0035, accuracy: 1e-12, "全小写 totalcost 同样被拦截")
    }

    func testParseHistoryBodyIgnoresSubstringKeyIDField() throws {
        let dir = makeTempDir("substring-keyid")
        // keyID 同病根变体:apikeyID 含 keyID: 子串,修复前会抢匹配到 key_wrong
        let body = """
        const data1 = { id:"usg_Key1", timeCreated:new Date("2026-08-23T00:00:00.000Z"), model:"gpt-test", provider:"openai", inputTokens:1, outputTokens:1, reasoningTokens:0, cacheReadTokens:0, cost:100000, apikeyID:"key_wrong", keyID:"key_right", sessionID:"ses_1", plan:null };
        """

        let items = QuotaClient.parseHistoryBody(body, diag: HistoryDiagSink(directory: dir))

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].keyID, "key_right", "keyID 不应从 apikeyID 抢匹配")
    }

    func testParseHistoryBodyAnchorIgnoresSubstringUidField() throws {
        let dir = makeTempDir("substring-uid")
        // anchor 同病根变体:uid:"usg_..." 含 id:"usg_..." 子串,
        // 修复前会在 uid 处切出伪记录;词边界锚定后只认独立的 id: 字段
        let body = """
        const data1 = { uid:"usg_fake", id:"usg_Real1", timeCreated:new Date("2026-08-23T00:00:00.000Z"), model:"gpt-test", provider:"openai", inputTokens:1, outputTokens:1, reasoningTokens:0, cacheReadTokens:0, cost:100000, keyID:"key_1", sessionID:"ses_1", plan:null };
        """

        let items = QuotaClient.parseHistoryBody(body, diag: HistoryDiagSink(directory: dir))

        XCTAssertEqual(items.count, 1, "uid 处的伪锚点不应产生记录")
        XCTAssertEqual(items[0].id, "usg_Real1")
    }

    func testParseHistoryBodyCostDefaultsToZeroWhenMissing() throws {
        let dir = makeTempDir("no-cost")
        // 无 cost 字段 → 默认 0(既有语义,锚定前后不变)
        let body = """
        const data1 = { id:"usg_NoCost", timeCreated:new Date("2026-08-23T00:00:00.000Z"), model:"gpt-test", provider:"openai", inputTokens:1, outputTokens:1, reasoningTokens:0, cacheReadTokens:0, keyID:"key_1", sessionID:"ses_1", plan:null };
        """

        let items = QuotaClient.parseHistoryBody(body, diag: HistoryDiagSink(directory: dir))

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].cost, 0, "无 cost 字段时应默认 0")
    }

    func testParseHistoryBodyTruncatesRecordAt4000Chars() throws {
        let dir = makeTempDir("truncate")
        // 单条记录扫描上限 4000 字符:截断点之前的字段正常解析,不崩溃(既有语义)
        let padding = String(repeating: "x", count: 4200)
        let body = """
        const data1 = { id:"usg_Trunc", timeCreated:new Date("2026-08-23T00:00:00.000Z"), model:"gpt-test", provider:"openai", inputTokens:1, outputTokens:1, reasoningTokens:0, cacheReadTokens:0, cost:1000000, keyID:"key_1", sessionID:"ses_1", plan:null, padding:"\(padding)" };
        """

        let items = QuotaClient.parseHistoryBody(body, diag: HistoryDiagSink(directory: dir))

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].id, "usg_Trunc")
        XCTAssertEqual(items[0].cost, 0.01, accuracy: 1e-12, "1000000 × 10⁻⁸ = $0.01")
    }

    // MARK: 校验

    func testValidateWorkspaceId() {
        XCTAssertNil(QuotaClient.validateWorkspaceId("wrk_AbC123"))
        XCTAssertNotNil(QuotaClient.validateWorkspaceId(""))
        XCTAssertNotNil(QuotaClient.validateWorkspaceId("wrk_"))
        XCTAssertNotNil(QuotaClient.validateWorkspaceId("not-a-workspace"))
        XCTAssertNotNil(QuotaClient.validateWorkspaceId("wrk_有中文"))
    }

    func testValidateAuthCookie() {
        XCTAssertNil(QuotaClient.validateAuthCookie("Fe26.2**sometoken"))
        XCTAssertNotNil(QuotaClient.validateAuthCookie(""))
        XCTAssertNotNil(QuotaClient.validateAuthCookie("Bearer xxx"))
    }

    func testParseUsageObject() {
        let window = QuotaClient.parseUsageObject(#"{usagePercent:12.5,resetInSec:900}"#)
        XCTAssertEqual(window?.usagePercent, 12.5)
        XCTAssertEqual(window?.resetInSec, 900)

        // 整数也要能解析
        let intWindow = QuotaClient.parseUsageObject(#"{usagePercent:0,resetInSec:3600}"#)
        XCTAssertEqual(intWindow?.usagePercent, 0)
        XCTAssertEqual(intWindow?.resetInSec, 3600)

        XCTAssertNil(QuotaClient.parseUsageObject("garbage"))
        XCTAssertNil(QuotaClient.parseUsageObject(#"{usagePercent:"x"}"#))
    }

    func testResetTextFormatting() {
        XCTAssertEqual(AccountCardView.resetText(from: 259_200), "3 天 0 小时")
        XCTAssertEqual(AccountCardView.resetText(from: 2.7 * 86_400), "2 天 16 小时")
        XCTAssertEqual(AccountCardView.resetText(from: 3_600 * 2 + 52 * 60), "2 小时 52 分")
        XCTAssertEqual(AccountCardView.resetText(from: 61), "1 分 1 秒")
        XCTAssertEqual(AccountCardView.resetText(from: -5), "0 秒")
    }
}
