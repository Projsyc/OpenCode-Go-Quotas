import Foundation
import XCTest
@testable import OpenCode_Go_Quotas

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
            GitHubAccountInput(
                username: "octocat", notes: "主账号",
                password: "P@ssw0rd-secret-1",
                credential: "GEZDGNBVGY3TQOJQ", kind: .totpSecret))

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
        let account = try t.store.add(GitHubAccountInput(username: "alice", password: "pass123456", credential: "123456", kind: .oneTimeCode))
        XCTAssertNotNil(t.store.accounts[0].lastCodeAt)
        XCTAssertEqual(t.store.credential(for: account), "123456")
    }

    func testAddValidation() throws {
        let t = makeTempStore()
        addTeardownBlock { try? FileManager.default.removeItem(at: t.dir) }
        XCTAssertThrowsError(try t.store.add(GitHubAccountInput(username: "  ", password: "pass123456"))) { error in
            XCTAssertEqual(error as? GitHubAccountStoreError, .emptyUsername)
        }
        XCTAssertThrowsError(try t.store.add(GitHubAccountInput(username: "bob", password: "12345"))) { error in
            XCTAssertEqual(error as? GitHubAccountStoreError, .passwordTooShort)
        }
        XCTAssertThrowsError(try t.store.add(GitHubAccountInput(username: "carol", password: "pass123456", credential: "123456", kind: nil))) { error in
            XCTAssertEqual(error as? GitHubAccountStoreError, .credentialWithoutKind)
        }
        _ = try t.store.add(GitHubAccountInput(username: "Alice", password: "pass123456"))
        XCTAssertThrowsError(try t.store.add(GitHubAccountInput(username: "alice", password: "other-pass-1"))) { error in
            XCTAssertEqual(error as? GitHubAccountStoreError, .duplicateUsername("alice"))
        }
    }

    /// ghaudit:store 是校验最后一环 —— add/update 拒绝含空白字符的用户名(与 UI/解析器一致)
    func testAddAndUpdateRejectWhitespaceUsername() throws {
        let t = makeTempStore()
        addTeardownBlock { try? FileManager.default.removeItem(at: t.dir) }
        XCTAssertThrowsError(try t.store.add(GitHubAccountInput(username: "john doe", password: "pass123456"))) { error in
            XCTAssertEqual(error as? GitHubAccountStoreError, .usernameContainsWhitespace)
        }
        let account = try t.store.add(GitHubAccountInput(username: "octocat", password: "pass123456"))
        XCTAssertThrowsError(try t.store.update(
            account.id,
            input: GitHubAccountInput(username: "bob smith", password: ""),
            passwordChanged: false)) { error in
            XCTAssertEqual(error as? GitHubAccountStoreError, .usernameContainsWhitespace)
        }
        // 失败的 update 未改动内存
        XCTAssertEqual(t.store.accounts[0].username, "octocat")
    }

    /// L8:add 中第二项 Keychain 写入失败 → 回滚第一项,不留孤儿条目,内存不变
    func testAddKeychainFailureRollsBackPassword() throws {
        let t = makeTempStore()
        addTeardownBlock { try? FileManager.default.removeItem(at: t.dir) }
        t.keychain.failPredicate = { $0.hasSuffix("-credential") }   // 模拟 credential 写入失败
        XCTAssertThrowsError(try t.store.add(
            GitHubAccountInput(
                username: "octocat", password: "P@ssw0rd-1",
                credential: "GEZDGNBVGY3TQOJQ", kind: .totpSecret)))
        XCTAssertTrue(t.store.accounts.isEmpty)
        // 不得留下孤儿 <uuid>-password Keychain 条目
        XCTAssertTrue(t.keychain.storage.allSatisfy { !$0.key.hasSuffix("-password") },
                      "失败的 add 不应在 Keychain 留下孤儿条目")
    }

    /// L8:update 中 Keychain 写入失败 → 内存不变(写入前置),且已写的 password 被回滚
    func testUpdateKeychainFailureLeavesMemoryUntouched() throws {
        let t = makeTempStore()
        addTeardownBlock { try? FileManager.default.removeItem(at: t.dir) }
        let account = try t.store.add(GitHubAccountInput(username: "octocat", password: "P@ssw0rd-1"))
        t.keychain.failPredicate = { $0.hasSuffix("-credential") }
        XCTAssertThrowsError(try t.store.update(
            account.id,
            input: GitHubAccountInput(
                username: "renamed", notes: "新备注",
                password: "NewP@ss-123", credential: "GEZDGNBVGY3TQOJQ", kind: .totpSecret),
            passwordChanged: true))
        // 内存不变:用户名/备注/类型均未应用
        XCTAssertEqual(t.store.accounts[0].username, "octocat")
        XCTAssertEqual(t.store.accounts[0].notes, "")
        XCTAssertNil(t.store.accounts[0].credentialKind)
        // Keychain 回滚:密码仍是旧值,凭据未写入
        XCTAssertEqual(t.store.password(for: account), "P@ssw0rd-1")
        XCTAssertNil(t.store.credential(for: account))
    }

    func testUpdate() throws {
        let t = makeTempStore()
        addTeardownBlock { try? FileManager.default.removeItem(at: t.dir) }
        let account = try t.store.add(
            GitHubAccountInput(
                username: "octocat", password: "P@ssw0rd-1",
                credential: "GEZDGNBVGY3TQOJQ", kind: .totpSecret))

        // 改用户名/备注
        try t.store.update(
            account.id,
            input: GitHubAccountInput(username: "octocat2", notes: "新备注", password: ""),
            passwordChanged: false)
        XCTAssertEqual(t.store.accounts[0].username, "octocat2")
        XCTAssertEqual(t.store.accounts[0].notes, "新备注")
        // 改密码,凭据留 nil 不修改
        try t.store.update(
            account.id,
            input: GitHubAccountInput(username: "octocat2", notes: "新备注", password: "P@ssw0rd-2"),
            passwordChanged: true)
        XCTAssertEqual(t.store.password(for: account), "P@ssw0rd-2")
        XCTAssertEqual(t.store.credential(for: account), "GEZDGNBVGY3TQOJQ")
        XCTAssertEqual(t.store.accounts[0].credentialKind, .totpSecret)
        // 换一次性验证码 + 类型
        try t.store.update(
            account.id,
            input: GitHubAccountInput(
                username: "octocat2", notes: "新备注",
                password: "", credential: "654321", kind: .oneTimeCode),
            passwordChanged: false)
        XCTAssertEqual(t.store.credential(for: account), "654321")
        XCTAssertEqual(t.store.accounts[0].credentialKind, .oneTimeCode)
        XCTAssertNotNil(t.store.accounts[0].lastCodeAt)
    }

    func testDelete() throws {
        let t = makeTempStore()
        addTeardownBlock { try? FileManager.default.removeItem(at: t.dir) }
        let account = try t.store.add(
            GitHubAccountInput(
                username: "octocat", password: "P@ssw0rd-1",
                credential: "GEZDGNBVGY3TQOJQ", kind: .totpSecret))
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
            GitHubAccountInput(
                username: "octocat", password: "P@ssw0rd-1",
                credential: "GEZDGNBVGY3TQOJQ", kind: .totpSecret))

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
        _ = try t.store.add(GitHubAccountInput(username: "octocat", password: password, credential: secret, kind: .totpSecret))
        _ = try t.store.add(GitHubAccountInput(username: "carol", password: "another-secret-456", credential: "654321", kind: .oneTimeCode))

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
        _ = try t.store.add(GitHubAccountInput(username: "alice", password: "alice-pass-123"))

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

    /// ghaudit:直接构造的 GitHubImportRow(绕过解析器)行级防御:空白用户名 / 空串凭据
    /// 不得入库(空串凭据 + 非空 kind 会命中 (credential?, kind?) 分支写出空凭据,
    /// 导致卡片 TOTP 永远显示「—」)
    func testImportBatchSkipsWhitespaceUsernameAndEmptyCredential() throws {
        let t = makeTempStore()
        addTeardownBlock { try? FileManager.default.removeItem(at: t.dir) }
        let rows = [
            GitHubImportRow(lineNumber: 1, username: "john doe", password: "pass123456", credential: nil, kind: nil),
            GitHubImportRow(lineNumber: 2, username: "u2", password: "pass123456", credential: "", kind: .totpSecret),
            GitHubImportRow(lineNumber: 3, username: "u3", password: "pass123456", credential: "GEZDGNBVGY3TQOJQ", kind: .totpSecret),
        ]
        let summary = try t.store.importBatch(rows)
        XCTAssertEqual(summary.imported, 1)
        XCTAssertEqual(summary.skipped.map(\.lineNumber), [1, 2])
        XCTAssertEqual(summary.skipped.map(\.reason), ["用户名不能包含空白字符", "凭据数据缺失"])
        XCTAssertEqual(t.store.accounts.map(\.username), ["u3"])
    }

    /// L8:批量导入中 credential 写失败 → 回滚该行已写的 password,不留孤儿条目
    func testImportBatchKeychainFailureLeavesNoOrphan() throws {
        let t = makeTempStore()
        addTeardownBlock { try? FileManager.default.removeItem(at: t.dir) }
        let rows = [
            GitHubImportRow(lineNumber: 1, username: "u1", password: "pass123456",
                            credential: "GEZDGNBVGY3TQOJQ", kind: .totpSecret),
        ]
        t.keychain.failPredicate = { $0.hasSuffix("-credential") }  // 模拟第二项写入失败
        let summary = try t.store.importBatch(rows)
        XCTAssertEqual(summary.imported, 0)
        XCTAssertEqual(summary.skipped.count, 1)
        XCTAssertTrue(summary.skipped[0].reason.hasPrefix("凭据写入失败"))
        // 该行被跳过,不得留下孤儿 <uuid>-password 条目
        XCTAssertTrue(t.keychain.storage.allSatisfy { !$0.key.hasSuffix("-password") })
    }

    // MARK: - 写前快照 + 损坏回退

    /// 写前快照:第二次 save() 前把第一次内容快照到 github-accounts.json.bak
    func testSaveSnapshotsPreviousContentBeforeOverwrite() throws {
        let t = makeTempStore()
        addTeardownBlock { try? FileManager.default.removeItem(at: t.dir) }
        _ = try t.store.add(GitHubAccountInput(username: "first", password: "pass-123456"))
        _ = try t.store.add(GitHubAccountInput(username: "second", password: "pass-654321"))

        let backupURL = t.dir.appendingPathComponent("github-accounts.json.bak")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path), "第二次写入前必须已生成快照")
        let snapshotted = try JSONDecoder().decode([GitHubAccount].self, from: Data(contentsOf: backupURL))
        XCTAssertEqual(snapshotted.count, 1)
        XCTAssertEqual(snapshotted[0].username, "first") // 快照 = 第一次(写前)的内容
        let current = try JSONDecoder().decode([GitHubAccount].self, from: Data(contentsOf: t.fileURL))
        XCTAssertEqual(current.count, 2)
    }

    /// 首次写入(无旧文件)→ 不产生快照
    func testFirstSaveCreatesNoSnapshot() throws {
        let t = makeTempStore()
        addTeardownBlock { try? FileManager.default.removeItem(at: t.dir) }
        _ = try t.store.add(GitHubAccountInput(username: "only", password: "pass-123456"))
        let backupURL = t.dir.appendingPathComponent("github-accounts.json.bak")
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupURL.path), "首次写入无旧文件,不应产生快照")
    }

    /// 损坏回退:主文件损坏 + 快照完好 → load 返回快照内容,loadError 提示已恢复,主文件被修复
    func testLoadCorruptedFileFallsBackToSnapshot() throws {
        let t = makeTempStore()
        addTeardownBlock { try? FileManager.default.removeItem(at: t.dir) }
        _ = try t.store.add(GitHubAccountInput(username: "完好账号", password: "pass-123456"))
        _ = try t.store.add(GitHubAccountInput(username: "最新写入", password: "pass-654321"))
        // 此刻 github-accounts.json.bak = 第一次写入([完好账号])

        try Data("not json {".utf8).write(to: t.fileURL) // 模拟主文件损坏
        let store = GitHubAccountStore(keychain: t.keychain, fileURL: t.fileURL)

        XCTAssertEqual(store.accounts.count, 1)
        XCTAssertEqual(store.accounts[0].username, "完好账号") // 从快照恢复
        let error = try XCTUnwrap(store.loadError)
        XCTAssertTrue(error.contains("已从备份恢复数据"), "实际: \(error)")
        // 主文件已用快照内容修复:可直接解码且与恢复结果一致
        let restored = try JSONDecoder().decode([GitHubAccount].self, from: Data(contentsOf: t.fileURL))
        XCTAssertEqual(restored, store.accounts)
        // 损坏原件已留证(github-accounts.json.bak-<时间戳>)
        let evidence = try FileManager.default.contentsOfDirectory(atPath: t.dir.path)
            .filter { $0.hasPrefix("github-accounts.json.bak-") }
        XCTAssertEqual(evidence.count, 1)
        XCTAssertEqual(try String(contentsOf: t.dir.appendingPathComponent(evidence[0]), encoding: .utf8),
                       "not json {")
    }

    /// 损坏回退-快照缺失或同样损坏 → 空数组不崩,loadError 置位,损坏原件留证
    func testLoadCorruptedWithCorruptedSnapshotFallsBackToEmpty() throws {
        let t = makeTempStore()
        addTeardownBlock { try? FileManager.default.removeItem(at: t.dir) }
        try Data("broken main".utf8).write(to: t.fileURL)
        try Data("broken snap".utf8).write(to: t.dir.appendingPathComponent("github-accounts.json.bak"))

        let store = GitHubAccountStore(keychain: t.keychain, fileURL: t.fileURL)
        XCTAssertTrue(store.accounts.isEmpty)
        let error = try XCTUnwrap(store.loadError)
        XCTAssertTrue(error.contains("github-accounts.json.bak-"), "实际: \(error)")
        let backups = try FileManager.default.contentsOfDirectory(atPath: t.dir.path)
            .filter { $0.hasPrefix("github-accounts.json.bak-") }
        XCTAssertEqual(backups.count, 1)
    }

    /// 快照失败(旧快照被置不可变,移除/复制都失败)→ 保存仍成功、不抛,主文件正常更新
    func testSnapshotFailureDoesNotBlockSave() throws {
        let t = makeTempStore()
        let backupURL = t.dir.appendingPathComponent("github-accounts.json.bak")
        addTeardownBlock {
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: backupURL.path)
            try? FileManager.default.removeItem(at: t.dir)
        }
        _ = try t.store.add(GitHubAccountInput(username: "A", password: "pass-123456"))
        _ = try t.store.add(GitHubAccountInput(username: "B", password: "pass-654321"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path))
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: backupURL.path)

        _ = try t.store.add(GitHubAccountInput(username: "C", password: "pass-999999"))

        let current = try JSONDecoder().decode([GitHubAccount].self, from: Data(contentsOf: t.fileURL))
        XCTAssertEqual(current.count, 3) // 主文件已正常更新,保存未被快照失败阻断
        XCTAssertNil(t.store.loadError)
    }
}
