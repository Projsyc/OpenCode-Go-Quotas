import Foundation
import XCTest
@testable import OpenCodeGo

/// GitHubLoginService 纯逻辑状态机测试:
/// URL + 步骤 → 决策(步骤 / JS / 是否轮询)、auth cookie 提取、JS 构造与转义。
/// 不测 WKWebView 交互(无真实网络)、不测真实 cookie 流。
final class GitHubLoginServiceTests: XCTestCase {

    private func url(_ s: String) -> URL? { URL(string: s) }

    // MARK: - decide:GitHub 登录页

    func testDecideGithubLoginPageReturnsFillCredentials() {
        let d = GitHubLoginService.decide(
            for: url("https://github.com/login?return_to=https%3A%2F%2Fgithub.com%2Flogin%2Foauth%2Fauthorize"),
            githubUsername: "alice", githubPassword: "s3cret",
            totpCode: nil, state: .loadingLoginPage)

        XCTAssertEqual(d.step, .githubLoginForm)
        XCTAssertFalse(d.pollCookie, "GitHub 页面不应触发 opencode cookie 轮询")
        let js = d.javascript ?? ""
        XCTAssertTrue(js.contains("login_field"), "应注入 #login_field")
        XCTAssertTrue(js.contains("password"), "应注入 #password")
        XCTAssertTrue(js.contains("\"alice\""))
        XCTAssertTrue(js.contains("\"s3cret\""))
    }

    func testDecideGithubSessionsPageAlsoFills() {
        let d = GitHubLoginService.decide(
            for: url("https://github.com/session"), githubUsername: "u", githubPassword: "p",
            totpCode: nil, state: .idle)
        XCTAssertEqual(d.step, .githubLoginForm)
        XCTAssertNotNil(d.javascript)
    }

    /// 已提交过(填表完成)又回到登录页 = 账号/密码错误,应转手动而非死循环重填
    func testDecideLoginPageAfterFailedSubmitGoesManual() {
        for state in [GitHubLoginStep.fillingCredentials, .twoFactor] {
            let d = GitHubLoginService.decide(
                for: url("https://github.com/login"), githubUsername: "u", githubPassword: "p",
                totpCode: nil, state: state)
            XCTAssertEqual(d.step, .needsManualIntervention("GitHub 登录未成功,请在窗口中手动登录"))
            XCTAssertNil(d.javascript)
        }
    }

    // MARK: - decide:OAuth 授权页

    func testDecideOAuthAuthorizePageClicksAuthorize() {
        let d = GitHubLoginService.decide(
            for: url("https://github.com/login/oauth/authorize?client_id=opencode&scope=read:user"),
            githubUsername: "u", githubPassword: "p",
            totpCode: nil, state: .twoFactor)

        XCTAssertEqual(d.step, .githubLoginForm)
        XCTAssertFalse(d.pollCookie)
        let js = d.javascript ?? ""
        XCTAssertTrue(js.contains("authorize"), "应注入点击 Authorize 按钮的 JS")
        XCTAssertTrue(js.contains("#js-oauth-authorize-btn"))
    }

    // MARK: - decide:2FA

    func testDecideTwoFactorWithCodeFillsOTP() {
        let d = GitHubLoginService.decide(
            for: url("https://github.com/sessions/two-factor"), githubUsername: "u", githubPassword: "p",
            totpCode: "123456", state: .fillingCredentials)

        XCTAssertEqual(d.step, .twoFactor)
        let js = d.javascript ?? ""
        XCTAssertTrue(js.contains("otp"), "应注入 #otp")
        XCTAssertTrue(js.contains("\"123456\""))
    }

    func testDecideTwoFactorWithoutCodeGoesManual() {
        let d = GitHubLoginService.decide(
            for: url("https://github.com/sessions/two-factor"), githubUsername: "u", githubPassword: "p",
            totpCode: nil, state: .fillingCredentials)

        XCTAssertEqual(d.step, .needsManualIntervention("请在窗口中输入两步验证码,完成后等待自动捕获"))
        XCTAssertNil(d.javascript)
    }

