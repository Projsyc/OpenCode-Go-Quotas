import Foundation
import Observation
import OSLog
import WebKit

/// GitHub 自动登录的凭据快照。由视图在启动前从 Store/Keychain 读取，
/// Coordinator 不依赖 GitHubAccountStore，便于隔离测试与后续复用。
struct GitHubLoginCredentials: Sendable {
    let password: String
    let totpSecret: String?
    let oneTimeCode: String?
}

/// GitHub 自动登录流程协调器。
///
/// 职责边界：
/// - `GitHubLoginService`：纯 URL + 状态 → `GitHubLoginDecision`
/// - `GitHubLoginCoordinator`：WebView I/O、注入结果解释、Cookie 轮询、超时和生命周期
/// - `GitHubLoginView`：只渲染 Coordinator 的公开状态并转发用户操作
@MainActor
@Observable
final class GitHubLoginCoordinator {
    let account: GitHubAccount
    let workspaceId: String

    private(set) var currentStep: GitHubLoginStep = .idle
    private(set) var webView: WKWebView?
    /// 凭据注入重试中（表单未渲染）：状态保持 `.githubLoginForm`
    private(set) var isWaitingFormRender = false

    private var lastDecision: GitHubLoginDecision?
    private var lastDecidedURL: URL?
    private var lastExecutedJS: (step: GitHubLoginStep, js: String)?
    /// 兼作流程终止标记：成功 / 超时 / 取消后丢弃残留回调。
    private var succeeded = false
    private var pollTimer: Timer?
    private var timeoutTask: Task<Void, Never>?
    private var stageTimeoutTask: Task<Void, Never>?
    private var injectionTask: Task<Void, Never>?
    private var injectSession = 0
    private var flowLog = GitHubLoginService.LoginFlowLog()
    private var flowLogDumped = false
    private var oneTimeCodeExpiryReported = false
    private var reachedGitHubOAuth = false
    private var navigator: LoginNavigator?

    private let credentials: GitHubLoginCredentials
    private let service: GitHubLoginService
    private let logger: Logger
    private let logSink: TextAppendLogSink
    private let onAuthCookie: (String, String?) -> Void
    private let onCancel: (() -> Void)?
    private let dismiss: (() -> Void)?

    nonisolated static let loginTimeout: Duration = .seconds(300)
    nonisolated static let loginStageTimeout: Duration = .seconds(15)
    nonisolated static let loginStageTimeoutMessage = "登录页加载超时(15s),请重试或手动打开授权链接"
    nonisolated static let injectOneShotMaxAttempts = 3
    nonisolated static let injectOneShotInitialDelayMs: UInt64 = 300
    nonisolated static let injectOneShotRetryStepMs: UInt64 = 300

    init(
        account: GitHubAccount,
        workspaceId: String,
        credentials: GitHubLoginCredentials,
        service: GitHubLoginService = GitHubLoginService(),
        logger: Logger = Logger(subsystem: "com.acccan.opencode-go", category: "github-login"),
        logSink: TextAppendLogSink = .login(),
        onAuthCookie: @escaping (String, String?) -> Void,
        onCancel: (() -> Void)? = nil,
        dismiss: (() -> Void)? = nil
    ) {
        self.account = account
        self.workspaceId = workspaceId
        self.credentials = credentials
        self.service = service
        self.logger = logger
        self.logSink = logSink
        self.onAuthCookie = onAuthCookie
        self.onCancel = onCancel
        self.dismiss = dismiss
    }

    func start() {
        resetForNewFlow()

        flowLog.log("flow start")
        let navigator = LoginNavigator { [weak self] url in
            Task { @MainActor [weak self] in
                self?.handleNavigation(to: url)
            }
        }
        self.navigator = navigator

        let webView = WKWebView(frame: .zero, configuration: LoginWebView.makeConfiguration())
        webView.customUserAgent = service.userAgent
        webView.navigationDelegate = navigator
        self.webView = webView

        loadStartPage(in: webView)
        restartTimeout()
        restartStageTimeout()
    }

    func cancel() {
        // 成功后有一秒延迟关闭；期间取消保持 no-op。
        if succeeded, case .done = currentStep { return }
        finish {
            flowLog.log("cancelled")
            onCancel?()
            dismiss?()
        }
    }

