import Foundation
import XCTest
@testable import OpenCode_Go_Quotas

/// UsageHistoryView 静态格式化工具的纯逻辑测试(不碰真实存储/网络)
final class UsageHistoryViewTests: XCTestCase {

    func testFmtCostKeepsTwoDecimals() {
        // 恰好 2 位小数且末位为 0 的金额必须保底 2 位小数,不得削成 "$12.0"
        XCTAssertEqual(UsageHistoryView.fmtCost(12.0), "$12.00")
        XCTAssertEqual(UsageHistoryView.fmtCost(0.1), "$0.10")
        XCTAssertEqual(UsageHistoryView.fmtCost(12.5), "$12.50")
    }

    func testFmtCostTrimsTrailingZerosBeyondTwoDecimals() {
        // 超出 2 位小数时去尾零,但保留至少 2 位小数
        XCTAssertEqual(UsageHistoryView.fmtCost(0.00123), "$0.00123")
        XCTAssertEqual(UsageHistoryView.fmtCost(12.1234), "$12.1234")
        XCTAssertEqual(UsageHistoryView.fmtCost(12.10), "$12.10")
    }
}
