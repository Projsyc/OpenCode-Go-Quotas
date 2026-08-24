import Foundation

/// GitHub 自动登录 opencode.ai 的步骤状态机(纯逻辑,可单测)。
///
/// 设计:WebView 只做 I/O(导航回调 → decide → 执行 JS / 轮询 cookie),
/// `decide` 只依据 URL + 当前步骤做决策,不依赖真实页面 HTML;
/// HTML 探测(表单是否渲染、授权按钮是否存在)由注入的 JS 在运行时判定。
enum GitHubLoginStep: Equatable {
    case idle
    case loadingLoginPage          // 正在打开 opencode 页面
    case githubLoginForm           // GitHub 登录页 / OAuth 授权页(等待自动填表或点授权)
    case fillingCredentials        // 已注入用户名/密码,等待提交结果
    case twoFactor                 // 2FA 页(等待填码)
    case waitingOAuthRedirect      // 已提交登录,等待跳回 opencode
    case done(authCookie: String)  // 已捕获 opencode auth cookie(由视图在轮询命中时置入)
    case failed(String)
    case needsManualIntervention(String)  // 无法自动处理(验证码缺失/登录失败/风控),等用户在窗口内手动完成
}

/// decide 的决策结果:下一步骤 + 要注入执行的 JS + 是否轮询 opencode cookie
struct GitHubLoginDecision: Equatable {
    let step: GitHubLoginStep
    let javascript: String?
    let pollCookie: Bool
    /// 是否为内联 2FA 探测注入(凭据已提交后对 github.com 任意页面追加):
    /// 结果由视图解释——命中填码提交,未命中按现有规则继续(登录页未命中 → 转手动)
    let isOTPProbe: Bool

    init(
        step: GitHubLoginStep,
        javascript: String?,
        pollCookie: Bool,
        isOTPProbe: Bool = false
    ) {
        self.step = step
        self.javascript = javascript
        self.pollCookie = pollCookie
        self.isOTPProbe = isOTPProbe
    }
}

/// GitHub 自动登录服务:URL → 决策的纯函数状态机 + JS 片段构造 + cookie 提取。
struct GitHubLoginService {
    let opencodeBaseURL: URL
    var userAgent: String

    /// 默认 macOS Safari UA(避免 GitHub 识别为无头 UA);可在 init 注入便于测试
    static let defaultUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
        + "(KHTML, like Gecko) Version/17.4 Safari/605.1.15"

    init(
        opencodeBaseURL: URL = URL(string: "https://opencode.ai")!,
        userAgent: String = Self.defaultUserAgent
    ) {
        self.opencodeBaseURL = opencodeBaseURL
        self.userAgent = userAgent
    }

    // MARK: - 主决策(URL + 步骤 → 决策)