    func testDecideTwoFactorWithEmptyCodeGoesManual() {
        let d = GitHubLoginService.decide(
            for: url("https://github.com/sessions/two-factor/challenge"), githubUsername: "u", githubPassword: "p",
            totpCode: "", state: .githubLoginForm)
        XCTAssertEqual(d.step, .needsManualIntervention("请在窗口中输入两步验证码,完成后等待自动捕获"))
    }

    // MARK: - decide:内联 2FA 探测(登录页内直接渲染 #otp,路径仍是 /login 或 /sessions)

    /// 修复②:凭据已提交后又回到 /login,有 TOTP 时应探测内联 OTP 并返回填码 JS,
    /// 而不是直接按「登录失败」转手动
    func testDecideInlineOTPOnLoginPageProbesAndFills() {
        for path in ["/login", "/login?return_to=%2Fsettings", "/sessions", "/session"] {
            let d = GitHubLoginService.decide(
                for: url("https://github.com\(path)"), githubUsername: "u", githubPassword: "p",
                totpCode: "123456", state: .fillingCredentials)

            XCTAssertEqual(d.step, .twoFactor, "\(path): 内联 OTP 探测应进入 2FA 等待态")
            XCTAssertTrue(d.isOTPProbe, "\(path): 应标记为 OTP 探测决策,由视图解释结果")
            let js = d.javascript ?? ""
            XCTAssertTrue(js.contains("otp"), "\(path): 应注入 OTP 填码 JS")
            XCTAssertTrue(js.contains("\"123456\""), "\(path): 验证码应经 JSON 转义嵌入 JS")
        }
    }

    func testDecideInlineOTPOnLoginPageWithoutTotpGoesManual() {
        let d = GitHubLoginService.decide(
            for: url("https://github.com/login"), githubUsername: "u", githubPassword: "p",
            totpCode: nil, state: .fillingCredentials)
        XCTAssertEqual(d.step, .needsManualIntervention("GitHub 登录未成功,请在窗口中手动登录"))
        XCTAssertNil(d.javascript)
        XCTAssertFalse(d.isOTPProbe)
    }

    /// 修复②:探测不依赖 URL 路径——github.com 任意页面(非登录/会话路径)在凭据已提交后
    /// 也追加 OTP 探测;未命中时由视图按现有规则继续
    func testDecideInlineOTPProbeOnAnyGithubPage() {
        for state in [GitHubLoginStep.fillingCredentials, .twoFactor] {
            let d = GitHubLoginService.decide(
                for: url("https://github.com/settings/security"), githubUsername: "u", githubPassword: "p",
                totpCode: "123456", state: state)

            XCTAssertEqual(d.step, state, "非登录路径:状态保持当前步骤")
            XCTAssertTrue(d.isOTPProbe, "凭据已提交后任意 github 页面都应追加 OTP 探测")
            let js = d.javascript ?? ""
            XCTAssertTrue(js.contains("one-time-code"), "探测 JS 应含 one-time-code 选择器")
        }
    }

    /// 无 TOTP 时其他 github 页面不追加探测,行为与修复前一致
    func testDecideOtherGithubPageWithoutTotpKeepsState() {
        let d = GitHubLoginService.decide(
            for: url("https://github.com/settings"), githubUsername: "u", githubPassword: "p",
            totpCode: nil, state: .fillingCredentials)
        XCTAssertEqual(d.step, .fillingCredentials)
        XCTAssertNil(d.javascript)
        XCTAssertFalse(d.isOTPProbe)
    }

    // MARK: - decide:通行密钥 / 设备验证

    func testDecideWebauthnPageGoesManual() {
        let d = GitHubLoginService.decide(
            for: url("https://github.com/sessions/webauthn"), githubUsername: "u", githubPassword: "p",
            totpCode: "123456", state: .githubLoginForm)
        XCTAssertEqual(d.step, .needsManualIntervention("GitHub 需要通行密钥验证,请在窗口中完成"))
        XCTAssertNil(d.javascript)
    }

