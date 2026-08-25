import Foundation
import XCTest
import CommonCrypto
import CryptoKit
@testable import OpenCode_Go_Quotas

final class BrowserCookieServiceTests: XCTestCase {

    // MARK: - PBKDF2(RFC 6070 已知向量)

    func testPBKDF2RFC6070Vector() throws {
        // PBKDF2-HMAC-SHA1("password", "salt", 1, 20)
        let key = try XCTUnwrap(BrowserCookieService.deriveKey(
            password: "password", iterations: 1))
        // deriveKey 固定 16 字节,这里改用通用函数验证 20 字节
        let salt = Array("salt".utf8)
        var out = [UInt8](repeating: 0, count: 20)
        let status = CCKeyDerivationPBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2), "password", 8,
            salt, salt.count,
            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
            1, &out, 20)
        XCTAssertEqual(status, CCCryptorStatus(kCCSuccess))
        let hex = out.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(hex, "0c60c80f961f0e71f3a9b524af6012062fe037a6")
        XCTAssertEqual(key.count, 16)
    }

    // MARK: - Cookie 解密

    /// 按 Chrome 127+ 方案本地构造加密值:v10 + AES-128-CBC(零 IV)+ 32 字节 host 前缀
    private func encryptCookie(_ value: String, hostKey: String, key: Data) -> Data {
        var plain = Data(SHA256.hash(data: Data(hostKey.utf8)))
        plain.append(Data(value.utf8))
        // PKCS7 补齐
        let blockSize = 16
        let padLen = blockSize - (plain.count % blockSize)
        plain.append(Data(repeating: UInt8(padLen), count: padLen))

        var out = [UInt8](repeating: 0, count: plain.count + 16)
        var outLen = 0
        let iv = [UInt8](repeating: 0, count: 16)
        let keyBytes = [UInt8](key)
        let status = CCCrypt(
            CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES),
            CCOptions(0),
            keyBytes, keyBytes.count, iv,
            [UInt8](plain), plain.count,
            &out, out.count, &outLen)
        XCTAssertEqual(status, CCCryptorStatus(kCCSuccess))

        var result = Data("v10".utf8)
        result.append(contentsOf: out.prefix(outLen))
        return result
    }

    func testDecryptCookieValueRoundTrip() throws {
        let key = try XCTUnwrap(BrowserCookieService.deriveKey(password: "test-password"))
        let host = "opencode.ai"
        let value = "Fe26.2**abcdefghijklmnopqrstuvwxyz"
        let encrypted = encryptCookie(value, hostKey: host, key: key)

        let decrypted = try XCTUnwrap(BrowserCookieService.decryptCookieValue(
            encrypted, key: key, hostKey: host))
        XCTAssertEqual(decrypted, value)
    }

    func testDecryptCookieValueLegacyPlaintext() throws {
        // 无 v10 前缀 = 旧版明文存储
        let key = try XCTUnwrap(BrowserCookieService.deriveKey(password: "x"))
        let plain = Data("Fe26.2**legacy".utf8)
        let decrypted = try XCTUnwrap(BrowserCookieService.decryptCookieValue(
            plain, key: key, hostKey: "opencode.ai"))
        XCTAssertEqual(decrypted, "Fe26.2**legacy")
    }

    func testDecryptCookieValueWrongKeyFails() throws {
        let key = try XCTUnwrap(BrowserCookieService.deriveKey(password: "right"))
        let wrongKey = try XCTUnwrap(BrowserCookieService.deriveKey(password: "wrong"))
        let encrypted = encryptCookie("Fe26.2**abcdef", hostKey: "opencode.ai", key: key)
        XCTAssertNil(BrowserCookieService.decryptCookieValue(
            encrypted, key: wrongKey, hostKey: "opencode.ai"))
    }

    // MARK: - Chrome 时间戳

    func testChromeEpochConversion() {
        // 2027-08-09T07:38:58Z ≈ 13462270738784917 (microseconds since 1601)
        let us: Int64 = 13_462_270_738_784_917
        let date = Date(timeIntervalSince1970: Double(us) / 1_000_000 - 11_644_473_600)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        XCTAssertEqual(formatter.string(from: date), "2027-08-09T07:38:58Z")
    }

    // MARK: - SVG 路径解析

    func testSVGPathParsesAbsoluteAndRelative() {
        // 三角形(绝对坐标):100×80,等比缩放入 100×100 容器后居中
        let tri = SVGPath(data: "M10 10 L110 10 L60 90 Z")
        let path = tri.path(in: CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertFalse(path.boundingRect.isNull)
        XCTAssertEqual(path.boundingRect.width, 100, accuracy: 0.001)
        XCTAssertEqual(path.boundingRect.height, 80, accuracy: 0.001)
        XCTAssertEqual(path.boundingRect.minX, 0, accuracy: 0.001)
        XCTAssertEqual(path.boundingRect.minY, 10, accuracy: 0.001)
    }

    func testSVGPathParsesRelativeAndCurves() {
        let star = SVGPath(data: SVGBuiltIn.sparkle)
        let path = star.path(in: CGRect(x: 0, y: 0, width: 48, height: 48))
        let box = path.boundingRect
        XCTAssertFalse(box.isNull)
        // 星芒应该占据整个容器(居中缩放)
        XCTAssertLessThan(box.width, 48.1)
        XCTAssertLessThan(box.height, 48.1)
        XCTAssertGreaterThan(box.width, 40)
        XCTAssertGreaterThan(box.height, 40)

        // 相对命令 + S 平滑曲线 + 波浪
        let wave = SVGPath(data: SVGBuiltIn.wave)
        let wavePath = wave.path(in: CGRect(x: 0, y: 0, width: 240, height: 40))
        XCTAssertFalse(wavePath.boundingRect.isNull)
    }

    func testSVGPathHandlesMalformedData() {
        let junk = SVGPath(data: "NOT A PATH !!!")
        XCTAssertTrue(junk.path(in: CGRect(x: 0, y: 0, width: 100, height: 100)).boundingRect.isNull)
        let empty = SVGPath(data: "")
        XCTAssertTrue(empty.path(in: .zero).boundingRect.isNull)
    }

    // MARK: - 浏览器发现(存在性,不触碰真实数据)

    func testProfilesDiscoveryPaths() {
        // 只验证返回类型与已安装浏览器的一致性,不读取 cookie 内容
        let all = BrowserCookieService.Browser.allCases
        XCTAssertEqual(all.map(\.rawValue).sorted(), ["Chrome", "Edge"])
        XCTAssertEqual(BrowserCookieService.Browser.chrome.keychainService, "Chrome Safe Storage")
        XCTAssertEqual(BrowserCookieService.Browser.edge.keychainService, "Microsoft Edge Safe Storage")
    }
}
