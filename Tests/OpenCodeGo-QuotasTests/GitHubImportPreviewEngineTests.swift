import Foundation
import XCTest
@testable import OpenCode_Go_Quotas

final class GitHubImportPreviewEngineTests: XCTestCase {
    private func makeCSV(lineCount: Int) -> String {
        (1...lineCount).map { "user\($0), pass123456" }.joined(separator: "\n")
    }

    func testThresholdUsesByteCount() {
        let shortText = "user1, pass123456"
        XCTAssertFalse(GitHubImportPreviewEngine.usesBackgroundParsing(shortText))

        let longText = String(repeating: "a", count: GitHubImportPreviewEngine.backgroundThresholdBytes + 1)
        XCTAssertTrue(GitHubImportPreviewEngine.usesBackgroundParsing(longText))
    }

    func testLargeInputParsesInBackgroundPathWithoutLoss() async {
        let text = makeCSV(lineCount: 1_200)
        XCTAssertTrue(text.utf8.count > GitHubImportPreviewEngine.backgroundThresholdBytes)

        let rows = await GitHubImportPreviewEngine.parse(text)

        XCTAssertEqual(rows.count, 1_200)
        XCTAssertEqual(rows.filter { $0.error == nil }.count, 1_200)
        XCTAssertEqual(rows.first?.username, "user1")
        XCTAssertEqual(rows.last?.username, "user1200")
    }

    func testDebounceCanBeCancelledAndDoesNotParseStaleInput() throws {
        let expectation = expectation(description: "debounced task observes cancellation")
        let task = Task {
            do {
                _ = try await GitHubImportPreviewEngine.parseAfterDebounce("stale-user, pass123456")
            } catch is CancellationError {
                expectation.fulfill()
            } catch {
                XCTFail("Expected CancellationError, got \(error)")
            }
        }

        Task {
            try? await Task.sleep(for: .milliseconds(20))
            task.cancel()
        }

        wait(for: [expectation], timeout: 2)
    }
}
