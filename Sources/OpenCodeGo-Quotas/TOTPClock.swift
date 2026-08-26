import Foundation
import Observation

/// 所有 GitHub 卡片共享的低频 TOTP 时钟。
///
/// SwiftUI 的 `TimelineView` 会为每个卡片创建独立调度；账号较多时同一秒内会重复唤醒。
/// 这里由父级视图启动一次 1 秒发布，卡片只订阅同一个 `Date` 快照。
@MainActor
@Observable
final class TOTPClock {
    /// 当前参考时间。订阅方用它生成验证码、剩余秒数和一次性码过期状态。
    private(set) var now: Date

    private var tickerTask: Task<Void, Never>?
    private let interval: Duration
    private let clock: ContinuousClock

    init(
        now: Date = Date(),
        interval: Duration = .seconds(1),
        clock: ContinuousClock = .continuous
    ) {
        self.now = now
        self.interval = interval
        self.clock = clock
    }

    func start() {
        guard tickerTask == nil else { return }
        tickerTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                do {
                    try await self.clock.sleep(for: self.interval)
                } catch {
                    break
                }
                self.tick()
            }
        }
    }

    func stop() {
        tickerTask?.cancel()
        tickerTask = nil
    }

    func tick(now: Date = Date()) {
        self.now = now
    }

    var isRunning: Bool { tickerTask != nil }
}
