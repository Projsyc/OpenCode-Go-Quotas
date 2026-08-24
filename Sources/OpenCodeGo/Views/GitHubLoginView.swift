import os
import SwiftUI
import WebKit

/// GitHub 自动登录 opencode.ai 的登录 sheet。
///
/// 流程:加载 opencode 工作区页 →(未登录)→ GitHub OAuth → 自动填用户名/密码 →
/// 2FA(有 TOTP 自动填,否则提示手动;登录页内直接渲染的 #otp 内联形态也会自动填)→
/// 自动点「Authorize」→ 跳回 opencode →
/// 轮询捕获 auth cookie(Fe26. 开头)→ 回调父视图填入表单。
///
/// 所有决策由 `GitHubLoginService.decide` 完成;本视图只做 I/O:
/// 导航回调 → decide → 注入 JS / 轮询 cookie;失败/取消都全清 nonPersistent 会话。
struct GitHubLoginView: View {
    @Environment(GitHubAccountStore.self) private var githubStore
    @Environment(\.dismiss) private var dismiss

    let account: GitHubAccount
    let workspaceId: String
    /// 捕获到 opencode auth cookie 后回调(cookie, 识别到的 workspaceId?;
    /// 值已取出,之后会清空会话,务必先保存)
    let onAuthCookie: (String, String?) -> Void
    /// 用户主动取消时回调(可选)
    var onCancel: (() -> Void)?

    // 凭据(从 Keychain 读取,仅存内存)
    @State private var password = ""
    @State private var totpSecret: String?
    @State private var oneTimeCode: String?

    // WebView 与导航
    // 注:onDisappear 必须显式置空这两者,断开「navigator → onFinish 闭包 → self →
    // @State 存储 → navigator/webView」的强环,否则 WKWebView 在 sheet 关闭后永不释放
    // (每次打开泄漏一个,含 WebContent 进程)。详见 onDisappear 注释。
    @State private var webView: WKWebView?
    @State private var navigator: LoginNavigator?

    // 状态机
    @State private var currentStep: GitHubLoginStep = .idle
    @State private var lastDecision: GitHubLoginDecision?
    @State private var lastDecidedURL: URL?
    @State private var lastExecutedJS: (step: GitHubLoginStep, js: String)?
    @State private var succeeded = false
    @State private var pollTimer: Timer?
    @State private var timeoutTask: Task<Void, Never>?
    /// 在途注入(凭据重试 / 内联 OTP 探测):新决策或页面消失时取消,防止旧页面上下文误注入
    @State private var injectionTask: Task<Void, Never>?
    /// 凭据注入重试中(表单未渲染):状态保持 .githubLoginForm,状态栏显示「等待表单渲染…」
    @State private var isWaitingFormRender = false
    /// 流程诊断时间线(不含凭据),失败/取消/超时时写入统一日志
    @State private var flowLog = GitHubLoginService.LoginFlowLog()
    /// 时间线已写入日志(避免同一流程重复输出,onDisappear 幂等兜底)
    @State private var flowLogDumped = false
    /// 是否已到达 GitHub OAuth:opencode.ai 对**任何匿名访问**都会下发 auth=Fe26.
    /// 开头的占位 cookie,未经过 GitHub 就把 Fe26. 判定为登录成功会捕获占位 → 虚假成功。
    /// 门槛:导航曾到达 github.com(含子域,登录/OAuth 授权/2FA 页)才允许采信 auth cookie
    @State private var reachedGitHubOAuth = false

    /// 统一日志(subsystem 固定,用户可用 `log show --predicate 'subsystem == "com.acccan.opencode-go"'` 提取)
    private let logger = Logger(subsystem: "com.acccan.opencode-go", category: "github-login")
    private let service = GitHubLoginService()
    private static let loginTimeout: Duration = .seconds(300)

