import SwiftUI

struct ContentView: View {
    @Environment(AccountStore.self) private var store
    @State private var showingAdd = false
    @State private var refreshing = false

    private var todayCost: Double? {
        var total: Double? = nil
        for account in store.accounts {
            guard let history = account.history else { continue }
            let cal = Calendar.current
            let day = history.filter { cal.isDateInToday($0.timeCreated) }
                .reduce(0.0) { $0 + $1.cost }
            total = (total ?? 0) + day
        }
        return total
    }

    var body: some View {
        ZStack {
            BackgroundMesh()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    hero
                    if store.accounts.isEmpty {
                        emptyState
                    } else {
                        accountGrid
                    }
                    footnote
                }
                .padding(.horizontal, 24)
                .padding(.top, 14)
                .padding(.bottom, 20)
            }
        }
        .sheet(isPresented: $showingAdd) {
            AddEditAccountView(account: nil)
        }
    }

    // MARK: - Hero

    private var hero: some View {
        HStack(alignment: .bottom, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    GradientTitle(text: "OpenCode Go 额度")
                    if store.demoMode {
                        Text("演示")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(.orange.opacity(0.18)))
                            .foregroundStyle(.orange)
                    }
                }
                Text("多账号用量一览 · Rolling / Weekly / Monthly")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            // 统计
            HStack(spacing: 10) {
                statChip(value: "\(store.accounts.count)", label: "账号")
                if let todayCost {
                    statChip(value: todayCost.formatted(.currency(code: "USD").precision(.fractionLength(2))),
                             label: "今日费用")
                }
            }
            .padding(.bottom, 2)

            // 操作
            HStack(spacing: 10) {
                Button {
                    Task {
                        refreshing = true
                        await store.refreshAll()
                        refreshing = false
                    }
                } label: {
                    Label(refreshing ? "刷新中…" : "全部刷新", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .disabled(refreshing || store.accounts.isEmpty)

                Button {
                    showingAdd = true
                } label: {
                    Label("添加账号", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .tint(ThemeAccent())
            }
        }
        .padding(.top, 30) // hiddenTitleBar 下给交通灯留空间
    }

    private func statChip(value: String, label: String) -> some View {
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

    // MARK: - 账号网格

    private var accountGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 350), spacing: 16)], spacing: 16) {
            ForEach(store.accounts) { account in
                AccountCardView(account: account)
            }
        }
    }

    // MARK: - 空状态

    private var emptyState: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.10))
                    .frame(width: 120, height: 120)
                SVGPath(data: SVGBuiltIn.sparkle)
                    .fill(Color.blue.opacity(0.35))
                    .frame(width: 46, height: 46)
            }
            VStack(spacing: 6) {
                Text("还没有账号")
                    .font(.title3.weight(.semibold))
                Text("从浏览器一键导入,或手动填入 Workspace ID 和 Cookie")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Button {
                showingAdd = true
            } label: {
                Label("添加账号", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .tint(ThemeAccent())
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 80)
    }

    private var footnote: some View {
        HStack {
            SVGPath(data: SVGBuiltIn.wave)
                .stroke(Color.primary.opacity(0.15), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .frame(width: 120, height: 24)
            Text("额度数据来自 opencode.ai 页面解析 · Cookie 存于本机 Keychain")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
        }
    }
}

/// 主操作按钮的渐变着色(需要返回 Color 的方法包装)
private func ThemeAccent() -> Color {
    Color(hex: 0x7C6CF0)
}
