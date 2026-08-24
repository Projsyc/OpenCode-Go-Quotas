import SwiftUI

// MARK: - 卡片外壳(AccountCardView / GitHubAccountCardView 共用)

extension View {
    /// 卡片外壳:毛玻璃圆角容器 + 渐变描边 + 悬停阴影增强 + 轻微放大 + spring 动画。
    ///
    /// 两卡片视图的悬停阴影参数原本略有差异(透明度/半径),以参数形式保留各自现状,
    /// 抽取外壳不产生任何视觉变化。
    /// - Parameters:
    ///   - hovering: 是否悬停(决定阴影增强与放大比例)
    ///   - hoverShadowOpacity: 悬停时阴影不透明度(非悬停固定 0.08)
    ///   - hoverShadowRadius: 悬停时阴影半径(非悬停固定 10)
    func cardShell(
        hovering: Bool,
        hoverShadowOpacity: Double = 0.18,
        hoverShadowRadius: CGFloat = 16
    ) -> some View {
        background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [Color.white.opacity(0.25), Color.primary.opacity(0.05)],
                                startPoint: .topLeading, endPoint: .bottomTrailing)))
                .shadow(
                    color: .black.opacity(hovering ? hoverShadowOpacity : 0.08),
                    radius: hovering ? hoverShadowRadius : 10,
                    y: 5))
        .scaleEffect(hovering ? 1.012 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: hovering)
    }
}
