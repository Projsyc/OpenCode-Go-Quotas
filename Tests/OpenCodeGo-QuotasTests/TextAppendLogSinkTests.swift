import Foundation
import XCTest
@testable import OpenCode_Go_Quotas

/// 统一诊断日志通道测试。全部注入临时目录，绝不触碰 ~/Library/Logs。
final class TextAppendLogSinkTests: XCTestCase {
    private func makeTempDir(_ factoryName: String) -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "TextAppendLogSinkTests-\(factoryName)-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func read(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    func testLoginFactoryCreatesTimestampedAppendOnlyLog() throws {
        let dir = makeTempDir("login")
        let sink = TextAppendLogSink.login(directory: dir)

        sink.append("first-dump")
        sink.append("second-dump")

        let content = try read(dir.appendingPathComponent("login.log"))
        XCTAssertTrue(content.hasPrefix("["))
        XCTAssertTrue(content.hasSuffix("\n"))
        XCTAssertTrue(content.contains("first-dump"))
        XCTAssertTrue(content.contains("second-dump"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("history.log").path))
    }

    func testHistoryFactoryCreatesDeepDirectoryAndIsolatesFileNames() throws {
        let root = makeTempDir("history-root")
        let deep = root
            .appendingPathComponent("a", isDirectory: true)
            .appendingPathComponent("b", isDirectory: true)
        let sink = TextAppendLogSink.history(directory: deep)

        sink.append("deep diag")

        XCTAssertTrue(try read(deep.appendingPathComponent("history.log")).contains("deep diag"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: deep.appendingPathComponent("login.log").path))
    }

    func testInvalidPathFailsSilently() throws {
        let dir = makeTempDir("invalid")
        let blocker = dir.appendingPathComponent("blocker-file")
        try Data("x".utf8).write(to: blocker)
        let invalidDir = blocker.appendingPathComponent("nested", isDirectory: true)

        TextAppendLogSink.login(directory: invalidDir).append("should-be-silent")

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: invalidDir.appendingPathComponent("login.log").path))
    }

    func testRotationKeepsMostRecentCompleteLog() throws {
        let dir = makeTempDir("rotation")
        // 64-byte limit makes deterministic entries rotate on every append.
        let sink = TextAppendLogSink(directory: dir, fileName: "login.log", maximumFileSize: 64)
        sink.append("first-entry")

        sink.append("second-entry")
        let firstArchive = dir.appendingPathComponent("login.log.1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstArchive.path))
        XCTAssertTrue(try read(firstArchive).contains("first-entry"))
        XCTAssertTrue(try read(dir.appendingPathComponent("login.log")).contains("second-entry"))

        sink.append("third-entry")
        XCTAssertTrue(try read(firstArchive).contains("second-entry"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("login.log.2").path))
    }

    func testZeroArchiveCountDropsRotatedContent() throws {
        let dir = makeTempDir("drop-archive")
        let sink = TextAppendLogSink(
            directory: dir,
            fileName: "login.log",
            maximumFileSize: 64,
            maximumArchivedFiles: 0)

        sink.append("discarded-entry")
        sink.append("active-entry")

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasPrefix("login.log") }, ["login.log"])
        XCTAssertTrue(try read(dir.appendingPathComponent("login.log")).contains("active-entry"))
        XCTAssertFalse(try read(dir.appendingPathComponent("login.log")).contains("discarded-entry"))
    }

    func testDefaultFactoriesDoNotTouchRealPathsDuringConstruction() {
        XCTAssertTrue(TextAppendLogSink.login().directory == nil)
        XCTAssertTrue(TextAppendLogSink.history().directory == nil)
        XCTAssertEqual(TextAppendLogSink.defaultMaximumFileSize, 1_048_576)
        XCTAssertEqual(TextAppendLogSink.defaultMaximumArchivedFiles, 1)
    }
}