    func testDecideDeviceVerificationPageGoesManual() {
        let d = GitHubLoginService.decide(
            for: url("https://github.com/sessions/verified-device"), githubUsername: "u", githubPassword: "p",
            totpCode: nil, state: .fillingCredentials)
        XCTAssertEqual(d.step, .needsManualIntervention("GitHub 需要设备验证,请在窗口中完成"))
        XCTAssertNil(d.javascript)
    }

    // MARK: - decide:回到 opencode 域

    func testDecideOpenCodeDomainPollsCookie() {
        let d = GitHubLoginService.decide(
            for: url("https://opencode.ai/workspace/wrk_abc123"), githubUsername: "u", githubPassword: "p",
            totpCode: nil, state: .githubLoginForm)

        XCTAssertEqual(d.step, .waitingOAuthRedirect, "登录流程中回到 opencode 域 = 等待回跳")
        XCTAssertTrue(d.pollCookie, "opencode 域必须轮询 cookie")
        let js = d.javascript ?? ""
        XCTAssertTrue(js.contains("document.cookie"))
    }

    func testDecideOpenCodeDomainFromIdleStaysLoading() {
        let d = GitHubLoginService.decide(
            for: url("https://opencode.ai/workspace/wrk_abc123"), githubUsername: "u", githubPassword: "p",
            totpCode: nil, state: .idle)
        XCTAssertEqual(d.step, .loadingLoginPage, "流程未开始时仍为加载中")
        XCTAssertTrue(d.pollCookie)
    }

    func testDecideOpenCodeSubdomainCountsAsOpenCode() {
        for host in ["api.opencode.ai", "dashboard.opencode.ai"] {
            let d = GitHubLoginService.decide(
                for: url("https://\(host)/callback?code=xx"), githubUsername: "u", githubPassword: "p",
                totpCode: nil, state: .waitingOAuthRedirect)
            XCTAssertTrue(d.pollCookie, "\(host) 应视为 opencode 域")
            XCTAssertEqual(d.step, .waitingOAuthRedirect)
        }
    }

    // MARK: - decide:其他页面 / 边界

    func testDecideNilURLFromIdleGoesLoading() {
        let d = GitHubLoginService.decide(
            for: nil, githubUsername: "u", githubPassword: "p", totpCode: nil, state: .idle)
        XCTAssertEqual(d.step, .loadingLoginPage)
        XCTAssertNil(d.javascript)
        XCTAssertFalse(d.pollCookie)
    }

    func testDecideNilURLKeepsNonIdleState() {
        let d = GitHubLoginService.decide(
            for: nil, githubUsername: "u", githubPassword: "p", totpCode: nil, state: .twoFactor)
        XCTAssertEqual(d.step, .twoFactor)
    }

    func testDecideUnknownHostKeepsState() {
        let d = GitHubLoginService.decide(
            for: url("https://example.com/captcha"), githubUsername: "u", githubPassword: "p",
            totpCode: nil, state: .twoFactor)
        XCTAssertEqual(d.step, .twoFactor, "风控/验证中间页不打断流程")
        XCTAssertNil(d.javascript)
        XCTAssertFalse(d.pollCookie)
    }

    func testDecideOtherGithubPageKeepsState() {
        let d = GitHubLoginService.decide(
            for: url("https://github.com/features"), githubUsername: "u", githubPassword: "p",
            totpCode: nil, state: .waitingOAuthRedirect)
        XCTAssertEqual(d.step, .waitingOAuthRedirect)
        XCTAssertNil(d.javascript)
    }

    // MARK: - extractAuthCookie

    func testExtractAuthCookieFindsFe26() {
        let cookie = makeCookie(name: "auth", value: "Fe26.2**abc", domain: "opencode.ai")
        XCTAssertEqual(GitHubLoginService.extractAuthCookie(from: [cookie]), "Fe26.2**abc")
    }

    func testExtractAuthCookieCaseInsensitiveName() {
        let cookie = makeCookie(name: "Auth", value: "Fe26.2**abc", domain: "opencode.ai")
        XCTAssertEqual(GitHubLoginService.extractAuthCookie(from: [cookie]), "Fe26.2**abc")
    }

