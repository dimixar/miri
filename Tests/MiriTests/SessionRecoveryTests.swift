import Foundation
import XCTest
@testable import miri

@MainActor
final class SessionRecoveryTests: XCTestCase {
    func testEmptyModelRetriesDeferredRecoveryWithoutUserInput() {
        let retried = expectation(description: "automatic recovery retried")
        var attempts = 0
        weak var recoveringSession: SessionController?
        let session = SessionController { event in
            guard case .session(.emptyModelRecoveryDue(let generation)) = event,
                  let session = recoveringSession
            else { return }
            attempts += 1
            XCTAssertEqual(session.scheduleRecoveryIfNeeded(), generation)
            XCTAssertNil(session.scheduleRecoveryIfNeeded(), "Do not start overlapping recovery")
            if attempts == 1 {
                // The transient-window guard rejected this attempt.
                session.cancelScheduledRecovery()
            } else {
                XCTAssertTrue(session.completeRecovery(generation: generation))
                retried.fulfill()
            }
        }
        recoveringSession = session
        session.pauseForUnavailableSession()
        session.prepareRecoveryInteraction(hasKnownWindowState: false)

        XCTAssertEqual(attempts, 1)
        XCTAssertFalse(session.isLayoutTrackingAllowed)
        wait(for: [retried], timeout: 2)
        XCTAssertTrue(session.isLayoutTrackingAllowed)
        XCTAssertTrue(session.recoveryStartedWithEmptyModel)
        session.stop()
    }

    func testEmptyModelDoesNotRecoverWhileLockedInactiveOrSleeping() {
        let states: [(Bool, Bool, Bool)] = [
            (true, true, false),
            (false, false, false),
            (false, true, true),
        ]
        for (locked, active, sleeping) in states {
            var requestedRecovery = false
            let session = SessionController { event in
                if case .session(.emptyModelRecoveryDue) = event {
                    requestedRecovery = true
                }
            }
            _ = session.apply(screenLocked: locked, workspaceActive: active, systemSleeping: sleeping)
            session.pauseForUnavailableSession()
            session.prepareRecoveryInteraction(hasKnownWindowState: false)

            XCTAssertFalse(requestedRecovery)
            XCTAssertFalse(session.isLayoutTrackingAllowed)
            session.stop()
        }
    }

    func testRelockAndSleepCancelAutomaticRetriesAndInvalidateOldRecovery() {
        let staleRetry = expectation(description: "old recovery must not retry")
        staleRetry.isInverted = true
        var paused = false
        var sessions: [SessionController] = []
        for sleeping in [false, true] {
            let session = SessionController { event in
                if paused, case .session(.emptyModelRecoveryDue) = event {
                    staleRetry.fulfill()
                }
            }
            session.pauseForUnavailableSession()
            session.prepareRecoveryInteraction(hasKnownWindowState: false)
            let oldGeneration = session.resumeGeneration
            _ = session.apply(screenLocked: !sleeping, workspaceActive: true, systemSleeping: sleeping)
            session.pauseForUnavailableSession()

            XCTAssertFalse(session.completeRecovery(generation: oldGeneration))
            XCTAssertFalse(session.isLayoutTrackingAllowed)
            sessions.append(session)
        }
        paused = true
        wait(for: [staleRetry], timeout: 0.65)
        sessions.forEach { $0.stop() }
    }

    func testDiscoverySettlingKeepsScanningWithoutExtendingItsDeadline() {
        let afterDeadline = expectation(description: "settling must finish")
        afterDeadline.isInverted = true
        let started = Date()
        var scans = 0
        let operations = AXOperationController(log: { _ in })
        weak var settlingObservation: WindowObservationController?
        let observation = WindowObservationController(axOperations: operations) { event in
            guard case .windows(.reconciliationRequested(let intent)) = event else { return }
            XCTAssertEqual(intent.source, .discoverySettling)
            guard case .allWindows = intent.scope else {
                return XCTFail("Settling must discover previously unknown apps")
            }
            scans += 1
            if Date().timeIntervalSince(started) > 0.35 {
                afterDeadline.fulfill()
            }
            // A duplicate startup/recovery callback must not extend polling.
            settlingObservation?.configureDiscoverySettlingTimer(enabled: true, duration: 0.25, interval: 0.025)
        }
        settlingObservation = observation
        observation.configureDiscoverySettlingTimer(enabled: true, duration: 0.25, interval: 0.025)

        wait(for: [afterDeadline], timeout: 0.5)
        XCTAssertGreaterThan(scans, 1, "An empty first scan must not end discovery")
        observation.stop()
    }

    func testStoppingObservationCancelsDiscoverySettling() {
        let firstScan = expectation(description: "settling started")
        let stoppedScan = expectation(description: "no discovery after stop")
        stoppedScan.isInverted = true
        var stopped = false
        let operations = AXOperationController(log: { _ in })
        let observation = WindowObservationController(axOperations: operations) { event in
            guard case .windows(.reconciliationRequested) = event else { return }
            if stopped {
                stoppedScan.fulfill()
            } else {
                firstScan.fulfill()
            }
        }
        observation.configureDiscoverySettlingTimer(enabled: true, duration: 1, interval: 0.025)
        wait(for: [firstScan], timeout: 1)
        stopped = true
        observation.stop()
        observation.configureDiscoverySettlingTimer(enabled: true, duration: 1, interval: 0.025)

        wait(for: [stoppedScan], timeout: 0.1)
    }
}
