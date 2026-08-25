import AppKit

// ===== OpenCode-Go-Quotas dmg 背景(600×400)=====
// 设计:深靛紫基底 + 品牌三色光斑(蓝/玫红/薄荷)+ 大仪表环弧线(呼应图标三环意象)
// + 星芒点缀 + 极简标题与安装提示。图标区留白,不画假图标——真实 Finder 图标直接
// 落在干净的背景上(DS_Store 摆位于 (150,130)/(390,130))。

let W: CGFloat = 600, H: CGFloat = 400
guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
) else { fatalError() }
let ctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = ctx

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}
func rounded(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
    let d = NSFont.systemFont(ofSize: size, weight: weight).fontDescriptor.withDesign(.rounded)!
    return NSFont(descriptor: d, size: size)!
}

// 1. 基底:深靛紫渐变(上暗下亮,带一点对角光照)
NSGradient(colors: [color(0x1C0E3E), color(0x35177F), color(0x5226C4)])!
    .draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -90)

// 2. 品牌光斑(径向渐变,呼应主题 accent:蓝/玫红/薄荷)
func glow(_ hex: UInt32, _ alpha: CGFloat, _ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) {
    guard let g = NSGradient(colorsAndLocations: (color(hex, alpha), 0.0), (color(hex, 0.0), 1.0)) else { return }
    g.draw(fromCenter: NSPoint(x: cx, y: cy), radius: 0,
           toCenter: NSPoint(x: cx, y: cy), radius: r, options: [])
}
glow(0x5B8DEF, 0.34, 80, 390, 250)     // 蓝 · 左上
glow(0xEC6EAD, 0.26, 560, 40, 260)     // 玫红 · 右下
glow(0x34D399, 0.18, 500, 350, 170)    // 薄荷 · 右上点缀

// 3. 大仪表环弧线:一道贯穿底部的弧,呼应额度仪表环
func arc(_ c: NSPoint, _ r: CGFloat, _ a0: CGFloat, _ a1: CGFloat, _ w: CGFloat) -> NSBezierPath {
    let p = NSBezierPath()
    p.appendArc(withCenter: c, radius: r, startAngle: a0, endAngle: a1, clockwise: false)
    p.lineWidth = w
    p.lineCapStyle = .round
    return p
}
let ringC = NSPoint(x: 300, y: -260)
NSColor.white.withAlphaComponent(0.05).setStroke()
arc(ringC, 478, 66, 114, 9).stroke()
NSColor.white.withAlphaComponent(0.08).setStroke()
arc(ringC, 450, 58, 122, 16).stroke()
NSColor(calibratedRed: 0.20, green: 0.87, blue: 0.58, alpha: 0.18).setStroke()
arc(ringC, 450, 62, 86, 16).stroke()

// 4. 星芒点缀(4 角星)
func sparkle(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat, _ alpha: CGFloat) {
    let p = NSBezierPath()
    p.move(to: NSPoint(x: cx, y: cy + r))
    p.curve(to: NSPoint(x: cx + r, y: cy),
            controlPoint1: NSPoint(x: cx + r * 0.16, y: cy + r * 0.16),
            controlPoint2: NSPoint(x: cx + r * 0.16, y: cy + r * 0.16))
    p.curve(to: NSPoint(x: cx, y: cy - r),
            controlPoint1: NSPoint(x: cx + r * 0.16, y: cy - r * 0.16),
            controlPoint2: NSPoint(x: cx + r * 0.16, y: cy - r * 0.16))
    p.curve(to: NSPoint(x: cx - r, y: cy),
            controlPoint1: NSPoint(x: cx - r * 0.16, y: cy - r * 0.16),
            controlPoint2: NSPoint(x: cx - r * 0.16, y: cy - r * 0.16))
    p.curve(to: NSPoint(x: cx, y: cy + r),
            controlPoint1: NSPoint(x: cx - r * 0.16, y: cy + r * 0.16),
            controlPoint2: NSPoint(x: cx - r * 0.16, y: cy + r * 0.16))
    NSColor.white.withAlphaComponent(alpha).setFill()
    p.fill()
}
sparkle(70, 320, 12, 0.30)
sparkle(130, 258, 6, 0.22)
sparkle(556, 300, 9, 0.26)
sparkle(520, 236, 5, 0.20)

// 5. 标题(带投影)+ 副标(字距放宽)
let titleSH = NSShadow()
titleSH.shadowColor = NSColor.black.withAlphaComponent(0.38)
titleSH.shadowBlurRadius = 16
titleSH.shadowOffset = NSSize(width: 0, height: -2)

let title = "OpenCode-Go-Quotas" as NSString
let titleAttrs: [NSAttributedString.Key: Any] = [
    .font: rounded(28, .semibold),
    .foregroundColor: NSColor.white,
    .kern: 0.8,
    .shadow: titleSH,
]
let titleSize = title.size(withAttributes: titleAttrs)
title.draw(at: NSPoint(x: (W - titleSize.width) / 2, y: H - 66), withAttributes: titleAttrs)

let sub = "多账号额度查询 · GitHub 登录管理" as NSString
let subAttrs: [NSAttributedString.Key: Any] = [
    .font: rounded(13, .regular),
    .foregroundColor: NSColor.white.withAlphaComponent(0.66),
    .kern: 2.4,
]
let subSize = sub.size(withAttributes: subAttrs)
sub.draw(at: NSPoint(x: (W - subSize.width) / 2, y: H - 100), withAttributes: subAttrs)

// 6. 底部安装提示(细字距)
let hint = "拖入 Applications 文件夹完成安装" as NSString
let hintAttrs: [NSAttributedString.Key: Any] = [
    .font: rounded(11, .medium),
    .foregroundColor: NSColor.white.withAlphaComponent(0.58),
    .kern: 1.6,
]
let hintSize = hint.size(withAttributes: hintAttrs)
hint.draw(at: NSPoint(x: (W - hintSize.width) / 2, y: 22), withAttributes: hintAttrs)

// 7. 上下轻柔暗角(提升纵深)
NSGradient(colors: [NSColor.black.withAlphaComponent(0.20), NSColor.black.withAlphaComponent(0.0)])!
    .draw(in: NSRect(x: 0, y: H - 130, width: W, height: 130), angle: -90)
NSGradient(colors: [NSColor.black.withAlphaComponent(0.16), NSColor.black.withAlphaComponent(0.0)])!
    .draw(in: NSRect(x: 0, y: 0, width: W, height: 110), angle: 90)

NSGraphicsContext.restoreGraphicsState()
guard let data = rep.representation(using: .png, properties: [:]) else { fatalError() }
try! data.write(to: URL(fileURLWithPath: "/tmp/dmg-background.png"))
print("dmg background written")
