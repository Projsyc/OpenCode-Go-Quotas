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

/// 计数版内存 Keychain:统计 delete 调用,验证「指纹一致时不再迁移(不删除重建)」
private final class CountingKeychain: KeychainStoring {
    private(set) var storage: [String: String] = [:]
    private(set) var deleteCount = 0

    func set(_ value: String, forKey key: String) throws { storage[key] = value }
    func get(_ key: String) -> String? { storage[key] }
    func delete(_ key: String) { storage[key] = nil; deleteCount += 1 }
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

    // MARK: - 免提示 ACL 候选路径(b19:dmg 安装后路径变化,ACL 仍匹配)

    /// 候选路径必须同时包含当前运行路径与 /Applications 安装路径,且无重复
    func testTrustedExecutablePathsContainsCurrentAndInstallPaths() {
        let paths = KeychainHelper.trustedExecutablePaths()
        if let current = Bundle.main.executablePath {
            XCTAssertTrue(
                paths.contains(current), "候选路径应包含当前运行路径(dev 运行)")
        }
        XCTAssertTrue(
            paths.contains("/Applications/OpenCodeGo.app/Contents/MacOS/OpenCodeGo"),
            "候选路径应包含 /Applications 安装路径(dmg 安装版)")
        XCTAssertEqual(paths.count, Set(paths).count, "候选路径不应重复")
    }

    /// 非空(测试宿主可执行路径必然存在,不会返回空列表)
    func testTrustedExecutablePathsNotEmpty() {
        XCTAssertFalse(KeychainHelper.trustedExecutablePaths().isEmpty)
    }

    /// 当前指纹 = 候选路径 join,定义同构
    func testCurrentMigrationFingerprintMatchesTrustedPaths() {
        XCTAssertEqual(
            KeychainHelper.currentMigrationFingerprint(),
            KeychainHelper.trustedExecutablePaths().joined(separator: "|"))
    }

    // MARK: - 迁移标记路径指纹(b19:路径变化 → 重新迁移)

    /// 指纹判定:一致 → 不需要迁移;不一致(Bool 遗留/未存/路径变化)→ 需要迁移
    func testMigrationNeededComparesFingerprints() {
        let current = KeychainHelper.currentMigrationFingerprint()
        XCTAssertFalse(
            KeychainHelper.migrationNeeded(
                storedFingerprint: current, currentFingerprint: current),
            "指纹一致 → 不需迁移")
        XCTAssertTrue(
            KeychainHelper.migrationNeeded(
                storedFingerprint: nil, currentFingerprint: current),
            "无标记(首次)→ 需要迁移")
        XCTAssertTrue(
            KeychainHelper.migrationNeeded(
                storedFingerprint: "true", currentFingerprint: current),
            "b17 Bool 遗留标记(值非指纹)→ 需要迁移")
        XCTAssertTrue(
            KeychainHelper.migrationNeeded(
                storedFingerprint: current + "|/tmp/dev-build/OpenCodeGo",
                currentFingerprint: current),
            "路径变化(dev 构建 → 安装版)→ 需要迁移")
    }

    /// 启动迁移全流程(注入内存 keychain + 独立 defaults,不碰真实 Keychain/UserDefaults):
    /// 首次(无标记)→ 迁移并写入当前指纹;指纹一致 → 不再删除重建;指纹不一致
    /// (模拟路径变化)→ 重新迁移并更新指纹。值全程保持不变。
    func testRunSelfAccessMigrationFingerprintLifecycle() throws {
        let suite = "test.keychain.migration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)
        defer { defaults?.removePersistentDomain(forName: suite) }
        let kc = CountingKeychain()
        let key = "11111111-1111-1111-1111-111111111111"
        try kc.set("cookie-migration", forKey: key)
        let service = "test-service"
        let flag = "keychain.selfAccess.migrationDone.\(service)"

        // 1. 首次:无标记 → 迁移,值不变,写入当前路径指纹
        KeychainHelper.runSelfAccessMigration(
            service: service, keys: [key], keychain: kc, defaults: defaults!)
        XCTAssertEqual(kc.get(key), "cookie-migration", "迁移必须保留值")
        XCTAssertEqual(kc.deleteCount, 1, "首次迁移应删除重建一次")
        XCTAssertEqual(
            defaults?.string(forKey: flag),
            KeychainHelper.currentMigrationFingerprint(),
            "成功后应写入当前路径指纹")

        // 2. 指纹一致 → 直接返回,不再删除重建
        KeychainHelper.runSelfAccessMigration(
            service: service, keys: [key], keychain: kc, defaults: defaults!)
        XCTAssertEqual(kc.deleteCount, 1, "指纹一致时不应重复迁移")

        // 3. 指纹不一致(模拟路径变化,如 dev → /Applications 安装)→ 重新迁移并更新指纹
        defaults?.set("some/dev/path|/Applications/OpenCodeGo.app/Contents/MacOS/OpenCodeGo", forKey: flag)
        KeychainHelper.runSelfAccessMigration(
            service: service, keys: [key], keychain: kc, defaults: defaults!)
        XCTAssertEqual(kc.deleteCount, 2, "路径变化应重新迁移")
        XCTAssertEqual(kc.get(key), "cookie-migration", "重迁移仍须保留值")
        XCTAssertEqual(
            defaults?.string(forKey: flag),
            KeychainHelper.currentMigrationFingerprint(),
            "重迁移后指纹更新为当前路径")
    }
}
