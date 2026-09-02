import ApplicationServices
import Foundation
import XCTest
@testable import miri

private final class LockedValues<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []

    func append(_ value: Value) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    var values: [Value] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

final class AXOperationExecutorTests: XCTestCase {
    @MainActor
    func testProductionApplicationReadPipelineAlwaysCompletes() {
        let controller = AXOperationController(log: { _ in })
        let completed = expectation(description: "production application read completed")
        completed.assertForOverFulfill = true

        controller.readApplication(
            pid: ProcessInfo.processInfo.processIdentifier,
            priority: .normal,
            coalescingKey: "pipeline-retention-test"
        ) { _ in
            completed.fulfill()
        }

        // The test runner may expose zero windows or reject its own AX root;
        // either terminal result is valid. A weakly retained production
        // pipeline produces no callback at all and this expectation times out.
        wait(for: [completed], timeout: 2)
    }

    @MainActor
    func testTerminationQuiescenceClosesLaterAdmission() {
        let controller = AXOperationController(log: { _ in })
        let restored = expectation(description: "termination restoration completed")
        let rejected = expectation(description: "post-termination operation rejected")

        controller.restoreFramesForTermination([], timeout: 0.5) { summary in
            XCTAssertTrue(summary.succeeded)
            restored.fulfill()
        }
        wait(for: [restored], timeout: 1)

        let app = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        controller.readWindow(
            handle: AXElementHandle(element: app, pid: ProcessInfo.processInfo.processIdentifier, windowID: nil)
        ) { result in
            XCTAssertEqual(result.disposition, .superseded)
            rejected.fulfill()
        }
        wait(for: [rejected], timeout: 1)
    }

    @MainActor
    func testCannotCompleteOpensOnlyThatPIDCircuitAndResetClearsIt() {
        let executor = AXOperationExecutor()
        let failed = expectation(description: "failure recorded")
        let circuitOpen = expectation(description: "circuit rejected next operation")
        let healthyPID = expectation(description: "other PID stayed healthy")
        let resetCompleted = expectation(description: "reset PID completed")

        executor.submit(
            pid: 77,
            key: "failure",
            generation: 1,
            priority: .normal,
            operation: { (Optional<Bool>.none, AXError.cannotComplete) },
            completion: AXCallback { _ in failed.fulfill() }
        )
        wait(for: [failed], timeout: 1)

        executor.submit(
            pid: 77,
            key: "blocked",
            generation: 2,
            priority: .interactive,
            operation: { (true, AXError.success) },
            completion: AXCallback { result in
                XCTAssertEqual(result.disposition, .circuitOpen)
                circuitOpen.fulfill()
            }
        )
        executor.submit(
            pid: 78,
            key: "healthy",
            generation: 1,
            priority: .interactive,
            operation: { (true, AXError.success) },
            completion: AXCallback { result in
                XCTAssertEqual(result.disposition, .completed)
                healthyPID.fulfill()
            }
        )
        wait(for: [circuitOpen, healthyPID], timeout: 1)

        executor.resetAllHealth()
        executor.submit(
            pid: 77,
            key: "reset",
            generation: 3,
            priority: .interactive,
            operation: { (true, AXError.success) },
            completion: AXCallback { result in
                XCTAssertEqual(result.disposition, .completed)
                resetCompleted.fulfill()
            }
        )
        wait(for: [resetCompleted], timeout: 1)
    }

    @MainActor
    func testOperationBudgetExhaustionIsReported() {
        let executor = AXOperationExecutor()
        let completed = expectation(description: "budgeted operation completed")

        executor.submit(
            pid: 99,
            key: "budget",
            generation: 1,
            priority: .normal,
            operationBudget: 0.01,
            operation: {
                Thread.sleep(forTimeInterval: 0.02)
                return (Optional<Bool>.none, AXError.cannotComplete)
            },
            completion: AXCallback { result in
                XCTAssertTrue(result.budgetExhausted)
                XCTAssertEqual(result.disposition, .failed)
                completed.fulfill()
            }
        )

        wait(for: [completed], timeout: 1)
    }

