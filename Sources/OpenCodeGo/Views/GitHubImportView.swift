import SwiftUI
import UniformTypeIdentifiers

/// 批量导入 GitHub 账号:粘贴 / 读入 CSV/TXT → 逐行解析预览 → 批量入库
struct GitHubImportView: View {
    @Environment(GitHubAccountStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var preview: [GitHubImportPreviewRow] = []
    @State private var showingFileImporter = false
    @State private var outcome: ImportOutcome?

    /// 批量导入结果:部分成功(停留展示)或全部失败(错误提示)
    enum ImportOutcome {
        case partial(imported: Int, skipped: [GitHubImportSkip])
        case failed([GitHubImportSkip])

        var skipped: [GitHubImportSkip] {
            switch self {
            case .partial(_, let skipped): return skipped
            case .failed(let skipped): return skipped
            }
        }
    }

    private var validCount: Int { preview.filter { $0.error == nil }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            formatHint
            editor
            actionRow
            if !preview.isEmpty {
                previewList
            } else if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("未解析出任何行(空输入或只有注释行)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            if let outcome {
                outcomeView(outcome)
            }
            footer
        }
        .padding(24)
        .frame(width: 580)
        .onAppear { refreshPreview() }
        .onChange(of: text) { _, _ in refreshPreview() }
        .fileImporter(isPresented: $showingFileImporter, allowedContentTypes: [.plainText, .commaSeparatedText]) { result in
            loadFile(result)
        }
    }

    // MARK: - 头部与格式提示

    private var header: some View {
        HStack {
            Text("批量导入 GitHub 账号")
                .font(.title2.bold())
            Spacer()
            SVGPath(data: SVGBuiltIn.sparkle)
                .fill(Color.purple.opacity(0.35))
                .frame(width: 18, height: 18)
        }
    }

