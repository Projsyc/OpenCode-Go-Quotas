import Foundation
import XCTest
@testable import OpenCode_Go_Quotas

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

    /// L5:严格解码拒绝截断/非规范输入(宽松解码能"成功"解出的样本,严格必须拒绝)
    func testStrictDecodeRejectsTruncatedAndMalformed() {
        // 截断到非完整块的 secret(18 字符,宽松解出 11 字节 ≥ 8)→ 拒绝
        XCTAssertNil(TOTPGenerator.decodeBase32Strict("GEZDGNBVGY3TQOJQGE"))
        XCTAssertNil(TOTPGenerator.generate(secretBase32: "GEZDGNBVGY3TQOJQGE", at: Date()))
        // 7 字符截断,末字符含非零余量位 → 拒绝
        XCTAssertNil(TOTPGenerator.decodeBase32Strict("GEZDGNB"))
        // '=' 出现在非尾部 / padding 后还有数据字符 → 拒绝
        XCTAssertNil(TOTPGenerator.decodeBase32Strict("GEZD=GNBVGY3TQOJQ"))
        XCTAssertNil(TOTPGenerator.decodeBase32Strict("GEZDGNBVGY3TQOJQ=GEZDGNBV"))
        // 规范长度需要 >2 个 padding(26 字符需 6 个 '=')→ 拒绝
        XCTAssertNil(TOTPGenerator.decodeBase32Strict("GEZDGNBVGY3TQOJQGEZDGNBVGY"))
        // 空/纯 padding → 拒绝
        XCTAssertNil(TOTPGenerator.decodeBase32Strict(""))
        XCTAssertNil(TOTPGenerator.decodeBase32Strict("===="))
        // 非法字符 → 拒绝
        XCTAssertNil(TOTPGenerator.decodeBase32Strict("ABC8DEF"))
    }

    /// L5:严格解码接受全部合法变体(与宽松版解码结果一致)
    func testStrictDecodeAcceptsLegalVariants() {
        XCTAssertEqual(TOTPGenerator.decodeBase32Strict("GEZDGNBVGY3TQOJQ")?.count, 10)
        XCTAssertEqual(TOTPGenerator.decodeBase32Strict("gezdgnbvgy3tqojq")?.count, 10)
        XCTAssertEqual(TOTPGenerator.decodeBase32Strict("GEZDGNBV GY3TQOJQ")?.count, 10)
        XCTAssertEqual(TOTPGenerator.decodeBase32Strict("GEZDGNBVGY3TQOJQ====")?.count, 10) // 冗余尾部 '=' 容忍
        XCTAssertEqual(TOTPGenerator.decodeBase32Strict("GEZDGNBVGY3TQOJQ\n")?.count, 10)
        // 7 字符 + 1 padding 且余量位为 0 的合法样本
        XCTAssertEqual(TOTPGenerator.decodeBase32Strict("GEZDGAA=")?.count, 4)
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
