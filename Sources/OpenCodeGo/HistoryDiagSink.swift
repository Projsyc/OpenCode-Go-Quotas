import Foundation

/// 用量历史 cost 异常诊断文件输出:与 LoginLogSink 同风格 —— 追加写到
/// ~/Library/Logs/OpenCodeGo/history.log(每行一条,ISO8601 时间戳前缀)。
/// 仅记录 id/model/cost/原始匹配串/上下文,不含任何凭据;写失败静默(不阻塞解析)。
///
/// 用途:排查「cost 正则匹配到其它字段/嵌套对象数值」类问题
/// (用户曾见合计费用 US$98,711,933 的天文数字;正常单次请求 cost 远低于 $5)。
struct HistoryDiagSink {
    /// 允许测试注入目录;nil → 默认 ~/Library/Logs/OpenCodeGo/
    var directory: URL?

    init(directory: URL? = nil) {
        self.directory = directory
    }

    private var logURL: URL {
        let dir = directory ?? {
            let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            return base.appendingPathComponent("Logs/OpenCodeGo", isDirectory: true)
        }()
        return dir.appendingPathComponent("history.log")
    }

    /// 追加一条诊断(文件不存在则创建,目录自动创建)。
    /// 安全红线:调用方传入的文本只含 id/model/cost/原始匹配串/上下文,
    /// 文件里绝不出现 cookie/密码/secret 等凭据。
    func append(_ text: String) {
        do {
            let url = logURL
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // FileHandle(forWritingTo:) 对不存在的文件会抛错:先补齐空文件保证 append 语义
            if !FileManager.default.fileExists(atPath: url.path) {
                guard FileManager.default.createFile(atPath: url.path, contents: nil) else { return }
            }
            let stamp = ISO8601DateFormatter().string(from: Date())
            let line = "[\(stamp)] \(text)\n"
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
        } catch {
            // 静默:诊断通道失败不影响用量历史解析
        }
    }
}
