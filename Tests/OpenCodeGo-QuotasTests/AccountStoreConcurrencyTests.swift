import Foundation
import XCTest
@testable import OpenCode_Go_Quotas

// MARK: - 非隔离小工具(供 URLProtocol handler 闭包直接调用,不依赖 MainActor)

private func okResponse(_ url: URL, body: String) -> (HTTPURLResponse, Data) {
    (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
}

private func errorResponse(_ url: URL, statusCode: Int) -> (HTTPURLResponse, Data) {
    (HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil)!, Data())
}

/// 从 RPC 请求体里取出 cursor(页码索引):t.a[1].s;非 RPC 请求返回 -1
private func requestCursor(_ request: URLRequest) -> Int {
    let bodyData = request.httpBody ?? readBodyStream(request)
    guard let body = bodyData.flatMap({ try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any],
          let t = body["t"] as? [String: Any],
          let a = t["a"] as? [[String: Any]],
          a.count > 1,
          let c = a[1]["s"] as? Int
    else { return -1 }
    return c
}

private func readBodyStream(_ request: URLRequest) -> Data? {
    guard let stream = request.httpBodyStream else { return nil }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
        let n = stream.read(&buffer, maxLength: buffer.count)
        if n <= 0 { break }
        data.append(buffer, count: n)
    }
    return data
}

/// 可配置 set 抛错的 Keychain mock(L8 用)
private final class ThrowingKeychain: KeychainStoring {
    private(set) var storage: [String: String] = [:]
    var failSet = false

    func set(_ value: String, forKey key: String) throws {
        if failSet { throw TestKeychainError.writeFailed }
        storage[key] = value
    }
    func get(_ key: String) -> String? { storage[key] }
    func delete(_ key: String) { storage[key] = nil }
}

private enum TestKeychainError: Error {
    case writeFailed
}

/// 线程安全请求计数器:按 key(workspaceId)记录每个账号的请求序号(1-based),
/// 用于区分「首轮」与「重试」请求,并统计总请求数(不同账号的请求并发交错)
private final class RequestCounter {
    private let lock = NSLock()
    private var attempts: [String: Int] = [:]

    /// 记录一次请求并返回该账号的当前请求序号(1-based)
    func next(_ key: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let n = (attempts[key] ?? 0) + 1
        attempts[key] = n
        return n
    }

    /// 全部账号的累计请求数
    var total: Int {
        lock.lock()
        defer { lock.unlock() }
        return attempts.values.reduce(0, +)
    }
}

