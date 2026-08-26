import Foundation

/// 用量历史时间范围。视图与统计模型共用同一枚举，避免筛选和汇总口径漂移。
enum UsageTimeRange: String, CaseIterable, Identifiable {
    case today = "今日"
    case week = "本周"
    case month = "本月"
    case all = "全部"

    var id: String { rawValue }
}

/// 一个时间范围内的请求总数、token 总数和费用。
struct UsagePeriodSummary: Equatable, Sendable {
    var requests = 0
    var tokens = 0
    var cost = 0.0

    static func += (lhs: inout UsagePeriodSummary, rhs: UsageHistoryItem) {
        lhs.requests += 1
        lhs.tokens += rhs.totalTokens
        lhs.cost += rhs.cost
    }

    static let empty = UsagePeriodSummary()
}

/// 历史加载完成后的预计算快照。
///
/// 一次遍历同时生成今日、本周、本月、全部四组汇总；SwiftUI 只读取结果，
/// 不再在每次 body 渲染时对同一份历史反复 filter/reduce。
///
/// `calculatedAt` 也作为筛选参考时间，保证同一次计算中的四个周期互相一致。
/// 应用跨过自然日 / 周 / 月后，调用方应重新创建快照。
struct UsageStats: Equatable, Sendable {
    let calculatedAt: Date
    let today: UsagePeriodSummary
    let week: UsagePeriodSummary
    let month: UsagePeriodSummary
    let all: UsagePeriodSummary

    init(
        history: [UsageHistoryItem],
        calendar: Calendar = .current,
        now: Date = Date()
    ) {
        self.calculatedAt = now
        var stats = [UsageTimeRange: UsagePeriodSummary]()
        stats.reserveCapacity(4)
        for key in UsageTimeRange.allCases { stats[key] = .empty }

        for item in history {
            stats[.all]? += item
            if calendar.isDate(item.timeCreated, equalTo: now, toGranularity: .day) {
                stats[.today]? += item
            }
            if calendar.isDate(item.timeCreated, equalTo: now, toGranularity: .weekOfYear) {
                stats[.week]? += item
            }
            if calendar.isDate(item.timeCreated, equalTo: now, toGranularity: .month) {
                stats[.month]? += item
            }
        }

        today = stats[.today] ?? .empty
        week = stats[.week] ?? .empty
        month = stats[.month] ?? .empty
        all = stats[.all] ?? .empty
    }

    func summary(for range: UsageTimeRange) -> UsagePeriodSummary {
        switch range {
        case .today: return today
        case .week: return week
        case .month: return month
        case .all: return all
        }
    }

    /// 按指定范围筛出明细；使用快照生成时的参考时间，避免表格和汇总使用不同“现在”。
    func items(
        in history: [UsageHistoryItem],
        for range: UsageTimeRange,
        calendar: Calendar = .current
    ) -> [UsageHistoryItem] {
        history.filter { item in
            switch range {
            case .today:
                return calendar.isDate(
                    item.timeCreated, equalTo: calculatedAt, toGranularity: .day)
            case .week:
                return calendar.isDate(
                    item.timeCreated, equalTo: calculatedAt, toGranularity: .weekOfYear)
            case .month:
                return calendar.isDate(
                    item.timeCreated, equalTo: calculatedAt, toGranularity: .month)
            case .all:
                return true
            }
        }
    }

    /// 主界面多账号今日费用。
    ///
    /// 返回 `nil` 表示还没有任何账号加载过历史（保持现有“隐藏统计”语义）；
    /// 已加载但为空的历史会贡献 0，不会把整体结果变回 nil。
    static func combinedTodayCost(
        of accounts: [Account],
        calendar: Calendar = .current,
        now: Date = Date()
    ) -> Double? {
        let loadedHistories = accounts.compactMap(\.history)
        guard !loadedHistories.isEmpty else { return nil }
        return loadedHistories.reduce(0.0) { total, history in
            total + UsageStats(history: history, calendar: calendar, now: now).today.cost
        }
    }
}
