import AppKit
import XCTest
@testable import miri

@MainActor
final class WorkspaceBarRefreshTests: XCTestCase {
    func testAppearanceCallbacksDuringEveryRefreshCannotKeepPollingAlive() {
        let clock = RefreshTestClock()
        var refreshTimes: [TimeInterval] = []
        weak var callbackScheduler: WorkspaceBarRefreshScheduler?
        let scheduler = WorkspaceBarRefreshScheduler(now: { clock.now }, schedule: clock.schedule) {
            refreshTimes.append(clock.now)
            callbackScheduler?.requestRefresh()
        }
        callbackScheduler = scheduler

        scheduler.beginSettling()
        clock.advance(to: 10)

        XCTAssertEqual(refreshTimes.first, 0)
        XCTAssertEqual(refreshTimes.last, 2)
        XCTAssertEqual(refreshTimes.count, 15)
        XCTAssertTrue(clock.jobs.isEmpty)
    }

    func testDuplicateTransitionEventsDoNotExtendDeadline() {
        let clock = RefreshTestClock()
        var refreshTimes: [TimeInterval] = []
        let scheduler = WorkspaceBarRefreshScheduler(now: { clock.now }, schedule: clock.schedule) {
            refreshTimes.append(clock.now)
        }

        scheduler.beginSettling()
        for time in [0.1, 0.5, 1.0, 1.9] {
            clock.advance(to: time)
            scheduler.beginSettling()
            scheduler.requestRefresh()
        }
        clock.advance(to: 10)

        XCTAssertEqual(refreshTimes.last, 2)
        XCTAssertEqual(refreshTimes.count, 15)
        XCTAssertTrue(clock.jobs.isEmpty)
    }

    func testFinalPollObservesAnAppearanceChangeAtTheEndOfTheAnimation() {
        let clock = RefreshTestClock()
        var darkAppearance = false
        var observedDarkAppearance = false
        let scheduler = WorkspaceBarRefreshScheduler(now: { clock.now }, schedule: clock.schedule) {
            observedDarkAppearance = darkAppearance
        }

        scheduler.beginSettling()
        clock.advance(to: 1.99)
        darkAppearance = true
        clock.advance(to: 2)

        XCTAssertTrue(observedDarkAppearance)
        XCTAssertTrue(clock.jobs.isEmpty)
    }

    func testAppearanceEventsAfterSettlingCoalesceWithoutStartingMorePolling() {
        let clock = RefreshTestClock()
        var refreshCount = 0
        let scheduler = WorkspaceBarRefreshScheduler(now: { clock.now }, schedule: clock.schedule) {
            refreshCount += 1
        }

        scheduler.beginSettling()
        clock.advance(to: 3)
        let countAfterSettling = refreshCount
        for _ in 0..<100 { scheduler.requestRefresh() }
        clock.advance(to: 10)

        XCTAssertEqual(refreshCount, countAfterSettling + 1)
        XCTAssertTrue(clock.jobs.isEmpty)
    }

    func testASeparateFullscreenExitGetsItsOwnSettlingWindow() {
        let clock = RefreshTestClock()
        var refreshTimes: [TimeInterval] = []
        let scheduler = WorkspaceBarRefreshScheduler(now: { clock.now }, schedule: clock.schedule) {
            refreshTimes.append(clock.now)
        }

        scheduler.beginSettling()
        clock.advance(to: 3)
        scheduler.beginSettling()
        clock.advance(to: 10)

        XCTAssertEqual(refreshTimes.last, 5)
        XCTAssertTrue(clock.jobs.isEmpty)
    }

    func testDelayedRunLoopPerformsOneFinalCheckWithoutReplayingMissedPolls() {
        let clock = RefreshTestClock()
        var refreshCount = 0
        let scheduler = WorkspaceBarRefreshScheduler(now: { clock.now }, schedule: clock.schedule) {
            refreshCount += 1
        }

        scheduler.beginSettling()
        clock.now = 5
        let delayedJob = clock.jobs.removeFirst()
        delayedJob.action()

        XCTAssertEqual(refreshCount, 1)
        XCTAssertTrue(clock.jobs.isEmpty)
    }

    func testRestoredAppearanceHasTheSameSignatureAfterATransientSnapshot() throws {
        let light = try XCTUnwrap(NSAppearance(named: .aqua))
        let dark = try XCTUnwrap(NSAppearance(named: .darkAqua))
        let before = WorkspaceBarAppearanceSignature(appearance: light, increaseContrast: false)
        let transient = WorkspaceBarAppearanceSignature(appearance: dark, increaseContrast: false)
        let restored = WorkspaceBarAppearanceSignature(appearance: light, increaseContrast: false)

        XCTAssertNotEqual(before, transient)
        XCTAssertEqual(before, restored)
        XCTAssertNotEqual(before, WorkspaceBarAppearanceSignature(appearance: light, increaseContrast: true))
    }
}

@MainActor
private final class RefreshTestClock {
    struct Job {
        let time: TimeInterval
        let action: @MainActor () -> Void
    }

    var now: TimeInterval = 0
    var jobs: [Job] = []

    func schedule(after delay: TimeInterval, action: @escaping @MainActor () -> Void) {
        jobs.append(Job(time: now + delay, action: action))
        jobs.sort { $0.time < $1.time }
    }

    func advance(to time: TimeInterval) {
        var executed = 0
        while let job = jobs.first, job.time <= time {
            jobs.removeFirst()
            now = job.time
            job.action()
            executed += 1
            guard executed < 1_000 else {
                XCTFail("Refresh loop did not become idle")
                return
            }
        }
        now = time
    }
}
