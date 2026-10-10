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
}
