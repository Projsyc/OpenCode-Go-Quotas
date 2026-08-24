import SwiftUI

/// 添加 / 编辑账号:支持从 Chrome / Edge 一键导入 Cookie,也可手动填写
struct AddEditAccountView: View {
    @Environment(AccountStore.self) private var store
    @Environment(GitHubAccountStore.self) private var githubStore
    @Environment(\.dismiss) private var dismiss

    let account: Account?

    @State private var name = ""
    @State private var workspaceId = ""
    @State private var authCookie = ""
    @State private var notes = ""
    @State private var showCookie = false
    @State private var errorText: String?
    @FocusState private var focusedField: Field?
    /// 填入 Cookie 后高亮描边(1.5s 淡出)
    @State private var cookieFlash = false

    // 浏览器导入
    @State private var importBrowser: BrowserCookieService.Browser = .chrome
    @State private var candidates: [BrowserCookieService.Candidate] = []
    @State private var importMessage: String?
    @State private var importChecked = false
    /// 首次出现时已自动扫描过一次;再次出现且未点「重新检测」则跳过自动扫描
    @State private var autoScanned = false
    @State private var hoveredCandidate: String?

    // GitHub 账号自动登录
    @State private var selectedGitHubAccountID: UUID?
    @State private var showGitHubLogin = false
    @State private var loginMessage: String?

    private enum Field: Hashable {
        case cookie
    }

    private enum FieldStatus: Equatable {
        case idle(text: String)
        case valid(text: String)
        case invalid(text: String)
    }

    private var isEditing: Bool { account != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(isEditing ? "编辑账号" : "添加账号")
                    .font(.title2.bold())
                Spacer()
                SVGPath(data: SVGBuiltIn.sparkle)
                    .fill(Color.purple.opacity(0.35))
                    .frame(width: 18, height: 18)
            }

            importSection

            githubLoginSection

            Form {
                TextField("账号名称（如：主账号）", text: $name)
                    .textFieldStyle(.roundedBorder)

                TextField("Workspace ID", text: $workspaceId)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.none)
                    .autocorrectionDisabled()
                statusRow(workspaceStatus)

                HStack {
                    Group {
                        if showCookie {
                            TextField("Auth Cookie", text: $authCookie)
                        } else {
                            SecureField("Auth Cookie", text: $authCookie)
                        }
                    }
                    .font(.system(.body, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .cookie)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.blue, lineWidth: 1.5)
                            .opacity(cookieFlash ? 1 : 0))

