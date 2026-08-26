import Foundation
import XCTest
@testable import OpenCode_Go_Quotas

final class UsageStatsTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private let now = Date(timeIntervalSince1970: 1_720_612_800) // 2024-07-10 12:00 UTC

    private func date(daysAgo: Int, hoursAgo: Int = 0) -> Date {
        now.addingTimeInterval(-Double(daysAgo * 24 + hoursAgo) * 3600)
    }

    private func item(
        id: String,
        date: Date,
        tokens: Int,
        cost: Double
    ) -> UsageHistoryItem {
        UsageHistoryItem(
            id: id,
            timeCreated: date,
            model: "model",
            provider: "provider",
            inputTokens: tokens,
            outputTokens: 0,
            reasoningTokens: 0,
            cacheReadTokens: 0,
            cacheWrite5mTokens: nil,
            cacheWrite1hTokens: nil,
            cost: cost,
            keyID: "key",
            sessionID: "session",
            plan: nil)
    }

    private func sampleHistory() -> [UsageHistoryItem] {
        [
            item(id: "today", date: date(daysAgo: 0, hoursAgo: 1), tokens: 10, cost: 1.5),
            item(id: "same-week", date: date(daysAgo: 2), tokens: 20, cost: 2.5),
            item(id: "same-month-only", date: date(daysAgo: 4), tokens: 40, cost: 4.0),
            item(id: "old", date: date(daysAgo: 400), tokens: 80, cost: 8.0),
        ]
    }

    func testSinglePassComputesConsistentPeriodSummaries() {
        let stats = UsageStats(history: sampleHistory(), calendar: calendar, now: now)

        XCTAssertEqual(stats.today.requests, 1)
        XCTAssertEqual(stats.today.tokens, 10)
        XCTAssertEqual(stats.today.cost, 1.5)

        XCTAssertEqual(stats.week.requests, 2)
        XCTAssertEqual(stats.week.tokens, 30)
        XCTAssertEqual(stats.week.cost, 4.0)

        XCTAssertEqual(stats.month.requests, 3)
        XCTAssertEqual(stats.month.tokens, 70)
        XCTAssertEqual(stats.month.cost, 8.0)

        XCTAssertEqual(stats.all.requests, 4)
        XCTAssertEqual(stats.all.tokens, 150)
        XCTAssertEqual(stats.all.cost, 16.0)
        XCTAssertEqual(stats.summary(for: .all), stats.all)
    }

    func testItemsUseSnapshotReferenceTimeAndMatchSummary() throws {
        let history = sampleHistory()
        let stats = UsageStats(history: history, calendar: calendar, now: now)

        let selected = stats.items(in: history, for: .month, calendar: calendar)
        XCTAssertEqual(Set(selected.map(\.id)), ["today", "same-week", "same-month-only"])
        XCTAssertEqual(
            selected.reduce(0) { $0 + $1.totalTokens },
            stats.month.tokens)
    }

    func testCombinedTodayCostKeepsMissingHistorySemantics() {
        let loaded = Account(name: "loaded", workspaceId: "wrk_1", history: sampleHistory())
        let empty = Account(name: "empty", workspaceId: "wrk_2", history: [])
        let missing = Account(name: "missing", workspaceId: "wrk_3", history: nil)

        XCTAssertNil(UsageStats.combinedTodayCost(of: [missing], calendar: calendar, now: now))
        XCTAssertEqual(
            UsageStats.combinedTodayCost(of: [loaded], calendar: calendar, now: now),
            1.5)
        // 空历史是“已加载但为 0”，不能让多账号合计回退成 nil。
        XCTAssertEqual(
            UsageStats.combinedTodayCost(of: [loaded, empty, missing], calendar: calendar, now: now),
            1.5)
    }
}
