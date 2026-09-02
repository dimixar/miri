import Darwin
import XCTest
@testable import miri

final class TerminationRestorationTests: XCTestCase {
    @MainActor
    func testPartialFailureIsReported() {
        var received: AXTerminationRestoreSummary?
        let session = AXTerminationRestoreSession(requestedPIDs: [11, 22]) {
            received = $0
        }

        session.record(pid: 11, succeeded: true)
        session.record(pid: 22, succeeded: false)
        session.finish(timedOut: false)

        XCTAssertEqual(received?.restoredPIDs, [11])
        XCTAssertEqual(received?.failedPIDs, [22])
        XCTAssertFalse(received?.succeeded ?? true)
    }

    @MainActor
    func testTimeoutMarksEveryPendingPIDFailed() {
        var received: AXTerminationRestoreSummary?
        let session = AXTerminationRestoreSession(requestedPIDs: [11, 22, 33]) {
            received = $0
        }

        session.record(pid: 11, succeeded: true)
        session.finish(timedOut: true)

        XCTAssertEqual(received?.restoredPIDs, [11])
        XCTAssertEqual(received?.failedPIDs, [22, 33])
        XCTAssertEqual(received?.timedOut, true)
    }

    @MainActor
    func testLateAndRepeatedResultsCannotCompleteTwice() {
        var completionCount = 0
        let session = AXTerminationRestoreSession(requestedPIDs: [11]) { _ in
            completionCount += 1
        }

        session.finish(timedOut: true)
        session.record(pid: 11, succeeded: true)
        session.finish(timedOut: false)

        XCTAssertEqual(completionCount, 1)
    }
}
