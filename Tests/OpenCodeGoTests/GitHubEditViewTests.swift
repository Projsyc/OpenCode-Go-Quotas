import Foundation
import XCTest
@testable import OpenCodeGo

/// GitHubEditView 密码首尾空白提示判定的纯逻辑(不碰存储 / 真实数据)
final class GitHubEditViewTests: XCTestCase {

    /// ghatips:编辑表单输入阶段实时提示 —— 密码非空且含首尾空白(保存时会被 trim,
    /// 可能是另一个密码 → 提示用户知情)。trim 后为空的纯空白不算(长度校验兜底)。
    func testPasswordContainsEdgeWhitespace() {
        XCTAssertTrue(GitHubEditView.passwordContainsEdgeWhitespace(" pass1234"))
        XCTAssertTrue(GitHubEditView.passwordContainsEdgeWhitespace("pass1234 "))
        XCTAssertTrue(GitHubEditView.passwordContainsEdgeWhitespace("  pass1234  "))
        // 保留内容(编辑态留空 = 不修改)与无首尾空白 → 不提示
        XCTAssertFalse(GitHubEditView.passwordContainsEdgeWhitespace("pass1234"))
        XCTAssertFalse(GitHubEditView.passwordContainsEdgeWhitespace(""))
        XCTAssertFalse(GitHubEditView.passwordContainsEdgeWhitespace(" "))
        XCTAssertFalse(GitHubEditView.passwordContainsEdgeWhitespace("pa ss 1234"))
    }
}
