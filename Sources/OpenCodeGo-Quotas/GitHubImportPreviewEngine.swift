import Foundation

/// 导入预览的调度策略：文本变化先防抖；超过阈值的输入放到后台线程解析。
///
/// 预览结果是纯 `Sendable` 值类型，后台任务只携带输入字符串，不触碰 Store 或 UI 状态。
enum GitHubImportPreviewEngine {
    /// 连续按键 / 拖拽选择期间的合并窗口。
    static let debounceInterval: Duration = .milliseconds(250)
    /// 超过该 UTF-8 字节数后不在调用方 actor 上解析。
    static let backgroundThresholdBytes = 20_000

    /// 判断给定输入是否应使用后台解析。
    static func usesBackgroundParsing(_ text: String) -> Bool {
        text.utf8.count > backgroundThresholdBytes
    }

    /// 解析预览；大输入显式切换到后台任务，避免阻塞主线程。
    static func parse(_ text: String) async -> [GitHubImportPreviewRow] {
        guard usesBackgroundParsing(text) else {
            return GitHubImportView.previewRows(from: text)
        }

        let task = Task.detached(priority: .userInitiated) {
            GitHubImportView.previewRows(from: text)
        }
        return await task.value
    }

    /// 先等待防抖窗口再解析；调用方可通过取消任务丢弃过期输入。
    static func parseAfterDebounce(
        _ text: String,
        clock: ContinuousClock = .continuous
    ) async throws -> [GitHubImportPreviewRow] {
        try await clock.sleep(for: debounceInterval)
        return await parse(text)
    }
}