    func testExtractAuthCookiePrefersOpenCodeDomain() {
        let github = makeCookie(name: "auth", value: "Fe26.2**github", domain: "github.com")
        let opencode = makeCookie(name: "auth", value: "Fe26.2**opencode", domain: ".opencode.ai")
        XCTAssertEqual(
            GitHubLoginService.extractAuthCookie(from: [github, opencode]),
            "Fe26.2**opencode", "多 cookie 时应挑中 opencode 域的目标")
    }

    func testExtractAuthCookieFallsBackToAnyDomain() {
        let session = makeCookie(name: "session", value: "Fe26.2**nope", domain: "opencode.ai")
        let github = makeCookie(name: "auth", value: "Fe26.2**gh", domain: "github.com")
        XCTAssertEqual(
            GitHubLoginService.extractAuthCookie(from: [session, github]),
            "Fe26.2**gh", "opencode 域无目标时退回任意域")
    }

    func testExtractAuthCookieNoTargetReturnsNil() {
        XCTAssertNil(GitHubLoginService.extractAuthCookie(from: []))
        XCTAssertNil(GitHubLoginService.extractAuthCookie(from: [
            makeCookie(name: "auth", value: "not-fe26", domain: "opencode.ai"),
            makeCookie(name: "session", value: "Fe26.2**wrong-name", domain: "opencode.ai"),
        ]))
    }

    // MARK: - JS 构造与转义

