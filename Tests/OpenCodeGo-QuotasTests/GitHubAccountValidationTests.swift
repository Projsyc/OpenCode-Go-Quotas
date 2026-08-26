import XCTest
@testable import OpenCode_Go_Quotas

final class GitHubAccountValidationTests: XCTestCase {
    func testUsernameTrimsAndRejectsInvalidValues() throws {
        XCTAssertEqual(try GitHubAccountStoreError.validatedUsername("  alice \n"), "alice")

        for invalid in ["", "   "] {
            XCTAssertThrowsError(try GitHubAccountStoreError.validatedUsername(invalid)) { error in
                XCTAssertEqual(error as? GitHubAccountStoreError, .emptyUsername)
            }
        }
        for invalid in ["jo hn", "jo\thn", " jo hn "] {
            XCTAssertThrowsError(try GitHubAccountStoreError.validatedUsername(invalid)) { error in
                XCTAssertEqual(error as? GitHubAccountStoreError, .usernameContainsWhitespace)
            }
        }
    }

    func testPasswordMinimumLengthIsShared() {
        XCTAssertEqual(try GitHubAccountStoreError.validatedPassword(" pass123456 "), "pass123456")

        for password in ["", " ", "12345"] {
            XCTAssertThrowsError(try GitHubAccountStoreError.validatedPassword(password)) { error in
                XCTAssertEqual(error as? GitHubAccountStoreError, .passwordTooShort)
            }
        }
    }

    func testFormAndCSVWhitespacePolicies() {
        XCTAssertTrue(GitHubPasswordWhitespacePolicy.isNotableFormValue(" pass123456"))
        XCTAssertTrue(GitHubPasswordWhitespacePolicy.isNotableFormValue("pass123456 "))
        XCTAssertFalse(GitHubPasswordWhitespacePolicy.isNotableFormValue("pass123456"))

        // 未加引号时，分隔符旁的单个空白视为格式约定；两个以上才提示。
        XCTAssertTrue(GitHubPasswordWhitespacePolicy.isNotableCSVField("  pass", treatAsLiteral: false))
        XCTAssertFalse(GitHubPasswordWhitespacePolicy.isNotableCSVField(" pass", treatAsLiteral: false))
        // 引号字面量中任何首尾空白都属于密码内容。
        XCTAssertTrue(GitHubPasswordWhitespacePolicy.isNotableCSVField(" pass", treatAsLiteral: true))
        XCTAssertFalse(GitHubPasswordWhitespacePolicy.isNotableCSVField("   ", treatAsLiteral: true))
    }
}