                    Button {
                        showCookie.toggle()
                    } label: {
                        Image(systemName: showCookie ? "eye.slash" : "eye")
                    }
                    .help(showCookie ? "隐藏 Cookie" : "显示 Cookie")
                }
                statusRow(cookieStatus)

                TextField("备注（可选）", text: $notes)
                    .textFieldStyle(.roundedBorder)
            }
            .formStyle(.columns)

            if let errorText {
                Label(errorText, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isEditing ? "保存" : "添加") {
                    do {
                        try save()
                        dismiss()
                    } catch {
                        errorText = error.localizedDescription
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
        .onAppear {
            prefill()
            if selectedGitHubAccountID == nil, let first = githubStore.accounts.first {
                selectedGitHubAccountID = first.id
            }
        }
        .task {
            guard !autoScanned else { return }
            autoScanned = true
            await detect()
        }
        .onChange(of: githubStore.accounts) { _, accounts in
            if let sel = selectedGitHubAccountID, !accounts.contains(where: { $0.id == sel }) {
                selectedGitHubAccountID = accounts.first?.id
            }
        }
        .sheet(isPresented: $showGitHubLogin) {
            if let githubAccount = githubStore.accounts.first(where: { $0.id == selectedGitHubAccountID }) {
                GitHubLoginView(
                    account: githubAccount,
                    workspaceId: workspaceId,
                    onAuthCookie: { cookie, ws in
                        handleAuthCookie(cookie, workspaceId: ws, githubUsername: githubAccount.username)
                    },
                    onCancel: {
                        loginMessage = nil
                    }
                )
            }
        }
    }

    // MARK: - 浏览器导入

    private var importSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "safari")
                    .foregroundStyle(.blue)
                Text("从浏览器自动获取")
                    .font(.callout.weight(.semibold))
                Spacer()
                Picker("", selection: $importBrowser) {
                    ForEach(BrowserCookieService.Browser.allCases) { b in
                        Text(b.rawValue).tag(b)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
                .onChange(of: importBrowser) { _, _ in
                    importMessage = nil
                }
                Button("重新检测") {
                    Task { await detect(force: true) }
                }
                .controlSize(.small)
            }

            if let importMessage {
                Label(importMessage, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if candidates.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(importChecked ? "未找到 opencode.ai 的 auth Cookie" : "正在检测…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            } else {
                ForEach(candidates) { candidate in
                    HStack(spacing: 10) {
                        Image(systemName: candidate.value.hasPrefix("Fe26.") ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(candidate.value.hasPrefix("Fe26.") ? .green : .orange)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(candidate.browser.rawValue) · \(candidate.profileName) · \(candidate.cookieName)")
                                .font(.caption.weight(.medium))
                            Text(expiryText(candidate))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("填入") {
                            authCookie = candidate.value
                            importMessage = "已填入表单 ✅"
                            flashCookieField()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(8)
                    .contentShape(RoundedRectangle(cornerRadius: 10))
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.primary.opacity(hoveredCandidate == candidate.id ? 0.08 : 0.04)))
                    .onHover { hovering in
                        hoveredCandidate = hovering ? candidate.id : nil
                    }
                    .animation(.easeOut(duration: 0.15), value: hoveredCandidate)
                }
            }

            Text("读取 Keychain 加密口令时系统可能弹出一次授权提示；Cookie 仅保存在本机 Keychain，不会上传")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08))))
    }

    // MARK: - GitHub 账号自动登录

    /// 用已导入的 GitHub 账号在应用内完成 opencode.ai 登录并捕获 auth Cookie
    private var githubLoginSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .foregroundStyle(.purple)
                Text("用 GitHub 账号自动登录")
                    .font(.callout.weight(.semibold))
                Spacer()
                if !githubStore.accounts.isEmpty {
                    Picker("", selection: $selectedGitHubAccountID) {
                        ForEach(githubStore.accounts) { a in
                            Text(a.username).tag(Optional(a.id))
                        }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                }
            }

            if githubStore.accounts.isEmpty {
                Label("请先在 GitHub 账号页导入账号", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button {
                    loginMessage = nil
                    showGitHubLogin = true
                } label: {
                    Label("开始自动登录", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedGitHubAccountID == nil)
                .help("在窗口内自动完成 GitHub 登录并捕获 opencode auth Cookie；Workspace ID 可留空，登录成功后自动识别")
            }

            if let loginMessage {
                Label(loginMessage, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }

            Text("需要所选账号的密码;若开启两步验证,请先在该账号中保存 TOTP 密钥。Workspace ID 可先留空,登录成功后自动识别并填入")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08))))
    }

    private func expiryText(_ candidate: BrowserCookieService.Candidate) -> String {
        var parts = ["\(candidate.value.count) 字符"]
        if candidate.value.hasPrefix("Fe26.") {
            parts.append("格式 ✓")
        } else {
            parts.append("非 Fe26. 格式")
        }
        if let expiresAt = candidate.expiresAt {
            parts.append("过期 \(expiresAt.formatted(date: .abbreviated, time: .shortened))")
        }
        return parts.joined(separator: " · ")
    }

    private func detect(force: Bool = false) async {
        if candidates.isEmpty == false && !force { return }
        importChecked = false
        importMessage = nil
        let browser = importBrowser
        // 扫描含 profile 枚举 + PBKDF2 解密,可能耗时;放后台执行避免卡主线程
        let all = await Task.detached(priority: .userInitiated) {
            BrowserCookieService.findOpenCodeAuthCookies()
        }.value
        candidates = all.filter { $0.browser == browser }
        importChecked = true
        if candidates.isEmpty {
            importMessage = "没有在 \(browser.rawValue) 中找到 opencode.ai 的 auth Cookie，可手动填写"
        }
    }

    // MARK: - 实时校验

    /// 输入为空时保持中性提示;非空则即时校验(✓ / ✗)
    private var workspaceStatus: FieldStatus {
        let ws = workspaceId.trimmingCharacters(in: .whitespacesAndNewlines)
        if ws.isEmpty {
            return .idle(text: "形如 wrk_xxxx，来自 opencode.ai 工作区页面")
        }
        if let err = QuotaClient.validateWorkspaceId(ws) {
            return .invalid(text: err)
        }
        return .valid(text: "格式正确")
    }

    /// Cookie 仅非空时校验;编辑模式留空表示不修改
    private var cookieStatus: FieldStatus {
        let c = authCookie.trimmingCharacters(in: .whitespacesAndNewlines)
        if c.isEmpty {
            return .idle(text: isEditing
                ? "留空表示不修改 Cookie；以 Fe26. 开头，也可在上方从浏览器一键获取"
                : "以 Fe26. 开头；也可在上方从浏览器一键获取")
        }
        if let err = QuotaClient.validateAuthCookie(c) {
            return .invalid(text: err)
        }
        return .valid(text: "格式正确")
    }

    private func statusRow(_ status: FieldStatus) -> some View {
        HStack(spacing: 4) {
            switch status {
            case .idle(let text):
                Text(text)
                    .foregroundStyle(.secondary)
            case .valid(let text):
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(text)
                    .foregroundStyle(.green)
            case .invalid(let text):
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
                Text(text)
                    .foregroundStyle(.red)
            }
        }
        .font(.caption)
    }

    /// 填入成功后聚焦 Cookie 字段并高亮描边,1.5s 淡出
    private func flashCookieField() {
        focusedField = .cookie
        cookieFlash = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            withAnimation(.easeOut(duration: 1.5)) { cookieFlash = false }
        }
    }

    private func prefill() {
        guard let account else { return }
        name = account.name
        workspaceId = account.workspaceId
        notes = account.notes
        authCookie = ""
    }

    /// 登录成功回调(由 GitHubLoginView 在捕获 cookie 时触发):
    /// 1. 回填 authCookie;回调带回了 workspaceId → 同步回填(登录起点可留空 ws);
    /// 2. 名称为空 → 用 GitHub 用户名兜底;
    /// 3. 新增场景(account == nil)自动保存并关闭 sheet —— 即「导入 GitHub 账号后
    ///    登录成功自动产生 opencode 账号」(store.addAccount 不去重:同 cookie 重复 add
    ///    会追加重复账号,故自动保存成功后立即 dismiss;用户重开表单才再走手动流程,
    ///    重复窗口极小且结果幂等可删,不做额外去重);
    ///    保存失败(ws 仍缺/无效等)不静默:提示具体错误并保持表单打开可修正。
    ///    编辑场景(account != nil)不自动保存,只回填(保持现状)。
    private func handleAuthCookie(_ cookie: String, workspaceId ws: String?, githubUsername: String) {
        authCookie = cookie
        loginMessage = "已自动获取 Cookie,请保存 ✅"
        flashCookieField()
        if let ws {
            workspaceId = ws
        }
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            name = githubUsername
        }
        guard !isEditing else { return }
        do {
            try save()
            loginMessage = "已自动保存账号 ✅"
            // 自动保存成功后关闭添加表单(延迟展示成功提示;GitHubLoginView 自身也会在
            // 1s 后 dismiss 自己,双 dismiss 幂等)。自动保存与手点「添加」并行时,
            // 后者会在表单关闭前多写一条重复账号 —— 概率极低且用户可直接删除,故不拦截。
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(600))
                dismiss()
            }
        } catch {
            loginMessage = nil
            if workspaceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                errorText = "未识别到 Workspace ID,请手动填写后点「添加」"
            } else {
                errorText = "自动保存失败:\(error.localizedDescription)"
            }
        }
    }

    private func save() throws {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw SaveError.message("账号名称不能为空") }
        guard QuotaClient.validateWorkspaceId(workspaceId) == nil else {
            throw SaveError.message("Workspace ID 格式无效（应为 wrk_xxx）")
        }
        if let account {
            // 编辑:留空表示不修改 Cookie
            try store.updateAccount(
                account.id, name: trimmedName, workspaceId: workspaceId,
                authCookie: authCookie.isEmpty ? nil : authCookie, notes: notes)
        } else {
            guard QuotaClient.validateAuthCookie(authCookie) == nil else {
                throw SaveError.message("Auth Cookie 格式无效（应以 Fe26. 开头）")
            }
            try store.addAccount(
                name: trimmedName, workspaceId: workspaceId,
                authCookie: authCookie, notes: notes)
        }
    }
}

private enum SaveError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self {
        case .message(let m): return m
        }
    }
}
