import Foundation
import XCTest
@testable import OpenCodeGo

/// RFC 6238 官方向量(附录 B,HMAC-SHA1,key = ASCII "12345678901234567890")
final class TOTPGeneratorTests: XCTestCase {

    /// "12345678901234567890" 的 base32 编码
    private let secret = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"

    func testRFC6238Vectors() {
        let vectors: [(time: TimeInterval, expected: String)] = [
            (59, "287082"),
            (1_111_111_109, "081804"),
            (1_111_111_111, "050471"),
            (1_234_567_890, "005924"),
            (2_000_000_000, "279037"),
            (20_000_000_000, "353130"),
        ]
        for v in vectors {
            let code = TOTPGenerator.generate(
                secretBase32: secret,
                at: Date(timeIntervalSince1970: v.time))
            XCTAssertEqual(code, v.expected, "time=\(v.time)")
        }
    }

    func testBase32VariantsProduceSameCode() {
        let date = Date(timeIntervalSince1970: 1_111_111_109)
        let expected = "081804"
        XCTAssertEqual(TOTPGenerator.generate(secretBase32: secret.lowercased(), at: date), expected)
        XCTAssertEqual(TOTPGenerator.generate(secretBase32: "GEZDGNBV GY3TQOJQ GEZDGNBV GY3TQOJQ", at: date), expected)
        XCTAssertEqual(TOTPGenerator.generate(secretBase32: secret + "====", at: date), expected)
        XCTAssertEqual(TOTPGenerator.generate(secretBase32: secret + "\n", at: date), expected)
    }

    func testInvalidBase32ReturnsNil() {
        XCTAssertNil(TOTPGenerator.generate(secretBase32: "ABC8DEF", at: Date())) // '8' 不在 base32 字母表
        XCTAssertNil(TOTPGenerator.generate(secretBase32: "ABC0DEF", at: Date())) // '0' 不在 base32 字母表
        XCTAssertNil(TOTPGenerator.generate(secretBase32: "!!!", at: Date()))
        XCTAssertNil(TOTPGenerator.generate(secretBase32: "", at: Date()))
        XCTAssertNil(TOTPGenerator.generate(secretBase32: "====", at: Date()))
    }

    func testRemainingSecondsBoundaries() {
        XCTAssertEqual(TOTPGenerator.remainingSeconds(at: Date(timeIntervalSince1970: 0)), 30)
        XCTAssertEqual(TOTPGenerator.remainingSeconds(at: Date(timeIntervalSince1970: 1)), 29)
        XCTAssertEqual(TOTPGenerator.remainingSeconds(at: Date(timeIntervalSince1970: 29)), 1)
        XCTAssertEqual(TOTPGenerator.remainingSeconds(at: Date(timeIntervalSince1970: 30)), 30)
        XCTAssertEqual(TOTPGenerator.remainingSeconds(at: Date(timeIntervalSince1970: 59)), 1)
        XCTAssertEqual(TOTPGenerator.remainingSeconds(at: Date(timeIntervalSince1970: 60)), 30)
        XCTAssertEqual(TOTPGenerator.remainingSeconds(at: Date(timeIntervalSince1970: 89)), 1)
        XCTAssertEqual(TOTPGenerator.remainingSeconds(at: Date(timeIntervalSince1970: 90)), 30)
        // 自定义周期
        XCTAssertEqual(TOTPGenerator.remainingSeconds(at: Date(timeIntervalSince1970: 59), period: 60), 1)
        XCTAssertEqual(TOTPGenerator.remainingSeconds(at: Date(timeIntervalSince1970: 60), period: 60), 60)
    }
}
