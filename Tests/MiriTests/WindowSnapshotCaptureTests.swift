import AppKit
import ApplicationServices
import ScreenCaptureKit
import XCTest
@testable import miri

@MainActor
private final class SuspendedSnapshotCapturer: WindowSnapshotCapturing {
    var requests: [WindowSnapshotRequest] = []
    var onStart: () -> Void = {}
    var continuation: CheckedContinuation<[WindowSnapshotRequest: WindowSnapshotResult], Never>?

    func capture(_ requests: [WindowSnapshotRequest]) async -> [WindowSnapshotRequest: WindowSnapshotResult] {
        self.requests = requests
        return await withCheckedContinuation {
            continuation = $0
            onStart()
        }
    }

    func complete(with result: WindowSnapshotResult) {
        let pending = continuation
        continuation = nil
        pending?.resume(returning: Dictionary(uniqueKeysWithValues: Set(requests).map { ($0, result) }))
    }
}

@MainActor
final class WindowSnapshotCaptureTests: XCTestCase {
    func testConfigurationMatchesWindowPixelsWithoutCursorShadowOrChildWindows() {
        let config = WindowSnapshotCapturer.configuration(
            contentSize: CGSize(width: 801.25, height: 600.5),
            pixelScale: 2
        )
        XCTAssertEqual(config.width, 1603)
        XCTAssertEqual(config.height, 1201)
        XCTAssertFalse(config.showsCursor)
        XCTAssertTrue(config.ignoreShadows)
        XCTAssertFalse(config.includeChildWindows)
        XCTAssertEqual(config.dynamicRange, .sdr)
        XCTAssertEqual(config.displayIntent, .local)
        XCTAssertNil(config.fileURL)
    }

    func testConfigurationUsesSourceScaleAndPositiveDimensions() {
        let config = WindowSnapshotCapturer.configuration(contentSize: CGSize(width: 800, height: 600), pixelScale: 1)
        XCTAssertEqual(config.width, 800)
        XCTAssertEqual(config.height, 600)
        let empty = WindowSnapshotCapturer.configuration(contentSize: .zero, pixelScale: 0)
        XCTAssertEqual(empty.width, 1)
        XCTAssertEqual(empty.height, 1)
    }

    func testBatchBoundsConcurrencyAndDeduplicatesRequests() async {
        let requests = (1...8).map { WindowSnapshotRequest(windowID: UInt32($0), pid: 100) }
        var active = 0
        var maximumActive = 0
        var captured: [WindowSnapshotRequest] = []
        let results = await WindowSnapshotBatch.capture(requests + requests, maxConcurrentCaptures: 3) { request in
            active += 1
            maximumActive = max(maximumActive, active)
            captured.append(request)
            try? await Task.sleep(for: .milliseconds(10))
            active -= 1
            return .failure(.missingWindow)
        }
        XCTAssertEqual(maximumActive, 3)
        XCTAssertEqual(captured.count, requests.count)
        XCTAssertEqual(Set(captured), Set(requests))
        XCTAssertEqual(results.count, requests.count)
    }

    func testBatchPreservesPartialSuccessAndContinuesAfterFailure() async throws {
        let image = try makeImage()
        let first = WindowSnapshotRequest(windowID: 1, pid: 100)
        let second = WindowSnapshotRequest(windowID: 2, pid: 100)
        let results = await WindowSnapshotBatch.capture([first, second], maxConcurrentCaptures: 1) { request in
            request == first ? .failure(.captureFailed("test error")) : .success(image)
        }
        guard case .failure(.captureFailed("test error")) = results[first] else {
            return XCTFail("Expected the individual capture failure")
        }
        XCTAssertEqual(try results[second]?.get().width, image.width)
    }

    func testCancelledBatchDoesNotLaunchRemainingCaptures() async {
        let started = expectation(description: "first capture started")
        var continuation: CheckedContinuation<WindowSnapshotResult, Never>?
        var captured = 0
        let requests = (1...5).map { WindowSnapshotRequest(windowID: UInt32($0), pid: 100) }
        let task = Task {
            await WindowSnapshotBatch.capture(requests, maxConcurrentCaptures: 1) { _ in
                captured += 1
                return await withCheckedContinuation {
                    continuation = $0
                    started.fulfill()
                }
            }
        }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        continuation?.resume(returning: .failure(.missingWindow))
        let results = await task.value
        XCTAssertEqual(captured, 1)
        XCTAssertTrue(results.isEmpty)
    }

