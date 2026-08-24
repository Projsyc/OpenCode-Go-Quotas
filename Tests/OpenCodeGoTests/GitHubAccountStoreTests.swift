import Foundation
import XCTest
@testable import OpenCodeGo

/// 内存 Keychain mock(测试专用,绝不碰真实 Keychain)
final class MemoryKeychain: KeychainStoring {
    private(set) var storage: [String: String] = [:]
    /// 精确匹配失败的 key
    var failKeys: Set<String> = []
    /// 谓词匹配失败的 key(如所有 `-password` 后缀)
    var failPredicate: ((String) -> Bool)?

    func set(_ value: String, forKey key: String) throws {
        if failPredicate?(key) == true || failKeys.contains(key) {
            throw NSError(domain: "MemoryKeychain", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "写入失败(测试模拟)"])
        }
        storage[key] = value
    }

    func get(_ key: String) -> String? { storage[key] }
    func delete(_ key: String) { storage[key] = nil }
}

@MainActor
final class GitHubAccountStoreTests: XCTestCase {

    /// 建一个独立临时目录 + 内存 keychain 的 store(每个测试独立,不碰真实存储)
    private func makeTempStore() -> (store: GitHubAccountStore, keychain: MemoryKeychain, fileURL: URL, dir: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitHubAccountStoreTests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent("github-accounts.json")
        let keychain = MemoryKeychain()
        let store = GitHubAccountStore(keychain: keychain, fileURL: fileURL)
        return (store, keychain, fileURL, dir)
    }

    // MARK: - 增删改

    func testAddRoundTrip() throws {
        let t = makeTempStore()
        addTeardownBlock { try? FileManager.default.removeItem(at: t.dir) }

        let account = try t.store.add(
            username: "octocat", notes: "主账号",
            password: "P@ssw0rd-secret-1",
            credential: "GEZDGNBVGY3TQOJQ", kind: .totpSecret)

        XCTAssertEqual(t.store.accounts.count, 1)
        XCTAssertEqual(t.store.accounts[0].username, "octocat")
        XCTAssertEqual(t.store.accounts[0].notes, "主账号")
        XCTAssertEqual(t.store.accounts[0].credentialKind, .totpSecret)
        XCTAssertNil(t.store.accounts[0].lastCodeAt)   // TOTP 未生成过验证码
        XCTAssertEqual(t.store.password(for: account), "P@ssw0rd-secret-1")
        XCTAssertEqual(t.store.credential(for: account), "GEZDGNBVGY3TQOJQ")
        // Keychain key 约定:<uuid>-password / <uuid>-credential
        XCTAssertEqual(t.keychain.storage["\(account.id.uuidString)-password"], "P@ssw0rd-secret-1")
        XCTAssertEqual(t.keychain.storage["\(account.id.uuidString)-credential"], "GEZDGNBVGY3TQOJQ")
    }

    func testAddOneTimeCodeRecordsLastCodeAt() throws {
        let t = makeTempStore()
        addTeardownBlock { try? FileManager.default.removeItem(at: t.dir) }
        let account = try t.store.add(username: "alice", password: "pass123456", credential: "123456", kind: .oneTimeCode)
        XCTAssertNotNil(t.store.accounts[0].lastCodeAt)
        XCTAssertEqual(t.store.credential(for: account), "123456")
    }

    func testAddValidation() throws {
        let t = makeTempStore()
        addTeardownBlock { try? FileManager.default.removeItem(at: t.dir) }
        XCTAssertThrowsError(try t.store.add(username: "  ", password: "pass123456")) { error in
            XCTAssertEqual(error as? GitHubAccountStoreError, .emptyUsername)
        }
        XCTAssertThrowsError(try t.store.add(username: "bob", password: "12345")) { error in
            XCTAssertEqual(error as? GitHubAccountStoreError, .passwordTooShort)
        }
        XCTAssertThrowsError(try t.store.add(username: "carol", password: "pass123456", credential: "123456", kind: nil)) { error in
            XCTAssertEqual(error as? GitHubAccountStoreError, .credentialWithoutKind)
        }
        _ = try t.store.add(username: "Alice", password: "pass123456")
        XCTAssertThrowsError(try t.store.add(username: "alice", password: "other-pass-1")) { error in
            XCTAssertEqual(error as? GitHubAccountStoreError, .duplicateUsername("alice"))
        }
    }