    init(
        account: GitHubAccount,
        workspaceId: String,
        onAuthCookie: @escaping (String, String?) -> Void,
        onCancel: (() -> Void)? = nil
    ) {
        self.account = account
        self.workspaceId = workspaceId
        self.onAuthCookie = onAuthCookie
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            webArea
            statusBar
        }
        .frame(width: 760, height: 600)
        .onAppear { start() }
        .onDisappear {
            stopPolling()
            stopTimeout()
            cancelPendingInjection()
            // 兜底清理:sheet 被编程式关闭 / 窗口直接关闭时,成功/取消/超时三条路径都
            // 不会走到 wipeStore,这里全清 nonPersistent 会话,不留 Cookie 残留。
            // removeData 幂等,与其余清理路径重复调用安全。
            wipeStore()
            // 窗口直接关闭等未走 cancel()/超时的路径也留痕(dumpFlowLog 幂等,
            // 成功/取消/超时已输出过的不会重复)
            dumpFlowLog()
            // 断环(WebView 泄漏修复):强引用链为
            //   @State 存储 → navigator → onFinish 闭包 → self(struct) → @State 存储
            //  → { navigator, webView }
            // 而 WKWebView 对 navigationDelegate 是弱引用(WebKit 系统属性),故唯一
            // 强环收敛在 @State 存储与 navigator 之间。置空后:
            //   · navigator 无任何强引用 → 立即释放,其弱委托同步置 nil,不再回调,
            //     handleNavigation 不会被调用,无需 Coordinator 收拢逻辑;
            //   · webView 不再被存储持有,随 SwiftUI 视图移除(NSViewRepresentable
            //     释放)而释放。
            // 不置空的话 sheet 关闭后 WKWebView 永不释放,每次打开泄漏一个。
            navigator = nil
            webView = nil
        }
    }

    // MARK: - UI

    /// header 里 workspace 文本:为空/无效时显示占位,提示登录后自动识别
    private var workspaceCaption: String {
        let ws = workspaceId.trimmingCharacters(in: .whitespacesAndNewlines)
        if ws.isEmpty { return "Workspace ID 登录后自动识别" }
        return "workspace \(ws)"
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.crop.circle.badge.checkmark")
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 1) {
                Text("用 GitHub 账号自动登录 opencode.ai")
                    .font(.headline)
                Text("\(account.username) · \(workspaceCaption)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
    }

    private var webArea: some View {
        ZStack {
            if let webView {
                LoginWebView(webView: webView)
            } else {
                ProgressView("正在准备浏览器…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.white)
    }

    private var statusBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: stepIcon)
                    .foregroundStyle(stepColor)
                Text(stepText)
                    .font(.callout)
                    .foregroundStyle(stepColor)
                Spacer()
                Button("取消") { cancel() }
                    .keyboardShortcut(.cancelAction)
            }
            if case .needsManualIntervention = currentStep {
                Text("操作完成后会自动捕获 Cookie,无需其他操作")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.ultraThinMaterial)
    }

    private var stepText: String {
        // 凭据注入重试中(表单未渲染)的特殊文案;其余文案数据收敛在 GitHubLoginStep.statusText
        if currentStep == .githubLoginForm, isWaitingFormRender {
            return "等待表单渲染…"
        }
        return currentStep.statusText
    }

    private var stepIcon: String {
        currentStep.statusIcon
    }

    private var stepColor: Color {
        // service 层只给语义标签,颜色映射留在视图层
        switch currentStep.appearance {
        case .normal: return .secondary
        case .working: return .blue
        case .success: return .green
        case .error: return .red
        case .warning: return .orange
        }
    }

    // MARK: - 启动

    @MainActor
    private func start() {
        flowLog.log("flow start")
        flowLogDumped = false
        fetchCredentials()
        let navigator = LoginNavigator { url in
            Task { @MainActor in
                self.handleNavigation(to: url)
            }
        }
        self.navigator = navigator

        let wv = WKWebView(frame: .zero, configuration: LoginWebView.makeConfiguration())
        wv.customUserAgent = service.userAgent
        wv.navigationDelegate = navigator
        webView = wv

        loadStartPage(in: wv)
        restartTimeout()
    }

    private func fetchCredentials() {
        password = githubStore.password(for: account) ?? ""
        switch account.credentialKind {
        case .totpSecret:
            totpSecret = githubStore.credential(for: account)
        case .oneTimeCode:
            oneTimeCode = githubStore.credential(for: account)
        case nil:
            break
        }
    }

    /// workspaceId 有效则直接打开工作区页(未登录会 302 到 GitHub OAuth);
    /// 为空/无效则打开 opencode.ai 首页:未登录时 SPA 前端自行跳转 GitHub OAuth,
    /// 登录成功后由 opencode 前端跳回工作区页(URL 含 /workspace/{ws},自动识别回传)。
    /// 其余逻辑(decide / 注入 / 轮询)不受起点影响。
    private func loadStartPage(in wv: WKWebView) {
        let ws = workspaceId.trimmingCharacters(in: .whitespacesAndNewlines)
        let url: URL
        if QuotaClient.validateWorkspaceId(ws) == nil {
            url = service.opencodeBaseURL.appendingPathComponent("workspace").appendingPathComponent(ws)
        } else {
            url = service.opencodeBaseURL
        }
        wv.load(URLRequest(url: url))
    }

    // MARK: - 导航决策

    /// 每次页面加载完成(didFinish / 加载失败)后调用:URL + 当前步骤 → 决策 → 注入 JS / 轮询 cookie
    @MainActor
    private func handleNavigation(to url: URL?) {
        guard !succeeded else { return }
        // 门槛:到达过 github.com(含子域)才允许把 auth cookie 判定为登录成功;
        // 未到达前的 Fe26. cookie 是 opencode 对匿名访问下发的占位,轮询时必须忽略(见 pollCookies)
        if isGitHubHost(url) {
            reachedGitHubOAuth = true
        }
        let previousStep = currentStep

        let decision = GitHubLoginService.decide(
            for: url,
            githubUsername: account.username,
            githubPassword: password,
            totpCode: totpCodeNow(),
            state: currentStep)

        // 同一 URL + 同一决策不重复处理(didFinish 可能对同一页面重复回调)
        if decision == lastDecision, lastDecidedURL == url { return }
        // 诊断打点:URL 域名 + 步骤转换(flowLogLine 只取域名与枚举名,不含凭据)
        flowLog.log(GitHubLoginService.flowLogLine(url: url, from: previousStep, to: decision.step))
        // 新决策:页面上下文已变化,取消上一轮未完成的注入(凭据重试 / OTP 探测)
        cancelPendingInjection()
        lastDecision = decision
        lastDecidedURL = url

        if decision.step != currentStep {
            currentStep = decision.step
            restartTimeout()
        }
        if decision.pollCookie {
            startPolling()
        } else {
            stopPolling()
        }

        guard let js = decision.javascript else { return }
        // 只注入一次:同一 (step, js) 不重复注入(防止表单未渲染时的重复提交);
        // 凭据注入的受控重试走 injectCredentials,不受此去重约束
        if let last = lastExecutedJS, last.step == decision.step, last.js == js { return }
        lastExecutedJS = (decision.step, js)

        // 凭据表单注入:确认成功(JS 返回 filled / already-filled)后才推进到
        // .fillingCredentials;no-login-field → 保持 .githubLoginForm 并重试
        if js.contains("login_field") {
            injectCredentials(js: js, attempt: 0)
            return
        }
        // 内联 2FA 探测:结果由 handleOTPProbeResult 解释(命中 → 填码提交;
        // 未命中 → 登录页转手动,其他页面按现有规则继续)
        if decision.isOTPProbe {
            injectOTPProbe(js: js, url: url)
            return
        }
        // 其余注入(授权点击 / two-factor 页 OTP / 读 cookie):一次性注入,结果不解释
        injectOneShot(js: js)
    }

    /// URL host 是否为 github.com 或其子域(与 GitHubLoginService.decide 内部判断一致)
    private func isGitHubHost(_ url: URL?) -> Bool {
        guard let host = url?.host?.lowercased() else { return false }
        return host == "github.com" || host.hasSuffix(".github.com")
    }

    // MARK: - 注入执行

    /// 一次性注入:didFinish 后延时 300ms(防表单尚未渲染),结果不解释
    @MainActor
    private func injectOneShot(js: String) {
        guard let wv = webView else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            wv.evaluateJavaScript(js) { _, error in
                if let error {
                    NSLog("GitHubLogin: JS 注入失败: %@", error.localizedDescription)
                }
            }
        }
    }

    /// 凭据表单注入(带重试,修复「注入前推进状态导致卡死」):
    /// 首次 didFinish 后 300ms 注入;JS 返回 filled / already-filled → 推进 .fillingCredentials;
    /// no-login-field / no-form / JS 错误 → 保持 .githubLoginForm,间隔 500ms 重试,
    /// 最多 credentialInjectMaxRetries 次重试;耗尽 → needsManualIntervention。
    /// 5 分钟总超时仍由 restartTimeout 兜底;新决策到达时由 handleNavigation 取消本轮注入。
    @MainActor
    private func injectCredentials(js: String, attempt: Int) {
        guard !succeeded, let wv = webView else { return }
        injectionTask?.cancel()
        let delayMs = attempt == 0 ? 300 : GitHubLoginService.credentialInjectRetryDelayMs
        injectionTask = Task { @MainActor [self] in
            try? await Task.sleep(for: .milliseconds(delayMs))
            guard !Task.isCancelled, !self.succeeded else { return }
            wv.evaluateJavaScript(js) { value, error in
                if let error {
                    NSLog("GitHubLogin: 凭据注入失败(将重试): %@", error.localizedDescription)
                }
                Task { @MainActor in
                    self.handleCredentialInjectResult(value as? String, js: js, attempt: attempt)
                }
            }
        }
    }

    @MainActor
    private func handleCredentialInjectResult(_ rawResult: String?, js: String, attempt: Int) {
        guard !succeeded, currentStep == .githubLoginForm else { return }
        switch GitHubLoginService.classifyCredentialInjectResult(rawResult) {
        case .success:
            // 确认注入成功后才推进状态(修复①:不再提前置位 .fillingCredentials)
            flowLog.log("inject: \(rawResult ?? "js-error") -> success")
            isWaitingFormRender = false
            currentStep = .fillingCredentials
        case .retry:
            guard attempt < GitHubLoginService.credentialInjectMaxRetries else {
                // 5 次重试后仍无表单:转手动而不是死等 5 分钟超时
                flowLog.log("inject: retry 耗尽(共 \(attempt + 1) 次) -> 转手动")
                dumpFlowLog()
                isWaitingFormRender = false
                currentStep = .needsManualIntervention("页面未按预期渲染,请在窗口中手动登录")
                return
            }
            flowLog.log("inject: \(rawResult ?? "js-error") -> retry(\(attempt + 1)/\(GitHubLoginService.credentialInjectMaxRetries))")
            isWaitingFormRender = true
            injectCredentials(js: js, attempt: attempt + 1)
        }
    }

    /// 内联 2FA 探测注入:github.com 任意页面、凭据已提交后执行一次(不依赖 URL 路径),
    /// 命中 #otp 等选择器 → 自动填码提交;结果由 handleOTPProbeResult 解释
    @MainActor
    private func injectOTPProbe(js: String, url: URL?) {
        guard !succeeded, let wv = webView else { return }
        injectionTask?.cancel()
        injectionTask = Task { @MainActor [self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, !self.succeeded else { return }
            wv.evaluateJavaScript(js) { value, error in
                if let error {
                    NSLog("GitHubLogin: 内联 2FA 探测注入失败: %@", error.localizedDescription)
                }
                Task { @MainActor in
                    self.handleOTPProbeResult(value as? String, url: url)
                }
            }
        }
    }

    @MainActor
    private func handleOTPProbeResult(_ rawResult: String?, url: URL?) {
        guard !succeeded else { return }
        switch GitHubLoginService.classifyOTPProbeResult(rawResult) {
        case .filled:
            // 已填码并提交 → 进入等待 2FA 结果阶段
            flowLog.log("otp-probe: \(rawResult ?? "js-error") -> filled")
            currentStep = .twoFactor
        case .notPresent:
            flowLog.log("otp-probe: \(rawResult ?? "js-error") -> notPresent")
            // 未命中:URL 是登录/会话页且凭据已提交 → 无内联 2FA = 登录未成功 → 转手动;
            // 其他 github 页面 → 按现有规则继续(不打断)
            let path = url?.path.lowercased() ?? ""
            if path.contains("/login") || path.contains("/session") {
                flowLog.log("otp-probe: 登录页无内联 OTP -> 转手动")
                dumpFlowLog()
                currentStep = .needsManualIntervention("GitHub 登录未成功,请在窗口中手动登录")
            }
        }
    }

    /// 取消在途注入(新决策 / onDisappear)
    private func cancelPendingInjection() {
        injectionTask?.cancel()
        injectionTask = nil
        isWaitingFormRender = false
    }

    /// 每次决策时取当前可用验证码:TOTP 每次现算(30s 滚动),一次性码用已保存值
    private func totpCodeNow() -> String? {
        if let oneTimeCode { return oneTimeCode }
        if let secret = totpSecret {
            return TOTPGenerator.generate(secretBase32: secret)
        }
        return nil
    }

    // MARK: - Cookie 轮询

    private func startPolling() {
        guard pollTimer == nil, !succeeded else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { _ in
            Task { @MainActor in
                self.pollCookies()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// 从 WKHTTPCookieStore 轮询 opencode auth cookie(HttpOnly 也能读到);命中 → 成功。
    /// 门槛(修复):opencode.ai 对匿名访问立即下发 auth=Fe26. 占位 cookie,
    /// 未到达 GitHub OAuth(reachedGitHubOAuth)前命中的一律按占位忽略,继续轮询,
    /// 避免「自动登录在启动 1.5 秒后虚假成功、捕获占位 cookie」。
    @MainActor
    private func pollCookies() {
        guard !succeeded, let webView else { return }
        let cookieStore = webView.configuration.websiteDataStore.httpCookieStore
        cookieStore.getAllCookies { cookies in
            Task { @MainActor in
                guard !self.succeeded else { return }
                if let cookie = GitHubLoginService.extractAuthCookie(
                    from: cookies, oauthStarted: self.reachedGitHubOAuth) {
                    self.flowLog.log("cookie: poll hit")
                    self.succeed(cookie: cookie)
                } else if !self.reachedGitHubOAuth,
                          GitHubLoginService.extractAuthCookie(from: cookies, oauthStarted: true) != nil {
                    // 命中了 Fe26. 前缀但尚未到 GitHub —— 匿名占位,忽略并继续轮询
                    self.flowLog.log("cookie: anonymous placeholder before OAuth, ignoring")
                }
            }
        }
    }

    // MARK: - 成功 / 失败 / 取消

    @MainActor
    private func succeed(cookie: String) {
        guard !succeeded else { return }
        succeeded = true
        stopPolling()
        stopTimeout()
        flowLog.log("success: cookie captured")
        dumpFlowLog()
        wipeStore()
        currentStep = .done(authCookie: cookie)
        // 登录成功后当前 URL 通常已回到 /workspace/{ws}:把识别到的 ws 随回调带出,
        // 供父视图回填表单/自动保存(ws 为 nil 时由父视图提示手动填写)
        onAuthCookie(cookie, GitHubLoginService.workspaceId(from: webView?.url))
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            dismiss()
        }
    }

    @MainActor
    private func cancel() {
        guard !succeeded else { return }
        stopPolling()
        stopTimeout()
        flowLog.log("cancelled")
        dumpFlowLog()
        wipeStore()
        onCancel?()
        dismiss()
    }

    /// 超时(5 分钟无进展)→ failed,用户可取消后重试
    private func restartTimeout() {
        stopTimeout()
        timeoutTask = Task { @MainActor in
            try? await Task.sleep(for: Self.loginTimeout)
            guard !Task.isCancelled, !succeeded else { return }
            stopPolling()
            flowLog.log("timeout: 300s 无进展")
            dumpFlowLog()
            wipeStore()
            currentStep = .failed("登录超时(5 分钟无进展),请取消后重试")
        }
    }

    private func stopTimeout() {
        timeoutTask?.cancel()
        timeoutTask = nil
    }

    /// 全清 nonPersistent 会话(Cookie/缓存),不留痕;成功与失败/取消都会调用
    private func wipeStore() {
        guard let webView else { return }
        webView.configuration.websiteDataStore.removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince: .distantPast) { }
    }

    /// 把流程时间线写入统一日志(每流程最多一次)。
    /// 时间线条目已按 GitHubLoginService.LoginFlowLog 红线过滤凭据(只含域名/步骤名/
    /// 分类结果),整行标 public 以便 `log show --predicate 'subsystem == "com.acccan.opencode-go"'`
    /// 在真机/本机均可采集;失败/取消/超时/转手动/关闭窗口时调用。
    private func dumpFlowLog() {
        guard !flowLogDumped else { return }
        flowLogDumped = true
        logger.info("login flow: \(self.flowLog.timelineText, privacy: .public)")
    }
}

/// WKWebView 导航代理:把「页面加载完成 / 失败」转发给登录流程做决策
private final class LoginNavigator: NSObject, WKNavigationDelegate {
    let onFinish: (URL?) -> Void

    init(onFinish: @escaping (URL?) -> Void) {
        self.onFinish = onFinish
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        onFinish(webView.url)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        onFinish(webView.url)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        onFinish(webView.url)
    }
}