    /// 依据导航到的 URL 与当前步骤决定下一步。
    /// 规则(按序判定,github.com 优先于 opencode):
    /// 1. GitHub 2FA 页(路径含 two-factor)→ 有码自动填,无码手动;
    /// 2. GitHub 通行密钥(webauthn)/设备验证(device)→ 手动;
    /// 3. GitHub OAuth 授权页(oauth/authorize)→ 注入点击授权按钮的 JS;
    /// 4. GitHub 登录表单(/login、/sessions)→ 注入用户名/密码并提交(确认成功后才推进状态);
    ///    若已提交过(状态为 fillingCredentials/twoFactor)又回到登录页:先探测内联 2FA
    ///    输入框(登录页内直接渲染 #otp 的形态,路径仍是 /login)——命中 → 自动填码提交,
    ///    未命中且无 two-factor 路径 → 登录失败 → 手动;
    /// 5. 其他 GitHub 页面(资料页、安全页等)→ 按当前状态延续;凭据已提交后追加一次
    ///    内联 OTP 探测(不依赖 URL 路径),命中 → 自动填码,未命中 → 按现有规则继续;
    /// 6. opencode 域(含子域)→ 轮询 cookie + 注入读 cookie / 点击 GitHub 登录入口的 JS;
    /// 7. 其他域(风控/验证码页等)→ 按当前状态延续,不打断。
    static func decide(
        for url: URL?,
        githubUsername: String,
        githubPassword: String,
        totpCode: String?,
        state: GitHubLoginStep
    ) -> GitHubLoginDecision {
        guard let url else {
            // 无 URL(首次加载前):进入加载中
            let step: GitHubLoginStep = (state == .idle) ? .loadingLoginPage : state
            return GitHubLoginDecision(step: step, javascript: nil, pollCookie: false)
        }

        let host = url.host?.lowercased() ?? ""
        let path = url.path.lowercased()
        let isGitHubHost = host == "github.com" || host.hasSuffix(".github.com")
        let isOpenCodeHost = host == "opencode.ai" || host.hasSuffix(".opencode.ai")

        if isGitHubHost {
            // 1) 2FA 页(/sessions/two-factor 等)
            if path.contains("two-factor") {
                if let totpCode, !totpCode.isEmpty {
                    return GitHubLoginDecision(
                        step: .twoFactor, javascript: fillOTPJS(code: totpCode), pollCookie: false)
                }
                return GitHubLoginDecision(
                    step: .needsManualIntervention("请在窗口中输入两步验证码,完成后等待自动捕获"),
                    javascript: nil, pollCookie: false)
            }
            // 2) 通行密钥 / 设备验证 / 风控类页面:无法自动处理,转手动
            if path.contains("webauthn") {
                return GitHubLoginDecision(
                    step: .needsManualIntervention("GitHub 需要通行密钥验证,请在窗口中完成"),
                    javascript: nil, pollCookie: false)
            }
            if path.contains("device") {   // /sessions/verified-device、/sessions/device-verification
                return GitHubLoginDecision(
                    step: .needsManualIntervention("GitHub 需要设备验证,请在窗口中完成"),
                    javascript: nil, pollCookie: false)
            }
            // 3) OAuth 授权页:会话已建立(刚登录完),直接点「Authorize」
            if path.contains("oauth/authorize") {
                return GitHubLoginDecision(
                    step: .githubLoginForm, javascript: authorizeJS(), pollCookie: false)
            }
            // 4) 登录表单 / 会话页(/login、/session、/sessions/...)
            if path.contains("/login") || path.contains("/session") {
                switch state {
                case .fillingCredentials, .twoFactor:
                    // 提交后仍回到登录页:先探测内联 2FA 输入框(GitHub 会在登录页内
                    // 直接渲染 #otp,路径仍是 /login 或 /sessions)——命中 → 自动填码提交;
                    // 未命中(无内联 2FA)→ 登录未成功,转手动避免死循环
                    if let totpCode, !totpCode.isEmpty {
                        return GitHubLoginDecision(
                            step: .twoFactor,
                            javascript: probeAndFillOTPJS(code: totpCode),
                            pollCookie: false,
                            isOTPProbe: true)
                    }
                    return GitHubLoginDecision(
                        step: .needsManualIntervention("GitHub 登录未成功,请在窗口中手动登录"),
                        javascript: nil, pollCookie: false)
                case .idle, .loadingLoginPage, .githubLoginForm:
                    return GitHubLoginDecision(
                        step: .githubLoginForm,
                        javascript: fillCredentialsJS(username: githubUsername, password: githubPassword),
                        pollCookie: false)
                default:
                    // 手动处理中/等待回跳等:不打断用户操作
                    return GitHubLoginDecision(step: state, javascript: nil, pollCookie: false)
                }
            }
            // 5) 其他 GitHub 页面(资料页、安全页等):按当前状态延续;
            //    凭据已提交后(等内联 2FA)追加一次 OTP 探测,不依赖 URL 路径:
            //    命中 → 自动填码提交,未命中由视图按现有规则继续
            if (state == .fillingCredentials || state == .twoFactor),
               let totpCode, !totpCode.isEmpty {
                return GitHubLoginDecision(
                    step: state,
                    javascript: probeAndFillOTPJS(code: totpCode),
                    pollCookie: false,
                    isOTPProbe: true)
            }
            return GitHubLoginDecision(step: state, javascript: nil, pollCookie: false)
        }

        if isOpenCodeHost {
            // 回到 opencode 域(含子域):开始轮询 cookie;JS 顺带读取 document.cookie,
            // 若页面仍是未登录态(如 SPA 登录页)则点击 GitHub 登录入口触发 OAuth
            let step: GitHubLoginStep =
                (state == .idle || state == .loadingLoginPage) ? .loadingLoginPage : .waitingOAuthRedirect
            return GitHubLoginDecision(step: step, javascript: readCookiesJS(), pollCookie: true)
        }

        // 其他域(验证码/风控中间页等):按当前状态延续,不打断流程
        if state == .idle {
            return GitHubLoginDecision(step: .loadingLoginPage, javascript: nil, pollCookie: false)
        }
        return GitHubLoginDecision(step: state, javascript: nil, pollCookie: false)
    }

