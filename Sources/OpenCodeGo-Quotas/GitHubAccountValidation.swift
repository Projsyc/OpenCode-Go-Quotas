import Foundation

/// GitHub 账号领域校验。导入解析、单个表单和 Account Store 共用同一套规则，
/// 避免同一输入在不同入口得到不同结论或不同文案。
enum GitHubAccountStoreError: LocalizedError, Equatable {
    case emptyUsername
    case usernameContainsWhitespace
    case passwordTooShort
    case duplicateUsername(String)
    case credentialWithoutKind

    var errorDescription: String? {
        switch self {
        case .emptyUsername: return "用户名不能为空"
        case .usernameContainsWhitespace: return "用户名不能包含空白字符"
        case .passwordTooShort: return "密码至少 6 个字符"
        case .duplicateUsername(let name): return "用户名 \(name) 已存在"
        case .credentialWithoutKind: return "提供验证码/TOTP secret 时必须指定凭据类型"
        }
    }

    /// 校验并归一化用户名：去除首尾空白后必须非空且不含任何内部空白。
    static func validatedUsername(_ rawValue: String) throws -> String {
        let username = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty else { throw GitHubAccountStoreError.emptyUsername }
        guard !username.contains(where: \.isWhitespace) else {
            throw GitHubAccountStoreError.usernameContainsWhitespace
        }
        return username
    }

    /// 校验新密码：调用方先完成首尾空白 trim；最小长度与导入 / 表单保持一致。
    static func validatedPassword(_ rawValue: String) throws -> String {
        let password = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !password.isEmpty, password.count >= 6 else { throw GitHubAccountStoreError.passwordTooShort }
        return password
    }
}

/// 密码首尾空白的统一提示语义。
/// 表单中的任何非空首尾空白都值得提示；CSV 字段则区分引号字面量和分隔符旁的单个空白。
enum GitHubPasswordWhitespacePolicy {
    static func isNotableFormValue(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && trimmed != value
    }

    static func isNotableCSVField(_ field: String, treatAsLiteral: Bool) -> Bool {
        let trimmed = field.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != field else { return false }
        if treatAsLiteral { return true }

        let leading = field.count - field.drop(while: \.isWhitespace).count
        let trailing = field.count - field.reversed().drop(while: \.isWhitespace).count
        return leading > 1 || trailing > 1
    }
}
