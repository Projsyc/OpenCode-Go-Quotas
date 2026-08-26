import Foundation
import XCTest
@testable import OpenCode_Go_Quotas

/// GitHubLoginCoordinator 一次性注入重试纯逻辑测试(b23 审计 #8):
/// 退避序列(300ms × n 级进)与「未命中 → 重试」判定(no-authorize-btn / no-otp /
/// no-form / JS 错误 / readCookies 未命中);不测 WKWebView 交互(无真实网络)。
final class GitHubLoginViewTests: XCTestCase {

    // MARK: - 退避序列(注入前等待毫秒)

    func testInjectOneShotDelaysMsProgression() {
        XCTAssertEqual(
            GitHubLoginCoordinator.injectOneShotDelaysMs(maxAttempts: 3),
            [300, 600, 900],
            "共 3 次尝试,300ms × n 级进小退避(300/600/900)")
    }

    func testInjectOneShotDelaysMsSingleAttemptMatchesLegacy() {
        XCTAssertEqual(GitHubLoginCoordinator.injectOneShotDelaysMs(maxAttempts: 1), [300],
                       "仅 1 次尝试 = 原有 300ms 单次注入行为,向后兼容")
    }

    func testInjectOneShotDelaysMsNonPositiveIsEmpty() {
        XCTAssertEqual(GitHubLoginCoordinator.injectOneShotDelaysMs(maxAttempts: 0), [])
        XCTAssertEqual(GitHubLoginCoordinator.injectOneShotDelaysMs(maxAttempts: -1), [])
    }

    func testInjectOneShotMaxAttemptsContract() {
        XCTAssertEqual(GitHubLoginCoordinator.injectOneShotMaxAttempts, 3, "首次 + 最多 2 次重试(共 3 次)")
        XCTAssertEqual(
            GitHubLoginCoordinator.injectOneShotDelaysMs(
                maxAttempts: GitHubLoginCoordinator.injectOneShotMaxAttempts).count,
            GitHubLoginCoordinator.injectOneShotMaxAttempts,
            "退避序列长度应与总尝试次数一致")
    }

    // MARK: - 未命中判定(目标未就绪 → 重试)

    func testInjectOneShotShouldRetryMissProtocols() {
        for result in ["no-authorize-btn", "no-otp", "no-form"] {
            XCTAssertTrue(GitHubLoginCoordinator.injectOneShotShouldRetry(result),
                          "\(result) 应视为目标元素未就绪,触发受控重试")
        }
    }

    func testInjectOneShotShouldRetryJSErrorIsConservative() {
        XCTAssertTrue(GitHubLoginCoordinator.injectOneShotShouldRetry(nil),
                      "JS 执行出错 / 无返回值 → 保守重试")
    }

    func testInjectOneShotShouldRetryHitsDoNotRetry() {
        for result in ["authorized", "submitted", "otp-filled", "filled", "already-filled"] {
            XCTAssertFalse(GitHubLoginCoordinator.injectOneShotShouldRetry(result),
                           "\(result) 应视为命中,不再重试")
        }
    }

    // MARK: - 启动加载阶段守护超时(b23 审计 #9)

    /// 契约:start() 起 15s 内未到达首个关键步骤(进入 github 登录页/授权页,
    /// 即离开 idle/loadingLoginPage)→ 判失败。阶段超时只覆盖启动加载段,
    /// 必须明显短于全局 300s 无进展超时;阶段达成后由全局超时继续兜底
    func testLoginStageTimeoutContract() {
        XCTAssertEqual(GitHubLoginCoordinator.loginStageTimeout, .seconds(15),
                       "启动加载阶段守护超时 = 15s")
        XCTAssertLessThan(GitHubLoginCoordinator.loginStageTimeout, GitHubLoginCoordinator.loginTimeout,
                          "阶段超时必须短于全局 300s 无进展超时(阶段内不依赖全局超时)")
        XCTAssertTrue(GitHubLoginCoordinator.loginStageTimeoutMessage.contains("登录页加载超时"),
                      "失败文案须明确「登录页加载超时」")
        XCTAssertTrue(GitHubLoginCoordinator.loginStageTimeoutMessage.contains("15s"),
                      "失败文案须带超时时长,用户可据此判断重试")
    }

    // MARK: - readCookiesJS 结果(JSON 串)

    func testInjectOneShotShouldRetryReadCookiesJSON() {
        // 未取到 auth 且未点击登录入口(SPA 未渲染完)→ 重试
        XCTAssertTrue(GitHubLoginCoordinator.injectOneShotShouldRetry(#"{"auth":null,"clicked":false}"#))
        // 缺少 clicked 键:无任何进展 → 保守重试
        XCTAssertTrue(GitHubLoginCoordinator.injectOneShotShouldRetry(#"{"auth":null}"#))
        // 已点击入口(等待跳转)→ 不重试
        XCTAssertFalse(GitHubLoginCoordinator.injectOneShotShouldRetry(#"{"auth":null,"clicked":true}"#))
        // 已取到 auth=Fe26... cookie → 不重试
        XCTAssertFalse(GitHubLoginCoordinator.injectOneShotShouldRetry(#"{"auth":"Fe26.1.abc"}"#))
        // 异常返回(非 JSON)→ 保守重试
        XCTAssertTrue(GitHubLoginCoordinator.injectOneShotShouldRetry("{malformed"))
    }
}
