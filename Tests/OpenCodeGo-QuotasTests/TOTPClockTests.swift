import XCTest
@testable import OpenCode_Go_Quotas

@MainActor
final class TOTPClockTests: XCTestCase {
    func testTickUpdatesSharedSnapshot() {
        let initial = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = TOTPClock(now: initial)

        XCTAssertEqual(clock.now, initial)

        let next = initial.addingTimeInterval(1)
        clock.tick(now: next)

        XCTAssertEqual(clock.now, next)
    }

    func testStartIsIdempotentAndStopClearsRunningState() async {
        let clock = TOTPClock(interval: .milliseconds(10))

        clock.start()
        XCTAssertTrue(clock.isRunning)

        // 第二次 start 不应创建第二个 ticker。
        clock.start()
        XCTAssertTrue(clock.isRunning)

        clock.stop()
        XCTAssertFalse(clock.isRunning)
    }

    func testTickerAdvancesNowAndStopsAfterCancel() async throws {
        let interval = Duration.milliseconds(10)
        let clock = TOTPClock(now: Date(timeIntervalSince1970: 1_800_000_000), interval: interval)

        let started = Date()
        clock.start()
        try await Task.sleep(for: .milliseconds(80))

        XCTAssertGreaterThan(clock.now.timeIntervalSince(started), 0.02)

        clock.stop()
        XCTAssertFalse(clock.isRunning)

        let stoppedAt = clock.now
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(clock.now, stoppedAt)
    }

    func testTOTPGenerationUsesClockBoundarySemantics() {
        let secret = "JBSWY3DPEHPK3PXP"
        let boundary = Date(timeIntervalSince1970: 1_800_000_030)

        XCTAssertEqual(TOTPGenerator.remainingSeconds(at: boundary), 30)
        XCTAssertEqual(
            TOTPGenerator.generate(secretBase32: secret, at: boundary),
            TOTPGenerator.generate(secretBase32: secret, at: boundary.addingTimeInterval(29)))
    }
}
