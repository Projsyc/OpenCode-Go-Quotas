import Foundation

/// 统一的文本诊断日志通道：按 ISO8601 时间戳追加文本，超过上限时滚动归档。
///
/// 调用方必须保证写入内容已经过滤凭据；本类型只负责可靠的文件 I/O。
/// 写入失败会静默返回，确保诊断通道不会阻断登录、解析或刷新流程。
struct TextAppendLogSink: Sendable {
    /// nil 表示使用默认 `~/Library/Logs/OpenCodeGo`；测试必须注入临时目录。
    let directory: URL?
    let fileName: String
    /// 主日志的软上限（字节）。单条超大诊断可能略超该值，避免截断破坏 UTF-8。
    let maximumFileSize: UInt64
    /// 保留的归档数量。例如 1 表示只有 `name.log.1`；0 表示轮转时直接丢弃旧内容。
    let maximumArchivedFiles: Int

    init(
        directory: URL?,
        fileName: String,
        maximumFileSize: UInt64 = Self.defaultMaximumFileSize,
        maximumArchivedFiles: Int = Self.defaultMaximumArchivedFiles
    ) {
        self.directory = directory
        self.fileName = fileName
        self.maximumFileSize = maximumFileSize
        self.maximumArchivedFiles = max(0, maximumArchivedFiles)
    }

    /// 登录流程时间线通道，替代原 LoginLogSink。
    static func login(directory: URL? = nil) -> Self {
        Self(directory: directory, fileName: "login.log")
    }

    /// 历史解析诊断通道，替代原 HistoryDiagSink。
    static func history(directory: URL? = nil) -> Self {
        Self(directory: directory, fileName: "history.log")
    }

    static let defaultMaximumFileSize: UInt64 = 1_048_576 // 1 MiB
    static let defaultMaximumArchivedFiles = 1

    private static let timestampFormatter = ISO8601DateFormatter()

    private var logURL: URL {
        let dir = directory ?? {
            let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            return library.appendingPathComponent("Logs/OpenCodeGo", isDirectory: true)
        }()
        return dir.appendingPathComponent(fileName)
    }

    func append(_ text: String) {
        do {
            try FileManager.default.createDirectory(
                at: logURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)

            let stamp = Self.timestampFormatter.string(from: Date())
            let data = Data("[\(stamp)] \(text)\n".utf8)
            rotateIfNeeded(upcomingByteCount: UInt64(data.count))

            if !FileManager.default.fileExists(atPath: logURL.path) {
                guard FileManager.default.createFile(atPath: logURL.path, contents: nil) else { return }
            }

            let handle = try FileHandle(forWritingTo: logURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            // 静默失败：诊断是辅助通道，不能影响业务流程。
        }
    }

    /// 在新记录写不下时滚动主日志。旧归档按数字递增平移，
    /// 超出保留数量的最老文件会被删除。
    private func rotateIfNeeded(upcomingByteCount: UInt64) {
        guard maximumFileSize > 0,
              let attributes = try? FileManager.default.attributesOfItem(atPath: logURL.path),
              let size = attributes[.size] as? NSNumber,
              size.uint64Value + upcomingByteCount > maximumFileSize
        else { return }

        if maximumArchivedFiles == 0 {
            try? FileManager.default.removeItem(at: logURL)
            return
        }

        for index in stride(from: maximumArchivedFiles - 1, through: 1, by: -1) {
            let source = archivedURL(index)
            let destination = archivedURL(index + 1)
            try? FileManager.default.removeItem(at: destination)
            try? FileManager.default.moveItem(at: source, to: destination)
        }

        try? FileManager.default.removeItem(at: archivedURL(1))
        try? FileManager.default.moveItem(at: logURL, to: archivedURL(1))
    }

    private func archivedURL(_ index: Int) -> URL {
        logURL.deletingLastPathComponent()
            .appendingPathComponent("\(fileName).\(index)")
    }
}