    func testUpdate() throws {
        let t = makeTempStore()
        addTeardownBlock { try? FileManager.default.removeItem(at: t.dir) }
        let account = try t.store.add(
            username: "octocat", password: "P@ssw0rd-1",
            credential: "GEZDGNBVGY3TQOJQ", kind: .totpSecret)

        // 改用户名/备注
        try t.store.update(account.id, username: "octocat2", notes: "新备注")
        XCTAssertEqual(t.store.accounts[0].username, "octocat2")
        XCTAssertEqual(t.store.accounts[0].notes, "新备注")
        // 改密码,凭据留 nil 不修改
        try t.store.update(account.id, username: "octocat2", notes: "新备注", password: "P@ssw0rd-2")
        XCTAssertEqual(t.store.password(for: account), "P@ssw0rd-2")
        XCTAssertEqual(t.store.credential(for: account), "GEZDGNBVGY3TQOJQ")
        XCTAssertEqual(t.store.accounts[0].credentialKind, .totpSecret)
        // 换一次性验证码 + 类型
        try t.store.update(account.id, username: "octocat2", notes: "新备注", credential: "654321", kind: .oneTimeCode)
        XCTAssertEqual(t.store.credential(for: account), "654321")
        XCTAssertEqual(t.store.accounts[0].credentialKind, .oneTimeCode)
        XCTAssertNotNil(t.store.accounts[0].lastCodeAt)
    }

    func testDelete() throws {
        let t = makeTempStore()
        addTeardownBlock { try? FileManager.default.removeItem(at: t.dir) }
        let account = try t.store.add(
            username: "octocat", password: "P@ssw0rd-1",
            credential: "GEZDGNBVGY3TQOJQ", kind: .totpSecret)
        t.store.delete(account.id)
        XCTAssertTrue(t.store.accounts.isEmpty)
        XCTAssertNil(t.keychain.storage["\(account.id.uuidString)-password"])
        XCTAssertNil(t.keychain.storage["\(account.id.uuidString)-credential"])
    }

    // MARK: - 持久化

    func testLoadIsIdempotent() throws {
        let t = makeTempStore()
        addTeardownBlock { try? FileManager.default.removeItem(at: t.dir) }
        try t.store.add(
            username: "octocat", password: "P@ssw0rd-1",
            credential: "GEZDGNBVGY3TQOJQ", kind: .totpSecret)

        // 第二个 store 共享同一文件 + 同一 keychain → 能加载回元数据与凭据
        let store2 = GitHubAccountStore(keychain: t.keychain, fileURL: t.fileURL)
        XCTAssertEqual(store2.accounts.count, 1)
        XCTAssertEqual(store2.accounts[0].username, "octocat")
        XCTAssertEqual(store2.accounts[0].credentialKind, .totpSecret)
        XCTAssertEqual(store2.password(for: store2.accounts[0]), "P@ssw0rd-1")
    }

    func testLoadMissingFileGivesEmpty() {
        let t = makeTempStore()
        addTeardownBlock { try? FileManager.default.removeItem(at: t.dir) }
        XCTAssertTrue(t.store.accounts.isEmpty)
    }