    @MainActor
    func testRemovingLaneCancelsQueuedJobExactlyOnce() {
        let executor = AXOperationExecutor()
        let blockerStarted = DispatchSemaphore(value: 0)
        let releaseBlocker = DispatchSemaphore(value: 0)
        let queuedCallbacks = LockedValues<AXOperationDisposition>()
        let queuedCompleted = expectation(description: "queued cancellation completed")
        let blockerCompleted = expectation(description: "running operation completed")

        executor.submit(
            pid: 100,
            key: "blocker",
            generation: 1,
            priority: .interactive,
            operation: {
                blockerStarted.signal()
                releaseBlocker.wait()
                return (true, AXError.success)
            },
            completion: AXCallback { _ in blockerCompleted.fulfill() }
        )
        XCTAssertEqual(blockerStarted.wait(timeout: .now() + 1), .success)
        executor.submit(
            pid: 100,
            key: "queued",
            generation: 2,
            priority: .normal,
            operation: { (true, AXError.success) },
            completion: AXCallback { result in
                queuedCallbacks.append(result.disposition)
                queuedCompleted.fulfill()
            }
        )

        executor.remove(pid: 100)
        wait(for: [queuedCompleted], timeout: 1)
        XCTAssertEqual(queuedCallbacks.values, [.superseded])
        releaseBlocker.signal()
        wait(for: [blockerCompleted], timeout: 1)
    }

    @MainActor
    func testDifferentPIDLaneCompletesWhileAnotherLaneIsBlocked() {
        let executor = AXOperationExecutor()
        let slowStarted = DispatchSemaphore(value: 0)
        let releaseSlow = DispatchSemaphore(value: 0)
        let fastCompleted = expectation(description: "fast PID completed")
        let slowCompleted = expectation(description: "slow PID completed")

        executor.submit(
            pid: 101,
            key: "slow",
            generation: 1,
            priority: .normal,
            operation: {
                slowStarted.signal()
                releaseSlow.wait()
                return (true, AXError.success)
            },
            completion: AXCallback { _ in slowCompleted.fulfill() }
        )
        XCTAssertEqual(slowStarted.wait(timeout: .now() + 1), .success)

        executor.submit(
            pid: 202,
            key: "fast",
            generation: 1,
            priority: .interactive,
            operation: { (true, AXError.success) },
            completion: AXCallback { result in
                XCTAssertEqual(result.disposition, .completed)
                fastCompleted.fulfill()
            }
        )

        wait(for: [fastCompleted], timeout: 0.5)
        releaseSlow.signal()
        wait(for: [slowCompleted], timeout: 1)
    }

    @MainActor
    func testNewerGenerationSupersedesQueuedJobExactlyOnce() {
        let executor = AXOperationExecutor()
        let blockerStarted = DispatchSemaphore(value: 0)
        let releaseBlocker = DispatchSemaphore(value: 0)
        let callbacks = LockedValues<AXOperationDisposition>()
        let oldCompleted = expectation(description: "old generation completed")
        let newCompleted = expectation(description: "new generation completed")

        executor.submit(
            pid: 303,
            key: "blocker",
            generation: 1,
            priority: .interactive,
            operation: {
                blockerStarted.signal()
                releaseBlocker.wait()
                return (true, AXError.success)
            },
            completion: AXCallback { _ in }
        )
        XCTAssertEqual(blockerStarted.wait(timeout: .now() + 1), .success)

        executor.submit(
            pid: 303,
            key: "coalesced",
            generation: 2,
            priority: .normal,
            operation: { (2, AXError.success) },
            completion: AXCallback { result in
                callbacks.append(result.disposition)
                oldCompleted.fulfill()
            }
        )
        executor.submit(
            pid: 303,
            key: "coalesced",
            generation: 3,
            priority: .normal,
            operation: { (3, AXError.success) },
            completion: AXCallback { result in
                callbacks.append(result.disposition)
                newCompleted.fulfill()
            }
        )

        releaseBlocker.signal()
        wait(for: [oldCompleted, newCompleted], timeout: 1)
        XCTAssertEqual(callbacks.values.count, 2)
        XCTAssertTrue(callbacks.values.contains(.superseded))
        XCTAssertTrue(callbacks.values.contains(.completed))
    }

