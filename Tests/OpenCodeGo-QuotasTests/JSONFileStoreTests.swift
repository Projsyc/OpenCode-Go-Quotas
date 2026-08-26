import OSLog
import XCTest
@testable import OpenCode_Go_Quotas

/// JSONFileStore 单测：全部使用临时目录，绝不触碰真实 Application Support。
@MainActor
final class JSONFileStoreTests: XCTestCase {
    private struct Payload: Codable, Equatable, Sendable {
        var id: Int
        var name: String
    }

    private var dir: URL!
    private var fileURL: URL!
    private var store: JSONFileStore<Payload>!

    override func setUp() {
        super.setUp()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("opg-jsonfilestore-\(UUID().uuidString)", isDirectory: true)
        fileURL = dir.appendingPathComponent("payload.json")
        makeStore()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    private func makeStore() {
        store = JSONFileStore(
            fileURL: fileURL,
            subject: "测试",
            sourceName: "payload.json",
            logger: Logger(subsystem: "com.acccan.opencode-go", category: "json-file-store-tests"))
    }

    func testSaveCreatesDirectoryAndLoadsRoundTrip() throws {
        let payload = Payload(id: 7, name: "首次写入")

        try store.save(payload)
        let result = store.load()

        XCTAssertEqual(result.model, payload)
        XCTAssertNil(result.recoveryMessage)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testSecondSaveSnapshotsPreviousContents() throws {
        try store.save(Payload(id: 1, name: "旧数据"))
        try store.save(Payload(id: 2, name: "新数据"))

        let snapshotted = try JSONDecoder().decode(
            Payload.self,
            from: Data(contentsOf: dir.appendingPathComponent("payload.json.bak")))
        let current = try JSONDecoder().decode(Payload.self, from: Data(contentsOf: fileURL))

        XCTAssertEqual(snapshotted, Payload(id: 1, name: "旧数据"))
        XCTAssertEqual(current, Payload(id: 2, name: "新数据"))
    }

    func testCorruptedMainRecoversFromSnapshotAndPreservesEvidence() throws {
        try store.save(Payload(id: 1, name: "快照数据"))
        try store.save(Payload(id: 2, name: "当前数据"))
        try Data("broken main".utf8).write(to: fileURL)

        let result = store.load()

        XCTAssertEqual(result.model, Payload(id: 1, name: "快照数据"))
        XCTAssertEqual(try JSONDecoder().decode(Payload.self, from: Data(contentsOf: fileURL)), result.model)
        XCTAssertTrue(result.recoveryMessage?.contains("已从备份恢复数据") == true)
        let evidence = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("payload.json.bak-") }
        XCTAssertEqual(evidence.count, 1)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent(evidence[0])), Data("broken main".utf8))
    }

    func testUnrecoverableFileIsMovedAsideAndModelResets() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("broken main".utf8).write(to: fileURL)
        try Data("broken snapshot".utf8).write(to: dir.appendingPathComponent("payload.json.bak"))

        let result = store.load()

        XCTAssertNil(result.model)
        XCTAssertTrue(result.recoveryMessage?.contains("payload.json.bak-") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        let backups = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("payload.json.bak-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent(backups[0])), Data("broken main".utf8))
    }
}
