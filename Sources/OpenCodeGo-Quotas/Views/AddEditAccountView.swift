import SwiftUI

/// 添加 / 编辑账号:支持从 Chrome / Edge 一键导入 Cookie,也可手动填写
struct AddEditAccountView: View {
    @Environment(AccountStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let account: Account?

    @State private var name = ""
    @State private var workspaceId = ""
    @State private var authCookie = ""
    @State private var notes = ""
    @State private var showCookie = false
    @State private var errorText: String?

    // 浏览器导入
    @State private var importBrowser: BrowserCookieService.Browser = .chrome
    @State private var candidates: [BrowserCookieService.Candidate] = []
    @State private var importMessage: String?
    @State private var importChecked = false

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

            Form {
                TextField("账号名称（如：主账号）", text: $name)
                    .textFieldStyle(.roundedBorder)

                TextField("Workspace ID", text: $workspaceId)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.none)
                    .autocorrectionDisabled()
                Text("形如 wrk_xxxx，来自 opencode.ai 工作区页面")
                    .font(.caption)
                    .foregroundStyle(.secondary)

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

                    Button {
                        showCookie.toggle()
                    } label: {
                        Image(systemName: showCookie ? "eye.slash" : "eye")
                    }
                    .help(showCookie ? "隐藏 Cookie" : "显示 Cookie")
                }
                Text("以 Fe26. 开头；也可在上方从浏览器一键获取")
                    .font(.caption)
                    .foregroundStyle(.secondary)

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
        .onAppear { prefill() }
        .task { await detect() }
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
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
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
        await Task.yield()
        let all = BrowserCookieService.findOpenCodeAuthCookies()
        candidates = all.filter { $0.browser == importBrowser }
        importChecked = true
        if candidates.isEmpty {
            importMessage = "没有在 \(importBrowser.rawValue) 中找到 opencode.ai 的 auth Cookie，可手动填写"
        }
    }

    // MARK: - 表单

    private func prefill() {
        guard let account else { return }
        name = account.name
        workspaceId = account.workspaceId
        notes = account.notes
        authCookie = ""
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