    func testEmptyBatchDoesNotCapture() async {
        let results = await WindowSnapshotBatch.capture([]) { _ in
            XCTFail("Empty batch must not capture")
            return .failure(.missingWindow)
        }
        XCTAssertTrue(results.isEmpty)
    }

    func testCaptureFailureDoesNotReconcileButMissingWindowDoes() async {
        for failure in [WindowSnapshotFailure.captureFailed("permission denied"), .missingWindow] {
            let capturer = SuspendedSnapshotCapturer()
            let started = expectation(description: "capture started")
            capturer.onStart = { started.fulfill() }
            var reconciled: [pid_t] = []
            let controller = fixture(capturer: capturer, reconcile: { reconciled.append($0) })
            let token = LayoutRequestToken(rawValue: 10)
            controller.activeRequestToken = token
            let motion = makeMotion()
            let task = Task { await controller.captureSnapshotMotions([motion], requestToken: token) }
            await fulfillment(of: [started], timeout: 2)
            capturer.complete(with: .failure(failure))
            let images = await task.value
            XCTAssertTrue(images.isEmpty)
            XCTAssertEqual(capturer.requests, [WindowSnapshotRequest(windowID: 42, pid: 1000)])
            if case .missingWindow = failure {
                XCTAssertEqual(reconciled, [1000])
            } else {
                XCTAssertTrue(reconciled.isEmpty)
            }
        }
    }

    func testSupersededCaptureCannotReturnImagesOrRequestReconciliation() async throws {
        for result in [WindowSnapshotResult.success(try makeImage()), .failure(.missingWindow)] {
            let capturer = SuspendedSnapshotCapturer()
            let started = expectation(description: "capture started")
            capturer.onStart = { started.fulfill() }
            let controller = fixture(capturer: capturer, reconcile: { _ in XCTFail("Stale reconciliation") })
            let token = LayoutRequestToken(rawValue: 10)
            controller.activeRequestToken = token
            let motion = makeMotion()
            let task = Task { await controller.captureSnapshotMotions([motion], requestToken: token) }
            await fulfillment(of: [started], timeout: 2)
            controller.activeRequestToken = LayoutRequestToken(rawValue: 11)
            capturer.complete(with: result)
            let images = await task.value
            XCTAssertTrue(images.isEmpty)
        }
    }

    func testUnavailableSessionCancelsCaptureAndRejectsLateImage() async throws {
        let capturer = SuspendedSnapshotCapturer()
        let started = expectation(description: "capture started")
        capturer.onStart = { started.fulfill() }
        let controller = fixture(capturer: capturer)
        let token = LayoutRequestToken(rawValue: 10)
        controller.activeRequestToken = token
        controller.snapshotAnimationPreparing = true
        controller.snapshotAnimationPreparingRequestGeneration = token.rawValue
        let motion = makeMotion()
        var imageCount = -1
        let task = Task {
            imageCount = await controller.captureSnapshotMotions([motion], requestToken: token).count
        }
        controller.snapshotCaptureTask = task
        await fulfillment(of: [started], timeout: 2)
        _ = controller.beginUnavailableSessionPause()
        XCTAssertTrue(task.isCancelled)
        XCTAssertNil(controller.snapshotCaptureTask)
        XCTAssertNil(controller.activeRequestToken)
        XCTAssertFalse(controller.snapshotAnimationPreparing)
        capturer.complete(with: .success(try makeImage()))
        await task.value
        XCTAssertEqual(imageCount, 0)
        XCTAssertNil(controller.snapshotAnimationSession)
        controller.assertInvariants()
    }