    func handleDisappearance() {
        stopPolling()
        stopTimeout()
        stopStageTimeout()
        cancelPendingInjection()
        wipeStore()
        dumpFlowLog()
        navigator = nil
        webView = nil
    }

    func injectOneShotDelaysMs(maxAttempts: Int) -> [UInt64] {
        Self.injectOneShotDelaysMs(maxAttempts: maxAttempts)
    }

    // MARK: - 启动

    private func resetForNewFlow() {
        succeeded = false
        reachedGitHubOAuth = false
        currentStep = .idle
        lastDecision = nil
        lastDecidedURL = nil
        lastExecutedJS = nil
        cancelPendingInjection()
        stopPolling()
        stopTimeout()
        stopStageTimeout()
        flowLog.clear()
        flowLogDumped = false
        oneTimeCodeExpiryReported = false
    }

    /// workspaceId 有效则直接打开工作区页；无效则打开首页并等待自动识别。
    private func loadStartPage(in webView: WKWebView) {
        let workspaceId = workspaceId.trimmingCharacters(in: .whitespacesAndNewlines)
        let url: URL
        if QuotaClient.validateWorkspaceId(workspaceId) == nil {
            url = service.opencodeBaseURL
                .appendingPathComponent("workspace")
                .appendingPathComponent(workspaceId)
        } else {
            url = service.opencodeBaseURL
        }
        webView.load(URLRequest(url: url))
    }

    // MARK: - 导航决策

    func handleNavigation(to url: URL?) {
        guard !succeeded else { return }
        if GitHubLoginService.isGitHubHost(url) {
            reachedGitHubOAuth = true
        }

        let previousStep = currentStep
        let decision = GitHubLoginService.decide(
            for: url,
            githubUsername: account.username,
            githubPassword: credentials.password,
            totpCode: totpCodeNow(),
            state: currentStep)

        if decision == lastDecision, lastDecidedURL == url { return }
        flowLog.log(GitHubLoginService.flowLogLine(url: url, from: previousStep, to: decision.step))
        cancelPendingInjection()
        lastDecision = decision
        lastDecidedURL = url

        if decision.step != currentStep {
            currentStep = decision.step
            if GitHubLoginService.shouldRestartTimeout(oldStep: previousStep, newStep: decision.step) {
                restartTimeout()
            }
            if !GitHubLoginService.isStartupLoadingStep(decision.step) {
                stopStageTimeout()
            }
        }

        if decision.pollCookie {
            startPolling()
        } else {
            stopPolling()
        }

        guard let js = decision.javascript else { return }
        if let last = lastExecutedJS, last.step == decision.step, last.js == js { return }
        lastExecutedJS = (decision.step, js)
        execute(decision.action, js: js, url: url)
    }

    private func execute(_ action: GitHubLoginAction, js: String, url: URL?) {
        switch action {
        case .none:
            break
        case .fillCredentials:
            injectCredentials(js: js, attempt: 0)
        case .probeOTP:
            injectOTPProbe(js: js, url: url)
        case .authorize, .fillOTP, .readCookies:
            injectOneShot(js: js)
        }
    }

    // MARK: - 注入执行

