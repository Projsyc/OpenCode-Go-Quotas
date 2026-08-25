import Foundation
import XCTest
@testable import OpenCode_Go_Quotas

/// GitHubAccountCardView 纯逻辑测试:一次性验证码 60 秒有效期判定
/// (原实现在 body 里一次性渲染,过期状态不自刷新;判定提取为纯函数后固化语义)
final class GitHubAccountCardViewTests: XCTestCase {

    func testOneTimeCodeExpiryBoundary() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        // 无 lastCodeAt(如旧数据 / 从未生成过)→ 视为已过期
        let noCode = GitHubAccount(username: "u1", credentialKind: .oneTimeCode)
        XCTAssertTrue(GitHubAccountCardView.isOneTimeCodeExpired(noCode, at: now))
        // 刚生成 → 未过期;59s → 仍未过期
        let fresh = GitHubAccount(username: "u2", credentialKind: .oneTimeCode, lastCodeAt: now)
        XCTAssertFalse(GitHubAccountCardView.isOneTimeCodeExpired(fresh, at: now))
        XCTAssertFalse(GitHubAccountCardView.isOneTimeCodeExpired(fresh, at: now.addingTimeInterval(59)))
        // 边界:>= 60s → 已过期(60s / 61s)
        XCTAssertTrue(GitHubAccountCardView.isOneTimeCodeExpired(fresh, at: now.addingTimeInterval(60)))
        XCTAssertTrue(GitHubAccountCardView.isOneTimeCodeExpired(fresh, at: now.addingTimeInterval(61)))
        // 仅密码账号无 lastCodeAt → 与无码账号一致(该判定只用于 oneTimeCode 行)
        let pwdOnly = GitHubAccount(username: "u3")
        XCTAssertTrue(GitHubAccountCardView.isOneTimeCodeExpired(pwdOnly, at: now))
    }
}
