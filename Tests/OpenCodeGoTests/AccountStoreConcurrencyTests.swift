import Foundation
import XCTest
@testable import OpenCodeGo

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
    private func makeGatedTempStore() -> (store: AccountStore, fileURL: URL, dir: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AccountStoreConcurrencyTests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent("accounts.json")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GatedURLProtocol.self]
        let store = AccountStore(
            client: QuotaClient(session: URLSession(configuration: config)),
            keychain: InMemoryKeychain(),
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
}
