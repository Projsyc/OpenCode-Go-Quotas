import SwiftUI

// MARK: - 主题色板(亮/暗自适应)

enum Theme {
    static func backgroundGradient(_ scheme: ColorScheme) -> LinearGradient {
        scheme == .dark
            ? LinearGradient(colors: [Color(hex: 0x0C0F16), Color(hex: 0x111722)], startPoint: .top, endPoint: .bottom)
            : LinearGradient(colors: [Color(hex: 0xF6F8FC), Color(hex: 0xECF0F8)], startPoint: .top, endPoint: .bottom)
    }

    /// 主渐变(用于标题、仪表环)
    static let accent = LinearGradient(
        colors: [Color(hex: 0x5B8DEF), Color(hex: 0x8B5CF6), Color(hex: 0xEC6EAD)],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    /// 光斑配色:亮色模式低透明度,暗色模式稍高
    static func blobColor(_ scheme: ColorScheme, hex: UInt32) -> Color {
        Color(hex: hex).opacity(scheme == .dark ? 0.16 : 0.10)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255)
    }
}

// MARK: - 背景装饰:渐变底 + SVG 光斑 + 星芒

struct BackgroundMesh: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            Theme.backgroundGradient(scheme)
            // SVG 光斑
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                ZStack {
                    SVGPath(data: SVGBuiltIn.blob)
                        .fill(Theme.blobColor(scheme, hex: 0x5B8DEF))
                        .frame(width: w * 0.45, height: w * 0.45)
                        .blur(radius: 60)
                        .offset(x: -w * 0.22, y: -h * 0.28)
                    SVGPath(data: SVGBuiltIn.blob)
                        .fill(Theme.blobColor(scheme, hex: 0xEC6EAD))
                        .frame(width: w * 0.38, height: w * 0.38)
                        .blur(radius: 60)
                        .offset(x: w * 0.30, y: h * 0.30)
                    SVGPath(data: SVGBuiltIn.blob)
                        .fill(Theme.blobColor(scheme, hex: 0x34D399))
                        .frame(width: w * 0.30, height: w * 0.30)
                        .blur(radius: 50)
                        .offset(x: w * 0.34, y: -h * 0.34)
                    // 星芒点缀
                    sparkles
                }
            }
            .allowsHitTesting(false)
        }
        .ignoresSafeArea()
    }

    private var sparkles: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                SVGPath(data: SVGBuiltIn.sparkle)
                    .fill(Color.white.opacity(0.25))
                    .frame(width: 22, height: 22)
                    .offset(x: w * 0.12, y: h * 0.18)
                SVGPath(data: SVGBuiltIn.sparkle)
                    .fill(Color.white.opacity(0.18))
                    .frame(width: 14, height: 14)
                    .offset(x: w * 0.82, y: h * 0.14)
                SVGPath(data: SVGBuiltIn.star4)
                    .fill(Color.white.opacity(0.20))
                    .frame(width: 10, height: 10)
                    .offset(x: w * 0.90, y: h * 0.52)
                SVGPath(data: SVGBuiltIn.star4)
                    .fill(Color.white.opacity(0.22))
                    .frame(width: 8, height: 8)
                    .offset(x: w * 0.06, y: h * 0.62)
            }
        }
    }
}

// MARK: - 额度仪表环(渐变圆弧 + 圆头端点 + 微光)

struct GaugeRing: View {
    var title: String
    var percent: Double
    var resetText: String
    var color: Color
    var size: CGFloat = 74

    private var clamped: Double { max(0, min(percent / 100, 1)) }

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.08), lineWidth: 7)
                Circle()
                    .trim(from: 0, to: clamped == 0 ? 0.004 : clamped)
                    .stroke(
                        AngularGradient(
                            colors: [color.opacity(0.55), color],
                            center: .center),
                        style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: color.opacity(0.45), radius: 3, y: 1)
                VStack(spacing: 0) {
                    Text("\(Int(percent.rounded()))%")
                        .font(.system(size: size * 0.21, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                }
            }
            .frame(width: size, height: size)

            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(resetText)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }
}

// MARK: - 账号头像(渐变色 + 首字)

struct AccountAvatar: View {
    var name: String
    var size: CGFloat = 34

    private var initial: String {
        let s = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(s.isEmpty ? "?" : s.prefix(1))
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(Theme.accent)
            Text(initial)
                .font(.system(size: size * 0.45, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .shadow(color: .purple.opacity(0.3), radius: 4, y: 1)
    }
}

// MARK: - 渐变文字标题

struct GradientTitle: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.system(size: 26, weight: .bold, design: .rounded))
            .foregroundStyle(Theme.accent)
    }
}
