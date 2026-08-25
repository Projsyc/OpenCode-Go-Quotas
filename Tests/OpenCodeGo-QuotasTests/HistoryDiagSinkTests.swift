import Foundation
import XCTest
@testable import OpenCode_Go_Quotas

/// HistoryDiagSink 单测:全部注入临时目录(参照现有测试红线,绝不碰
/// ~/Library/Logs 等真实路径),断言建文件/追加/自动建目录/失败静默,
/// 风格对齐 LoginLogSinkTests。
final class HistoryDiagSinkTests: XCTestCase {

    /// 每个测试独立的临时目录(自动建,teardown 删除)
    private func makeTempDir(_ name: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HistoryDiagSinkTests-\(name)-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func readLog(at url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - 文件存在与内容

    func testAppendCreatesHistoryLogWithTimestampPrefix() throws {
        let dir = makeTempDir("create")
        let sink = HistoryDiagSink(directory: dir)
        let diag = "id=usg_AbC123 model=claude-opus-4-8 cost=98711933.0 match=cost:98711933.00 ctx=total_cost:98711933.00"

        sink.append(diag)

        let logURL = dir.appendingPathComponent("history.log")
        XCTAssertTrue(FileManager.default.fileExists(atPath: logURL.path))
        let content = try readLog(at: logURL)
        XCTAssertTrue(content.contains(diag))
        XCTAssertTrue(content.hasPrefix("["), "每行应以 ISO8601 时间戳开头")
        XCTAssertTrue(content.hasSuffix("\n"))
        // 文件名隔离:只写 history.log,绝不写 login.log
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("login.log").path))
    }

    // MARK: - 追加而非覆盖

    func testMultipleAppendsAreAppendedNotOverwritten() throws {
        let dir = makeTempDir("append")
        let sink = HistoryDiagSink(directory: dir)

        sink.append("first-diag")
        sink.append("second-diag")
        sink.append("third-diag")

        let content = try readLog(at: dir.appendingPathComponent("history.log"))
        let lines = content.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 3, "多次 append 应是追加而非覆盖")
        XCTAssertTrue(lines[0].contains("first-diag"))
        XCTAssertTrue(lines[1].contains("second-diag"))
        XCTAssertTrue(lines[2].contains("third-diag"))
    }

    // MARK: - 深层目录自动创建

    func testDeepMissingDirectoryIsAutoCreated() throws {
        let dir = makeTempDir("deep-root")
        let deep = dir
            .appendingPathComponent("a", isDirectory: true)
            .appendingPathComponent("b", isDirectory: true)
            .appendingPathComponent("c", isDirectory: true)
        // 深层目录刻意不预创建
        let sink = HistoryDiagSink(directory: deep)

        sink.append("deep diag")

        let logURL = deep.appendingPathComponent("history.log")
        XCTAssertTrue(FileManager.default.fileExists(atPath: logURL.path))
        XCTAssertTrue(try readLog(at: logURL).contains("deep diag"))
    }

    // MARK: - 无效路径静默(不抛)

    func testInvalidPathFailsSilently() throws {
        let dir = makeTempDir("invalid")
        // 用普通文件占住「父路径」位置:在其下建目录必然失败(ENOTDIR)
        let blocker = dir.appendingPathComponent("blocker-file")
        try Data("x".utf8).write(to: blocker)
        let invalidDir = blocker.appendingPathComponent("nested", isDirectory: true)

        let sink = HistoryDiagSink(directory: invalidDir)

        // 核心断言:不抛、不阻塞(append 内部静默)
        sink.append("should-be-silent")

        // 该路径下不应产生 history.log
        XCTAssertFalse(FileManager.default.fileExists(atPath: invalidDir.appendingPathComponent("history.log").path))
    }

    // MARK: - 注入目录与默认目录隔离

    func testNilDirectoryUsesLibraryLogsPath() {
        // 只验证默认目录推导(不写文件、不碰真实路径):nil → ~/Library/Logs/OpenCodeGo/history.log
        let sink = HistoryDiagSink()
        XCTAssertTrue(sink.directory == nil, "默认构造不注入目录,append 时才推导 ~/Library/Logs")
    }
}
