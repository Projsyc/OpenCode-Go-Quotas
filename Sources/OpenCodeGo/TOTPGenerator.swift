import CryptoKit
import Foundation

/// RFC 6238 TOTP 验证码生成器(HMAC-SHA1 + Dynamic Truncation)
enum TOTPGenerator {

    /// 生成指定时间点的 TOTP 验证码;secret 无法严格 base32 解码时返回 nil
    static func generate(secretBase32: String, at date: Date = Date(), digits: Int = 6, period: Int = 30) -> String? {
        guard digits >= 1, digits <= 10, period > 0,
              let secret = decodeBase32Strict(secretBase32), !secret.isEmpty
        else { return nil }

        // RFC 6238:计数器 T = (t - T0) / X;按无符号位模式序列化,防负数截断问题
        let counter = UInt64(bitPattern: Int64(date.timeIntervalSince1970) / Int64(period)).bigEndian
        let counterBytes = withUnsafeBytes(of: counter) { Array($0) }

        let mac = HMAC<Insecure.SHA1>.authenticationCode(
            for: counterBytes, using: SymmetricKey(data: secret))
        let digest = mac.withUnsafeBytes { Data($0) }

        // Dynamic Truncation:取摘要最后字节低 4 位为偏移,截取 4 字节
        let offset = Int(digest[digest.count - 1] & 0x0f)
        let bin = UInt32(digest[offset]) << 24
            | UInt32(digest[offset + 1]) << 16
            | UInt32(digest[offset + 2]) << 8
            | UInt32(digest[offset + 3])

        var modulus: UInt64 = 1
        for _ in 0..<digits { modulus *= 10 }
        let otp = UInt64(bin & 0x7fff_ffff) % modulus
        return String(format: "%0*d", digits, Int(otp))
    }

    /// 当前时间步剩余秒数(UI 倒计时用);周期边界(整点)返回 period
    static func remainingSeconds(at date: Date = Date(), period: Int = 30) -> Int {
        guard period > 0 else { return 0 }
        let t = Int64(date.timeIntervalSince1970)
        var remainder = t % Int64(period)
        if remainder < 0 { remainder += Int64(period) }
        return Int(Int64(period) - remainder)
    }

    /// base32 解码:忽略空白与 `=` padding;大小写均可;非法字符返回 nil。
    /// 宽松模式(历史兼容),仅供识别性判定复用;验证码生成请用 `decodeBase32Strict`。
    static func decodeBase32(_ input: String) -> Data? {
        var buffer: UInt32 = 0
        var bits = 0
        var out = Data()
        for byte in input.uppercased().utf8 {
            // 跳过空白(空格/Tab/换行)与 '=' padding
            if byte == 61 || byte == 32 || byte == 9 || byte == 10 || byte == 13 { continue }
            guard let value = base32Values[byte] else { return nil }
            buffer = (buffer << 5) | UInt32(value)
            bits += 5
            if bits >= 8 {
                bits -= 8
                out.append(UInt8((buffer >> bits) & 0xff))
            }
        }
        return out.isEmpty ? nil : out
    }

    /// RFC 4648 严格 base32 解码:供验证码生成与凭据类型判定使用。
    /// 相对 `decodeBase32` 的差异(截断/非法输入的 secret 不再"成功"解码):
    /// - '=' 仅允许出现在尾部,出现后不得再有数据字符;数据字符数 N 需满足
    ///   N % 8 ∈ {6, 7, 0}(规范编码所需 padding 为 0/1/2 个,即「数量 ≤ 2」);
    ///   完整块(0 padding)后的冗余尾部 '=' 容忍,与既有样本兼容;
    /// - 尾部残余位必须全为 0(非 0 视为截断/非规范编码,返回 nil);
    /// - 空白与大小写容忍、空结果返回 nil 与宽松版一致。
    static func decodeBase32Strict(_ input: String) -> Data? {
        var buffer: UInt32 = 0
        var bits = 0
        var out = Data()
        var dataChars = 0
        var sawPadding = false
        for byte in input.uppercased().utf8 {
            if byte == 32 || byte == 9 || byte == 10 || byte == 13 { continue }
            if byte == 61 { sawPadding = true; continue }
            guard !sawPadding, let value = base32Values[byte] else { return nil }
            dataChars += 1
            buffer = (buffer << 5) | UInt32(value)
            bits += 5
            if bits >= 8 {
                bits -= 8
                out.append(UInt8((buffer >> bits) & 0xff))
            }
        }
        guard dataChars > 0, !out.isEmpty else { return nil }
        // 规范长度:N % 8 = 0/6/7(需要 0/2/1 个 '=');其余需 3+ 个 '=' → 拒绝
        switch dataChars % 8 {
        case 0, 6, 7: break
        default: return nil
        }
        // 尾部残余位必须全 0(截断/非规范编码会留下非零余量)
        if bits > 0, (buffer & ((UInt32(1) << bits) - 1)) != 0 { return nil }
        return out
    }

    // MARK: - base32 字母表(A-Z2-7)

    private static let base32Values: [UInt8: UInt8] = {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var map: [UInt8: UInt8] = [:]
        for (i, ch) in alphabet.enumerated() {
            map[ch.asciiValue!] = UInt8(i)
        }
        return map
    }()
}
