import SwiftUI

/// 添加 / 编辑单个 GitHub 账号:用户名 + 密码(可显隐)+ 验证码/TOTP 密钥(按内容推断类型)+ 备注
struct GitHubEditView: View {
    @Environment(GitHubAccountStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let account: GitHubAccount?

    @State private var username = ""
    @State private var password = ""
    @State private var credential = ""
    @State private var notes = ""
    @State private var showPassword = false
    @State private var kind: GitHubCredentialKind?
    @State private var errorText: String?
    @State private var showClearConfirm = false
    @State private var clearMessage: String?

    private var isEditing: Bool { account != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(isEditing ? "编辑 GitHub 账号" : "添加 GitHub 账号")
                    .font(.title2.bold())
                Spacer()
                SVGPath(data: SVGBuiltIn.sparkle)
                    .fill(Color.purple.opacity(0.35))
                    .frame(width: 18, height: 18)
            }

            Form {
                TextField("用户名(必填)", text: $username)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                Text("如 gh-username;GitHub 用户名不能包含空白字符")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Group {
                        if showPassword {
                            TextField("密码", text: $password)
                        } else {
                            SecureField("密码", text: $password)
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()

                    Button {
                        showPassword.toggle()
                    } label: {
                        Image(systemName: showPassword ? "eye.slash" : "eye")
                    }
                    .help(showPassword ? "隐藏密码" : "显示密码")
                }
                Text(isEditing
                     ? "编辑时留空表示不修改;密码至少 6 个字符"
                     : "密码至少 6 个字符,仅保存在本机 Keychain")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField("验证码 / TOTP 密钥(可选)", text: $credential)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                    .onChange(of: credential) { _, newValue in
                        if let inferred = Self.inferKind(newValue) {
                            kind = inferred
                        }
                    }
                if !credential.isEmpty {
                    Picker("凭据类型", selection: $kind) {
                        Text("一次性验证码").tag(Optional(GitHubCredentialKind.oneTimeCode))
                        Text("TOTP 密钥").tag(Optional(GitHubCredentialKind.totpSecret))
                    }
                    .pickerStyle(.segmented)
                    Text(isEditing ? "留空表示不修改" : "6 位数字为一次性验证码,其余按 base32 TOTP 密钥识别")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                TextField("备注(可选)", text: $notes)
                    .textFieldStyle(.roundedBorder)
            }
            .formStyle(.columns)

            if isEditing, let account, account.credentialKind != nil {
                Button("清除已存凭据", role: .destructive) {
                    showClearConfirm = true
                }
                .font(.caption)
                .buttonStyle(.borderless)
                .confirmationDialog(
                    "清除已存凭据?",
                    isPresented: $showClearConfirm,
                    titleVisibility: .visible
                ) {
                    Button("清除", role: .destructive) { clearStoredCredential() }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text("将删除已保存的 TOTP 密钥或一次性验证码,密码不受影响")
                }
            }

            if let errorText {
                Label(errorText, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            if let clearMessage {
                Label(clearMessage, systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
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
                .tint(Theme.accentSolid)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
        .onAppear { prefill() }
    }

    // MARK: - 表单

    private func prefill() {
        guard let account else { return }
        username = account.username
        notes = account.notes
        kind = account.credentialKind
    }

    private func clearStoredCredential() {
        guard let account else { return }
        do {
            try store.clearCredential(account.id)
            credential = ""
            kind = nil
            clearMessage = "已清除已存凭据"
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func save() throws {
        let name = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw SaveError.message("用户名不能为空") }
        guard !name.contains(where: { $0.isWhitespace }) else {
            throw SaveError.message("用户名不能包含空白字符")
        }
        let passwordValue = password.trimmingCharacters(in: .whitespacesAndNewlines)
        let credentialValue = credential.trimmingCharacters(in: .whitespacesAndNewlines)

        // 有凭据但未显式选择类型时按内容推断;推断不出则报错
        var effectiveKind = kind
        if !credentialValue.isEmpty, effectiveKind == nil {
            effectiveKind = Self.inferKind(credentialValue)
            guard effectiveKind != nil else { throw SaveError.message("验证码/TOTP 密钥格式无效") }
        }
        let notesValue = notes.trimmingCharacters(in: .whitespacesAndNewlines)

        if let account {
            try store.update(
                account.id,
                username: name,
                notes: notesValue,
                password: passwordValue.isEmpty ? nil : passwordValue,
                credential: credentialValue.isEmpty ? nil : credentialValue,
                kind: credentialValue.isEmpty ? nil : effectiveKind)
        } else {
            try store.add(
                username: name,
                notes: notesValue,
                password: passwordValue,
                credential: credentialValue.isEmpty ? nil : credentialValue,
                kind: credentialValue.isEmpty ? nil : effectiveKind)
        }
    }

    /// 按内容推断凭据类型:6 位纯数字 → 一次性验证码;合法 base32(≥ 8 字节)→ TOTP 密钥
    static func inferKind(_ value: String) -> GitHubCredentialKind? {
        let v = value.trimmingCharacters(in: .whitespaces)
        if v.count == 6, v.allSatisfy({ $0.isASCII && $0.isWholeNumber }) {
            return .oneTimeCode
        }
        if let decoded = TOTPGenerator.decodeBase32(v), decoded.count >= 8 {
            return .totpSecret
        }
        return nil
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
