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
            ProgressView("加载用量历史…")
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
                Text(item.model)
                    .font(.caption)
                    .lineLimit(1)
            }
            .width(min: 120, ideal: 160)
            TableColumn("Provider") { item in
                Text(item.provider)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .width(90)
            TableColumn("输入") { item in
                Text("\(Self.fmt(item.inputTokens))")
                    .font(.caption.monospacedDigit())
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(80)
            TableColumn("输出") { item in
                Text("\(Self.fmt(item.outputTokens))")
                    .font(.caption.monospacedDigit())
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(80)
            TableColumn("缓存") { item in
                Text("\(Self.fmt(item.cacheReadTokens + (item.cacheWrite5mTokens ?? 0) + (item.cacheWrite1hTokens ?? 0)))")
                    .font(.caption.monospacedDigit())
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(80)
            TableColumn("费用") { item in
                Text(item.cost, format: .currency(code: "USD").precision(.fractionLength(2...4)))
                    .font(.caption.monospacedDigit())
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(90)
        }
        .alternatingRowBackgrounds()
    }

    private var footer: some View {
        HStack {
            Text("\(filtered.count) 次请求 · \(Self.fmt(totals.tokens)) tokens")
            Spacer()
            Text("合计费用: \(totals.cost, format: .currency(code: "USD").precision(.fractionLength(2...4)))")
                .fontWeight(.medium)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    static func fmt(_ n: Int) -> String {
        n.formatted(.number.grouping(.automatic))
    }
}