    func testOldCompletionCannotClearNewPreparation() {
        let controller = fixture(capturer: SuspendedSnapshotCapturer())
        controller.activeRequestToken = LayoutRequestToken(rawValue: 11)
        controller.snapshotAnimationPreparing = true
        controller.snapshotAnimationPreparingRequestGeneration = 11
        controller.finishSnapshotPreparation(for: LayoutRequestToken(rawValue: 10))
        XCTAssertTrue(controller.snapshotAnimationPreparing)
        XCTAssertEqual(controller.snapshotAnimationPreparingRequestGeneration, 11)
        controller.assertInvariants()
        controller.cancel(reason: "test-finished")
    }

    func testSubmissionsAreCoalescedWhileCaptureIsPreparing() {
        var cancelled: [LayoutRequestToken] = []
        let controller = fixture(capturer: SuspendedSnapshotCapturer(), emit: { event in
            if case .cancelled(let token) = event { cancelled.append(token) }
        })
        let token = LayoutRequestToken(rawValue: 99)
        controller.activeRequestToken = token
        controller.snapshotAnimationPreparing = true
        controller.snapshotAnimationPreparingRequestGeneration = token.rawValue
        let state = LayoutState(activeWorkspace: 0, activeColumns: [], scrollOffsets: [])
        for _ in 0..<2 {
            controller.submit(previousState: state, targetState: state, viewport: .zero,
                              focusActiveWindow: false, animated: true, lockDelay: 0)
        }
        XCTAssertEqual(controller.activeRequestToken, token)
        XCTAssertEqual(cancelled, [LayoutRequestToken(rawValue: 1)])
        XCTAssertFalse(controller.resumeDeferredSubmissionIfReady())
        controller.finishSnapshotPreparation(for: token)
        controller.completeRequest(token, after: 0)
        XCTAssertTrue(controller.resumeDeferredSubmissionIfReady())
        XCTAssertEqual(controller.activeRequestToken, LayoutRequestToken(rawValue: 2))
        controller.assertInvariants()
        controller.cancel(reason: "test-finished")
    }

    private func makeImage() throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8,
                                            bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        return try XCTUnwrap(context.makeImage())
    }

    private func makeMotion() -> WindowMotion {
        let window = ManagedWindow(element: AXUIElementCreateApplication(1000), pid: 1000, windowID: 42,
                                   bundleID: nil, appName: "Test", title: "Test")
        let frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        return WindowMotion(window: window, startFrame: frame, endFrame: frame.offsetBy(dx: 100, dy: 0),
                            startsVisible: true, endsVisible: true)
    }

    private func fixture(
        capturer: any WindowSnapshotCapturing,
        reconcile: @escaping (pid_t) -> Void = { _ in },
        emit: @escaping (LayoutEvent) -> Void = { _ in }
    ) -> LayoutController {
        let dependencies = LayoutControllerDependencies(
            modelSnapshot: { WorkspaceModelSnapshot(workspaces: [], floatingWindows: [], activeWorkspace: 0) },
            settings: {
                LayoutControllerSettings(focusAlignment: .centered, innerGap: 0, parkedSliverWidth: 1,
                                         animationStrategy: .snapshot, debugLogging: false,
                                         snapshotAnimationSpeed: 50, animationFPS: 60,
                                         animationPixelThreshold: 1, floatingWindowLevel: 0)
            },
            activeWindow: { nil }, widthRatio: { _ in 0.5 },
            renderedOutsets: { _ in (0, 0, 0, 0) }, screenContaining: { _ in nil },
            suppressManualResize: { _ in }, isLayoutTrackingAllowed: { true },
            currentViewport: { CGRect(x: 0, y: 0, width: 1200, height: 800) },
            parkedSliverPoints: { _ in 1 }, location: { _ in nil }, tiledWindows: { [] },
            debugLog: { _ in }, stripMetrics: { _, _ in ([], []) },
            maxHorizontalCameraOffset: { _, _ in 0 }, visualFrame: { frame, _ in frame },
            deferReconciliation: { pid, _, _ in reconcile(pid) },
            setFocusedNotificationSuppressionUntil: { _ in }, notePhysicalFocusTarget: { _ in },
            workspaceProjection: { _ in nil }
        )
        return LayoutController(dependencies: dependencies, axOperations: AXOperationController(log: { _ in }),
                                snapshotCapturer: capturer, emit: emit)
    }
}
