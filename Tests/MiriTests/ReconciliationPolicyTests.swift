import ApplicationServices
import Darwin
import XCTest
@testable import miri

final class ReconciliationPolicyTests: XCTestCase {
    @MainActor
    func testCanonicalDiscoveryOrderDoesNotDependOnAsyncCompletionOrder() {
        let miri = Miri()
        let firstElement = AXUIElementCreateApplication(20)
        let secondElement = AXUIElementCreateApplication(10)
        let observations = [
            DiscoveredWindowObservation(
                element: firstElement,
                pid: 20,
                windowID: 200,
                bundleID: "twenty",
                appName: "Twenty",
                title: "B"
            ),
            DiscoveredWindowObservation(
                element: secondElement,
                pid: 10,
                windowID: 100,
                bundleID: "ten",
                appName: "Ten",
                title: "A"
            ),
        ]

        XCTAssertEqual(miri.canonicalWindows(from: observations).map(\.pid), [10, 20])
    }

    @MainActor
    func testUnavailableEnumerationPreservesKnownCGVisibleWindow() {
        let controller = AXOperationController(log: { _ in })
        let management = WindowManagement(axOperations: controller, emit: { _ in })

        let disposition = management.classifyMissingWindow(MissingWindowFacts(
            axEnumerationUnavailable: true,
            hasCGInfo: true,
            isFullscreen: false,
            pendingFullscreenWithinGrace: false,
            isFullScan: true,
            runningApplicationExists: true,
            temporarilyHidden: false,
            behaviorIsIgnored: false,
            fullscreenGuardActive: false,
            appearsInUnknownSpace: false,
            launchRemovalDeferred: false
        ))

        guard case .preserveCGVisible = disposition else {
            return XCTFail("Unavailable AX enumeration must preserve a known visible window")
        }
    }

    @MainActor
    func testFullScanBarrierExpiresOnlyTheSlowPID() {
        let barrier = FullWindowDiscoveryAccumulator(
            generation: 1,
            pids: [10, 20],
            completion: { _ in }
        )

        XCTAssertFalse(barrier.recordCompletion(pid: 10))
        let expired = barrier.expirePendingPIDs()

        XCTAssertEqual(expired, [20])
        XCTAssertEqual(barrier.unavailablePIDs, [20])
        XCTAssertTrue(barrier.finished)
    }
}
