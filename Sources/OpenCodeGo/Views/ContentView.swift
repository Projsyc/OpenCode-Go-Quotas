import SwiftUI

/// 主界面分段:OpenCode 额度 / GitHub 账号
enum AppTab: String, CaseIterable, Identifiable {
    case opencode
    case github

    var id: String { rawValue }

    var title: String {
        switch self {
        case .opencode: return "OpenCode 额度"
        case .github: return "GitHub 账号"
        }
    }
}

struct ContentView: View {
    @Environment(AccountStore.self) private var store
    @Environment(GitHubAccountStore.self) private var githubStore
    @State private var tab: AppTab = .opencode
    @State private var showingAdd = false
    @State private var showingImport = false
    @State private var showingAddGitHub = false
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
                    tabPicker
                    if tab == .opencode {
                        if store.accounts.isEmpty {
                            emptyState
                        } else {
                            accountGrid
                        }
                    } else {
                        githubSection
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
        .sheet(isPresented: $showingImport) {
            GitHubImportView()
        }
        .sheet(isPresented: $showingAddGitHub) {
            GitHubEditView(account: nil)
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

    // MARK: - 分段切换

    private var tabPicker: some View {
        HStack(spacing: 4) {
            ForEach(AppTab.allCases) { tabOption in
                Button {
                    tab = tabOption
                } label: {
                    Text(tabOption.title)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(tab == tabOption ? Color.white : Color.secondary)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(tab == tabOption ? ThemeAccent() : Color.clear))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Capsule().fill(.ultraThinMaterial))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
        .frame(maxWidth: .infinity)
    }

    // MARK: - GitHub 账号 tab

    private var githubSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Text("GitHub 多账号")
                    .font(.title3.weight(.bold))
                Spacer()
                statChip(value: "\(githubStore.accounts.count)", label: "账号")
                Button {
                    showingImport = true
                } label: {
                    Label("批量导入", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                Button {
                    showingAddGitHub = true
                } label: {
                    Label("添加账号", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .tint(ThemeAccent())
            }
            if githubStore.accounts.isEmpty {
                githubEmptyState
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 350), spacing: 16)], spacing: 16) {
                    ForEach(githubStore.accounts) { account in
                        GitHubAccountCardView(account: account)
                    }
                }
            }
        }
    }

    private var githubEmptyState: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color(hex: 0x24292F).opacity(0.12))
                    .frame(width: 104, height: 104)
                Image(systemName: "person.crop.circle.badge.plus")
                    .font(.system(size: 34))
                    .foregroundStyle(Color(hex: 0x24292F).opacity(0.45))
            }
            VStack(spacing: 6) {
                Text("还没有 GitHub 账号")
                    .font(.title3.weight(.semibold))
                Text("批量粘贴导入「用户名 密码 验证码/TOTP 密钥」,或手动添加单个账号")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Button {
                    showingImport = true
                } label: {
                    Label("批量导入", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                Button {
                    showingAddGitHub = true
                } label: {
                    Label("添加账号", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .tint(ThemeAccent())
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
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
