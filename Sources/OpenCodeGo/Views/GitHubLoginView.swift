import SwiftUI
import WebKit

/// GitHub 自动登录 opencode.ai 的登录 sheet。
///
/// 流程:加载 opencode 工作区页 →(未登录)→ GitHub OAuth → 自动填用户名/密码 →
/// 2FA(有 TOTP 自动填,否则提示手动)→ 自动点「Authorize」→ 跳回 opencode →
/// 轮询捕获 auth cookie(Fe26. 开头)→ 回调父视图填入表单。
///
/// 所有决策由 `GitHubLoginService.decide` 完成;本视图只做 I/O:
/// 导航回调 → decide → 注入 JS / 轮询 cookie;失败/取消都全清 nonPersistent 会话。
struct GitHubLoginView: View {
    @Environment(GitHubAccountStore.self) private var githubStore
    @Environment(\.dismiss) private var dismiss

    let account: GitHubAccount
    let workspaceId: String
    /// 捕获到 opencode auth cookie 后回调(值已取出,之后会清空会话,务必先保存)
    let onAuthCookie: (String) -> Void
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

    private let service = GitHubLoginService()
    private static let loginTimeout: Duration = .seconds(300)

    init(
        account: GitHubAccount,
        workspaceId: String,
        onAuthCookie: @escaping (String) -> Void,
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
            // 兜底清理:sheet 被编程式关闭 / 窗口直接关闭时,成功/取消/超时三条路径都
            // 不会走到 wipeStore,这里全清 nonPersistent 会话,不留 Cookie 残留。
            // removeData 幂等,与其余清理路径重复调用安全。
            wipeStore()
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

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.crop.circle.badge.checkmark")
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 1) {
                Text("用 GitHub 账号自动登录 opencode.ai")
                    .font(.headline)
                Text("\(account.username) · workspace \(workspaceId.trimmingCharacters(in: .whitespacesAndNewlines))")
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
        switch currentStep {
        case .idle: return "准备中…"
        case .loadingLoginPage: return "正在打开 opencode.ai…"
        case .githubLoginForm: return "正在自动完成 GitHub 登录…"
        case .fillingCredentials: return "正在提交登录信息…"
        case .twoFactor: return "正在自动输入两步验证码…"
        case .waitingOAuthRedirect: return "登录成功,正在读取 Cookie…"
        case .done: return "✓ 已获取 Cookie,即将关闭"
        case .failed(let message): return message
        case .needsManualIntervention(let message): return message
        }
    }

    private var stepIcon: String {
        switch currentStep {
        case .done: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .needsManualIntervention: return "person.crop.circle.badge.exclamationmark"
        case .waitingOAuthRedirect: return "arrow.triangle.2.circlepath"
        case .twoFactor: return "number.circle"
        case .githubLoginForm, .fillingCredentials: return "pencil.circle"
        default: return "circle.dotted"
        }
    }

    private var stepColor: Color {
        switch currentStep {
        case .done: return .green
        case .failed: return .red
        case .needsManualIntervention: return .orange
        case .waitingOAuthRedirect: return .blue
        default: return .secondary
        }
    }

    // MARK: - 启动

    @MainActor
    private func start() {
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

    /// workspaceId 有效则直接打开工作区页(未登录会 302 到 GitHub OAuth);无效则打开登录页
    private func loadStartPage(in wv: WKWebView) {
        let ws = workspaceId.trimmingCharacters(in: .whitespacesAndNewlines)
        let url: URL
        if QuotaClient.validateWorkspaceId(ws) == nil {
            url = service.opencodeBaseURL.appendingPathComponent("workspace").appendingPathComponent(ws)
        } else {
            url = service.opencodeBaseURL.appendingPathComponent("login")
        }
        wv.load(URLRequest(url: url))
    }

    // MARK: - 导航决策

    /// 每次页面加载完成(didFinish / 加载失败)后调用:URL + 当前步骤 → 决策 → 注入 JS / 轮询 cookie
    @MainActor
    private func handleNavigation(to url: URL?) {
        guard !succeeded else { return }

        let decision = GitHubLoginService.decide(
            for: url,
            githubUsername: account.username,
            githubPassword: password,
            totpCode: totpCodeNow(),
            state: currentStep)

        // 同一 URL + 同一决策不重复处理(didFinish 可能对同一页面重复回调)
        if decision == lastDecision, lastDecidedURL == url { return }
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
        // 只注入一次:同一 (step, js) 不重复注入(防止表单未渲染时的重复提交)
        if let last = lastExecutedJS, last.step == decision.step, last.js == js { return }
        lastExecutedJS = (decision.step, js)
        // didFinish 后延时注入,防表单尚未渲染
        if let wv = webView {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                wv.evaluateJavaScript(js) { _, error in
                    if let error {
                        NSLog("GitHubLogin: JS 注入失败: %@", error.localizedDescription)
                    }
                }
            }
        }
        // 已注入凭据后进入「提交中」状态,供 decide 识别提交结果
        if decision.step == .githubLoginForm,
           js.contains("login_field") {
            currentStep = .fillingCredentials
        }
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

    /// 从 WKHTTPCookieStore 轮询 opencode auth cookie(HttpOnly 也能读到);命中 → 成功
    @MainActor
    private func pollCookies() {
        guard !succeeded, let webView else { return }
        let cookieStore = webView.configuration.websiteDataStore.httpCookieStore
        cookieStore.getAllCookies { cookies in
            Task { @MainActor in
                guard !self.succeeded else { return }
                if let cookie = GitHubLoginService.extractAuthCookie(from: cookies) {
                    self.succeed(cookie: cookie)
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
        wipeStore()
        currentStep = .done(authCookie: cookie)
        onAuthCookie(cookie)
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
