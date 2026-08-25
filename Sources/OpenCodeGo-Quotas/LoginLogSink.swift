import Foundation

/// 登录流程诊断文件输出:os_log 之外,把流程时间线追加写到
/// ~/Library/Logs/OpenCodeGo/login.log(每行一条,不含任何凭据)。
/// 失败/取消/超时/转手动时由 GitHubLoginView 调用;写文件失败静默(不阻塞登录流程)。
///
/// 为何双通道:os_log 采集依赖用户手动执行
/// `log show --predicate 'subsystem == "com.acccan.opencode-go"'`,门槛高,
/// 且部分环境(沙箱/中转)log show 看不到新日志 → 诊断盲区;
/// 文件通道零门槛,用户出问题时直接看 login.log 即可。
struct LoginLogSink {
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
        return dir.appendingPathComponent("login.log")
    }

    /// 追加一条时间线(整段 dump;文件不存在则创建,目录自动创建)。
    /// 安全红线:调用方传入的是已按 LoginFlowLog 红线过滤的文本(只含域名/步骤名/
    /// 分类结果),文件里绝不出现用户名/密码/验证码/cookie 值。
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
            // 静默:诊断通道失败不影响登录流程
        }
    }
}
