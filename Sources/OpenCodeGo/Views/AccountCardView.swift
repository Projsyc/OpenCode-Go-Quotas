import SwiftUI

/// 现代化账号卡片:头像 + 套餐 + 三档额度仪表环(Rolling/Weekly/Monthly)+ 操作
struct AccountCardView: View {
    @Environment(AccountStore.self) private var store
    let account: Account

    @State private var refreshing = false
    @State private var showingHistory = false
    @State private var showingEdit = false
    @State private var confirmingDelete = false
    @State private var hovering = false

    private var liveAccount: Account? {
        store.accounts.first { $0.id == account.id }
    }

    var body: some View {
        if let account = liveAccount {
            card(for: account)
        }
    }

    @ViewBuilder
    private func card(for account: Account) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            header(account)
            if let error = account.usageError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10).fill(.red.opacity(0.10)))
            }
            rings(account)
            Divider().opacity(0.5)
            footbar(account)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [Color.white.opacity(0.25), Color.primary.opacity(0.05)],
                                startPoint: .topLeading, endPoint: .bottomTrailing)))
                .shadow(color: .black.opacity(hovering ? 0.18 : 0.08), radius: hovering ? 16 : 10, y: 5))
        .scaleEffect(hovering ? 1.012 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: hovering)
        .onHover { hovering = $0 }
        .onTapGesture {
            if !account.historyLoading, store.cookie(for: account) != nil || store.demoMode {
                showingHistory = true
            }
        }
        .overlay(alignment: .topTrailing) {
            // SVG 装饰:卡片角上的星芒
            SVGPath(data: SVGBuiltIn.star4)
                .fill(Color.primary.opacity(0.07))
                .frame(width: 16, height: 16)
                .padding(10)
                .allowsHitTesting(false)
        }
        .sheet(isPresented: $showingEdit) { AddEditAccountView(account: account) }
        .sheet(isPresented: $showingHistory) {
            UsageHistoryView(accountID: account.id)
        }
        .confirmationDialog(
            "删除账号「\(account.name)」?此操作不会影响 opencode.ai 上的账号本身。",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) { store.deleteAccount(account.id) }
        }
    }

    // MARK: - 头部

    private func header(_ account: Account) -> some View {
        HStack(spacing: 12) {
            AccountAvatar(name: account.name)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.name.isEmpty ? "未命名账号" : account.name)
                    .font(.headline)
                HStack(spacing: 6) {
                    Text(account.workspaceId)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    if let plan = account.usage?.plan, !plan.isEmpty {
                        Text(plan)
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(.blue.opacity(0.14)))
                            .foregroundStyle(.blue)
                    }
                }
            }
            Spacer()
            if let fetchedAt = account.usage?.fetchedAt {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("更新于")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(fetchedAt, format: .dateTime.month().day().hour().minute())
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
    }

    // MARK: - 三档额度仪表环

    private func rings(_ account: Account) -> some View {
        HStack(spacing: 12) {
            GaugeRing(
                title: "Rolling",
                percent: account.usage?.rolling?.usagePercent ?? 0,
                resetText: resetText(account.usage?.rolling?.resetInSec),
                color: Color(hex: 0x5B8DEF),
                size: 76)
            GaugeRing(
                title: "Weekly",
                percent: account.usage?.weekly?.usagePercent ?? 0,
                resetText: resetText(account.usage?.weekly?.resetInSec),
                color: Color(hex: 0x8B5CF6),
                size: 76)
            GaugeRing(
                title: "Monthly",
                percent: account.usage?.monthly?.usagePercent ?? 0,
                resetText: resetText(account.usage?.monthly?.resetInSec),
                color: Color(hex: 0xEC6EAD),
                size: 76)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    private func resetText(_ seconds: Double?) -> String {
        guard let seconds else { return "—" }
        return "重置 \(Self.resetText(from: seconds))"
    }

    /// 秒数 → "2 天 16 小时" / "2 小时 52 分" / "10 分 5 秒"
    static func resetText(from seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        let days = s / 86400, hours = (s % 86400) / 3600, mins = (s % 3600) / 60
        if days > 0 { return "\(days) 天 \(hours) 小时" }
        if hours > 0 { return "\(hours) 小时 \(mins) 分" }
        if mins > 0 { return "\(mins) 分 \(s % 60) 秒" }
        return "\(s) 秒"
    }

    // MARK: - 操作栏

    private func footbar(_ account: Account) -> some View {
        HStack(spacing: 4) {
            iconButton("arrow.clockwise", help: "刷新额度") {
                Task {
                    refreshing = true
                    await store.refresh(account)
                    refreshing = false
                }
            }
            .disabled(refreshing)

            iconButton("pencil", help: "编辑账号") { showingEdit = true }
            iconButton("trash", help: "删除账号", destructive: true) { confirmingDelete = true }

            Spacer()

            Button {
                showingHistory = true
            } label: {
                Label("用量历史", systemImage: "clock.arrow.circlepath")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private func iconButton(_ systemImage: String, help: String, destructive: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(role: destructive ? .destructive : nil, action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.primary.opacity(0.06)))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
