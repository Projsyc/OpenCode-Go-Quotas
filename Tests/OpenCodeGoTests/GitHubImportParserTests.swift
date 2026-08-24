import Foundation
import XCTest
@testable import OpenCodeGo

final class GitHubImportParserTests: XCTestCase {

    func testCommaSeparated() throws {
        let rows = try GitHubImportParser.parse("user1, password123, ABCDEFGHIJKLMNOP\nuser2, pass456")
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].username, "user1")
        XCTAssertEqual(rows[0].password, "password123")
        XCTAssertEqual(rows[0].credential, "ABCDEFGHIJKLMNOP")
        XCTAssertEqual(rows[0].kind, .totpSecret)
        XCTAssertEqual(rows[1].username, "user2")
        XCTAssertEqual(rows[1].credential, nil)
        XCTAssertEqual(rows[1].kind, nil)
    }

    func testTabSeparated() throws {
        let rows = try GitHubImportParser.parse("user2\tpass456\t123456")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].username, "user2")
        XCTAssertEqual(rows[0].password, "pass456")
        XCTAssertEqual(rows[0].credential, "123456")
        XCTAssertEqual(rows[0].kind, .oneTimeCode)
    }

    func testSpaceSeparated() throws {
        let rows = try GitHubImportParser.parse("user3 password789 JBSWY3DPEHPK3PXP")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].username, "user3")
        XCTAssertEqual(rows[0].password, "password789")
        XCTAssertEqual(rows[0].credential, "JBSWY3DPEHPK3PXP")
        XCTAssertEqual(rows[0].kind, .totpSecret)
    }

    func testSemicolonSeparated() throws {
        let rows = try GitHubImportParser.parse("user4;pass1234;GEZDGNBVGY3TQOJQ")
        XCTAssertEqual(rows[0].username, "user4")
        XCTAssertEqual(rows[0].kind, .totpSecret)
    }

    func testCredentialClassification() throws {
        // 6 位纯数字 → 一次性验证码
        let code = try GitHubImportParser.parse("u1,pass1234,000000")
        XCTAssertEqual(code[0].kind, .oneTimeCode)
        // base32(解码 ≥ 8 字节)→ TOTP secret
        let totp = try GitHubImportParser.parse("u2,pass1234,GEZDGNBVGY3TQOJQ")
        XCTAssertEqual(totp[0].kind, .totpSecret)
        // 小写 base32 同样识别
        let lower = try GitHubImportParser.parse("u3,pass1234,gezdgnbvgy3tqojq")
        XCTAssertEqual(lower[0].kind, .totpSecret)
        // 带 '=' padding 的 base32 同样识别
        let padded = try GitHubImportParser.parse("u4,pass1234,GEZDGNBVGY3TQOJQ====")
        XCTAssertEqual(padded[0].kind, .totpSecret)
    }

    /// S1:共享判定函数(原 classifyCredential / inferKind 两份实现收敛于此,严格 base32)
    func testCredentialKindSharedFunction() {
        // 6 位纯数字 → 一次性验证码(含首尾空白裁剪)
        XCTAssertEqual(GitHubCredentialKind.kind(for: "123456"), .oneTimeCode)
        XCTAssertEqual(GitHubCredentialKind.kind(for: " 123456 "), .oneTimeCode)
        // 合法 base32(解码 ≥ 8 字节)→ TOTP secret(大小写 / padding 均可)
        XCTAssertEqual(GitHubCredentialKind.kind(for: "GEZDGNBVGY3TQOJQ"), .totpSecret)
        XCTAssertEqual(GitHubCredentialKind.kind(for: "gezdgnbvgy3tqojq"), .totpSecret)
        XCTAssertEqual(GitHubCredentialKind.kind(for: "GEZDGNBVGY3TQOJQ===="), .totpSecret)
        // nil:位数不足 / 非法字符('1' 不在 base32 字母表)/ 空串
        XCTAssertNil(GitHubCredentialKind.kind(for: "12345"))
        XCTAssertNil(GitHubCredentialKind.kind(for: "ABC123"))
        XCTAssertNil(GitHubCredentialKind.kind(for: ""))
        XCTAssertNil(GitHubCredentialKind.kind(for: "   "))
    }

    /// L5/收敛:kind(for:) 已统一为严格 base32 —— 截断/非法 padding 的 secret 不再被识别为 TOTP
    func testCredentialKindRejectsTruncatedSecret() {
        // 截断的 secret:严格解码拒绝(宽松解码能解出 ≥ 8 字节)
        XCTAssertNil(GitHubCredentialKind.kind(for: "GEZDGNBVGY3TQOJQGE"))
        // 余量位非 0 / '=' 位置非法
        XCTAssertNil(GitHubCredentialKind.kind(for: "GEZDGNB"))
        XCTAssertNil(GitHubCredentialKind.kind(for: "GEZD=GNBVGY3TQOJQ"))
        // 合法样本仍识别
        XCTAssertEqual(GitHubCredentialKind.kind(for: "GEZDGNBVGY3TQOJQ"), .totpSecret)
        XCTAssertEqual(GitHubCredentialKind.kind(for: "GEZDGNBVGY3TQOJQ===="), .totpSecret)
        XCTAssertEqual(GitHubCredentialKind.kind(for: "123456"), .oneTimeCode)
        XCTAssertNil(GitHubCredentialKind.kind(for: "ABC123"))
        XCTAssertNil(GitHubCredentialKind.kind(for: ""))
    }

    /// L5:导入路径用严格判定,截断 secret 整行报格式无效
    func testParseRejectsTruncatedSecretCredential() throws {
        XCTAssertThrowsError(try GitHubImportParser.parse("u1,pass1234,GEZDGNBVGY3TQOJQGE")) { error in
            XCTAssertEqual(error as? GitHubParseError,
                           .invalidRow(line: 1, reason: "验证码/TOTP secret 格式无效"))
        }
        // 完整 secret 正常通过
        let rows = try GitHubImportParser.parse("u1,pass1234,GEZDGNBVGY3TQOJQ")
        XCTAssertEqual(rows[0].kind, .totpSecret)
    }

    /// S2:逐行解析入口(供预览复用,与 parse 全量路径共用判定)
    func testParseRow() throws {
        // 空行 / 纯空白 / 注释行 → nil(跳过)
        XCTAssertNil(try GitHubImportParser.parseRow("", lineNumber: 1))
        XCTAssertNil(try GitHubImportParser.parseRow("   ", lineNumber: 2))
        XCTAssertNil(try GitHubImportParser.parseRow("# 注释", lineNumber: 3))
        // 有效行 → 解析结果,行号保留
        let row = try XCTUnwrap(GitHubImportParser.parseRow("user1, pass123, JBSWY3DPEHPK3PXP", lineNumber: 7))
        XCTAssertEqual(row.lineNumber, 7)
        XCTAssertEqual(row.username, "user1")
        XCTAssertEqual(row.password, "pass123")
        XCTAssertEqual(row.kind, .totpSecret)
        // 无效行 → 抛带行号的错误
        XCTAssertThrowsError(try GitHubImportParser.parseRow("onlyuser", lineNumber: 5)) { error in
            XCTAssertEqual(error as? GitHubParseError,
                           .invalidRow(line: 5, reason: "空格分隔列数不足(应包含用户名和密码)"))
        }
    }

    func testInvalidCredentialReportsLineNumber() {
        // 行 1 有效;行 4 第三列既不是 6 位数字也不是合法 base32('1' 不在字母表)
        let text = """
        u1,pass1234,GEZDGNBVGY3TQOJQ

        # 注释行
        u2,pass1234,ABC123
        """
        XCTAssertThrowsError(try GitHubImportParser.parse(text)) { error in
            XCTAssertEqual(error as? GitHubParseError,
                           .invalidRow(line: 4, reason: "验证码/TOTP secret 格式无效"))
        }
    }

    func testPasswordTooShort() {
        XCTAssertThrowsError(try GitHubImportParser.parse("u1,short")) { error in
            XCTAssertEqual(error as? GitHubParseError,
                           .invalidRow(line: 1, reason: "密码不能为空且至少 6 个字符"))
        }
    }

    func testEmptyInput() {
        XCTAssertThrowsError(try GitHubImportParser.parse("")) { error in
            XCTAssertEqual(error as? GitHubParseError, .emptyInput)
        }
        XCTAssertThrowsError(try GitHubImportParser.parse("\n  \n# 只有注释\n# 第二行注释\n")) { error in
            XCTAssertEqual(error as? GitHubParseError, .emptyInput)
        }
    }

    func testSpaceRequiresExactlyThreeColumns() throws {
        // 2 列空格分隔(用户名 密码)→ 与逗号/Tab 一致,支持无凭据账号(2 token 无歧义)
        let two = try GitHubImportParser.parse("user1 pass123456")
        XCTAssertEqual(two.count, 1)
        XCTAssertEqual(two[0].username, "user1")
        XCTAssertEqual(two[0].password, "pass123456")
        XCTAssertNil(two[0].credential)
        XCTAssertNil(two[0].kind)
    }

    func testSpaceSeparatedFourColumnsRejected() {
        // 4 列及以上无法区分「带空格的密码」与多余列 → 报错并提示换用逗号/Tab
        XCTAssertThrowsError(try GitHubImportParser.parse("user1 pass word 123456")) { error in
            XCTAssertEqual(error as? GitHubParseError,
                           .invalidRow(line: 1, reason: "空格分隔最多 3 列,实际 4 列(密码含空格请用逗号/Tab 分隔)"))
        }
    }

    /// ghaudit:第三列为空(尾随分隔符 / Excel 空列)→ 视为未提供凭据,不再整行报错
    func testEmptyThirdColumnTreatedAsNoCredential() throws {
        let rows = try GitHubImportParser.parse("user1,pass1234,\nuser2;pass5678;\nuser3\tpass9012\t")
        XCTAssertEqual(rows.count, 3)
        for row in rows {
            XCTAssertNil(row.credential)
            XCTAssertNil(row.kind)
        }
        XCTAssertEqual(rows[2].password, "pass9012")
        // 空第三列不阻塞后续有效行(parse 全量路径首错即抛 → 一行空列毁掉整份导入的回归)
        let mixed = try GitHubImportParser.parse("user1,pass1234,\nuser2,pass5678,GEZDGNBVGY3TQOJQ")
        XCTAssertEqual(mixed.count, 2)
        XCTAssertEqual(mixed[1].kind, .totpSecret)
    }

    /// ghaudit:CRLF 行尾(Excel/Windows 导出)→ 不被 \r 污染字段
    func testCRLFLines() throws {
        let rows = try GitHubImportParser.parse("user1,pass1234,GEZDGNBVGY3TQOJQ\r\nuser2,pass5678\r\n# 注释\r\n")
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].username, "user1")
        XCTAssertEqual(rows[1].username, "user2")
        XCTAssertEqual(rows[1].password, "pass5678")
        XCTAssertEqual(rows.map(\.lineNumber), [1, 2])
    }

    func testCSVQuotedFieldWithDelimiter() throws {
        let rows = try GitHubImportParser.parse(#""user,name",pass1234,GEZDGNBVGY3TQOJQ"#)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].username, "user,name")
        XCTAssertEqual(rows[0].password, "pass1234")
        XCTAssertEqual(rows[0].kind, .totpSecret)
    }

    func testCSVEscapedQuotes() throws {
        let rows = try GitHubImportParser.parse(#""user""name",pass1234,GEZDGNBVGY3TQOJQ"#)
        XCTAssertEqual(rows[0].username, #"user"name"#)
    }

    func testUnclosedQuoteReportsLine() {
        XCTAssertThrowsError(try GitHubImportParser.parse("u1,pass1234,GEZDGNBVGY3TQOJQ\n\"abc,pass1234")) { error in
            XCTAssertEqual(error as? GitHubParseError, .invalidRow(line: 2, reason: "引号未闭合"))
        }
    }

    func testParseCSVData() throws {
        let data = Data("user1,pass1234,GEZDGNBVGY3TQOJQ\nuser2,pass5678,123456\n".utf8)
        let rows = try GitHubImportParser.parseCSV(data: data)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].kind, .totpSecret)
        XCTAssertEqual(rows[1].kind, .oneTimeCode)
        XCTAssertEqual(rows[1].lineNumber, 2)
    }

    func testParseCSVInvalidUTF8() {
        let bad = Data([0xff, 0xfe, 0x00, 0x41])
        XCTAssertThrowsError(try GitHubImportParser.parseCSV(data: bad)) { error in
            XCTAssertEqual(error as? GitHubParseError,
                           .invalidRow(line: 1, reason: "文件不是有效的 UTF-8 文本"))
        }
    }

    /// M2:CSV 文件导入剥离 UTF-8 前缀 BOM(U+FEFF),避免首行用户名入库为 "\u{FEFF}user1"
    func testParseCSVStripsBOM() throws {
        let data = Data("\u{FEFF}user1,pass1234,GEZDGNBVGY3TQOJQ\nuser2,pass5678,123456".utf8)
        let rows = try GitHubImportParser.parseCSV(data: data)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].username, "user1")
        XCTAssertFalse(rows[0].username.hasPrefix("\u{FEFF}"))
        XCTAssertEqual(rows[1].username, "user2")
        XCTAssertEqual(rows[1].kind, .oneTimeCode)
        // 仅 BOM + 空白 → 剥离后无内容,按空输入处理
        XCTAssertThrowsError(try GitHubImportParser.parseCSV(data: Data("\u{FEFF}\n  ".utf8))) { error in
            XCTAssertEqual(error as? GitHubParseError, .emptyInput)
        }
    }

    /// M2:decodeUTF8Text 共用解码入口(parseCSV 与视图 loadFile 同路径)
    func testDecodeUTF8TextStripsBOM() {
        XCTAssertEqual(GitHubImportParser.decodeUTF8Text(Data("\u{FEFF}abc".utf8)), "abc")
        XCTAssertEqual(GitHubImportParser.decodeUTF8Text(Data("abc".utf8)), "abc")
        XCTAssertNil(GitHubImportParser.decodeUTF8Text(Data([0xff, 0xfe, 0x00, 0x41])))
    }

    func testLineNumbersWithCommentsAndBlanks() throws {
        let text = "# 表头\n\nuser1,pass1234,GEZDGNBVGY3TQOJQ\n   \nuser2,pass5678"
        let rows = try GitHubImportParser.parse(text)
        XCTAssertEqual(rows.map(\.lineNumber), [3, 5])
    }
}
