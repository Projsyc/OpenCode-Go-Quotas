import SwiftUI

/// 用量历史:今日 / 本周 / 本月 / 全部 筛选 + 汇总 + 明细表
struct UsageHistoryView: View {
    @Environment(AccountStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let accountID: Account.ID

    private enum Range: String, CaseIterable, Identifiable {
        case today = "今日"
        case week = "本周"
        case month = "本月"
        case all = "全部"
        var id: String { rawValue }
    }

    @State private var range: Range = .today

    private var account: Account? {
        store.accounts.first { $0.id == accountID }
    }

    private var filtered: [UsageHistoryItem] {
        guard let history = account?.history else { return [] }
        let cal = Calendar.current
        let now = Date()
        return history.filter { item in
            switch range {
            case .today: return cal.isDateInToday(item.timeCreated)
            case .week: return cal.isDate(item.timeCreated, equalTo: now, toGranularity: .weekOfYear)
            case .month: return cal.isDate(item.timeCreated, equalTo: now, toGranularity: .month)
            case .all: return true
            }
        }
    }

    private var totals: (requests: Int, tokens: Int, cost: Double) {
        var requests = 0, tokens = 0, cost = 0.0
        for item in filtered {
            requests += 1
            tokens += item.totalTokens
            cost += item.cost
        }
        return (requests, tokens, cost)
    }

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
        HStack(spacing: 10) {
            statCard(value: Self.fmtCost(todayCost), label: "今日费用")
            statCard(value: Self.fmtCost(weekCost), label: "本周费用")
            statCard(value: Self.fmtCost(monthCost), label: "本月费用")
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
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

    private var todayCost: Double { cost(in: .today) }
    private var weekCost: Double { cost(in: .week) }
    private var monthCost: Double { cost(in: .month) }

    /// 按自然日 / 自然周 / 自然月统计全部历史的费用(不受当前筛选影响)
    private func cost(in range: Range) -> Double {
        guard let history = account?.history else { return 0 }
        let cal = Calendar.current
        let now = Date()
        return history.reduce(0.0) { acc, item in
            switch range {
            case .today: return cal.isDateInToday(item.timeCreated) ? acc + item.cost : acc
            case .week: return cal.isDate(item.timeCreated, equalTo: now, toGranularity: .weekOfYear) ? acc + item.cost : acc
            case .month: return cal.isDate(item.timeCreated, equalTo: now, toGranularity: .month) ? acc + item.cost : acc
            case .all: return acc + item.cost
            }
        }
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
                ForEach(Range.allCases) { Text($0.rawValue).tag($0) }
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
        } else if filtered.isEmpty {
            ContentUnavailableView("该时间段没有用量记录", systemImage: "tray")
        } else {
            table
        }
    }

    private var table: some View {
        Table(filtered) {
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
            Text("\(filtered.count) 次请求 · \(Self.fmtCompact(totals.tokens)) tokens")
            Spacer()
            Text("合计费用: \(Self.fmtCost(totals.cost))")
                .fontWeight(.medium)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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

    /// 费用:至少 2 位小数,超出部分去尾零(0.001230 → 0.00123)
    static func fmtCost(_ cost: Double) -> String {
        var s = cost.formatted(.currency(code: "USD").precision(.fractionLength(2...6)))
        guard let dot = s.firstIndex(of: ".") else { return s }
        let fracStart = s.index(after: dot)
        while s.distance(from: fracStart, to: s.endIndex) > 2, s.hasSuffix("0") {
            s.removeLast()
        }
        return s
    }

    private static func trimZero(_ s: String) -> String {
        s.hasSuffix(".0") ? String(s.dropLast(2)) : s
    }
}
