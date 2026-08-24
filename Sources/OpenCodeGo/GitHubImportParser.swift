import Foundation

/// 批量导入的一行(已解析,含原始行号)
struct GitHubImportRow: Equatable, Sendable {
    var lineNumber: Int
    var username: String
    var password: String
    var credential: String?
    var kind: GitHubCredentialKind?
}

/// 批量导入解析错误(以行号定位)
enum GitHubParseError: LocalizedError, Equatable {
    case emptyInput
    case invalidRow(line: Int, reason: String)

    var errorDescription: String? {
        switch self {
        case .emptyInput:
            return "没有可导入的内容(空输入或只有注释行)"
        case .invalidRow(let line, let reason):
            return "第 \(line) 行:\(reason)"
        }
    }
}

/// 批量导入文本/CSV 解析器:每行独立判断分隔符(Tab/逗号/分号/空格)
enum GitHubImportParser {

    /// 解析粘贴文本;遇到第一处无效行即抛错(带行号)
    static func parse(_ text: String) throws -> [GitHubImportRow] {
        let lines = splitLines(text)
        var rows: [GitHubImportRow] = []
        for (index, raw) in lines.enumerated() {
            if let row = try parseRow(raw, lineNumber: index + 1) {
                rows.append(row)
            }
        }
        guard !rows.isEmpty else { throw GitHubParseError.emptyInput }
        return rows
    }

    /// 行拆分(CRLF 兼容):CRLF / 单独 CR / LF 统一归一化为 \n 后按行切分。
    /// ⚠️ 不能用 `String.split(separator: "\n")`:CR+LF 在 Unicode 字素簇
    /// (TR29 GB3)中是单一簇,`"\n"` 不是独立 Character —— CRLF 文本整段不
    /// 切分,Excel/Windows 导出的整份 CSV 会被当成一行,首行即报列数过多。
    /// 空行保留(与 omittingEmptySubsequences: false 语义一致,行号不漂移)。
    static func splitLines(_ text: String) -> [String] {
        text.components(separatedBy: "\r\n").joined(separator: "\n")
            .components(separatedBy: "\r").joined(separator: "\n")
            .components(separatedBy: "\n")
    }

    /// 逐行解析入口:空行 / `#` 注释行返回 nil(跳过);无效行抛带行号的错误;
    /// 空输入(emptyInput)是全文级语义,不在此抛。供逐行预览等场景复用,
    /// 避免与 `parse` 重复「按行拆分 + 空行/注释跳过」逻辑。
    static func parseRow(_ line: String, lineNumber: Int) throws -> GitHubImportRow? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.hasPrefix("#") { return nil }

        let fields = try splitFields(trimmed, lineNumber: lineNumber)
        guard fields.count >= 2, fields.count <= 3 else {
            throw GitHubParseError.invalidRow(
                line: lineNumber,
                reason: fields.count < 2
                    ? "列数不足(应包含用户名和密码)"
                    : "列数过多(应为 2~3 列,实际 \(fields.count) 列)")
        }

        let username = fields[0]
        let password = fields[1]
        guard !username.isEmpty else {
            throw GitHubParseError.invalidRow(line: lineNumber, reason: "用户名不能为空")
        }
        guard !username.contains(where: { $0.isWhitespace }) else {
            throw GitHubParseError.invalidRow(line: lineNumber, reason: "用户名不能包含空白字符")
        }
        guard !password.isEmpty, password.count >= 6 else {
            throw GitHubParseError.invalidRow(line: lineNumber, reason: "密码不能为空且至少 6 个字符")
        }

        if fields.count == 3 {
            let credential = fields[2]
            if credential.isEmpty {
                // 尾随分隔符 / Excel 导出的空第三列 → 视为未提供凭据(与 2 列一致),
                // 避免「一行空列」让整份导入在第一处无效行即中止
                return GitHubImportRow(
                    lineNumber: lineNumber,
                    username: username,
                    password: password,
                    credential: nil,
                    kind: nil)
            }
            guard let kind = GitHubCredentialKind.kind(for: credential) else {
                throw GitHubParseError.invalidRow(
                    line: lineNumber,
                    reason: "验证码/TOTP secret 格式无效")
            }
            return GitHubImportRow(
                lineNumber: lineNumber,
                username: username,
                password: password,
                credential: credential,
                kind: kind)
        }
        return GitHubImportRow(
            lineNumber: lineNumber,
            username: username,
            password: password,
            credential: nil,
            kind: nil)
    }

    /// 解析 CSV 文件数据(假定 UTF-8;编码无效按第 1 行报错)
    static func parseCSV(data: Data) throws -> [GitHubImportRow] {
        guard let text = decodeUTF8Text(data) else {
            throw GitHubParseError.invalidRow(line: 1, reason: "文件不是有效的 UTF-8 文本")
        }
        return try parse(text)
    }

    /// 解码 UTF-8 文本并剥离文件开头的前缀 BOM(U+FEFF);非 UTF-8 返回 nil。
    /// parseCSV 与视图 loadFile 共用此解码路径,避免 BOM 混入首行用户名
    /// 导致自动登录静默失败。
    static func decodeUTF8Text(_ data: Data) -> String? {
        guard var text = String(data: data, encoding: .utf8) else { return nil }
        if text.hasPrefix("\u{FEFF}") {
            text.removeFirst()
        }
        return text
    }

    // MARK: - 私有

    /// 按行检测分隔符并切分:Tab > 逗号 > 分号 > 空格。
    /// 空格分隔接受 2~3 列(2 列 = 用户名+密码,无歧义;3 列 = 用户名+密码+凭据);
    /// 4 列及以上无法区分「带空格的密码」与多余列,报错并提示换用逗号/Tab。
    private static func splitFields(_ line: String, lineNumber: Int) throws -> [String] {
        if line.contains("\t") {
            return try csvSplit(line, delimiter: "\t", lineNumber: lineNumber).map(trimField)
        }
        if line.contains(",") {
            return try csvSplit(line, delimiter: ",", lineNumber: lineNumber).map(trimField)
        }
        if line.contains(";") {
            return try csvSplit(line, delimiter: ";", lineNumber: lineNumber).map(trimField)
        }
        let tokens = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard tokens.count >= 2, tokens.count <= 3 else {
            throw GitHubParseError.invalidRow(
                line: lineNumber,
                reason: tokens.count < 2
                    ? "空格分隔列数不足(应包含用户名和密码)"
                    : "空格分隔最多 3 列,实际 \(tokens.count) 列(密码含空格请用逗号/Tab 分隔)")
        }
        return tokens
    }

    /// 按指定分隔符切分一行,支持双引号包裹字段与 `""` 转义引号;引号未闭合抛错
    private static func csvSplit(_ line: String, delimiter: Character, lineNumber: Int) throws -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        let chars = Array(line)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" {
                        current.append("\"")
                        i += 2
                    } else {
                        inQuotes = false
                        i += 1
                    }
                } else {
                    current.append(c)
                    i += 1
                }
            } else if c == "\"" {
                inQuotes = true
                i += 1
            } else if c == delimiter {
                fields.append(current)
                current = ""
                i += 1
            } else {
                current.append(c)
                i += 1
            }
        }
        guard !inQuotes else {
            throw GitHubParseError.invalidRow(line: lineNumber, reason: "引号未闭合")
        }
        fields.append(current)
        return fields
    }

    private static func trimField(_ field: String) -> String {
        field.trimmingCharacters(in: .whitespaces)
    }
}
