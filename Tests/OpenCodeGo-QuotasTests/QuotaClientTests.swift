import Foundation
import XCTest
@testable import OpenCode_Go_Quotas

// MARK: - Mock URLProtocol

final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

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

/// 用量历史响应体:SolidStart 序列化,每条记录以 id:"usg_xxx" 为锚
let historyBody = """
{"$SNIPPET":"usage list"}
const data1 = { id:"usg_AbCd123", timeCreated:new Date("2026-08-20T10:00:00.000Z"), model:"claude-opus-4-8", provider:"anthropic", inputTokens:1200, outputTokens:500, reasoningTokens:200, cacheReadTokens:300, cacheWrite5mTokens:null, cacheWrite1hTokens:50, cost:0.0123, keyID:"key_1", sessionID:"ses_1", plan:"OpenCode Go Pro" };
const data2 = { id:"usg_EfGh456", timeCreated:$R[3]=new Date("2026-08-21T08:30:00.000Z"), model:"gemini-2.5-pro", provider:"google", inputTokens:900, outputTokens:600, reasoningTokens:100, cacheReadTokens:0, cacheWrite5mTokens:75, cacheWrite1hTokens:null, cost:0.045, keyID:"key_2", sessionID:"ses_2", plan:null };
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
        XCTAssertEqual(items[0].cost, 0.045, accuracy: 0.0001)
        XCTAssertNil(items[0].plan)

        XCTAssertEqual(items[1].id, "usg_AbCd123")
        XCTAssertEqual(items[1].model, "claude-opus-4-8")
        XCTAssertNil(items[1].cacheWrite5mTokens)
        XCTAssertEqual(items[1].cacheWrite1hTokens, 50)
        XCTAssertEqual(items[1].plan, "OpenCode Go Pro")
        XCTAssertEqual(items[1].cost, 0.0123, accuracy: 0.0001)
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
