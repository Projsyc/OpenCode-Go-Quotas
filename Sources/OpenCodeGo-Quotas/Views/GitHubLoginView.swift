import SwiftUI

/// GitHub 自动登录 sheet。
///
/// 流程决策与 WebView I/O 由 `GitHubLoginCoordinator` 负责；本视图只读取
/// 状态、渲染 WebView / 状态栏，并转发“取消”与生命周期事件。
struct GitHubLoginView: View {
    @Environment(GitHubAccountStore.self) private var githubStore
    @Environment(\.dismiss) private var dismiss

    let account: GitHubAccount
    let workspaceId: String
    /// 捕获到 opencode auth cookie 后回调(cookie, 识别到的 workspaceId?)。
    /// 值已取出，之后会清空会话，调用方务必先保存。
    let onAuthCookie: (String, String?) -> Void
    /// 用户主动取消时回调（可选）
    var onCancel: (() -> Void)?

    @State private var coordinator: GitHubLoginCoordinator?

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
        Group {
            if let coordinator {
                content(coordinator)
            } else {
                ProgressView("正在准备登录流程…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 760, height: 600)
        .onAppear(perform: makeAndStartCoordinatorIfNeeded)
        .onDisappear(perform: stopCoordinator)
    }

    private func makeAndStartCoordinatorIfNeeded() {
        guard coordinator == nil else { return }

        var totpSecret: String?
        var oneTimeCode: String?
        switch account.credentialKind {
        case .totpSecret:
            totpSecret = githubStore.credential(for: account)
        case .oneTimeCode:
            oneTimeCode = githubStore.credential(for: account)
        case nil:
            break
        }
        let credentials = GitHubLoginCredentials(
            password: githubStore.password(for: account) ?? "",
            totpSecret: totpSecret,
            oneTimeCode: oneTimeCode)

        let newCoordinator = GitHubLoginCoordinator(
            account: account,
            workspaceId: workspaceId,
            credentials: credentials,
            onAuthCookie: onAuthCookie,
            onCancel: onCancel,
            dismiss: { dismiss() })
        coordinator = newCoordinator
        newCoordinator.start()
    }

    private func stopCoordinator() {
        coordinator?.handleDisappearance()
        coordinator = nil
    }

    private func content(_ coordinator: GitHubLoginCoordinator) -> some View {
        VStack(spacing: 0) {
            header
            webArea(coordinator)
            statusBar(coordinator)
        }
    }

    // MARK: - UI

    private var workspaceCaption: String {
        let workspaceId = workspaceId.trimmingCharacters(in: .whitespacesAndNewlines)
        if workspaceId.isEmpty { return "Workspace ID 登录后自动识别" }
        return "workspace \(workspaceId)"
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

    private func webArea(_ coordinator: GitHubLoginCoordinator) -> some View {
        ZStack {
            if let webView = coordinator.webView {
                LoginWebView(webView: webView)
            } else {
                ProgressView("正在准备浏览器…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.white)
    }

    private func statusBar(_ coordinator: GitHubLoginCoordinator) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: stepIcon(coordinator.currentStep))
                    .foregroundStyle(stepColor(coordinator.currentStep))
                Text(stepText(coordinator))
                    .font(.callout)
                    .foregroundStyle(stepColor(coordinator.currentStep))
                Spacer()
                Button("取消") {
                    coordinator.cancel()
                }
                .keyboardShortcut(.cancelAction)
            }
            if case .needsManualIntervention = coordinator.currentStep {
                Text("操作完成后会自动捕获 Cookie,无需其他操作")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.ultraThinMaterial)
    }

    private func stepText(_ coordinator: GitHubLoginCoordinator) -> String {
        if coordinator.currentStep == .githubLoginForm, coordinator.isWaitingFormRender {
            return "等待表单渲染…"
        }
        return coordinator.currentStep.statusText
    }

    private func stepIcon(_ step: GitHubLoginStep) -> String {
        step.statusIcon
    }

    private func stepColor(_ step: GitHubLoginStep) -> Color {
        switch step.appearance {
        case .normal: return .secondary
        case .working: return .blue
        case .success: return .green
        case .error: return .red
        case .warning: return .orange
        }
    }
}
