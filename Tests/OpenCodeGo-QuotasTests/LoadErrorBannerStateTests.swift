import XCTest
@testable import OpenCode_Go_Quotas

final class LoadErrorBannerStateTests: XCTestCase {
    private let model = LoadErrorBannerModel(
        accountMessage: "账号数据写入失败",
        githubMessage: "GitHub 账号数据损坏")

    func testMessagesUseStableSourceOrderAndSkipMissingStores() {
        XCTAssertEqual(model.allMessages.map(\.source), [.opencodeAccount, .githubAccount])

        let accountOnly = LoadErrorBannerModel(
            accountMessage: "账号数据写入失败",
            githubMessage: nil)
        XCTAssertEqual(accountOnly.allMessages.map(\.source), [.opencodeAccount])
    }

    func testAcknowledgingOneSourceDoesNotHideTheOther() {
        let visible = model.visibleMessages(dismissing: [])
        let dismissed = LoadErrorBannerModel.dismissing(visible, in: [])

        XCTAssertEqual(dismissed, Set(LoadErrorSource.allCases))
        XCTAssertTrue(model.visibleMessages(dismissing: dismissed).isEmpty)

        let accountDismissed = dismissingOnly(.opencodeAccount)
        XCTAssertEqual(
            model.visibleMessages(dismissing: accountDismissed).map(\.source),
            [.githubAccount])
    }

    func testChangingOrClearingAStoreErrorResetsThatSourceOnly() {
        var dismissed = Set(LoadErrorSource.allCases)

        // 账号 Store 错误清空后再出现：账号重新显示，GitHub 仍保持已确认。
        dismissed = LoadErrorSource.opencodeAccount.resetting(in: dismissed)
        XCTAssertEqual(
            model.visibleMessages(dismissing: dismissed).map(\.source),
            [.opencodeAccount])

        // 用户确认新的账号错误后，GitHub 的确认状态不受影响。
        let accountMessage = model.visibleMessages(dismissing: dismissed)
            .filter { $0.source == .opencodeAccount }
        dismissed = LoadErrorBannerModel.dismissing(accountMessage, in: dismissed)
        XCTAssertTrue(model.visibleMessages(dismissing: dismissed).isEmpty)

        // GitHub Store 错误变化后，只重置 GitHub 来源。
        dismissed = LoadErrorSource.githubAccount.resetting(in: dismissed)
        XCTAssertEqual(
            model.visibleMessages(dismissing: dismissed).map(\.source),
            [.githubAccount])
    }

    private func dismissingOnly(_ source: LoadErrorSource) -> Set<LoadErrorSource> {
        let visible = model.visibleMessages(dismissing: []).filter { $0.source == source }
        return LoadErrorBannerModel.dismissing(visible, in: [])
    }
}
