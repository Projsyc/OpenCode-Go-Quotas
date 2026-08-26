import Combine
import SwiftUI

/// 用量历史:今日 / 本周 / 本月 / 全部 筛选 + 汇总 + 明细表
struct UsageHistoryView: View {
    @Environment(AccountStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    let accountID: Account.ID

    @State private var range: UsageTimeRange = .today
    /// 历史加载后的预计算汇总；body 只读取该结果。
    @State private var stats: UsageStats?
    /// 当前筛选的缓存明细与汇总，避免分段表格每次渲染重复聚合。
    @State private var selection: SelectionSnapshot?

    private struct SelectionSnapshot: Equatable {
        let items: [UsageHistoryItem]
        let summary: UsagePeriodSummary
    }

    private var account: Account? {
        store.accounts.first { $0.id == accountID }
    }

    /// 跨过自然日 / 周 / 月后刷新快照；低频时钟比每次 body 全量扫描更便宜。
    private let refreshClock = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if account?.history != nil {
                summaryStrip
                Divider()
            }
            content
            Divider()
            footer
        }
        .frame(minWidth: 760, minHeight: 460)
        .onChange(of: scenePhase) { _, _ in
            recalculateStats()
        }
        .onReceive(refreshClock) { _ in
            recalculateStats()
        }
        .onChange(of: range) { _, _ in
            applySelectedRange()
        }
        .task(id: account?.history) {
            recalculateStats()
        }
        .task {
            guard let account else { return }
            let hasCookie = store.demoMode || store.cookie(for: account) != nil
            if hasCookie && account.history == nil {
                await store.loadHistory(account)
            }
        }
    }

    // MARK: - 顶部汇总(今日 / 本周 / 本月费用,风格对齐主界面 statChip)

    private var summaryStrip: some View {
        let resolvedStats = stats ?? UsageStats(history: account?.history ?? [])
        return HStack(spacing: 10) {
            statCard(value: Self.fmtCost(resolvedStats.today.cost), label: "今日费用")
            statCard(value: Self.fmtCost(resolvedStats.week.cost), label: "本周费用")
            statCard(value: Self.fmtCost(resolvedStats.month.cost), label: "本月费用")
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    /// 只在首次渲染 / 历史加载 / 跨应用生命周期切换时重算；
    /// 后续渲染复用同一快照，保证汇总和明细的时间参考一致。
    private func recalculateStats() {
        let history = account?.history ?? []
        let newStats = UsageStats(history: history)
        apply(newStats, to: history)
    }

    private func applySelectedRange() {
        guard let stats else {
            recalculateStats()
            return
        }
        apply(stats, to: account?.history ?? [])
    }

    private func statCard(value: String, label: String) -> some View {
        VStack(spacing: 1) {
            Text(value)
                .font(.system(.headline, design: .rounded))
                .monospacedDigit()
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08))))
    }

    private func apply(_ stats: UsageStats, to history: [UsageHistoryItem]) {
        let items = stats.items(in: history, for: range)
        self.stats = stats
        selection = SelectionSnapshot(items: items, summary: Self.summary(of: items))
    }

    private var header: some View {
        HStack {
            Text(account?.name ?? "")
                .font(.title3.bold())
            Text(account?.workspaceId ?? "")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Spacer()
            Picker("", selection: $range) {
                ForEach(UsageTimeRange.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 260)
            Button("关闭") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(12)
    }

    @ViewBuilder
    private var content: some View {
        if let error = account?.historyError {
            ContentUnavailableView {
                Label("加载失败", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("重试") { if let a = account { Task { await store.loadHistory(a) } } }
            }
        } else if let account, account.historyLoading {
            ProgressView("加载中…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if account?.history == nil {
            ContentUnavailableView {
                Label("暂无数据", systemImage: "clock.arrow.circlepath")
            } description: {
                Text("点击右上角按钮从 opencode.ai 拉取用量历史")
            } actions: {
                Button("加载历史") { if let a = account { Task { await store.loadHistory(a) } } }
            }
        } else if displayedItems.isEmpty {
            ContentUnavailableView("该时间段没有用量记录", systemImage: "tray")
        } else {
            table
        }
    }

    private var table: some View {
        Table(displayedItems) {
            TableColumn("时间") { item in
                Text(item.timeCreated, format: .dateTime
                    .year().month().day().hour().minute())
                    .font(.caption.monospacedDigit())
            }
            .width(min: 130, ideal: 150)
            TableColumn("模型") { item in
                Text(item.model.isEmpty ? "未知模型" : item.model)
                    .font(.caption)
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Theme.modelColor(item.model).opacity(0.12)))
                    .foregroundStyle(Theme.modelColor(item.model))
            }
            .width(min: 130, ideal: 170)
            TableColumn("Provider") { item in
                Text(item.provider)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .width(90)
            TableColumn("输入") { item in
                Text("\(Self.fmtCompact(item.inputTokens))")
                    .font(.caption.monospacedDigit())
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(80)
            TableColumn("输出") { item in
                Text("\(Self.fmtCompact(item.outputTokens))")
                    .font(.caption.monospacedDigit())
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(80)
            TableColumn("缓存") { item in
                Text("\(Self.fmtCompact(item.cacheReadTokens + (item.cacheWrite5mTokens ?? 0) + (item.cacheWrite1hTokens ?? 0)))")
                    .font(.caption.monospacedDigit())
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(80)
            TableColumn("费用") { item in
                Text(Self.fmtCost(item.cost))
                    .font(.caption.monospacedDigit())
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(90)
        }
        .alternatingRowBackgrounds()
        .padding(.vertical, 4) // 表格滚动时首尾行不被裁切
    }

    private var footer: some View {
        HStack {
            Text("\(displayedItems.count) 次请求 · \(Self.fmtCompact(displayedSummary.tokens)) tokens")
            Spacer()
            Text("合计费用: \(Self.fmtCost(displayedSummary.cost))")
                .fontWeight(.medium)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var displayedItems: [UsageHistoryItem] {
        if let selection {
            return selection.items
        }
        // 首帧兜底：task 尚未写入缓存时仍按旧口径展示一次。
        guard let history = account?.history else { return [] }
        let now = Date()
        let calendar = Calendar.current
        return history.filter { item in
            switch range {
            case .today: return calendar.isDateInToday(item.timeCreated)
            case .week: return calendar.isDate(item.timeCreated, equalTo: now, toGranularity: .weekOfYear)
            case .month: return calendar.isDate(item.timeCreated, equalTo: now, toGranularity: .month)
            case .all: return true
            }
        }
    }

    private var displayedSummary: UsagePeriodSummary {
        if let selection {
            return selection.summary
        }
        return Self.summary(of: displayedItems)
    }

    private static func summary(of items: [UsageHistoryItem]) -> UsagePeriodSummary {
        items.reduce(into: UsagePeriodSummary.empty) { $0 += $1 }
    }

    static func fmt(_ n: Int) -> String {
        n.formatted(.number.grouping(.automatic))
    }

    /// token 可读性:≥1e6 → 1.2M、≥1e3 → 8.5K,其余千分位
    static func fmtCompact(_ n: Int) -> String {
        switch n {
        case 1_000_000...:
            return trimZero(String(format: "%.1fM", Double(n) / 1_000_000))
        case 1_000...:
            return trimZero(String(format: "%.1fK", Double(n) / 1_000))
        default:
            return fmt(n)
        }
    }

    /// 费用:至少 2 位小数,超出部分去尾零(0.001230 → 0.00123);
    /// 固定 en_US 区域,避免 "US$12.00" / 小数点差异导致金额显示与测试不稳定
    static func fmtCost(_ cost: Double) -> String {
        var s = cost.formatted(
            .currency(code: "USD")
            .locale(Locale(identifier: "en_US"))
            .precision(.fractionLength(2...6)))
        guard let dot = s.firstIndex(of: ".") else { return s }
        let fracStart = s.index(after: dot)
        // 保底 2 位小数:仅当小数位 ≥3 时才去尾零,确保 "$12.00" 不被削成 "$12.0"
        while s.distance(from: fracStart, to: s.endIndex) > 2, s.hasSuffix("0") {
            s.removeLast()
        }
        return s
    }

    private static func trimZero(_ s: String) -> String {
        s.hasSuffix(".0") ? String(s.dropLast(2)) : s
    }
}