    func testFillCredentialsJSEscapesSpecialChars() {
        let js = GitHubLoginService.fillCredentialsJS(
            username: "a\"b\\c 中文", password: "p'w\"d\\q")
        // JSON 转义后的字面量必须原样出现在 JS 中
        XCTAssertTrue(js.contains(#"a\"b\\c 中文"#), "用户名应经 JSON 转义后嵌入 JS, 实际: \(js)")
        XCTAssertTrue(js.contains(#"p'w\"d\\q"#))
        // 原始未转义的双引号不应直接拼进 JS 字符串
        XCTAssertFalse(js.contains("var user = \"a\"b"))
    }

    /// 修复①:注入成功返回值须明确区分「已填并提交」与「幂等已填」
    func testFillCredentialsJSReturnsDistinctSuccessMarkers() {
        let js = GitHubLoginService.fillCredentialsJS(username: "alice", password: "s3cret")
        XCTAssertTrue(js.contains("return 'filled';"), "已填并提交应返回 filled")
        XCTAssertTrue(js.contains("return 'already-filled';"), "值已一致(幂等)应返回 already-filled")
        XCTAssertTrue(js.contains("return 'no-login-field';"), "表单未渲染应返回 no-login-field")
        XCTAssertTrue(js.contains("return 'no-form';"))
    }

    func testFillCredentialsJSNoScriptInjection() {
        let payload = "\"); alert(1); //"
        let js = GitHubLoginService.fillCredentialsJS(username: payload, password: payload)
        let escaped = GitHubLoginService.jsonEscaped(payload)
        XCTAssertTrue(js.contains(escaped))
        // 注入载荷必须被转义为字符串内容,而非可执行代码
        XCTAssertFalse(js.contains("); alert(1); //\")"), "载荷不应以原始形式执行")
    }

    func testFillOTPJSContainsEscapedCode() {
        let js = GitHubLoginService.fillOTPJS(code: "123 456")
        XCTAssertTrue(js.contains("otp"))
        XCTAssertTrue(js.contains("\"123 456\""))
    }

    /// 修复②:内联 2FA 探测 JS 须覆盖 #otp / input[name="otp"] / input[autocomplete="one-time-code"]
    /// 三种选择器,命中即填码提交,未命中返回 no-otp
    func testProbeAndFillOTPJSUsesThreeSelectors() {
        let js = GitHubLoginService.probeAndFillOTPJS(code: "654321")
        XCTAssertTrue(js.contains("getElementById('otp')"), "应探测 #otp")
        XCTAssertTrue(js.contains(#"input[name="otp"]"#), "应探测 input[name=\"otp\"]")
        XCTAssertTrue(js.contains(#"input[autocomplete="one-time-code"]"#), "应探测 autocomplete 选择器")
        XCTAssertTrue(js.contains("return 'otp-filled';"))
        XCTAssertTrue(js.contains("return 'no-otp';"))
        XCTAssertTrue(js.contains("\"654321\""), "验证码应经 JSON 转义嵌入 JS")
        XCTAssertTrue(js.contains("form.submit()"), "应复用 OTP 注入逻辑(填值 + input 事件 + 提交)")
    }

    // MARK: - 注入结果分类(修复①/②的状态机推进依据)

    func testClassifyCredentialInjectResultFilledIsSuccess() {
        for result in ["filled", "already-filled"] {
            XCTAssertEqual(
                GitHubLoginService.classifyCredentialInjectResult(result), .success,
                "\(result) 应视为注入成功,推进状态机")
        }
    }

    func testClassifyCredentialInjectResultRetryCases() {
        for result in [String?].init(arrayLiteral: "no-login-field", "no-form", nil, "weird-return") {
            XCTAssertEqual(
                GitHubLoginService.classifyCredentialInjectResult(result), .retry,
                "\(String(describing: result)) 应视为表单未渲染,保持 .githubLoginForm 重试")
        }
    }

    func testClassifyOTPProbeResult() {
        XCTAssertEqual(GitHubLoginService.classifyOTPProbeResult("otp-filled"), .filled)
        for result in [String?].init(arrayLiteral: "no-otp", "no-form", nil, "submitted") {
            XCTAssertEqual(
                GitHubLoginService.classifyOTPProbeResult(result), .notPresent,
                "\(String(describing: result)) 应视为页面无 OTP 输入框,按现有规则继续")
        }
    }

    func testCredentialInjectRetryParameters() {
        XCTAssertEqual(GitHubLoginService.credentialInjectMaxRetries, 5, "表单未渲染最多重试 5 次")
        XCTAssertEqual(GitHubLoginService.credentialInjectRetryDelayMs, 500, "重试间隔 500ms")
    }

    func testReadCookiesJSUsesDocumentCookieAndOAuthSelector() {
        let js = GitHubLoginService.readCookiesJS()
        XCTAssertTrue(js.contains("document.cookie"))
        XCTAssertTrue(js.contains(#"a[href*="oauth/authorize"]"#))
        XCTAssertTrue(js.contains("JSON.stringify"))
    }

    // MARK: - jsonEscaped

    func testJsonEscapedEdgeCases() {
        XCTAssertEqual(GitHubLoginService.jsonEscaped(""), "\"\"")
        XCTAssertEqual(GitHubLoginService.jsonEscaped("abc"), "\"abc\"")
        XCTAssertEqual(GitHubLoginService.jsonEscaped("a\"b"), #""a\"b""#)
        XCTAssertEqual(GitHubLoginService.jsonEscaped("a\\b"), #""a\\b""#)
        XCTAssertEqual(GitHubLoginService.jsonEscaped("a\nb"), #""a\nb""#)
        XCTAssertEqual(GitHubLoginService.jsonEscaped("中文🙂"), "\"中文🙂\"")
    }

    func testJsonEscapedRoundTrip() throws {
        let values = ["", "abc", "a\"b", "a\\b", "a\nb", "中文🙂", "tab\there", "a/b", "<script>alert(1)</script>"]
        for value in values {
            let escaped = GitHubLoginService.jsonEscaped(value)
            let data = Data("[\(escaped)]".utf8)
            let decoded = try JSONSerialization.jsonObject(with: data) as? [String]
            XCTAssertEqual(decoded?.first, value, "转义结果必须能被 JSON 反解回原值: \(escaped)")
        }
    }

    // MARK: - 辅助

    private func makeCookie(name: String, value: String, domain: String) -> HTTPCookie {
        HTTPCookie(properties: [
            .domain: domain,
            .path: "/",
            .name: name,
            .value: value,
        ])!
    }
}
