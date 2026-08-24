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
        XCTAssertEqual(GitHubLoginService.extractAuthCookie(from: [cookie], oauthStarted: true), "Fe26.2**abc")
    }

    func testExtractAuthCookieCaseInsensitiveName() {
        let cookie = makeCookie(name: "Auth", value: "Fe26.2**abc", domain: "opencode.ai")
        XCTAssertEqual(GitHubLoginService.extractAuthCookie(from: [cookie], oauthStarted: true), "Fe26.2**abc")
    }

    func testExtractAuthCookiePrefersOpenCodeDomain() {
        let github = makeCookie(name: "auth", value: "Fe26.2**github", domain: "github.com")
        let opencode = makeCookie(name: "auth", value: "Fe26.2**opencode", domain: ".opencode.ai")
        XCTAssertEqual(
            GitHubLoginService.extractAuthCookie(from: [github, opencode], oauthStarted: true),
            "Fe26.2**opencode", "多 cookie 时应挑中 opencode 域的目标")
    }

    func testExtractAuthCookieFallsBackToAnyDomain() {
        let session = makeCookie(name: "session", value: "Fe26.2**nope", domain: "opencode.ai")
        let github = makeCookie(name: "auth", value: "Fe26.2**gh", domain: "github.com")
        XCTAssertEqual(
            GitHubLoginService.extractAuthCookie(from: [session, github], oauthStarted: true),
            "Fe26.2**gh", "opencode 域无目标时退回任意域")
    }

    func testExtractAuthCookieNoTargetReturnsNil() {
        XCTAssertNil(GitHubLoginService.extractAuthCookie(from: [], oauthStarted: true))
        XCTAssertNil(GitHubLoginService.extractAuthCookie(from: [
            makeCookie(name: "auth", value: "not-fe26", domain: "opencode.ai"),
            makeCookie(name: "session", value: "Fe26.2**wrong-name", domain: "opencode.ai"),
        ], oauthStarted: true))
    }

    // MARK: - extractAuthCookie:匿名占位门槛(修复:占位 cookie 被误判为登录成功)

    /// 线上实证(opencode.ai 对任何匿名访问立即下发 auth=Fe26. 开头占位 cookie):
    /// 未经过 GitHub OAuth(oauthStarted: false)命中的 Fe26. cookie 必是匿名占位 → 必须忽略
    func testExtractAuthCookieRejectsPlaceholderBeforeOAuth() {
        let placeholder = "Fe26.2**f20346b046d4ee255c0560383902bd9e0f845921653010f619cdf2f7295bbe7e*"
        let cookie = makeCookie(name: "auth", value: placeholder, domain: "opencode.ai")
        XCTAssertNil(GitHubLoginService.extractAuthCookie(from: [cookie], oauthStarted: false),
                     "未经过 GitHub OAuth 的 Fe26. cookie 是匿名占位,不得判定命中")
    }

    /// 同一占位 cookie,经过 GitHub OAuth 后照常命中(值与提取逻辑不变)
    func testExtractAuthCookieHitsPlaceholderAfterOAuth() {
        let placeholder = "Fe26.2**f20346b046d4ee255c0560383902bd9e0f845921653010f619cdf2f7295bbe7e*"
        let cookie = makeCookie(name: "auth", value: placeholder, domain: "opencode.ai")
        XCTAssertEqual(GitHubLoginService.extractAuthCookie(from: [cookie], oauthStarted: true), placeholder)
    }

    /// 未经过 OAuth 时,即使集合里存在 Fe26. cookie(含 github 域)也一律不命中
    func testExtractAuthCookieRejectsAllFe26BeforeOAuth() {
        let cookies = [
            makeCookie(name: "auth", value: "Fe26.2**placeholder", domain: "opencode.ai"),
            makeCookie(name: "auth", value: "Fe26.2**gh", domain: "github.com"),
        ]
        XCTAssertNil(GitHubLoginService.extractAuthCookie(from: cookies, oauthStarted: false))
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

    /// 修复①:注入成功返回值须明确区分「已填并提交」与「幂等已填」;
    /// 裁决「已填也提交」:两个分支共用一次 form.submit(),再按是否幂等返回标记
    func testFillCredentialsJSReturnsDistinctSuccessMarkers() {
        let js = GitHubLoginService.fillCredentialsJS(username: "alice", password: "s3cret")
        XCTAssertTrue(js.contains("return already ? 'already-filled' : 'filled';"),
                      "已填与本次填入都返回成功标记,且共用同一次表单提交")
        XCTAssertTrue(js.contains("form.submit()"), "必须执行表单提交")
        XCTAssertTrue(js.contains("return 'no-login-field';"), "表单未渲染应返回 no-login-field")
        XCTAssertTrue(js.contains("return 'no-form';"))
    }

    /// 裁决「已填也提交」:already-filled 分支的 form.submit() 必须出现在返回标记之前,
    /// 而不是像旧实现那样提前 return 跳过提交(消除浏览器自动填充同值凭据但表单未提交的残留风险)
    func testFillCredentialsJSAlreadyFilledStillSubmits() {
        let js = GitHubLoginService.fillCredentialsJS(username: "alice", password: "s3cret")
        guard let submit = js.range(of: "form.submit()"),
              let already = js.range(of: "'already-filled'")
        else {
            return XCTFail("JS 应同时包含表单提交与 already-filled 标记")
        }
        XCTAssertLessThan(submit.lowerBound, already.lowerBound,
                          "already-filled 分支也必须先 form.submit() 再返回标记")
        XCTAssertEqual(js.ranges(of: "form.submit()").count, 1, "两个分支共用同一次表单提交")
    }

    // MARK: - 备用选择器链(选择器单点假设加固)

    /// 修复②:主 #login_field/#password 之外须有 input[name="login"/"password"] 备用,
    /// 以及仅当页面恰有一个匹配时启用的 type=text/password 兜底;任一主+备组合命中即填并提交
    func testFillCredentialsJSIncludesFallbackSelectors() {
        let js = GitHubLoginService.fillCredentialsJS(username: "u", password: "p")
        XCTAssertTrue(js.contains(#"input[name="login"]"#), "应回退到 input[name=\"login\"]")
        XCTAssertTrue(js.contains(#"input[name="password"]"#), "应回退到 input[name=\"password\"]")
        XCTAssertTrue(js.contains(#"document.querySelectorAll('input[type="text"]').length === 1"#),
                      "text 兜底仅当页面恰有一个时启用")
        XCTAssertTrue(js.contains(#"document.querySelectorAll('input[type="password"]').length === 1"#),
                      "password 兜底仅当页面恰有一个时启用")
        XCTAssertTrue(js.contains("getElementById('login_field')"), "主选择器 #login_field 必须保留")
        XCTAssertTrue(js.contains("getElementById('password')"), "主选择器 #password 必须保留")
    }

    /// 修复②:2FA 填码 JS 的选择器链须含 #otp / name / autocomplete / tel / numeric 回退
    /// (fillOTPJS 与 probeAndFillOTPJS 共用同一链,行为一致)
    func testFillOTPJSIncludesFallbackSelectors() {
        for js in [GitHubLoginService.fillOTPJS(code: "123456"),
                   GitHubLoginService.probeAndFillOTPJS(code: "123456")] {
            XCTAssertTrue(js.contains("getElementById('otp')"), "主选择器 #otp 必须保留")
            XCTAssertTrue(js.contains(#"input[name="otp"]"#))
            XCTAssertTrue(js.contains(#"input[autocomplete="one-time-code"]"#))
            XCTAssertTrue(js.contains(#"document.querySelectorAll('input[type="tel"]').length === 1"#),
                          "tel 兜底仅当页面恰有一个时启用")
            XCTAssertTrue(js.contains(#"document.querySelectorAll('input[inputmode="numeric"]').length === 1"#),
                          "numeric 兜底仅当页面恰有一个时启用")
        }
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

    /// 修复(线上实证):OpenAuth 登录页真实入口是 href="/github/authorize"(带前导斜杠,
    /// 避免误匹配 github.com/login/oauth 之类),readCookiesJS 必须覆盖它;
    /// 且既有守卫(无 auth cookie + 未点击过才点一次)必须保留
    func testReadCookiesJSIncludesGithubAuthorizeEntry() {
        let js = GitHubLoginService.readCookiesJS()
        XCTAssertTrue(js.contains(#"a[href*="/github/authorize"]"#),
                      "线上 OpenAuth 页入口 href=/github/authorize 必须被选择器覆盖")
        XCTAssertTrue(js.contains("!auth &&"), "仅无 auth cookie 时才点击")
        XCTAssertTrue(js.contains("window.__opencodeGoClickedSignIn"), "「仅未点击过时点击一次」守卫必须保留")
        XCTAssertTrue(js.contains("link.click()"), "命中链接应执行点击")
    }

    /// 选择器链按优先级排序(首个命中即用,且 querySelector 按文档顺序返回):
    /// `a[href*="/github/authorize"]`(线上 OpenAuth 入口)→ `a[href*="oauth/authorize"]`
    /// → `a[href*="github.com/login/oauth"]`(标准 GitHub OAuth 链接)
    func testReadCookiesJSSelectorChainOrder() {
        let js = GitHubLoginService.readCookiesJS()
        let selectors = [
            #"a[href*="/github/authorize"]"#,
            #"a[href*="oauth/authorize"]"#,
            #"a[href*="github.com/login/oauth"]"#,
        ]
        var previousEnd: String.Index?
        for selector in selectors {
            guard let range = js.range(of: selector) else {
                XCTFail("readCookiesJS 应包含选择器: \(selector)")
                continue
            }
            if let previousEnd {
                XCTAssertLessThan(previousEnd, range.lowerBound,
                                  "选择器应按优先级排序,\(selector) 应位于前一个之后")
            }
            previousEnd = range.upperBound
        }
    }

    // MARK: - 步骤状态栏展示属性(S5:stepText/stepIcon/stepColor 数据收敛到 enum)

    func testStepStatusText() {
        XCTAssertEqual(GitHubLoginStep.idle.statusText, "准备中…")
        XCTAssertEqual(GitHubLoginStep.loadingLoginPage.statusText, "正在打开 opencode.ai…")
        XCTAssertEqual(GitHubLoginStep.githubLoginForm.statusText, "正在自动完成 GitHub 登录…")
        XCTAssertEqual(GitHubLoginStep.fillingCredentials.statusText, "正在提交登录信息…")
        XCTAssertEqual(GitHubLoginStep.twoFactor.statusText, "正在自动输入两步验证码…")
        XCTAssertEqual(GitHubLoginStep.waitingOAuthRedirect.statusText, "登录成功,正在读取 Cookie…")
        XCTAssertEqual(GitHubLoginStep.done(authCookie: "x").statusText, "✓ 已获取 Cookie,即将关闭")
        XCTAssertEqual(GitHubLoginStep.failed("登录超时(5 分钟无进展),请取消后重试").statusText,
                       "登录超时(5 分钟无进展),请取消后重试", "失败文案透传错误消息")
        XCTAssertEqual(GitHubLoginStep.needsManualIntervention("请手动完成").statusText, "请手动完成")
    }

    func testStepStatusIcon() {
        XCTAssertEqual(GitHubLoginStep.done(authCookie: "x").statusIcon, "checkmark.circle.fill")
        XCTAssertEqual(GitHubLoginStep.failed("x").statusIcon, "exclamationmark.triangle.fill")
        XCTAssertEqual(GitHubLoginStep.needsManualIntervention("x").statusIcon,
                       "person.crop.circle.badge.exclamationmark")
        XCTAssertEqual(GitHubLoginStep.waitingOAuthRedirect.statusIcon, "arrow.triangle.2.circlepath")
        XCTAssertEqual(GitHubLoginStep.twoFactor.statusIcon, "number.circle")
        XCTAssertEqual(GitHubLoginStep.githubLoginForm.statusIcon, "pencil.circle")
        XCTAssertEqual(GitHubLoginStep.fillingCredentials.statusIcon, "pencil.circle")
        XCTAssertEqual(GitHubLoginStep.idle.statusIcon, "circle.dotted")
        XCTAssertEqual(GitHubLoginStep.loadingLoginPage.statusIcon, "circle.dotted")
    }

    func testStepAppearance() {
        XCTAssertEqual(GitHubLoginStep.done(authCookie: "x").appearance, .success)
        XCTAssertEqual(GitHubLoginStep.failed("x").appearance, .error)
        XCTAssertEqual(GitHubLoginStep.needsManualIntervention("x").appearance, .warning)
        XCTAssertEqual(GitHubLoginStep.waitingOAuthRedirect.appearance, .working)
        for step in [GitHubLoginStep.idle, .loadingLoginPage, .githubLoginForm,
                     .fillingCredentials, .twoFactor] {
            XCTAssertEqual(step.appearance, .normal, "进行中/等待态统一为 normal 色")
        }
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

    // MARK: - 流程诊断时间线(可观测性,不含凭据)

    func testLoginFlowLogAppendAndClear() {
        var flow = GitHubLoginService.LoginFlowLog()
        XCTAssertTrue(flow.isEmpty)
        flow.log("decide github.com: idle -> loadingLoginPage")
        flow.log("inject: filled -> success", at: Date(timeIntervalSince1970: 1000))
        XCTAssertEqual(flow.count, 2)
        XCTAssertFalse(flow.isEmpty)
        XCTAssertTrue(flow.timelineText.contains("decide github.com"))
        XCTAssertTrue(flow.timelineText.contains("filled -> success"))
        flow.clear()
        XCTAssertTrue(flow.isEmpty)
        XCTAssertEqual(flow.timelineText, "(empty)")
    }

    func testLoginFlowLogTimelineTextKeepsOrder() {
        var flow = GitHubLoginService.LoginFlowLog()
        let start = Date(timeIntervalSince1970: 0)
        flow.log("first", at: start)
        flow.log("second", at: start.addingTimeInterval(1.5))
        flow.log("third", at: start.addingTimeInterval(3))
        let text = flow.timelineText
        guard let first = text.range(of: "first"),
              let second = text.range(of: "second"),
              let third = text.range(of: "third")
        else { return XCTFail("时间线应包含全部条目") }
        XCTAssertLessThan(first.lowerBound, second.lowerBound, "条目按追加顺序输出")
        XCTAssertLessThan(second.lowerBound, third.lowerBound)
    }

    /// 安全红线:即使 decide / JS 构造收到含敏感值的参数,时间线条目与输出也绝不包含
    /// 用户名/密码/验证码/cookie 值(视图侧只记录域名/步骤名/分类结果)
    func testLoginFlowLogNeverContainsCredentials() {
        let username = "alice", password = "hunter2-s3cret", totp = "123456"
        let cookie = "Fe26.2**top-secret-cookie"

        var flow = GitHubLoginService.LoginFlowLog()
        // 与 GitHubLoginView 实际打点一致:decide 诊断行 + 注入分类 + OTP 探测 + cookie 命中
        let d = GitHubLoginService.decide(
            for: url("https://github.com/login"), githubUsername: username,
            githubPassword: password, totpCode: totp, state: .loadingLoginPage)
        flow.log(GitHubLoginService.flowLogLine(
            url: url("https://github.com/login"), from: .loadingLoginPage, to: d.step))
        flow.log("inject: filled -> \(GitHubLoginService.classifyCredentialInjectResult("filled"))")
        flow.log("otp-probe: no-otp -> \(GitHubLoginService.classifyOTPProbeResult("no-otp"))")
        flow.log("cookie: poll hit")
        // 含关联值的状态(如 .done(authCookie:))也必须以纯枚举名出现(flowName)
        flow.log("decide opencode.ai: waitingOAuthRedirect -> \(GitHubLoginStep.done(authCookie: cookie).flowName)")

        let text = flow.timelineText
        XCTAssertFalse(text.contains(username), "时间线不得含用户名")
        XCTAssertFalse(text.contains(password), "时间线不得含密码")
        XCTAssertFalse(text.contains(totp), "时间线不得含验证码")
        XCTAssertFalse(text.contains(cookie), "时间线不得含 cookie 值")

        // 前置:JS 片段确实嵌入了凭据;但时间线只记录分类,绝不能把 JS 片段或原始返回值写进去
        let js = GitHubLoginService.fillCredentialsJS(username: username, password: password)
        XCTAssertTrue(js.contains(password), "前置断言:JS 内确实嵌入了凭据")
        XCTAssertFalse(text.contains("var user"), "时间线不得包含 JS 片段")
    }

    func testFlowLogLineUsesDomainAndFlowNameOnly() {
        let line = GitHubLoginService.flowLogLine(
            url: url("https://github.com/sessions/two-factor"),
            from: .fillingCredentials, to: .needsManualIntervention("请手动完成"))
        XCTAssertEqual(line, "decide github.com: fillingCredentials -> needsManualIntervention",
                       "诊断行只含域名与纯枚举名,不带出消息内容")

        let doneLine = GitHubLoginService.flowLogLine(
            url: url("https://opencode.ai"), from: .waitingOAuthRedirect, to: .done(authCookie: "Fe26.2**x"))
        XCTAssertEqual(doneLine, "decide opencode.ai: waitingOAuthRedirect -> done",
                       ".done 的关联值(cookie)绝不能出现在诊断行")
        XCTAssertFalse(doneLine.contains("Fe26"))
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