    // MARK: - Cookie 提取

    /// 从 cookie 集合中提取 opencode auth cookie:
    /// 名称大小写不敏感匹配 "auth",值以 "Fe26." 开头;
    /// 优先取 opencode 域(含子域)的 cookie,没有匹配时退回任意域。
    static func extractAuthCookie(from cookies: [HTTPCookie]) -> String? {
        let matches = cookies.filter { $0.name.lowercased() == "auth" && $0.value.hasPrefix("Fe26.") }
        guard let first = matches.first else { return nil }
        return matches.first(where: { isOpenCodeCookie($0) })?.value ?? first.value
    }

    private static func isOpenCodeCookie(_ cookie: HTTPCookie) -> Bool {
        let domain = cookie.domain.lowercased()
        return domain == "opencode.ai" || domain.hasSuffix(".opencode.ai")
    }

    // MARK: - JS 片段构造(值一律经 jsonEscaped,绝不字符串拼接注入)

    /// 填 GitHub 登录表单(#login_field / #password)并提交;返回值为状态机提供确认信号:
    /// - `filled`:本次注入填入并提交;
    /// - `already-filled`:填入前值已一致(幂等,重试/自动填充场景),视为成功;
    /// - `no-form` / `no-login-field`:表单未就绪,由视图重试。
    static func fillCredentialsJS(username: String, password: String) -> String {
        let user = jsonEscaped(username)
        let pass = jsonEscaped(password)
        return """
        (function() {
          var user = \(user);
          var pass = \(pass);
          var u = document.getElementById('login_field');
          var p = document.getElementById('password');
          if (u && p) {
            var already = u.value === user && p.value === pass;
            u.value = user; p.value = pass;
            u.dispatchEvent(new Event('input', {bubbles:true}));
            p.dispatchEvent(new Event('input', {bubbles:true}));
            var form = u.closest('form') || p.closest('form') || document.querySelector('form');
            if (form) {
              if (already) { return 'already-filled'; }
              form.submit(); return 'filled';
            }
            return 'no-form';
          }
          return 'no-login-field';
        })();
        """
    }

    /// 点 GitHub OAuth 授权页的「Authorize」按钮
    static func authorizeJS() -> String {
        """
        (function() {
          var btn = document.querySelector(
            '#js-oauth-authorize-btn, button[name="authorize"], input[type="submit"][name="authorize"]');
          if (btn) { btn.click(); return 'authorized'; }
          return 'no-authorize-btn';
        })();
        """
    }

