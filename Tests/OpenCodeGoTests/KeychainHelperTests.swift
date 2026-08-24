import Foundation
import XCTest
@testable import OpenCodeGo

/// 可注入「set 失败」的 Keychain mock:验证迁移的重试/失败上报逻辑(不碰真实 Keychain)
private final class FlakyKeychain: KeychainStoring {
    private(set) var storage: [String: String] = [:]
    /// 第 failAtAttempt 次 set 抛错一次(1-based);其余成功
    var failAtAttempt: Int?
    /// 置位后所有 set 一律抛错
    var failAlways = false
    private var setAttempts = 0

    func set(_ value: String, forKey key: String) throws {
        setAttempts += 1
        if failAlways || setAttempts == failAtAttempt {
            throw NSError(
                domain: "FlakyKeychain", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "模拟写入失败"])
        }
        storage[key] = value
    }
    func get(_ key: String) -> String? { storage[key] }
    func delete(_ key: String) { storage[key] = nil }
}

final class KeychainHelperTests: XCTestCase {

    /// 真实环境 Bundle.main.executablePath 存在 → selfAccess() 应能创建出访问控制对象
    /// (创建过程不访问 Keychain 存储,仅构造内存中的 SecAccess,安全)
    func testSelfAccessReturnsNonNil() {
        XCTAssertNotNil(KeychainHelper.selfAccess())
    }

    /// 迁移:项存在 → 删除重建后 get 值不变;项不存在 → 不操作;返回无失败 key
    func testMigrateKeysToSelfAccessPreservesValuesAndSkipsMissing() throws {
        let kc = InMemoryKeychain()
        try kc.set("cookie-111", forKey: "11111111-1111-1111-1111-111111111111")
        try kc.set("cookie-222", forKey: "22222222-2222-2222-2222-222222222222")

        let failed = kc.migrateKeysToSelfAccess([
            "11111111-1111-1111-1111-111111111111",
            "22222222-2222-2222-2222-222222222222",
            "missing-key",
        ])

        XCTAssertTrue(failed.isEmpty, "不应有失败 key")
        XCTAssertEqual(kc.get("11111111-1111-1111-1111-111111111111"), "cookie-111")
        XCTAssertEqual(kc.get("22222222-2222-2222-2222-222222222222"), "cookie-222")
        XCTAssertNil(kc.get("missing-key"))
    }

    /// 迁移重建首次 set 瞬时失败 → 重试成功:值保留,不计为失败
    func testMigrateRetriesAfterTransientSetFailure() throws {
        let kc = FlakyKeychain()
        try kc.set("cookie-333", forKey: "k3") // 第 1 次 set:写入初始值
        kc.failAtAttempt = 2                   // 迁移的首次重建 set 失败一次 → 重试通过

        let failed = kc.migrateKeysToSelfAccess(["k3"])

        XCTAssertTrue(failed.isEmpty)
        XCTAssertEqual(kc.get("k3"), "cookie-333")
    }

    /// 重建持续失败 → 记入返回值(调用方记日志/下次启动重试),不静默
    func testMigrateReportsFailedKeys() throws {
        let kc = FlakyKeychain()
        try kc.set("cookie-444", forKey: "k4")
        kc.failAlways = true // 迁移的所有重建 set 均失败(重试 3 次都失败)

        let failed = kc.migrateKeysToSelfAccess(["k4", "k5"])

        XCTAssertEqual(failed, ["k4"])
        XCTAssertNil(kc.get("k4"), "重建失败后项已删除(失败已上报,等待下次迁移重试)")
    }
}
