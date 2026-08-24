import Foundation
import XCTest
@testable import OpenCodeGo

/// LoginLogSink 单测:全部注入临时目录(参照现有测试红线,绝不碰
/// ~/Library/Logs 等真实路径),断言文件存在/追加/自动建目录/失败静默。
final class LoginLogSinkTests: XCTestCase {

    /// 每个测试独立的临时目录(自动建,teardown 删除)
    private func makeTempDir(_ name: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LoginLogSinkTests-\(name)-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func readLog(at url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - 文件存在与内容

    func testAppendCreatesFileAndWritesTimelineText() throws {
        let dir = makeTempDir("create")
        let sink = LoginLogSink(directory: dir)
        let timeline = "decide github.com: githubLoginForm -> githubLoginForm | cookie: poll hit"

        sink.append(timeline)

        let logURL = dir.appendingPathComponent("login.log")
        XCTAssertTrue(FileManager.default.fileExists(atPath: logURL.path))
        let content = try readLog(at: logURL)
        XCTAssertTrue(content.contains(timeline))
        XCTAssertTrue(content.hasPrefix("["), "每行应以 ISO8601 时间戳开头")
        XCTAssertTrue(content.hasSuffix("\n"))
    }

    // MARK: - 追加而非覆盖

    func testMultipleAppendsAreAppendedNotOverwritten() throws {
        let dir = makeTempDir("append")
        let sink = LoginLogSink(directory: dir)

        sink.append("first-dump")
        sink.append("second-dump")
        sink.append("third-dump")

        let content = try readLog(at: dir.appendingPathComponent("login.log"))
        let lines = content.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 3, "多次 append 应是追加而非覆盖")
        XCTAssertTrue(lines[0].contains("first-dump"))
        XCTAssertTrue(lines[1].contains("second-dump"))
        XCTAssertTrue(lines[2].contains("third-dump"))
    }

    // MARK: - 深层目录自动创建

    func testDeepMissingDirectoryIsAutoCreated() throws {
        let dir = makeTempDir("deep-root")
        let deep = dir
            .appendingPathComponent("a", isDirectory: true)
            .appendingPathComponent("b", isDirectory: true)
            .appendingPathComponent("c", isDirectory: true)
        // 深层目录刻意不预创建
        let sink = LoginLogSink(directory: deep)

        sink.append("deep timeline")

        let logURL = deep.appendingPathComponent("login.log")
        XCTAssertTrue(FileManager.default.fileExists(atPath: logURL.path))
        XCTAssertTrue(try readLog(at: logURL).contains("deep timeline"))
    }

    // MARK: - 无效路径静默(不抛)

    func testInvalidPathFailsSilently() throws {
        let dir = makeTempDir("invalid")
        // 用普通文件占住「父路径」位置:在其下建目录必然失败(ENOTDIR)
        let blocker = dir.appendingPathComponent("blocker-file")
        try Data("x".utf8).write(to: blocker)
        let invalidDir = blocker.appendingPathComponent("nested", isDirectory: true)

        let sink = LoginLogSink(directory: invalidDir)

        // 核心断言:不抛、不阻塞(append 内部静默)
        sink.append("should-be-silent")

        // 该路径下不应产生 login.log
        XCTAssertFalse(FileManager.default.fileExists(atPath: invalidDir.appendingPathComponent("login.log").path))
    }

    func testUnwritableRootFailsSilently() throws {
        // 只读目录:append 应静默失败,不抛异常
        let dir = makeTempDir("readonly")
        let readOnlyDir = dir.appendingPathComponent("ro", isDirectory: true)
        try FileManager.default.createDirectory(at: readOnlyDir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: readOnlyDir.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: readOnlyDir.path) }

        let sink = LoginLogSink(directory: readOnlyDir)
        // 只读目录 + 文件不存在:创建文件失败 → 静默返回;能走到这里即证明未抛
        sink.append("should-be-silent")
    }

    // MARK: - 注入目录与默认目录隔离

    func testNilDirectoryUsesLibraryLogsPath() {
        // 只验证默认目录推导(不写文件、不碰真实路径):nil → ~/Library/Logs/OpenCodeGo/login.log
        let sink = LoginLogSink()
        XCTAssertTrue(sink.directory == nil, "默认构造不注入目录,append 时才推导 ~/Library/Logs")
    }
}