    @MainActor
    func testQueuedCoalescingPhysicallyRemovesSupersededBurstJobs() {
        let executor = AXOperationExecutor()
        let blockerStarted = DispatchSemaphore(value: 0)
        let releaseBlocker = DispatchSemaphore(value: 0)
        let executions = LockedValues<Int>()
        let callbacks = expectation(description: "every burst job completed exactly once")
        callbacks.expectedFulfillmentCount = 40

        executor.submit(
            pid: 350,
            key: "blocker",
            generation: 1,
            priority: .interactive,
            operation: {
                blockerStarted.signal()
                releaseBlocker.wait()
                return (true, AXError.success)
            },
            completion: AXCallback { _ in }
        )
        XCTAssertEqual(blockerStarted.wait(timeout: .now() + 1), .success)

        for generation in 2...41 {
            executor.submit(
                pid: 350,
                key: "resize-burst",
                generation: UInt64(generation),
                priority: .normal,
                operation: {
                    executions.append(generation)
                    return (generation, AXError.success)
                },
                completion: AXCallback { _ in callbacks.fulfill() }
            )
        }

        releaseBlocker.signal()
        wait(for: [callbacks], timeout: 1)
        XCTAssertEqual(executions.values, [41])
    }

    @MainActor
    func testQuiescenceResetsHealthAfterRunningFailureFinishes() {
        let executor = AXOperationExecutor()
        let operationStarted = DispatchSemaphore(value: 0)
        let releaseOperation = DispatchSemaphore(value: 0)
        let quiesced = expectation(description: "lane quiesced")
        let postQuiescence = expectation(description: "post-quiescence operation ran")

        executor.submit(
            pid: 375,
            key: "running-failure",
            generation: 1,
            priority: .normal,
            operation: {
                operationStarted.signal()
                releaseOperation.wait()
                return (Optional<Bool>.none, AXError.cannotComplete)
            },
            completion: AXCallback { _ in }
        )
        XCTAssertEqual(operationStarted.wait(timeout: .now() + 1), .success)

        executor.quiesceAllAndResetHealth {
            quiesced.fulfill()
            executor.submit(
                pid: 375,
                key: "final-attempt",
                generation: 2,
                priority: .interactive,
                operation: { (true, AXError.success) },
                completion: AXCallback { result in
                    XCTAssertEqual(result.disposition, .completed)
                    postQuiescence.fulfill()
                }
            )
        }
        releaseOperation.signal()
        wait(for: [quiesced, postQuiescence], timeout: 1)
    }

    @MainActor
    func testInteractiveJobRunsBeforeQueuedBackgroundJob() {
        let executor = AXOperationExecutor()
        let blockerStarted = DispatchSemaphore(value: 0)
        let releaseBlocker = DispatchSemaphore(value: 0)
        let executionOrder = LockedValues<String>()
        let completed = expectation(description: "queued jobs completed")
        completed.expectedFulfillmentCount = 2

        executor.submit(
            pid: 404,
            key: "blocker",
            generation: 1,
            priority: .interactive,
            operation: {
                blockerStarted.signal()
                releaseBlocker.wait()
                return (true, AXError.success)
            },
            completion: AXCallback { _ in }
        )
        XCTAssertEqual(blockerStarted.wait(timeout: .now() + 1), .success)

        executor.submit(
            pid: 404,
            key: "background",
            generation: 2,
            priority: .background,
            operation: {
                executionOrder.append("background")
                return (true, AXError.success)
            },
            completion: AXCallback { _ in completed.fulfill() }
        )
        executor.submit(
            pid: 404,
            key: "interactive",
            generation: 3,
            priority: .interactive,
            operation: {
                executionOrder.append("interactive")
                return (true, AXError.success)
            },
            completion: AXCallback { _ in completed.fulfill() }
        )

        releaseBlocker.signal()
        wait(for: [completed], timeout: 1)
        XCTAssertEqual(executionOrder.values, ["interactive", "background"])
    }
}
