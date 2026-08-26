import Foundation
import XCTest
@testable import OpenCode_Go_Quotas

/// 记录 set 调用次数的 Keychain spy:用于断言 demo 模式绝不写入注入/真实的 Keychain
private final class KeychainSpy: KeychainStoring {
    private(set) var setCalls = 0
    private(set) var storage: [String: String] = [:]

    func set(_ value: String, forKey key: String) throws {
        setCalls += 1
        storage[key] = value
    }
    func get(_ key: String) -> String? { storage[key] }
    func delete(_ key: String) { storage[key] = nil }
}

@MainActor
final class GitHubAccountStoreDemoTests: XCTestCase {

    /// demo 模式 + 临时目录 + spy keychain(每个测试独立,不碰真实存储)
    private func makeDemoStore() -> (store: GitHubAccountStore, spy: KeychainSpy, fileURL: URL, dir: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitHubAccountStoreDemoTests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent("github-accounts.json")
        let spy = KeychainSpy()
        let store = GitHubAccountStore(keychain: spy, fileURL: fileURL, demoMode: true)
        return (store, spy, fileURL, dir)
    }

    // MARK: - demo 隔离

    func testDemoModePreloadsThreeFakeAccounts() {
        let t = makeDemoStore()
        addTeardownBlock { try? FileManager.default.removeItem(at: t.dir) }

        XCTAssertTrue(t.store.demoMode)
        XCTAssertEqual(t.store.accounts.count, 3)
        let kinds = Set(t.store.accounts.compactMap(\.credentialKind))
        XCTAssertEqual(kinds, [.totpSecret, .oneTimeCode])   // 三种凭据形态: TOTP / 一次性 / 仅密码
        XCTAssertTrue(t.store.accounts.contains { $0.credentialKind == nil })
    }

    func testDemoModeNeverWritesFileOrRealKeychain() throws {
        let t = makeDemoStore()
        addTeardownBlock { try? FileManager.default.removeItem(at: t.dir) }

        // 预置数据 + 导入 + 添加/清除,均不得产生任何文件或对注入 keychain 的写入
        _ = try t.store.importBatch([
            GitHubImportRow(lineNumber: 1, username: "imported-user", password: "import-pass-123",
                            credential: "GEZDGNBVGY3TQOJQ", kind: .totpSecret),
        ])
        _ = try t.store.add(GitHubAccountInput(username: "added-user", password: "added-pass-123"))
        try t.store.clearCredential(t.store.accounts[0].id)
        try t.store.delete(t.store.accounts[0].id)

        XCTAssertFalse(FileManager.default.fileExists(atPath: t.fileURL.path), "demo 模式不得创建 JSON 文件")
        XCTAssertEqual(t.spy.setCalls, 0, "demo 模式不得向注入的 Keychain 写入任何数据")
        XCTAssertTrue(t.spy.storage.isEmpty)
        // 数据仍留在内存 store 中
        XCTAssertEqual(t.store.accounts.count, 4)
        XCTAssertNotNil(t.store.credential(for: t.store.accounts[0]))
    }

    func testDemoAccountsHaveReadableCredentials() throws {
        let t = makeDemoStore()
        addTeardownBlock { try? FileManager.default.removeItem(at: t.dir) }

        let totp = try XCTUnwrap(t.store.accounts.first { $0.credentialKind == .totpSecret })
        let code = try XCTUnwrap(t.store.accounts.first { $0.credentialKind == .oneTimeCode })
        let pwdOnly = try XCTUnwrap(t.store.accounts.first { $0.credentialKind == nil })

        XCTAssertEqual(t.store.password(for: totp), "demo-pass-123456")
        XCTAssertEqual(t.store.password(for: code), "demo-pass-123456")
        XCTAssertEqual(t.store.password(for: pwdOnly), "demo-pass-123456")
        XCTAssertEqual(t.store.credential(for: totp), "JBSWY3DPEHPK3PXP")
        XCTAssertEqual(t.store.credential(for: code), "123456")
        XCTAssertNil(t.store.credential(for: pwdOnly))
    }

    func testDemoTOTPAccountCanGenerateCode() throws {
        let t = makeDemoStore()
        addTeardownBlock { try? FileManager.default.removeItem(at: t.dir) }

        let totp = try XCTUnwrap(t.store.accounts.first { $0.credentialKind == .totpSecret })
        let secret = try XCTUnwrap(t.store.credential(for: totp))
        let code = TOTPGenerator.generate(secretBase32: secret)
        XCTAssertNotNil(code)
        XCTAssertEqual(code?.count, 6)
    }

    func testDemoModeDefaultOffWhenNoFlag() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitHubAccountStoreDemoTests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        // 测试进程无 --demo 参数 → demoMode 缺省为 false(走真实文件/keychain 路径)
        let store = GitHubAccountStore(
            keychain: KeychainSpy(), fileURL: dir.appendingPathComponent("github-accounts.json"), demoMode: nil)
        XCTAssertFalse(store.demoMode)
        XCTAssertTrue(store.accounts.isEmpty)
    }

    // MARK: - 凭据清除

    func testClearCredentialRemovesCredentialButKeepsPassword() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitHubAccountStoreDemoTests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let keychain = InMemoryKeychain()
        let store = GitHubAccountStore(
            keychain: keychain, fileURL: dir.appendingPathComponent("github-accounts.json"))

        let account = try store.add(
            GitHubAccountInput(
                username: "octocat", password: "P@ssw0rd-1",
                credential: "GEZDGNBVGY3TQOJQ", kind: .totpSecret))
        XCTAssertEqual(store.credential(for: account), "GEZDGNBVGY3TQOJQ")

        try store.clearCredential(account.id)

        XCTAssertNil(store.credential(for: account), "凭据已清除")
        XCTAssertNil(keychain.storage["\(account.id.uuidString)-credential"])
        XCTAssertNil(store.accounts[0].credentialKind)
        XCTAssertNil(store.accounts[0].lastCodeAt)
        XCTAssertEqual(store.password(for: account), "P@ssw0rd-1", "密码不受影响")
        XCTAssertNotNil(keychain.storage["\(account.id.uuidString)-password"])
    }

    func testClearCredentialOnOneTimeCodeClearsLastCodeAt() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitHubAccountStoreDemoTests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let store = GitHubAccountStore(
            keychain: InMemoryKeychain(), fileURL: dir.appendingPathComponent("github-accounts.json"))

        let account = try store.add(GitHubAccountInput(username: "alice", password: "pass123456", credential: "123456", kind: .oneTimeCode))
        XCTAssertNotNil(store.accounts[0].lastCodeAt)

        try store.clearCredential(account.id)

        XCTAssertNil(store.credential(for: account))
        XCTAssertNil(store.accounts[0].credentialKind)
        XCTAssertNil(store.accounts[0].lastCodeAt)
    }
}
