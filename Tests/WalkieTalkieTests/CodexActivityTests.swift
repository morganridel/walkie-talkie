import XCTest
@testable import WalkieTalkie

final class CodexActivityTests: XCTestCase {
    func testSummaryDeduplicatesThreadsAndSeparatesBoundFromOtherWork() {
        let summary = CodexActivitySummary([
            "threads": [
                ["id": "bound", "state": "active"],
                ["id": "bound", "state": "active"],
                ["id": "other", "busy": true, "status": "idle"],
                ["id": "idle", "state": "idle"],
            ]
        ], boundID: "bound")

        XCTAssertTrue(summary.boundWorking)
        XCTAssertFalse(summary.boundWaiting)
        XCTAssertEqual(summary.runningCount, 2)
        XCTAssertEqual(summary.waitingCount, 0)
        XCTAssertTrue(summary.description.contains("Bound chat is working"))
        XCTAssertTrue(summary.description.contains("2 running"))
    }

    func testWaitingApprovalAndQuestionCountAsRunningAndWaiting() {
        let summary = CodexActivitySummary([
            "threads": [
                ["id": "bound", "state": "waitingOnApproval"],
                ["id": "other", "status": "waitingOnUserInput"],
            ]
        ], boundID: "bound")

        XCTAssertTrue(summary.boundWorking)
        XCTAssertTrue(summary.boundWaiting)
        XCTAssertEqual(summary.runningCount, 2)
        XCTAssertEqual(summary.waitingCount, 2)
        XCTAssertTrue(summary.description.contains("Bound chat needs your input"))
        XCTAssertTrue(summary.description.contains("2 waiting for you"))
    }

    func testUnavailableStatusIsVisibleInsteadOfClaimingIdle() {
        var summary = CodexActivitySummary()
        summary.unavailable = true

        XCTAssertTrue(summary.description.contains("Codex activity unavailable"))
    }

    func testBoundThreadErrorIsReportedAsAnErrorInsteadOfIdle() {
        let summary = CodexActivitySummary([
            "threads": [
                ["id": "bound", "state": "error", "error": "worker stopped"],
                ["id": "other", "state": "active"],
            ]
        ], boundID: "bound")

        XCTAssertFalse(summary.boundWorking)
        XCTAssertTrue(summary.boundError)
        XCTAssertEqual(summary.errorCount, 1)
        XCTAssertTrue(summary.description.localizedCaseInsensitiveContains("error") ||
                      summary.description.localizedCaseInsensitiveContains("attention"))
        XCTAssertTrue(summary.description.contains("1 running"))
    }
}
