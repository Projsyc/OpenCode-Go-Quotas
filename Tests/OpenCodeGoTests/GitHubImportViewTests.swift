import Foundation
import XCTest
@testable import OpenCodeGo

/// GitHubImportView 预览行 / GitHubEditView 类型推断的纯逻辑测试(不碰真实存储)
final class GitHubImportViewTests: XCTestCase {

    func testPreviewValidRows() throws {
        let rows = GitHubImportView.previewRows(from: "user1, pass123, JBSWY3DPEHPK3PXP\nuser2, pass456, 123456\nuser3, pass789")
        XCTAssertEqual(rows.count, 3)
        XCTAssertNil(rows[0].error)
        XCTAssertEqual(rows[0].username, "user1")
        XCTAssertEqual(rows[0].kind, .totpSecret)
        XCTAssertNotNil(rows[0].row)
        XCTAssertNil(rows[1].error)
        XCTAssertEqual(rows[1].kind, .oneTimeCode)
        XCTAssertNil(rows[2].error)
        XCTAssertNil(rows[2].kind)
    }

    func testPreviewInvalidLineKeepsOthers() throws {
        let rows = GitHubImportView.previewRows(
            from: "user1, pass123\nuser2, pass456, not-a-valid-credential\nuser3, pass789, ABCDEFGHIJKLMNOP")
        XCTAssertEqual(rows.count, 3)
        XCTAssertNil(rows[0].error)
        XCTAssertNotNil(rows[1].error)
        XCTAssertEqual(rows[1].lineNumber, 2)
        XCTAssertEqual(rows[1].username, "user2")
        XCTAssertNil(rows[1].row)
        XCTAssertNil(rows[2].error)
        XCTAssertEqual(rows[2].lineNumber, 3)
    }

    func testPreviewSkipsEmptyAndCommentLines() throws {
        let rows = GitHubImportView.previewRows(from: "# 注释\n\nuser1, pass123")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].lineNumber, 3)
        XCTAssertNil(rows[0].error)
    }

    func testPreviewColumnCountErrors() throws {
        let rows = GitHubImportView.previewRows(from: "onlyuser\n")
        XCTAssertEqual(rows.count, 1)
        XCTAssertNotNil(rows[0].error)
        XCTAssertTrue(rows[0].error!.contains("列"))
        XCTAssertEqual(rows[0].username, "onlyuser")
        XCTAssertNil(rows[0].row)
    }

    func testPreviewTabSeparatedAndQuoted() throws {
        let rows = GitHubImportView.previewRows(from: "user1\tpass123\tJBSWY3DPEHPK3PXP")
        XCTAssertEqual(rows.count, 1)
        XCTAssertNil(rows[0].error)
        XCTAssertEqual(rows[0].kind, .totpSecret)
    }

    func testPreviewEmptyInput() throws {
        let rows = GitHubImportView.previewRows(from: "   \n# 只有注释\n")
        XCTAssertTrue(rows.isEmpty)
    }

    func testInferKind() {
        XCTAssertEqual(GitHubEditView.inferKind("123456"), .oneTimeCode)
        XCTAssertEqual(GitHubEditView.inferKind("JBSWY3DPEHPK3PXP"), .totpSecret)
        XCTAssertNil(GitHubEditView.inferKind("12345"))
        XCTAssertNil(GitHubEditView.inferKind("notbase32!!"))
        XCTAssertEqual(GitHubEditView.inferKind(" 123456 "), .oneTimeCode)
    }
}
