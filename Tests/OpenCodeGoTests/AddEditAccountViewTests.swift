import Foundation
import XCTest
@testable import OpenCodeGo

/// AddEditAccountView 自动保存查重决策的纯逻辑测试(视图结构不支持直接驱动
/// onAuthCookie(需 SwiftUI 环境/登录回调),决策函数独立可测 —— 与
/// UsageHistoryViewTests 静态工具测试同构;store 层加账号不去重,防重复在本层决策)
final class AddEditAccountViewTests: XCTestCase {

    /// 无标记且 ws 未被占用 → 正常自动保存
    func testDecisionSavesWhenNoMarkerAndNoDuplicate() {
        XCTAssertEqual(
            AddEditAccountView.autoSaveDecision(
                autoSaved: false, workspaceId: "wrk_new", existingWorkspaceIds: []),
            .save)
    }

    /// 同 sheet 已自动保存过(autoSaved)→ 不再保存(即使 ws 也重复,防重优先)
    func testDecisionSkipsAfterAutoSavedInSameSheet() {
        XCTAssertEqual(
            AddEditAccountView.autoSaveDecision(
                autoSaved: true, workspaceId: "wrk_new", existingWorkspaceIds: []),
            .alreadySaved)
        XCTAssertEqual(
            AddEditAccountView.autoSaveDecision(
                autoSaved: true, workspaceId: "wrk_existing",
                existingWorkspaceIds: ["wrk_existing"]),
            .alreadySaved)
    }

    /// 识别到的 ws 已被现有账号占用 → 不自动保存(防跨 sheet/历史重复)
    func testDecisionSkipsWhenWorkspaceAlreadyExists() {
        XCTAssertEqual(
            AddEditAccountView.autoSaveDecision(
                autoSaved: false, workspaceId: "wrk_existing",
                existingWorkspaceIds: ["wrk_a", "wrk_existing"]),
            .duplicateWorkspace)
    }

    /// ws 未识别(nil)→ 不在此判定,放行由 save() 给出「未识别到 Workspace ID」提示
    func testDecisionAllowsMissingWorkspaceToFallThrough() {
        XCTAssertEqual(
            AddEditAccountView.autoSaveDecision(
                autoSaved: false, workspaceId: nil, existingWorkspaceIds: ["wrk_a", "wrk_b"]),
            .save)
    }

    /// 其余账号的 ws 与本表单不同 → 正常自动保存(同名不同 ws 不误拦)
    func testDecisionSavesWhenOtherWorkspacesDoNotMatch() {
        XCTAssertEqual(
            AddEditAccountView.autoSaveDecision(
                autoSaved: false, workspaceId: "wrk_new", existingWorkspaceIds: ["wrk_a", "wrk_b"]),
            .save)
    }
}
