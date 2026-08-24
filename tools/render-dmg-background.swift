import AppKit

// ===== OpenCodeGo dmg 背景(600×400)=====
let W: CGFloat = 600, H: CGFloat = 400
guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
) else { fatalError() }
let ctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = ctx

// 背景:深紫渐变(与 icon 一致)
let bgRect = NSRect(x: 0, y: 0, width: W, height: H)
NSGradient(colors: [
    NSColor(calibratedRed: 0.24, green: 0.09, blue: 0.58, alpha: 1.0),
    NSColor(calibratedRed: 0.42, green: 0.16, blue: 0.86, alpha: 1.0),
])!.draw(in: bgRect, angle: -55)

// 顶部柔光带
NSColor(white: 1.0, alpha: 0.04).setFill()
NSBezierPath(roundedRect: NSRect(x: 0, y: H - 88, width: W, height: 88),
             xRadius: 0, yRadius: 0).fill()

// 标题
let title = "OpenCode Go" as NSString
let titleAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 44, weight: .bold),
    .foregroundColor: NSColor.white,
]
let titleSize = title.size(withAttributes: titleAttrs)
title.draw(at: NSPoint(x: (W - titleSize.width) / 2, y: H - 96), withAttributes: titleAttrs)

// 副标题
let sub = "多账号额度查询 · GitHub 登录管理" as NSString
let subAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 17, weight: .regular),
    .foregroundColor: NSColor.white.withAlphaComponent(0.72),
]
let subSize = sub.size(withAttributes: subAttrs)
sub.draw(at: NSPoint(x: (W - subSize.width) / 2, y: H - 138), withAttributes: subAttrs)

// 左侧 app 缩略图(白色圆角底 + App 图标风格小图)
let appCard = NSBezierPath(roundedRect: NSRect(x: 92, y: 92, width: 120, height: 120), xRadius: 26, yRadius: 26)
NSColor.white.withAlphaComponent(0.92).setFill()
appCard.fill()
// 卡片内迷你 icon:紫色圆角 + 三环
let mini = NSBezierPath(roundedRect: NSRect(x: 104, y: 104, width: 96, height: 96), xRadius: 20, yRadius: 20)
NSGradient(colors: [
    NSColor(calibratedRed: 0.55, green: 0.24, blue: 0.98, alpha: 1.0),
    NSColor(calibratedRed: 0.30, green: 0.11, blue: 0.72, alpha: 1.0),
])!.draw(in: mini, angle: -40)
let ring1 = NSBezierPath()
ring1.appendArc(withCenter: NSPoint(x: 152, y: 168), radius: 26, startAngle: 90, endAngle: 350, clockwise: false)
ring1.lineWidth = 9; ring1.lineCapStyle = .round
NSColor(calibratedRed: 0.20, green: 0.87, blue: 0.58, alpha: 1.0).setStroke(); ring1.stroke()
let ring2 = NSBezierPath()
ring2.appendArc(withCenter: NSPoint(x: 130, y: 126), radius: 15, startAngle: 200, endAngle: 400, clockwise: false)
ring2.lineWidth = 7; ring2.lineCapStyle = .round
NSColor(calibratedRed: 1.00, green: 0.72, blue: 0.22, alpha: 1.0).setStroke(); ring2.stroke()

// 右侧 Applications 图标(Finder 蓝文件夹风格)
let folder = NSBezierPath(roundedRect: NSRect(x: 388, y: 106, width: 120, height: 92), xRadius: 18, yRadius: 18)
NSColor(calibratedRed: 0.98, green: 0.99, blue: 1.0, alpha: 0.95).setFill()
folder.fill()
NSColor(calibratedRed: 0.80, green: 0.85, blue: 1.0, alpha: 1.0).setFill()
NSBezierPath(roundedRect: NSRect(x: 388, y: 172, width: 120, height: 26), xRadius: 13, yRadius: 13).fill()
NSColor(calibratedRed: 0.62, green: 0.70, blue: 0.95, alpha: 1.0).setFill()
NSBezierPath(roundedRect: NSRect(x: 414, y: 62, width: 68, height: 44), xRadius: 10, yRadius: 10).fill()

// 中间箭头 + 文字
let arrow = "→" as NSString
let arrowAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 72, weight: .semibold),
    .foregroundColor: NSColor.white.withAlphaComponent(0.85),
]
arrow.draw(at: NSPoint(x: 268, y: 118), withAttributes: arrowAttrs)

let hint = "拖拽到 Applications 完成安装" as NSString
let hintAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 15, weight: .medium),
    .foregroundColor: NSColor.white.withAlphaComponent(0.85),
]
let hintSize = hint.size(withAttributes: hintAttrs)
hint.draw(at: NSPoint(x: (W - hintSize.width) / 2, y: 62), withAttributes: hintAttrs)

NSGraphicsContext.restoreGraphicsState()
guard let data = rep.representation(using: .png, properties: [:]) else { fatalError() }
try! data.write(to: URL(fileURLWithPath: "/tmp/dmg-background.png"))
print("dmg background written")