    private func injectOneShot(js: String, attempt: Int = 0) {
        guard !succeeded, let webView else { return }
        let delays = Self.injectOneShotDelaysMs(maxAttempts: Self.injectOneShotMaxAttempts)
        guard !delays.isEmpty else { return }
        injectSession &+= 1
        let session = injectSession
        injectionTask?.cancel()
        let delayMs = delays[min(attempt, delays.count - 1)]
        injectionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(delayMs))
            guard let self, !Task.isCancelled, !self.succeeded, self.webView === webView else { return }
            do {
                let value = try await webView.evaluateJavaScript(js)
                self.handleOneShotInjectResult(value as? String, js: js, attempt: attempt, session: session)
            } catch {
                self.logger.error("GitHubLogin: JS 注入失败: \(error.localizedDescription, privacy: .public)")
                self.handleOneShotInjectResult(nil, js: js, attempt: attempt, session: session)
            }
        }
    }

    private func handleOneShotInjectResult(_ rawResult: String?, js: String, attempt: Int, session: Int) {
        guard !succeeded, session == injectSession else { return }
        guard attempt + 1 < Self.injectOneShotMaxAttempts,
              Self.injectOneShotShouldRetry(rawResult) else { return }
        flowLog.log("inject: \(rawResult ?? "js-error") -> retry(\(attempt + 1)/\(Self.injectOneShotMaxAttempts))")
        injectOneShot(js: js, attempt: attempt + 1)
    }

    nonisolated static func injectOneShotDelaysMs(maxAttempts: Int) -> [UInt64] {
        guard maxAttempts > 0 else { return [] }
        return (0..<maxAttempts).map {
            injectOneShotInitialDelayMs + injectOneShotRetryStepMs * UInt64($0)
        }
    }

    nonisolated static func injectOneShotShouldRetry(_ rawResult: String?) -> Bool {
        switch rawResult {
        case .none:
            return true
        case let s? where s.hasPrefix("{"):
            guard let data = s.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return true }
            let hasAuth = (obj["auth"] as? String)?.isEmpty == false
            let clicked = obj["clicked"] as? Bool ?? false
            return !hasAuth && !clicked
        case "no-authorize-btn", "no-otp", "no-form":
            return true
        default:
            return false
        }
    }

    private func injectCredentials(js: String, attempt: Int) {
        guard !succeeded, let webView else { return }
        injectionTask?.cancel()
        let delayMs = attempt == 0 ? 300 : GitHubLoginService.credentialInjectRetryDelayMs
        injectionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(delayMs))
            guard let self, !Task.isCancelled, !self.succeeded else { return }
            do {
                let value = try await webView.evaluateJavaScript(js)
                self.handleCredentialInjectResult(value as? String, js: js, attempt: attempt)
            } catch {
                self.logger.error("GitHubLogin: 凭据注入失败(将重试): \(error.localizedDescription, privacy: .public)")
                self.handleCredentialInjectResult(nil, js: js, attempt: attempt)
            }
        }
    }

    private func handleCredentialInjectResult(_ rawResult: String?, js: String, attempt: Int) {
        guard !succeeded, currentStep == .githubLoginForm else { return }
        switch GitHubLoginService.classifyCredentialInjectResult(rawResult) {
        case .success:
            flowLog.log("inject: \(rawResult ?? "js-error") -> success")
            isWaitingFormRender = false
            currentStep = .fillingCredentials
            restartTimeout()
        case .retry:
            guard attempt < GitHubLoginService.credentialInjectMaxRetries else {
                flowLog.log("inject: retry 耗尽(共 \(attempt + 1) 次) -> 转手动")
                transitionToManual("页面未按预期渲染,请在窗口中手动登录")
                return
            }
            flowLog.log("inject: \(rawResult ?? "js-error") -> retry(\(attempt + 1)/\(GitHubLoginService.credentialInjectMaxRetries))")
            isWaitingFormRender = true
            injectCredentials(js: js, attempt: attempt + 1)
        }
    }

    private func injectOTPProbe(js: String, url: URL?) {
        guard !succeeded, let webView else { return }
        injectionTask?.cancel()
        injectionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled, !self.succeeded else { return }
            do {
                let value = try await webView.evaluateJavaScript(js)
                self.handleOTPProbeResult(value as? String, url: url)
            } catch {
                self.logger.error("GitHubLogin: 内联 2FA 探测注入失败: \(error.localizedDescription, privacy: .public)")
                self.handleOTPProbeResult(nil, url: url)
            }
        }
    }

    private func handleOTPProbeResult(_ rawResult: String?, url: URL?) {
        guard !succeeded, GitHubLoginService.isCredentialSubmittedState(currentStep) else { return }
        switch GitHubLoginService.classifyOTPProbeResult(rawResult) {
        case .filled:
            flowLog.log("otp-probe: \(rawResult ?? "js-error") -> filled")
            currentStep = .twoFactor
            restartTimeout()
        case .notPresent:
            flowLog.log("otp-probe: \(rawResult ?? "js-error") -> notPresent")
            let path = url?.path.lowercased() ?? ""
            if path.contains("/login") || path.contains("/session") {
                transitionToManual("GitHub 登录未成功,请在窗口中手动登录", logPrefix: "otp-probe: 登录页无内联 OTP -> 转手动")
            }
        }
    }

    private func transitionToManual(_ message: String, logPrefix: String? = nil) {
        if let logPrefix {
            flowLog.log(logPrefix)
        }
        dumpFlowLog()
        isWaitingFormRender = false
        currentStep = .needsManualIntervention(message)
        restartTimeout()
    }

    private func cancelPendingInjection() {
        injectSession &+= 1
        injectionTask?.cancel()
        injectionTask = nil
        isWaitingFormRender = false
    }

    private func totpCodeNow() -> String? {
        if let oneTimeCode = credentials.oneTimeCode {
            if GitHubLoginService.isOneTimeCodeExpired(since: account.lastCodeAt, now: Date()) {
                if !oneTimeCodeExpiryReported {
                    flowLog.log("onetime-code 已过期(不再自动填入)")
                    oneTimeCodeExpiryReported = true
                }
                return nil
            }
            return oneTimeCode
        }
        if let secret = credentials.totpSecret {
            return TOTPGenerator.generate(secretBase32: secret)
        }
        return nil
    }

    // MARK: - Cookie 轮询

    private func startPolling() {
        guard pollTimer == nil, !succeeded else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pollCookies()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func pollCookies() {
        guard !succeeded, let webView else { return }
        let cookieStore = webView.configuration.websiteDataStore.httpCookieStore
        cookieStore.getAllCookies { cookies in
            Task { @MainActor [weak self] in
                guard let self, !self.succeeded else { return }
                if let cookie = GitHubLoginService.extractAuthCookie(
                    from: cookies, oauthStarted: self.reachedGitHubOAuth) {
                    self.flowLog.log("cookie: poll hit")
                    self.succeed(cookie: cookie)
                } else if !self.reachedGitHubOAuth,
                          GitHubLoginService.extractAuthCookie(from: cookies, oauthStarted: true) != nil {
                    self.flowLog.log("cookie: anonymous placeholder before OAuth, ignoring")
                }
            }
        }
    }

    // MARK: - 成功 / 失败 / 超时

    private func succeed(cookie: String) {
        guard !succeeded else { return }
        succeeded = true
        stopPolling()
        stopTimeout()
        stopStageTimeout()
        flowLog.log("success: cookie captured")
        dumpFlowLog()
        wipeStore()
        currentStep = .done(authCookie: cookie)
        onAuthCookie(cookie, GitHubLoginService.workspaceId(from: webView?.url))
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            self?.dismiss?()
        }
    }

    private func finish(actions: () -> Void) {
        succeeded = true
        stopPolling()
        stopTimeout()
        stopStageTimeout()
        actions()
        wipeStore()
    }

    private func restartTimeout() {
        stopTimeout()
        timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.loginTimeout)
            guard let self, !Task.isCancelled, !self.succeeded else { return }
            self.stopPolling()
            self.stopStageTimeout()
            self.succeeded = true
            self.flowLog.log("timeout: 300s 无进展")
            self.dumpFlowLog()
            self.wipeStore()
            self.currentStep = .failed("登录超时(5 分钟无进展),请取消后重试")
        }
    }

    private func stopTimeout() {
        timeoutTask?.cancel()
        timeoutTask = nil
    }

    private func restartStageTimeout() {
        stopStageTimeout()
        stageTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.loginStageTimeout)
            guard let self, !Task.isCancelled, !self.succeeded else { return }
            guard GitHubLoginService.isStartupLoadingStep(self.currentStep) else { return }
            self.stopPolling()
            self.stopTimeout()
            self.succeeded = true
            self.flowLog.log("stage-timeout: 15s 未到达登录页")
            self.dumpFlowLog()
            self.wipeStore()
            self.currentStep = .failed(Self.loginStageTimeoutMessage)
        }
    }

    private func stopStageTimeout() {
        stageTimeoutTask?.cancel()
        stageTimeoutTask = nil
    }

    private func wipeStore() {
        guard let webView else { return }
        webView.configuration.websiteDataStore.removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince: .distantPast) { }
    }

    private func dumpFlowLog() {
        guard !flowLogDumped else { return }
        flowLogDumped = true
        logger.info("login flow: \(self.flowLog.timelineText, privacy: .public)")
        logSink.append(flowLog.timelineText)
    }
}

/// WKWebView 导航代理：把页面加载完成 / 失败统一交给 Coordinator 决策。
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
