import SwiftUI

/// GitHub 账号卡片:GitHub 风头像 + 凭据徽章 + TOTP 实时验证码 / 一次性验证码状态 + 操作
struct GitHubAccountCardView: View {
    @Environment(GitHubAccountStore.self) private var store

    let account: GitHubAccount

    @State private var hovering = false
    @State private var showingEdit = false
    @State private var confirmingDelete = false
    @State private var copied: CopiedTarget?
    @State private var secret: String?

    private enum CopiedTarget { case code, password }

    private var liveAccount: GitHubAccount? {
        store.accounts.first { $0.id == account.id }
    }

    var body: some View {
        if let account = liveAccount {
            card(account)
        }
    }

    @ViewBuilder
    private func card(_ account: GitHubAccount) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            header(account)
            switch account.credentialKind {
            case .totpSecret:
                totpRow(account)
            case .oneTimeCode:
                oneTimeCodeStatus(account)
            case nil:
                Text("未配置验证码,可通过下方按钮复制密码")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Divider().opacity(0.5)
            footbar(account)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [Color.white.opacity(0.25), Color.primary.opacity(0.05)],
                                startPoint: .topLeading, endPoint: .bottomTrailing)))
                .shadow(color: .black.opacity(hovering ? 0.18 : 0.08), radius: hovering ? 16 : 10, y: 5))
        .scaleEffect(hovering ? 1.012 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: hovering)
        .onHover { hovering = $0 }
        .task(id: account.updatedAt) {
            secret = store.credential(for: account)
        }
        .sheet(isPresented: $showingEdit) { GitHubEditView(account: account) }
        .confirmationDialog(
            "删除 GitHub 账号「\(account.username)」?将同时删除本机保存的密码与验证码凭据。",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) { store.delete(account.id) }
        }
    }

    // MARK: - 头部

    private func header(_ account: GitHubAccount) -> some View {
        HStack(spacing: 12) {
            GitHubAvatar(initial: initial(of: account.username))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(account.username)
                        .font(.headline)
                        .lineLimit(1)
                    badge(for: account.credentialKind)
                }
                HStack(spacing: 6) {
                    Text("@\(account.username)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if !account.notes.isEmpty {
                        Text(account.notes)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }
            Spacer()
        }
    }

    private func initial(of username: String) -> String {
        username.first.map { String($0).uppercased() } ?? "?"
    }

    /// 凭据徽章:TOTP 密钥 → 蓝紫渐变字;一次性验证码 → 橙色;仅密码 → 灰色
    private func badge(for kind: GitHubCredentialKind?) -> some View {
        let text: String
        switch kind {
        case .totpSecret: text = "TOTP 密钥"
        case .oneTimeCode: text = "一次性验证码"
        case nil: text = "仅密码"
        }
        return Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
            .foregroundStyle(foreground(for: kind))
    }

    private func foreground(for kind: GitHubCredentialKind?) -> AnyShapeStyle {
        switch kind {
        case .totpSecret: return AnyShapeStyle(Theme.accent)
        case .oneTimeCode: return AnyShapeStyle(Color.orange)
        case nil: return AnyShapeStyle(Color.gray)
        }
    }

    // MARK: - TOTP 实时验证码行

    private func totpRow(_ account: GitHubAccount) -> some View {
        Group {
            if let secret {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let code = TOTPGenerator.generate(secretBase32: secret, at: context.date)
                    let remaining = TOTPGenerator.remainingSeconds(at: context.date)
                    HStack(spacing: 12) {
                        Text(code ?? "—")
                            .font(.system(size: 28, weight: .semibold, design: .monospaced))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                        Spacer()
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise")
                            Text("\(remaining)s")
                        }
                        .font(.callout.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(remaining <= 5 ? Color.orange : Color.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.blue.opacity(0.08)))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.blue.opacity(0.15)))
                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .onTapGesture { copy(code, as: .code) }
                    .help("点击复制验证码")
                }
            } else {
                Text("读取 TOTP 密钥…")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 6)
            }
        }
    }

    // MARK: - 一次性验证码状态行

    private func oneTimeCodeStatus(_ account: GitHubAccount) -> some View {
        let expired = account.lastCodeAt.map { Date().timeIntervalSince($0) >= 60 } ?? true
        return HStack(spacing: 8) {
            Image(systemName: expired ? "clock.badge.xmark" : "clock")
                .font(.callout)
                .foregroundStyle(expired ? Color.gray.opacity(0.45) : Color.orange)
            Text(expired ? "已失效" : "验证码 60 秒后失效")
                .font(.callout)
                .foregroundStyle(expired ? .tertiary : .secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.orange.opacity(0.06)))
    }

    // MARK: - 操作栏

    private func footbar(_ account: GitHubAccount) -> some View {
        HStack(spacing: 8) {
            if account.credentialKind != nil {
                copyButton("复制验证码", icon: "number", target: .code)
            }
            copyButton("复制密码", icon: "lock", target: .password)
            Spacer()
            iconButton("pencil", help: "编辑账号") { showingEdit = true }
            iconButton("trash", help: "删除账号", destructive: true) { confirmingDelete = true }
        }
    }

    private func copyButton(_ label: String, icon: String, target: CopiedTarget) -> some View {
        Button {
            let value: String?
            switch target {
            case .code: value = codeValue()
            case .password: value = store.password(for: account)
            }
            copy(value, as: target)
        } label: {
            Label(copied == target ? "已复制" : label, systemImage: copied == target ? "checkmark" : icon)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private func iconButton(_ systemImage: String, help: String, destructive: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(role: destructive ? .destructive : nil, action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.primary.opacity(0.06)))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - 复制

    /// 当前验证码:TOTP 用缓存 secret 实时生成;一次性验证码直接取 Keychain 中的原始值
    private func codeValue() -> String? {
        switch account.credentialKind {
        case .totpSecret:
            return secret.flatMap { TOTPGenerator.generate(secretBase32: $0) }
        case .oneTimeCode:
            return store.credential(for: account)
        case nil:
            return nil
        }
    }

    private func copy(_ value: String?, as target: CopiedTarget) {
        guard let value, !value.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        withAnimation(.easeOut(duration: 0.15)) { copied = target }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if copied == target { copied = nil }
        }
    }
}

/// GitHub 风头像:暗色圆 + 亮色圆环 + 白色首字母
private struct GitHubAvatar: View {
    var initial: String
    var size: CGFloat = 34

    var body: some View {
        ZStack {
            Circle().fill(Color(hex: 0x24292F))
            Circle().stroke(Color(hex: 0x57606A).opacity(0.55), lineWidth: 1.5)
            Text(initial)
                .font(.system(size: size * 0.42, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
    }
}