    private var formatHint: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("格式:用户名 <Tab 或逗号> 密码 <Tab 或逗号> TOTP 密钥或 6 位验证码(可省略,`#` 开头为注释)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("例:user1, 密码123, JBSWY3DPEHPK3PXP   |   user2, 密码456, 123456")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - 编辑器

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .autocorrectionDisabled()
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
                .frame(minHeight: 140)
            if text.isEmpty {
                Text("每行一个账号,粘贴在这里…\nuser1, 密码123, JBSWY3DPEHPK3PXP\nuser2, 密码456, 123456")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 16)
                    .padding(.leading, 14)
                    .allowsHitTesting(false)
            }
        }
    }

    private var actionRow: some View {
        HStack {
            Button {
                showingFileImporter = true
            } label: {
                Label("导入 CSV/TXT 文件…", systemImage: "doc.badge.plus")
            }
            .buttonStyle(.bordered)
            Spacer()
            Button {
                refreshPreview()
            } label: {
                Label("解析预览", systemImage: "text.magnifyingglass")
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: - 预览列表

    private var previewList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("解析预览(共 \(preview.count) 行,\(validCount) 行有效)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(preview) { row in
                        rowView(row)
                    }
                }
            }
            .frame(maxHeight: 170)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.03)))
    }

    private func rowView(_ row: GitHubImportPreviewRow) -> some View {
        HStack(spacing: 8) {
            Image(systemName: row.error == nil ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(row.error == nil ? .green : .red)
            Text("\(row.lineNumber)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 26, alignment: .trailing)
            Text(row.username.isEmpty ? "—" : row.username)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .frame(maxWidth: 150, alignment: .leading)
            if let kind = row.kind {
                kindBadge(kind)
            }
            Spacer(minLength: 8)
            if row.error == nil {
                // 密码只展示「已填」,绝不显示明文
                Label("密码已填", systemImage: "checkmark")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else if let error = row.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
            }
        }
        .padding(.vertical, 3)
    }

    private func kindBadge(_ kind: GitHubCredentialKind) -> some View {
        Text(kind == .totpSecret ? "TOTP 密钥" : "一次性验证码")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill((kind == .totpSecret ? Color.blue : Color.orange).opacity(0.14)))
            .foregroundStyle(kind == .totpSecret ? .blue : .orange)
    }

    // MARK: - 导入结果

    private func outcomeView(_ outcome: ImportOutcome) -> some View {
        let isPartial: Bool
        if case .partial = outcome { isPartial = true } else { isPartial = false }
        return VStack(alignment: .leading, spacing: 5) {
            Label(
                isPartial ? summaryText(outcome) : "没有账号被导入,详见下方明细",
                systemImage: isPartial ? "info.circle" : "exclamationmark.triangle.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(isPartial ? .orange : .red)
            ForEach(outcome.skipped, id: \.lineNumber) { skip in
                Text("第 \(skip.lineNumber) 行:\(skip.reason)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.orange.opacity(0.07)))
    }

    private func summaryText(_ outcome: ImportOutcome) -> String {
        guard case .partial(let imported, let skipped) = outcome else { return "" }
        return "已导入 \(imported) 个,跳过 \(skipped.count) 个(见下方明细)"
    }

    // MARK: - 底部操作

    private var footer: some View {
        HStack {
            Spacer()
            Button("取消") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("导入 \(validCount) 个账号") {
                importAll()
            }
            .buttonStyle(.borderedProminent)
            .tint(ThemeAccent())
            .keyboardShortcut(.defaultAction)
            .disabled(validCount == 0)
        }
    }

    // MARK: - 动作

    private func refreshPreview() {
        preview = Self.previewRows(from: text)
        outcome = nil
    }

    private func importAll() {
        let rows = preview.compactMap(\.row)
        guard !rows.isEmpty else { return }
        do {
            let summary = try store.importBatch(rows)
            if summary.skipped.isEmpty {
                dismiss()
            } else if summary.imported > 0 {
                outcome = .partial(imported: summary.imported, skipped: summary.skipped)
            } else {
                outcome = .failed(summary.skipped)
            }
        } catch {
            outcome = .failed([GitHubImportSkip(lineNumber: 0, reason: error.localizedDescription)])
        }
    }

    private func loadFile(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            let didStart = url.startAccessingSecurityScopedResource()
            defer { if didStart { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url),
                  let chunk = String(data: data, encoding: .utf8)
            else { return }
            let trimmed = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? trimmed
                : text + "\n" + trimmed
        case .failure:
            break
        }
    }

    // MARK: - 逐行预览(纯逻辑,可单测)

    /// 将导入文本逐行解析为预览行:有效行携带解析结果(供导入),错误行携带原因;空行/注释行跳过
    static func previewRows(from text: String) -> [GitHubImportPreviewRow] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var rows: [GitHubImportPreviewRow] = []
        for (index, raw) in lines.enumerated() {
            let lineNumber = index + 1
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            do {
                guard let parsed = try GitHubImportParser.parse(line).first else { continue }
                rows.append(GitHubImportPreviewRow(
                    lineNumber: lineNumber,
                    username: parsed.username,
                    error: nil,
                    row: parsed))
            } catch let error as GitHubParseError {
                guard case .invalidRow(_, let reason) = error else { continue }
                rows.append(GitHubImportPreviewRow(
                    lineNumber: lineNumber,
                    username: usernameHint(from: line),
                    error: reason,
                    row: nil))
            } catch {
                rows.append(GitHubImportPreviewRow(
                    lineNumber: lineNumber,
                    username: usernameHint(from: line),
                    error: error.localizedDescription,
                    row: nil))
            }
        }
        return rows
    }

    /// 从一行文本里尽量提取用户名(首个非分隔符字段),仅供错误行展示
    private static func usernameHint(from line: String) -> String {
        line.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "\t" || $0.isWhitespace })
            .first.map(String.init) ?? ""
    }
}

/// 批量导入预览行(纯值类型,可单测)
struct GitHubImportPreviewRow: Identifiable, Equatable, Sendable {
    var lineNumber: Int
    var username: String
    var error: String?
    var row: GitHubImportRow?

    var id: Int { lineNumber }
    var kind: GitHubCredentialKind? { row?.kind }
}

private func ThemeAccent() -> Color {
    Color(hex: 0x7C6CF0)
}
