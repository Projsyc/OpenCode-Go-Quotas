import AppKit

// ===== OpenCodeGo 图标渲染(macOS app icon,1024 base)=====
// 设计:紫色渐变 squircle 背景 + 三枚错落的环形仪表(多账号·额度意象)
// 主环薄荷绿/副环琥珀/备环玫红,中央白色高光,底部柔和投影

let size: CGFloat = 1024
guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
) else { fatalError("bitmap fail") }
NSGraphicsContext.saveGraphicsState()
let ctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = ctx

let s = size
// 背景 squircle:内容区 224..800(留 macOS 透明边距)
let rect = NSRect(x: s * 0.12, y: s * 0.12, width: s * 0.76, height: s * 0.76)
let radius = rect.width * 0.225
let bgPath = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

// 底部投影
let shadowCtx = ctx.cgContext
shadowCtx.saveGState()
shadowCtx.setShadow(offset: CGSize(width: 0, height: -14), blur: 48,
                    color: NSColor.black.withAlphaComponent(0.42).cgColor)
bgPath.fill()
shadowCtx.restoreGState()

// 主体渐变(左上亮紫 → 右下深紫蓝)
let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.55, green: 0.24, blue: 0.98, alpha: 1.0),   // #8C3DFA
    NSColor(calibratedRed: 0.30, green: 0.11, blue: 0.72, alpha: 1.0),   // #4D1CB8
])!
gradient.draw(in: bgPath, angle: -40)

// 顶部柔光(增加立体感)
let topLight = NSBezierPath(ovalIn: NSRect(x: rect.minX + rect.width*0.10,
                                           y: rect.maxY - rect.height*0.42,
                                           width: rect.width*0.80,
                                           height: rect.height*0.42))
NSColor.white.withAlphaComponent(0.10).setFill()
topLight.fill()

// 内描边细线
NSColor.white.withAlphaComponent(0.16).setStroke()
bgPath.lineWidth = 5
bgPath.stroke()

// ===== 三枚环形仪表 =====
struct Ring { let center: NSPoint; let r: CGFloat; let width: CGFloat; let color: NSColor; let arc: CGFloat /* 0..1 */; let angle0: CGFloat }
let rings: [Ring] = [
    Ring(center: NSPoint(x: s*0.50, y: s*0.575), r: s*0.235, width: s*0.075, color: NSColor(calibratedRed: 0.20, green: 0.87, blue: 0.58, alpha: 1.0), arc: 0.72, angle0: 90),    // 薄荷绿 主环
    Ring(center: NSPoint(x: s*0.335, y: s*0.335), r: s*0.155, width: s*0.060, color: NSColor(calibratedRed: 1.00, green: 0.72, blue: 0.22, alpha: 1.0), arc: 0.55, angle0: 205), // 琥珀 左环
    Ring(center: NSPoint(x: s*0.665, y: s*0.315), r: s*0.135, width: s*0.055, color: NSColor(calibratedRed: 0.97, green: 0.40, blue: 0.75, alpha: 1.0), arc: 0.86, angle0: 250), // 玫红 右环
]

for ring in rings {
    // 轨道(暗底)
    let track = NSBezierPath()
    track.appendArc(withCenter: ring.center, radius: ring.r, startAngle: ring.angle0, endAngle: ring.angle0 + 360, clockwise: false)
    track.lineWidth = ring.width
    NSColor.white.withAlphaComponent(0.14).setStroke()
    track.stroke()

    // 进度弧(圆帽)
    let arc = NSBezierPath()
    arc.appendArc(withCenter: ring.center, radius: ring.r, startAngle: ring.angle0, endAngle: ring.angle0 + ring.arc * 360, clockwise: false)
    arc.lineWidth = ring.width
    arc.lineCapStyle = .round
    ring.color.setStroke()
    arc.stroke()

    // 弧高光
    let hi = NSBezierPath()
    hi.appendArc(withCenter: ring.center, radius: ring.r, startAngle: ring.angle0 + 4, endAngle: ring.angle0 + ring.arc * 360 - 6, clockwise: false)
    hi.lineWidth = ring.width * 0.32
    hi.lineCapStyle = .round
    NSColor.white.withAlphaComponent(0.30).setStroke()
    hi.stroke()
}

// 中心点缀:小圆点(Go 语言风格的小圆)
let dot = NSBezierPath(ovalIn: NSRect(x: s*0.5 - s*0.030, y: s*0.575 - s*0.030, width: s*0.060, height: s*0.060))
NSColor.white.withAlphaComponent(0.92).setFill()
dot.fill()

NSGraphicsContext.restoreGraphicsState()

// ===== 输出全尺寸 PNG =====
let outDir = URL(fileURLWithPath: "/tmp/icon/AppIcon.iconset", isDirectory: true)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func writePNG(_ sizePx: Int, scale: Int, name: String) {
    guard let data = rep.representation(using: .png, properties: [:]) else { fatalError("png fail") }
    // rep 是 1024;缩小到目标
    guard let src = NSImage(data: data) else { fatalError("img fail") }
    let target = NSSize(width: sizePx, height: sizePx)
    let small = NSImage(size: target)
    small.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high
    src.draw(in: NSRect(origin: .zero, size: target))
    small.unlockFocus()
    guard let tiff = small.tiffRepresentation,
          let bmp = NSBitmapImageRep(data: tiff),
          let png = bmp.representation(using: .png, properties: [:]) else { fatalError("small fail") }
    try? png.write(to: outDir.appendingPathComponent(name))
}

writePNG(16,  scale: 1, name: "icon_16x16.png")
writePNG(32,  scale: 2, name: "icon_16x16@2x.png")
writePNG(32,  scale: 1, name: "icon_32x32.png")
writePNG(64,  scale: 2, name: "icon_32x32@2x.png")
writePNG(128, scale: 1, name: "icon_128x128.png")
writePNG(256, scale: 2, name: "icon_128x128@2x.png")
writePNG(256, scale: 1, name: "icon_256x256.png")
writePNG(512, scale: 2, name: "icon_256x256@2x.png")
writePNG(512, scale: 1, name: "icon_512x512.png")
writePNG(1024, scale: 2, name: "icon_512x512@2x.png")
print("icons written to /tmp/icon/AppIcon.iconset")
