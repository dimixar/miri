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

    @MainActor
    func testUnlockAutomaticallyRecoversOnlyWhenTheGlobalWindowModelIsEmpty() {
        let window = ManagedWindow(
            element: AXUIElementCreateApplication(123),
            pid: 123,
            windowID: 456,
            bundleID: "example.app",
            appName: "Example",
            title: "Restored"
        )
        let identity = PersistentWindowIdentity(
            bundleID: window.bundleID,
            appName: window.appName,
            title: window.title
        )
        let minimized = PersistentWindowState(identity: identity, workspace: 1, column: 0)
        let fullscreen = FullscreenWindowState(
            identity: identity,
            element: window.element,
            pid: window.pid,
            windowID: window.windowID,
            bundleID: window.bundleID,
            appName: window.appName,
            title: window.title,
            workspace: 1,
            column: 0,
            leftNeighborID: nil,
            rightNeighborID: nil,
            leftNeighbor: nil,
            rightNeighbor: nil,
            widthRatio: 0.5,
            wasActive: true
        )
        let cases: [(String, Bool, (WindowManagement, LogicalSpaceContext) -> Void)] = [
            ("empty", false, { _, _ in }),
            ("saved state only", false, { _, context in
                context.minimizedWindowStates[identity] = minimized
                context.signature = [456]
            }),
            ("another workspace", true, { management, _ in
                management.ensureWorkspaceExists(1)
                management.workspaces[1].columns = [Column(windows: [window])]
            }),
            ("another Space", true, { _, context in
                context.workspaces[1].columns = [Column(windows: [window])]
            }),
            ("floating in another Space", true, { _, context in
                context.floatingWindows = [window]
            }),
            ("fullscreen in another Space", true, { _, context in
                context.fullscreenWindowStates[identity] = fullscreen
            }),
            ("minimized in another Space", true, { _, context in
                context.minimizedWindowStates[identity] = minimized
                context.minimizedWindowPIDs[identity] = window.pid
            }),
            ("buffered Space transition", true, { management, _ in
                management.buffer(
                    BufferedSpaceWindow(window: window, sourceContextID: 1),
                    windowID: 456
                )
            }),
        ]

        for (name, hasKnownState, populate) in cases {
            let miri = Miri()
            let context = LogicalSpaceContext(id: 1, workspaces: [Workspace(), Workspace()])
            miri.windowManagement.appendContext(context)
            populate(miri.windowManagement, context)
            XCTAssertTrue(miri.windowManagement.snapshot().workspaces[0].columns.isEmpty, name)
            XCTAssertEqual(miri.windowManagement.hasKnownWindowState, hasKnownState, name)

            var automaticRecoveryRequested = false
            let session = SessionController { event in
                if case .session(.emptyModelRecoveryDue) = event {
                    automaticRecoveryRequested = true
                }
            }
            miri.sessionController = session
            session.start(initialLocked: true, initialWorkspaceActive: true)
            miri.updateSessionStateImplementation(screenLocked: false, reason: "test-unlock")

            XCTAssertEqual(automaticRecoveryRequested, !hasKnownState, name)
            XCTAssertFalse(session.isLayoutTrackingAllowed, "Recovery must still pass the guards: \(name)")
            session.stop()
        }
    }
}