    /// 填 2FA 验证码(#otp)并提交
    static func fillOTPJS(code: String) -> String {
        let value = jsonEscaped(code)
        return """
        (function() {
          var otp = document.getElementById('otp');
          if (!otp) { return 'no-otp'; }
          otp.value = \(value);
          otp.dispatchEvent(new Event('input', {bubbles:true}));
          var form = otp.closest('form') || document.querySelector('form');
          if (form) { form.submit(); return 'submitted'; }
          return 'no-form';
        })();
        """
    }

    /// 探测内联 2FA 输入框并填码提交(GitHub 登录页内直接渲染 #otp 的形态,路径仍是
    /// /login 或 /sessions):命中 `#otp` / `input[name="otp"]` / `input[autocomplete="one-time-code"]`
    /// 任一选择器 → 填码并提交,返回 `otp-filled`;未命中返回 `no-otp`(视图按现有规则继续/转手动)
    static func probeAndFillOTPJS(code: String) -> String {
        let value = jsonEscaped(code)
        return """
        (function() {
          var otp = document.getElementById('otp')
            || document.querySelector('input[name="otp"]')
            || document.querySelector('input[autocomplete="one-time-code"]');
          if (!otp) { return 'no-otp'; }
          otp.value = \(value);
          otp.dispatchEvent(new Event('input', {bubbles:true}));
          var form = otp.closest('form') || document.querySelector('form');
          if (form) { form.submit(); return 'otp-filled'; }
          return 'no-form';
        })();
        """
    }

    /// 读 document.cookie 中的 auth cookie;未登录且页面有 GitHub 登录入口时点击它(触发 OAuth,仅一次)
    static func readCookiesJS() -> String {
        """
        (function() {
          var m = document.cookie.match(/(?:^|;\\s*)auth=([^;]*)/i);
          var auth = m ? decodeURIComponent(m[1]) : null;
          var out = {auth: auth};
          if (!auth && !window.__opencodeGoClickedSignIn) {
            var link = document.querySelector(
              'a[href*="oauth/authorize"], a[href*="github.com/login/oauth"]');
            if (link) {
              window.__opencodeGoClickedSignIn = true;
              link.click();
              out.clicked = true;
            }
          }
          return JSON.stringify(out);
        })();
        """
    }

    /// 把字符串安全地转义为 JS 字符串字面量(JSON 转义),防止注入
    static func jsonEscaped(_ s: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [s]),
              let array = String(data: data, encoding: .utf8),
              array.count >= 2
        else { return "\"\"" }
        return String(array.dropFirst().dropLast())
    }

    // MARK: - 注入结果分类(JS 返回值 → 状态机动作)与重试参数

    /// 凭据表单注入结果分类
    enum CredentialInjectResult: Equatable {
        /// filled / already-filled:已填并提交(或幂等已填,视为成功)→ 推进状态机
        case success
        /// no-login-field / no-form / 未知 / JS 错误:表单未渲染或注入异常 → 稍后重试
        case retry
    }

    /// 内联 2FA 探测结果分类
    enum OTPProbeResult: Equatable {
        /// otp-filled:已填码并提交 → 进入等待 2FA 结果
        case filled
        /// no-otp / no-form / 未知 / JS 错误:页面无 OTP 输入框 → 按现有规则继续
        case notPresent
    }

    /// 凭据表单注入:首次注入后的重试次数上限(总注入 = 1 + 该值)
    static let credentialInjectMaxRetries = 5
    /// 凭据表单注入重试间隔(毫秒)
    static let credentialInjectRetryDelayMs = 500

    static func classifyCredentialInjectResult(_ jsResult: String?) -> CredentialInjectResult {
        switch jsResult {
        case "filled", "already-filled": return .success
        case "no-login-field", "no-form": return .retry
        case .none: return .retry   // JS 执行失败(导航中断等):按未渲染保守重试
        default: return .retry      // 未知返回值:保守重试
        }
    }

    static func classifyOTPProbeResult(_ jsResult: String?) -> OTPProbeResult {
        switch jsResult {
        case "otp-filled": return .filled
        default: return .notPresent
        }
    }
}