    func testJSONFileNeverContainsSecrets() throws {
        let t = makeTempStore()
        addTeardownBlock { try? FileManager.default.removeItem(at: t.dir) }
        let password = "P@ssw0rd-verysecret-123"
        let secret = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"
        _ = try t.store.add(username: "octocat", password: password, credential: secret, kind: .totpSecret)
        _ = try t.store.add(username: "carol", password: "another-secret-456", credential: "654321", kind: .oneTimeCode)

        let json = String(decoding: try Data(contentsOf: t.fileURL), as: UTF8.self)
        XCTAssertFalse(json.contains(password))
        XCTAssertFalse(json.contains(secret))
        XCTAssertFalse(json.contains("another-secret-456"))
        XCTAssertFalse(json.contains("\"654321\""))   // 验证码不得以字符串形式出现在 JSON
        // 元数据可完整解码回(含凭据类型与时间字段)
        let decoded = try JSONDecoder().decode([GitHubAccount].self, from: Data(contentsOf: t.fileURL))
        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded.first?.credentialKind, .totpSecret)
        XCTAssertNotNil(decoded.first?.createdAt)
        XCTAssertNotNil(decoded[1].lastCodeAt)
    }

    // MARK: - 批量导入

    func testImportBatchPartialSuccess() throws {
        let t = makeTempStore()
        addTeardownBlock { try? FileManager.default.removeItem(at: t.dir) }
        _ = try t.store.add(username: "alice", password: "alice-pass-123")

        let rows = [
            GitHubImportRow(lineNumber: 1, username: "alice", password: "whatever-12345", credential: nil, kind: nil),
            GitHubImportRow(lineNumber: 2, username: "bob", password: "bob-pass-4567", credential: "GEZDGNBVGY3TQOJQ", kind: .totpSecret),
            GitHubImportRow(lineNumber: 3, username: "carol", password: "carol-pass-89", credential: "123456", kind: .oneTimeCode),
            GitHubImportRow(lineNumber: 4, username: "bob", password: "another-pass-1", credential: nil, kind: nil),
            GitHubImportRow(lineNumber: 5, username: "dave", password: "dave-pass-123", credential: nil, kind: nil),
        ]
        let summary = try t.store.importBatch(rows)
        XCTAssertEqual(summary.imported, 3)   // bob、carol、dave
        XCTAssertEqual(summary.skipped.map(\.lineNumber), [1, 4])
        XCTAssertEqual(summary.skipped.map(\.reason), ["用户名已存在", "用户名已存在"])

        XCTAssertEqual(t.store.accounts.count, 4)
        let bob = try XCTUnwrap(t.store.accounts.first { $0.username == "bob" })
        XCTAssertEqual(t.store.password(for: bob), "bob-pass-4567")
        XCTAssertEqual(t.store.credential(for: bob), "GEZDGNBVGY3TQOJQ")
        XCTAssertNil(bob.lastCodeAt)                       // TOTP 导入不记 lastCodeAt
        let carol = try XCTUnwrap(t.store.accounts.first { $0.username == "carol" })
        XCTAssertNotNil(carol.lastCodeAt)                  // 一次性验证码导入 → 记 lastCodeAt
        let dave = try XCTUnwrap(t.store.accounts.first { $0.username == "dave" })
        XCTAssertNil(dave.credentialKind)
        XCTAssertNil(t.store.credential(for: dave))
    }

    func testImportBatchSkipsInvalidRows() throws {
        let t = makeTempStore()
        addTeardownBlock { try? FileManager.default.removeItem(at: t.dir) }
        let rows = [
            GitHubImportRow(lineNumber: 1, username: " ", password: "pass123456", credential: nil, kind: nil),
            GitHubImportRow(lineNumber: 2, username: "u2", password: "123", credential: nil, kind: nil),
            GitHubImportRow(lineNumber: 3, username: "u3", password: "pass123456", credential: nil, kind: .totpSecret),
            GitHubImportRow(lineNumber: 4, username: "u4", password: "pass123456", credential: "GEZDGNBVGY3TQOJQ", kind: .totpSecret),
        ]
        let summary = try t.store.importBatch(rows)
        XCTAssertEqual(summary.imported, 1)
        XCTAssertEqual(summary.skipped.map(\.lineNumber), [1, 2, 3])
        XCTAssertEqual(summary.skipped.map(\.reason), ["用户名不能为空", "密码至少 6 个字符", "凭据数据缺失"])
        XCTAssertEqual(t.store.accounts.map(\.username), ["u4"])
    }

    func testImportBatchKeychainFailureSkipsRow() throws {
        let t = makeTempStore()
        addTeardownBlock { try? FileManager.default.removeItem(at: t.dir) }
        let rows = [
            GitHubImportRow(lineNumber: 1, username: "u1", password: "pass123456",
                            credential: "GEZDGNBVGY3TQOJQ", kind: .totpSecret),
        ]
        t.keychain.failPredicate = { $0.hasSuffix("-password") }   // 模拟 Keychain 写入失败
        let summary = try t.store.importBatch(rows)
        XCTAssertEqual(summary.imported, 0)
        XCTAssertEqual(summary.skipped.count, 1)
        XCTAssertTrue(summary.skipped[0].reason.hasPrefix("凭据写入失败"))
    }
}