/// 可控制交付时序的 URLProtocol(仅本文件测试用):
/// startLoading 立即返回,响应体在后台队列等 gate 后交付——不阻塞 URLSession 的
/// 协议加载队列,因此同一 session 可有多个请求同时在途(在 handler 里 gate.wait()
/// 会串行化后续协议加载,无法复现「两个 fetch 同时挂起」的并行时序)。
/// gates 按实例创建顺序消费:nil = 该请求立即交付;DispatchSemaphore = 交付前等待。
private final class GatedURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (URLResponse, Data))?
    nonisolated(unsafe) static var gates: [DispatchSemaphore?] = []
    nonisolated(unsafe) static var startedExpectation: XCTestExpectation?
    private static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let gate = Self.gates.isEmpty ? nil : Self.gates.removeFirst()
        Self.startedExpectation?.fulfill()
        Self.lock.unlock()

        let response: URLResponse
        let data: Data
        do {
            guard let handler = Self.handler else { throw URLError(.badServerResponse) }
            (response, data) = try handler(request)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            gate?.wait()
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

// MARK: - 测试

/// H1:刷新/历史在途时删除账号 → 按 id 重查下标,不越界崩溃、不写错账号
/// M4:损坏 accounts.json → 备份 + loadError,绝不静默清空
/// L8:updateAccount Keychain 写失败 → 内存/磁盘保持一致
@MainActor
final class AccountStoreConcurrencyTests: XCTestCase {

    override func tearDown() {
        MockURLProtocol.handler = nil
        GatedURLProtocol.handler = nil
        GatedURLProtocol.gates = []
        GatedURLProtocol.startedExpectation = nil
        super.tearDown()
    }

    /// 独立临时目录 + 内存 keychain + mock client 的 store(每个测试独立,不碰真实存储)
    private func makeTempStore(keychain: KeychainStoring = InMemoryKeychain())
        -> (store: AccountStore, fileURL: URL, dir: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AccountStoreConcurrencyTests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent("accounts.json")
        let store = AccountStore(client: makeClient(), keychain: keychain, fileURL: fileURL)
        return (store, fileURL, dir)
    }

    /// 用 GatedURLProtocol 的 store:可让多个请求同时在途并控制交付顺序
    private func makeGatedTempStore(keychain: KeychainStoring = InMemoryKeychain())
        -> (store: AccountStore, fileURL: URL, dir: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AccountStoreConcurrencyTests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent("accounts.json")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GatedURLProtocol.self]
        let store = AccountStore(
            client: QuotaClient(session: URLSession(configuration: config)),
            keychain: keychain,
            fileURL: fileURL)
        return (store, fileURL, dir)
    }

    // MARK: - H1:await 在途时删除账号

    /// 刷新 B 在途时删除前方的 A → 下标漂移;修复后按 id 重查:
    /// 不崩溃,B(新下标 0)被正确写入,其余账号(C)不被错误写入
    func testRefreshWhilePrecedingAccountDeletedWritesCorrectAccount() async throws {
        let t = makeTempStore()
        addTeardownBlock { try? FileManager.default.removeItem(at: t.dir) }
        _ = try t.store.addAccount(name: "A", workspaceId: validWorkspace, authCookie: validCookie, notes: "")
        _ = try t.store.addAccount(name: "B", workspaceId: validWorkspace, authCookie: validCookie, notes: "")
        _ = try t.store.addAccount(name: "C", workspaceId: validWorkspace, authCookie: validCookie, notes: "")
        let accountB = t.store.accounts[1]

        // 可挂起的 handler:fetch 真正开始后一直挂起,直到测试删完账号才放行
        let handlerStarted = XCTestExpectation(description: "fetchGoQuota 已开始")
        let gate = DispatchSemaphore(value: 0)
        MockURLProtocol.handler = { request in
            handlerStarted.fulfill()
            gate.wait()
            return okResponse(request.url!, body: quotaHTML)
        }

        let task = Task { await t.store.refresh(accountB) }
        await fulfillment(of: [handlerStarted], timeout: 5)

        t.store.deleteAccount(t.store.accounts[0].id) // 删除 A → B 的下标 1 → 0
        gate.signal()
        await task.value

        XCTAssertEqual(t.store.accounts.count, 2)
        let b = t.store.accounts[0]
        let c = t.store.accounts[1]
        XCTAssertEqual(b.id, accountB.id)
        // B 被正确写入(按 id 重查后的新下标)
        XCTAssertEqual(b.usage?.rolling?.usagePercent ?? -1, 34.567, accuracy: 0.0001)
        XCTAssertNil(b.usageError)
        // C 未被错误写入
        XCTAssertNil(c.usage)
        XCTAssertNil(c.usageError)
    }

    /// 刷新在途时把「被刷新账号本身」删除 → 恢复后查无此人,静默返回,不崩溃
    func testRefreshWhileAccountItselfDeletedSilentlyReturns() async throws {
        let t = makeTempStore()
        addTeardownBlock { try? FileManager.default.removeItem(at: t.dir) }
        _ = try t.store.addAccount(name: "A", workspaceId: validWorkspace, authCookie: validCookie, notes: "")

        let handlerStarted = XCTestExpectation(description: "fetchGoQuota 已开始")
        let gate = DispatchSemaphore(value: 0)
        MockURLProtocol.handler = { request in
            handlerStarted.fulfill()
            gate.wait()
            return okResponse(request.url!, body: quotaHTML)
        }

        let task = Task { await t.store.refresh(t.store.accounts[0]) }
        await fulfillment(of: [handlerStarted], timeout: 5)

        t.store.deleteAccount(t.store.accounts[0].id)
        gate.signal()
        await task.value

        XCTAssertTrue(t.store.accounts.isEmpty) // 不崩溃,静默返回
    }

    /// 刷新失败(HTTP 500)在途时删除账号 → catch 分支同样按 id 重查,不崩溃
    func testRefreshErrorWhileAccountDeletedDoesNotCrash() async throws {
        let t = makeTempStore()
        addTeardownBlock { try? FileManager.default.removeItem(at: t.dir) }
        _ = try t.store.addAccount(name: "A", workspaceId: validWorkspace, authCookie: validCookie, notes: "")

        let handlerStarted = XCTestExpectation(description: "fetchGoQuota 已开始")
        let gate = DispatchSemaphore(value: 0)
        MockURLProtocol.handler = { request in
            handlerStarted.fulfill()
            gate.wait()
            return errorResponse(request.url!, statusCode: 500)
        }

        let task = Task { await t.store.refresh(t.store.accounts[0]) }
        await fulfillment(of: [handlerStarted], timeout: 5)

        t.store.deleteAccount(t.store.accounts[0].id)
        gate.signal()
        await task.value

        XCTAssertTrue(t.store.accounts.isEmpty)
    }

    /// 历史加载在途时删除账号 → 旧 defer 写法会访问已失效下标;修复后按 id 重查,不崩溃
    func testLoadHistoryWhileAccountDeletedDoesNotCrash() async throws {
        let t = makeTempStore()
        addTeardownBlock { try? FileManager.default.removeItem(at: t.dir) }
        _ = try t.store.addAccount(name: "A", workspaceId: validWorkspace, authCookie: validCookie, notes: "")

        let handlerStarted = XCTestExpectation(description: "历史首页 fetch 已开始")
        let gate = DispatchSemaphore(value: 0)
        MockURLProtocol.handler = { request in
            if requestCursor(request) == 0 {
                handlerStarted.fulfill()
                gate.wait() // 只挂起首页;恢复后后续页直接返回空页终止
            }
            return okResponse(request.url!, body: "no more")
        }

        let task = Task { await t.store.loadHistory(t.store.accounts[0]) }
        await fulfillment(of: [handlerStarted], timeout: 5)

        t.store.deleteAccount(t.store.accounts[0].id)
        gate.signal()
        await task.value

        XCTAssertTrue(t.store.accounts.isEmpty) // 不崩溃,静默返回
    }

    /// 对照:正常路径(无删除)刷新仍照常写 usage 并 save
    func testRefreshWithoutDeletionStillWritesUsage() async throws {
        let t = makeTempStore()
        addTeardownBlock { try? FileManager.default.removeItem(at: t.dir) }
        _ = try t.store.addAccount(name: "A", workspaceId: validWorkspace, authCookie: validCookie, notes: "")

        MockURLProtocol.handler = { request in
            okResponse(request.url!, body: quotaHTML)
        }
        await t.store.refresh(t.store.accounts[0])

        XCTAssertEqual(t.store.accounts[0].usage?.rolling?.usagePercent ?? -1, 34.567, accuracy: 0.0001)
        XCTAssertNil(t.store.accounts[0].usageError)
        // save 已执行:磁盘含 usage 快照
        let json = String(decoding: try Data(contentsOf: t.fileURL), as: UTF8.self)
        XCTAssertTrue(json.contains("\"usage\""))
    }

    // MARK: - M4:损坏 JSON 备份 + loadError

    /// 损坏 JSON → 备份文件存在(内容完整)、loadError 非空、原文件被移走、内存空列表
    func testLoadCorruptedFileBacksUpAndSetsLoadError() throws {
        let t = makeTempStore()
        addTeardownBlock { try? FileManager.default.removeItem(at: t.dir) }
        try Data("not json {".utf8).write(to: t.fileURL)

        let store = AccountStore(client: makeClient(), keychain: InMemoryKeychain(), fileURL: t.fileURL)

        XCTAssertTrue(store.accounts.isEmpty)
        let error = try XCTUnwrap(store.loadError)
        XCTAssertTrue(error.contains("accounts.json.bak-"), "错误文案应含备份名,实际: \(error)")
        // 备份文件存在且内容完整
        let backups = try FileManager.default.contentsOfDirectory(atPath: t.dir.path)
            .filter { $0.hasPrefix("accounts.json.bak-") }
        XCTAssertEqual(backups.count, 1)
        let backupURL = t.dir.appendingPathComponent(backups[0])
        XCTAssertEqual(try String(contentsOf: backupURL, encoding: .utf8), "not json {")
        // 原文件已被移走(备份即移动,后续 save 不会覆盖损坏文件)
        XCTAssertFalse(FileManager.default.fileExists(atPath: t.fileURL.path))
    }

    /// 损坏后新增账号:备份保留,新文件为合法 JSON,重载不再报错
    func testSaveAfterCorruptedLoadKeepsBackupAndWritesValidFile() throws {
        let t = makeTempStore()
        addTeardownBlock { try? FileManager.default.removeItem(at: t.dir) }
        try Data("broken".utf8).write(to: t.fileURL)

        let store = AccountStore(client: makeClient(), keychain: InMemoryKeychain(), fileURL: t.fileURL)
        XCTAssertNotNil(store.loadError)
        _ = try store.addAccount(name: "新账号", workspaceId: validWorkspace, authCookie: validCookie, notes: "")

        // 备份仍在
        let backups = try FileManager.default.contentsOfDirectory(atPath: t.dir.path)
            .filter { $0.hasPrefix("accounts.json.bak-") }
        XCTAssertEqual(backups.count, 1)
        // 新文件是合法 JSON,重载后账号在、loadError 无
        let reloaded = AccountStore(client: makeClient(), keychain: InMemoryKeychain(), fileURL: t.fileURL)
        XCTAssertEqual(reloaded.accounts.count, 1)
        XCTAssertEqual(reloaded.accounts[0].name, "新账号")
        XCTAssertNil(reloaded.loadError)
    }

    /// L3:损坏加载置 loadError 后,首次成功 save()(addAccount)即清空 → 红条会话内可消除
    func testLoadErrorClearedAfterFirstSuccessfulSave() throws {
        let t = makeTempStore()
        addTeardownBlock { try? FileManager.default.removeItem(at: t.dir) }
        try Data("broken".utf8).write(to: t.fileURL)

        let store = AccountStore(client: makeClient(), keychain: InMemoryKeychain(), fileURL: t.fileURL)
        XCTAssertNotNil(store.loadError) // 损坏加载 → 红条显示

        // addAccount 触发首次成功 save() → 同一 store 的 loadError 必须清空(红条消除)
        _ = try store.addAccount(name: "新账号", workspaceId: validWorkspace, authCookie: validCookie, notes: "")
        XCTAssertNil(store.loadError)
    }

    /// 文件不存在(首次运行)→ 空列表,无 loadError
    func testLoadMissingFileHasNoLoadError() throws {
        let t = makeTempStore()
        addTeardownBlock { try? FileManager.default.removeItem(at: t.dir) }
        // 不创建 accounts.json
        XCTAssertTrue(t.store.accounts.isEmpty)
        XCTAssertNil(t.store.loadError)
    }

    /// 合法 JSON → 正常解码,无 loadError
    func testLoadValidFileHasNoLoadError() throws {
        let t = makeTempStore()
        addTeardownBlock { try? FileManager.default.removeItem(at: t.dir) }
        try Data("[]".utf8).write(to: t.fileURL)

        let store = AccountStore(client: makeClient(), keychain: InMemoryKeychain(), fileURL: t.fileURL)
        XCTAssertTrue(store.accounts.isEmpty)
        XCTAssertNil(store.loadError)
    }

    /// 同秒内两次损坏加载 → 备份名不冲突(自动加序号),两次内容都保留
    func testRepeatedCorruptedLoadCreatesUniqueBackups() throws {
        let t = makeTempStore()
        addTeardownBlock { try? FileManager.default.removeItem(at: t.dir) }

        try Data("broken one".utf8).write(to: t.fileURL)
        _ = AccountStore(client: makeClient(), keychain: InMemoryKeychain(), fileURL: t.fileURL)
        try Data("broken two".utf8).write(to: t.fileURL)
        _ = AccountStore(client: makeClient(), keychain: InMemoryKeychain(), fileURL: t.fileURL)

        let backups = try FileManager.default.contentsOfDirectory(atPath: t.dir.path)
            .filter { $0.hasPrefix("accounts.json.bak-") }
        XCTAssertEqual(backups.count, 2)
        XCTAssertEqual(Set(backups).count, 2, "备份名不得重复")
        let contents = try backups.map {
            try String(contentsOf: t.dir.appendingPathComponent($0), encoding: .utf8)
        }
        XCTAssertTrue(contents.contains("broken one"))
        XCTAssertTrue(contents.contains("broken two"))
    }

    // MARK: - M5:写前快照 + 损坏回退

    /// 写前快照:第二次 save() 前必须把第一次写入的内容快照到 accounts.json.bak
    func testSaveSnapshotsPreviousContentBeforeOverwrite() throws {
        let t = makeTempStore()
        addTeardownBlock { try? FileManager.default.removeItem(at: t.dir) }
        _ = try t.store.addAccount(name: "第一代", workspaceId: validWorkspace, authCookie: validCookie, notes: "")
        _ = try t.store.addAccount(name: "第二代", workspaceId: validWorkspace, authCookie: validCookie, notes: "")

        let backupURL = t.dir.appendingPathComponent("accounts.json.bak")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path), "第二次写入前必须已生成快照")
        let snapshotted = try JSONDecoder().decode([Account].self, from: Data(contentsOf: backupURL))
        XCTAssertEqual(snapshotted.count, 1)
        XCTAssertEqual(snapshotted[0].name, "第一代") // 快照 = 第一次(写前)的内容
        let current = try JSONDecoder().decode([Account].self, from: Data(contentsOf: t.fileURL))
        XCTAssertEqual(current.count, 2)
    }

    /// 首次写入(无旧文件)→ 不产生快照
    func testFirstSaveCreatesNoSnapshot() throws {
        let t = makeTempStore()
        addTeardownBlock { try? FileManager.default.removeItem(at: t.dir) }
        _ = try t.store.addAccount(name: "唯一", workspaceId: validWorkspace, authCookie: validCookie, notes: "")
        let backupURL = t.dir.appendingPathComponent("accounts.json.bak")
        XCTAssertFalse(FileManager.default.fileExists(atPath: backupURL.path), "首次写入无旧文件,不应产生快照")
    }

    /// 损坏回退:主文件损坏 + 快照完好 → load 返回快照内容,loadError 提示已从备份恢复,
    /// 主文件被修复为可用状态,损坏原件留证
    func testLoadCorruptedFileFallsBackToSnapshot() throws {
        let t = makeTempStore()
        addTeardownBlock { try? FileManager.default.removeItem(at: t.dir) }
        _ = try t.store.addAccount(name: "完好账号", workspaceId: validWorkspace, authCookie: validCookie, notes: "")
        _ = try t.store.addAccount(name: "最新写入", workspaceId: validWorkspace, authCookie: validCookie, notes: "")
        // 此刻 accounts.json.bak = 第一次写入([完好账号]),主文件 = [完好账号,最新写入]

        try Data("not json {".utf8).write(to: t.fileURL) // 模拟主文件损坏
        let store = AccountStore(client: makeClient(), keychain: InMemoryKeychain(), fileURL: t.fileURL)

        XCTAssertEqual(store.accounts.count, 1)
        XCTAssertEqual(store.accounts[0].name, "完好账号") // 从快照恢复
        let error = try XCTUnwrap(store.loadError)
        XCTAssertTrue(error.contains("已从备份恢复数据"), "实际: \(error)")
        // 主文件已用快照内容修复:可直接解码且内容与快照一致
        let restored = try JSONDecoder().decode([Account].self, from: Data(contentsOf: t.fileURL))
        XCTAssertEqual(restored, store.accounts)
        // 损坏原件已留证(accounts.json.bak-<时间戳>)
        let evidence = try FileManager.default.contentsOfDirectory(atPath: t.dir.path)
            .filter { $0.hasPrefix("accounts.json.bak-") }
        XCTAssertEqual(evidence.count, 1)
        XCTAssertEqual(try String(contentsOf: t.dir.appendingPathComponent(evidence[0]), encoding: .utf8),
                       "not json {")
    }

    /// 损坏回退-快照缺失或同样损坏 → 空列表不崩,loadError 置位,损坏原件留证
    func testLoadCorruptedWithCorruptedSnapshotFallsBackToEmpty() throws {
        let t = makeTempStore()
        addTeardownBlock { try? FileManager.default.removeItem(at: t.dir) }
        try Data("broken main".utf8).write(to: t.fileURL)
        try Data("broken snap".utf8).write(to: t.dir.appendingPathComponent("accounts.json.bak"))

        let store = AccountStore(client: makeClient(), keychain: InMemoryKeychain(), fileURL: t.fileURL)
        XCTAssertTrue(store.accounts.isEmpty)
        let error = try XCTUnwrap(store.loadError)
        XCTAssertTrue(error.contains("accounts.json.bak-"), "实际: \(error)")
        let backups = try FileManager.default.contentsOfDirectory(atPath: t.dir.path)
            .filter { $0.hasPrefix("accounts.json.bak-") }
        XCTAssertEqual(backups.count, 1)
    }

    /// 快照失败(旧快照被置不可变,移除/复制都失败)→ 保存仍成功、不抛,主文件正常更新
    func testSnapshotFailureDoesNotBlockSave() throws {
        let t = makeTempStore()
        let backupURL = t.dir.appendingPathComponent("accounts.json.bak")
        addTeardownBlock {
            // 先清掉 immutable 标志否则目录删不掉
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: backupURL.path)
            try? FileManager.default.removeItem(at: t.dir)
        }
        _ = try t.store.addAccount(name: "A", workspaceId: validWorkspace, authCookie: validCookie, notes: "")
        _ = try t.store.addAccount(name: "B", workspaceId: validWorkspace, authCookie: validCookie, notes: "")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path))
        // 旧快照置 immutable → removeItem/copyItem 均失败,快照步骤抛错但必须被吞掉
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: backupURL.path)

        _ = try t.store.addAccount(name: "C", workspaceId: validWorkspace, authCookie: validCookie, notes: "")

        let current = try JSONDecoder().decode([Account].self, from: Data(contentsOf: t.fileURL))
        XCTAssertEqual(current.count, 3) // 主文件已正常更新,保存未被快照失败阻断
        XCTAssertNil(t.store.loadError)
    }

    // MARK: - L8:updateAccount Keychain 写失败的一致性

    /// set 抛错 → 内存/Keychain/磁盘全部保持原状,并向上抛错
    func testUpdateAccountKeychainFailureKeepsMemoryAndDiskUnchanged() throws {
        let keychain = ThrowingKeychain()
        let t = makeTempStore(keychain: keychain)
        addTeardownBlock { try? FileManager.default.removeItem(at: t.dir) }
        _ = try t.store.addAccount(
            name: "原名", workspaceId: "wrk_old", authCookie: "cookie-1", notes: "旧备注")
        let id = t.store.accounts[0].id

        keychain.failSet = true
        XCTAssertThrowsError(try t.store.updateAccount(
            id, name: "新名", workspaceId: "wrk_new", authCookie: "cookie-2", notes: "新备注"))

        // 内存未变
        XCTAssertEqual(t.store.accounts[0].name, "原名")
        XCTAssertEqual(t.store.accounts[0].workspaceId, "wrk_old")
        XCTAssertEqual(t.store.accounts[0].notes, "旧备注")
        // Keychain 未变
        XCTAssertEqual(keychain.get(id.uuidString), "cookie-1")
        // 磁盘未变(update 未执行 save)
        let disk = String(decoding: try Data(contentsOf: t.fileURL), as: UTF8.self)
        XCTAssertTrue(disk.contains("原名"))
        XCTAssertFalse(disk.contains("新名"))
    }

    /// 正常路径:先写 Keychain 成功 → 内存 + 磁盘都更新
    func testUpdateAccountSuccessPersistsNewFieldsAndCookie() throws {
        let keychain = ThrowingKeychain()
        let t = makeTempStore(keychain: keychain)
        addTeardownBlock { try? FileManager.default.removeItem(at: t.dir) }
        _ = try t.store.addAccount(
            name: "原名", workspaceId: "wrk_old", authCookie: "cookie-1", notes: "旧备注")
        let id = t.store.accounts[0].id

        try t.store.updateAccount(
            id, name: "新名", workspaceId: "wrk_new", authCookie: "cookie-2", notes: "新备注")

        XCTAssertEqual(t.store.accounts[0].name, "新名")
        XCTAssertEqual(keychain.get(id.uuidString), "cookie-2")
        let disk = String(decoding: try Data(contentsOf: t.fileURL), as: UTF8.self)
        XCTAssertTrue(disk.contains("新名"))
        XCTAssertTrue(disk.contains("wrk_new"))
    }

    // MARK: - P1:refreshAll 并行化(TaskGroup)

    /// 两个账号的 fetch 必须同时发起(并行):第一个到达的请求交付前挂起,
    /// 第二个立即交付——先放行第二个再放行第一个,两者都成功写入。
    /// 串行版第二个请求在第一个完成前不会发起,「两个都在途」等待会超时失败。
    func testRefreshAllParallelizes() async throws {
        let t = makeGatedTempStore()
        addTeardownBlock { try? FileManager.default.removeItem(at: t.dir) }
        _ = try t.store.addAccount(name: "A", workspaceId: validWorkspace, authCookie: validCookie, notes: "")
        _ = try t.store.addAccount(name: "B", workspaceId: validWorkspace, authCookie: validCookie, notes: "")

        // 第一个实例的响应交付前挂起;第二个实例立即交付(先放行第二个再放行第一个)
        let bothInFlight = XCTestExpectation(description: "两个 fetch 均已发起")
        bothInFlight.expectedFulfillmentCount = 2
        let firstGate = DispatchSemaphore(value: 0)
        GatedURLProtocol.handler = { request in okResponse(request.url!, body: quotaHTML) }
        GatedURLProtocol.gates = [firstGate, nil]
        GatedURLProtocol.startedExpectation = bothInFlight

        let task = Task { await t.store.refreshAll() }
        await fulfillment(of: [bothInFlight], timeout: 5)

        firstGate.signal() // 第二个早已交付返回,这里再放行第一个
        await task.value

        // 两个账号都成功写入(第二个先完成、第一个后完成,时序不影响结果)
        XCTAssertEqual(t.store.accounts[0].usage?.rolling?.usagePercent ?? -1, 34.567, accuracy: 0.0001)
        XCTAssertEqual(t.store.accounts[1].usage?.rolling?.usagePercent ?? -1, 34.567, accuracy: 0.0001)
        XCTAssertNil(t.store.accounts[0].usageError)
        XCTAssertNil(t.store.accounts[1].usageError)
    }

    /// 聚合写回后只 save 一次:第二个 fetch 完成后(第一个仍挂起)文件不得提前变化;
    /// 全部完成后文件才更新且含两个账号的 usage(逐账号 save 实现会在聚合前落盘,此测试失败)
    func testRefreshAllAggregatesSave() async throws {
        let t = makeGatedTempStore()
        addTeardownBlock { try? FileManager.default.removeItem(at: t.dir) }
        _ = try t.store.addAccount(name: "A", workspaceId: validWorkspace, authCookie: validCookie, notes: "")
        _ = try t.store.addAccount(name: "B", workspaceId: validWorkspace, authCookie: validCookie, notes: "")

        let bothInFlight = XCTestExpectation(description: "两个 fetch 均已发起")
        bothInFlight.expectedFulfillmentCount = 2
        let firstGate = DispatchSemaphore(value: 0)
        GatedURLProtocol.handler = { request in okResponse(request.url!, body: quotaHTML) }
        GatedURLProtocol.gates = [firstGate, nil]
        GatedURLProtocol.startedExpectation = bothInFlight

        let task = Task { await t.store.refreshAll() }
        await fulfillment(of: [bothInFlight], timeout: 5)

        // 阶段 1:第二个 fetch 已返回并处理完毕,第一个仍挂起。
        // 聚合实现此时绝不落盘(逐结果 save 实现会在这时把 usage 写入文件)
        try await Task.sleep(nanoseconds: 200_000_000)
        let before = String(decoding: try Data(contentsOf: t.fileURL), as: UTF8.self)
        XCTAssertFalse(before.contains("\"usage\""), "聚合完成前文件不得写入 usage,实际: \(before)")

        firstGate.signal() // 放行第一个 → 全部完成
        await task.value

        // 阶段 2:全部完成后落盘一次,文件包含两个账号的 usage
        let after = String(decoding: try Data(contentsOf: t.fileURL), as: UTF8.self)
        XCTAssertTrue(after.contains("\"usage\""), "聚合后文件应含 usage,实际: \(after)")
        XCTAssertTrue(after.contains("\"A\""))
        XCTAssertTrue(after.contains("\"B\""))
    }

    // MARK: - P2:isRefreshing 生命周期(手动刷新按钮显示进度/禁用重复点击的依据)

    /// 刷新在途期间 isRefreshing 必须为 true;全部完成后复位为 false
    func testRefreshAllSetsIsRefreshingDuringAndClearsAfter() async throws {
        let t = makeGatedTempStore()
        addTeardownBlock { try? FileManager.default.removeItem(at: t.dir) }
        _ = try t.store.addAccount(name: "A", workspaceId: validWorkspace, authCookie: validCookie, notes: "")
        XCTAssertFalse(t.store.isRefreshing, "初始必须为 false")

        let started = XCTestExpectation(description: "fetch 已开始")
        let gate = DispatchSemaphore(value: 0)
        GatedURLProtocol.handler = { request in okResponse(request.url!, body: quotaHTML) }
        GatedURLProtocol.gates = [gate]
        GatedURLProtocol.startedExpectation = started

        let task = Task { await t.store.refreshAll() }
        await fulfillment(of: [started], timeout: 5)
        XCTAssertTrue(t.store.isRefreshing, "fetch 在途期间 isRefreshing 必须为 true")

        gate.signal()
        await task.value
        XCTAssertFalse(t.store.isRefreshing, "刷新完成后必须复位为 false")
        XCTAssertNotNil(t.store.accounts[0].usage)
    }

    /// 刷新失败(HTTP 500)路径同样复位为 false(失败也必须复位)
    func testRefreshAllClearsIsRefreshingAfterFailure() async throws {
        let t = makeGatedTempStore()
        addTeardownBlock { try? FileManager.default.removeItem(at: t.dir) }
        _ = try t.store.addAccount(name: "A", workspaceId: validWorkspace, authCookie: validCookie, notes: "")

        let started = XCTestExpectation(description: "fetch 已开始")
        let gate = DispatchSemaphore(value: 0)
        GatedURLProtocol.handler = { request in errorResponse(request.url!, statusCode: 500) }
        GatedURLProtocol.gates = [gate]
        GatedURLProtocol.startedExpectation = started

        let task = Task { await t.store.refreshAll() }
        await fulfillment(of: [started], timeout: 5)
        XCTAssertTrue(t.store.isRefreshing)

        gate.signal()
        await task.value
        XCTAssertFalse(t.store.isRefreshing, "失败后也必须复位为 false")
        XCTAssertNotNil(t.store.accounts[0].usageError)
    }

    /// 空账号列表(无网络请求)刷新后同样复位为 false
    func testRefreshAllWithNoAccountsEndsNotRefreshing() async throws {
        let t = makeTempStore()
        addTeardownBlock { try? FileManager.default.removeItem(at: t.dir) }
        await t.store.refreshAll()
        XCTAssertFalse(t.store.isRefreshing)
    }

    // MARK: - P3:refreshAll 失败自动重试(短退避)

    /// 首轮失败 + 重试成功 → 总请求数 2(仅该账号),usage 写回、usageError 清空
    func testRefreshAllRetrySucceedsWritesUsageAndClearsError() async throws {
        let t = makeGatedTempStore()
        addTeardownBlock { try? FileManager.default.removeItem(at: t.dir) }
        _ = try t.store.addAccount(name: "A", workspaceId: validWorkspace, authCookie: validCookie, notes: "")

        let counter = RequestCounter()
        GatedURLProtocol.handler = { request in
            // 首轮瞬时网络失败(超时),重试成功
            if counter.next(validWorkspace) == 1 { throw URLError(.timedOut) }
            return okResponse(request.url!, body: quotaHTML)
        }

        await t.store.refreshAll()

        XCTAssertEqual(counter.total, 2, "首轮 1 次 + 重试 1 次 = 总请求数 2")
        XCTAssertEqual(t.store.accounts[0].usage?.rolling?.usagePercent ?? -1, 34.567, accuracy: 0.0001)
        XCTAssertNil(t.store.accounts[0].usageError, "重试成功后 usageError 必须清空")
        XCTAssertFalse(t.store.isRefreshing, "重试完成后 isRefreshing 复位")
    }

    /// 首轮失败 + 重试仍失败 → usageError 以重试 error 为准(更具体),总请求数 2
    func testRefreshAllRetryStillFailsKeepsRetryError() async throws {
        let t = makeGatedTempStore()
        addTeardownBlock { try? FileManager.default.removeItem(at: t.dir) }
        _ = try t.store.addAccount(name: "A", workspaceId: validWorkspace, authCookie: validCookie, notes: "")

        let counter = RequestCounter()
        GatedURLProtocol.handler = { request in
            if counter.next(validWorkspace) == 1 { throw URLError(.timedOut) } // 首轮超时
            return errorResponse(request.url!, statusCode: 500) // 重试仍是服务端错误
        }

        await t.store.refreshAll()

        XCTAssertEqual(counter.total, 2, "首轮 1 次 + 重试 1 次 = 总请求数 2")
        XCTAssertNil(t.store.accounts[0].usage)
        XCTAssertEqual(t.store.accounts[0].usageError, "请求失败 (HTTP 500)",
                       "两次都失败时应以重试 error 为准(而非首轮超时文案)")
    }

    /// cookie 缺失(非网络错误)→ 不发起任何请求、不重试,错误文案「未找到 Cookie…」
    func testRefreshAllWithMissingCookieDoesNotRetry() async throws {
        let keychain = InMemoryKeychain()
        let t = makeGatedTempStore(keychain: keychain)
        addTeardownBlock { try? FileManager.default.removeItem(at: t.dir) }
        _ = try t.store.addAccount(name: "A", workspaceId: validWorkspace, authCookie: validCookie, notes: "")
        keychain.delete(t.store.accounts[0].id.uuidString) // 模拟 Cookie 缺失

        GatedURLProtocol.handler = { request in
            XCTFail("Cookie 缺失时不应发起任何请求")
            throw URLError(.badServerResponse)
        }

        await t.store.refreshAll()

        XCTAssertEqual(t.store.accounts[0].usageError, "未找到 Cookie，请重新添加账号")
        XCTAssertNil(t.store.accounts[0].usage)
    }

    /// 成功账号不受影响:总数 = 各账号轮数之和(A 首轮成功 1 次,B 失败后重试共 2 次)
    func testRefreshAllRetryDoesNotAffectSuccessfulAccounts() async throws {
        let t = makeGatedTempStore()
        addTeardownBlock { try? FileManager.default.removeItem(at: t.dir) }
        _ = try t.store.addAccount(name: "A", workspaceId: "wrk_aaa111", authCookie: validCookie, notes: "")
        _ = try t.store.addAccount(name: "B", workspaceId: "wrk_bbb222", authCookie: validCookie, notes: "")

        let counter = RequestCounter()
        GatedURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path.contains("wrk_bbb222") {
                if counter.next("wrk_bbb222") == 1 { throw URLError(.timedOut) } // B 首轮失败
            } else {
                _ = counter.next("wrk_aaa111")
            }
            return okResponse(request.url!, body: quotaHTML)
        }

        await t.store.refreshAll()

        XCTAssertEqual(counter.total, 3, "A 首轮 1 次 + B 首轮失败 + 重试成功 = 3 次")
        XCTAssertEqual(t.store.accounts[0].usage?.rolling?.usagePercent ?? -1, 34.567, accuracy: 0.0001)
        XCTAssertEqual(t.store.accounts[1].usage?.rolling?.usagePercent ?? -1, 34.567, accuracy: 0.0001)
        XCTAssertNil(t.store.accounts[0].usageError)
        XCTAssertNil(t.store.accounts[1].usageError, "重试成功后 B 的 usageError 必须清空")
    }

    /// 重试在途期间 isRefreshing 保持 true(整轮含重试全部完成后才复位)
    func testRefreshAllIsRefreshingStaysTrueDuringRetry() async throws {
        let t = makeGatedTempStore()
        addTeardownBlock { try? FileManager.default.removeItem(at: t.dir) }
        _ = try t.store.addAccount(name: "A", workspaceId: validWorkspace, authCookie: validCookie, notes: "")

        // 首轮与重试都返回 HTTP 500(经 didReceive 交付,可被 gate 挂起)
        let bothAttempts = XCTestExpectation(description: "首轮与重试均已发起")
        bothAttempts.expectedFulfillmentCount = 2
        let retryGate = DispatchSemaphore(value: 0)
        GatedURLProtocol.handler = { request in errorResponse(request.url!, statusCode: 500) }
        GatedURLProtocol.gates = [nil, retryGate] // 首轮立即交付,重试挂起
        GatedURLProtocol.startedExpectation = bothAttempts

        let task = Task { await t.store.refreshAll() }
        await fulfillment(of: [bothAttempts], timeout: 5)

        XCTAssertTrue(t.store.isRefreshing, "重试在途期间 isRefreshing 必须保持 true")
        retryGate.signal()
        await task.value

        XCTAssertFalse(t.store.isRefreshing, "重试完成后必须复位为 false")
        XCTAssertEqual(t.store.accounts[0].usageError, "请求失败 (HTTP 500)")
    }
}
