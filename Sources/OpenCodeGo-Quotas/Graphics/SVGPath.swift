import SwiftUI

/// 极简 SVG path data 解析器:支持 M/m L/l H/h V/v C/c S/s Z/z,
/// 把 SVG 路径字符串渲染为 SwiftUI Shape(自动缩放适配容器)。
/// 用于界面装饰图形(星芒、波形、光斑等)。
struct SVGPath: Shape {
    let data: String

    func path(in rect: CGRect) -> Path {
        var path = Path()
        var cursor = CGPoint.zero
        var start = CGPoint.zero
        var lastControl: CGPoint?
        var command: Character? = nil

        let tokens = tokenize(data)
        var i = 0

        func readNumber() -> Double? {
            guard i < tokens.count else { return nil }
            defer { i += 1 }
            return tokens[i].number
        }

        func readPoint(relative: Bool) -> CGPoint? {
            guard let x = readNumber(), let y = readNumber() else { return nil }
            let p = CGPoint(x: x, y: y)
            return relative ? CGPoint(x: cursor.x + p.x, y: cursor.y + p.y) : p
        }

        while i < tokens.count {
            let token = tokens[i]
            if let c = token.command {
                command = c
                i += 1
            }
            guard let c = command else { break }
            let relative = c.isLowercase
            let upper = Character(String(c).uppercased())

            switch upper {
            case "M":
                if let p = readPoint(relative: relative) {
                    cursor = p
                    start = p
                    path.move(to: p)
                    // M 之后隐含 L,直到出现新命令
                    command = relative ? "l" : "L"
                }
            case "L":
                if let p = readPoint(relative: relative) {
                    cursor = p
                    path.addLine(to: p)
                }
            case "H":
                if let x = readNumber() {
                    cursor = CGPoint(x: relative ? cursor.x + x : x, y: cursor.y)
                    path.addLine(to: cursor)
                }
            case "V":
                if let y = readNumber() {
                    cursor = CGPoint(x: cursor.x, y: relative ? cursor.y + y : y)
                    path.addLine(to: cursor)
                }
            case "C":
                guard let c1 = readPoint(relative: relative),
                      let c2 = readPoint(relative: relative),
                      let p = readPoint(relative: relative)
                else { break }
                path.addCurve(to: p, control1: c1, control2: c2)
                lastControl = c2
                cursor = p
            case "S":
                // 反射上一个控制点;没有上一个 C/S 时用当前点
                var c1 = cursor
                if let prev = lastControl { c1 = CGPoint(x: cursor.x * 2 - prev.x, y: cursor.y * 2 - prev.y) }
                guard let c2 = readPoint(relative: relative),
                      let p = readPoint(relative: relative)
                else { break }
                path.addCurve(to: p, control1: c1, control2: c2)
                lastControl = c2
                cursor = p
            case "Z":
                path.closeSubpath()
                cursor = start
                lastControl = nil
            default:
                break
            }
        }

        // 缩放到目标 rect(保持宽高比,居中)
        let bbox = path.boundingRect
        guard !bbox.isNull, bbox.width > 0, bbox.height > 0 else { return path }
        let scale = min(rect.width / bbox.width, rect.height / bbox.height)
        var transform = CGAffineTransform(translationX: -bbox.minX, y: -bbox.minY)
        transform = transform.concatenating(CGAffineTransform(scaleX: scale, y: scale))
        transform = transform.concatenating(CGAffineTransform(
            translationX: rect.minX + (rect.width - bbox.width * scale) / 2,
            y: rect.minY + (rect.height - bbox.height * scale) / 2))
        return path.applying(transform)
    }

    // MARK: - tokenizer

    private struct Token {
        let command: Character?
        let number: Double?
    }

    private func tokenize(_ data: String) -> [Token] {
        var tokens: [Token] = []
        var numberBuffer = ""
        let commands: Set<Character> = ["M", "m", "L", "l", "H", "h", "V", "v", "C", "c", "S", "s", "Z", "z"]

        func flushNumber() {
            guard !numberBuffer.isEmpty else { return }
            if let v = Double(numberBuffer) { tokens.append(Token(command: nil, number: v)) }
            numberBuffer = ""
        }

        for ch in data {
            if commands.contains(ch) {
                flushNumber()
                tokens.append(Token(command: ch, number: nil))
            } else if ch == "," || ch == " " || ch == "\t" || ch == "\n" || ch == "\r" {
                flushNumber()
            } else if ch == "-" || ch == "+" || ch == "." || ch.isNumber {
                numberBuffer.append(ch)
            } else {
                flushNumber()
            }
        }
        flushNumber()
        return tokens
    }
}

// MARK: - 内置装饰图形(SVG path data)

enum SVGBuiltIn {
    /// 四角星芒(24×24 设计坐标系)
    static let sparkle = "M12 1 C13.2 7.4 16.6 10.8 23 12 C16.6 13.2 13.2 16.6 12 23 C10.8 16.6 7.4 13.2 1 12 C7.4 10.8 10.8 7.4 12 1 Z"
    /// 小十字星
    static let star4 = "M12 4 C12.8 9.2 14.8 11.2 20 12 C14.8 12.8 12.8 14.8 12 20 C11.2 14.8 9.2 12.8 4 12 C9.2 11.2 11.2 9.2 12 4 Z"
    /// 有机光斑(100×100)
    static let blob = "M50 8 C72 8 88 24 92 46 C96 68 82 92 58 96 C34 100 10 88 6 64 C2 40 28 8 50 8 Z"
    /// 波浪分隔线(240×40)
    static let wave = "M0 20 C30 8 60 8 90 20 C120 32 150 32 180 20 C210 8 225 12 240 18"
}
