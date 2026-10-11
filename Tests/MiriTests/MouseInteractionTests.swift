import AppKit
import ApplicationServices
import CoreGraphics
import XCTest
@testable import miri

@MainActor
final class MouseInteractionTests: XCTestCase {
    private let viewport = CGRect(x: 0, y: 0, width: 1000, height: 800)
    private let frame = CGRect(x: 100, y: 100, width: 300, height: 500)

    func testLeftEdgeResizeTakesPrecedenceAndCanPromoteDrag() {
        let controller = fixture()
        defer { controller.cancel() }
        controller.observeFrame(frame.offsetBy(dx: 10, dy: 0))
        XCTAssertEqual(controller.session?.phase, .pending)
        controller.updatePointer(CGPoint(x: 110, y: 100))
        XCTAssertEqual(controller.session?.phase, .dragging)
        controller.observeFrame(CGRect(x: 110, y: 100, width: 290, height: 500))
        XCTAssertEqual(controller.session?.phase, .resizing)
        assertNone(controller.updatePreview(items: [], viewport: viewport, scrollBounds: 0...500))
        controller.updatePointer(frame.origin)
        controller.observeFrame(frame)
        XCTAssertEqual(controller.session?.phase, .resizing, "Returning to the starting size does not end a held resize")
    }

    func testContentSelectionAndFrameNoiseRemainPending() {
        let controller = fixture()
        defer { controller.cancel() }
        controller.updatePointer(CGPoint(x: 999, y: 100))
        controller.observeFrame(frame)
        controller.observeFrame(frame.offsetBy(dx: 1, dy: 1))
        XCTAssertEqual(controller.session?.phase, .pending)
        assertNone(controller.updatePreview(items: [], viewport: viewport, scrollBounds: 0...500, now: 0))
        XCTAssertNil(controller.advanceScroll(viewport: viewport, bounds: 0...500, now: 1))
    }

    func testSwapTargetsNonadjacentVisibleWindowWithoutChangingModel() throws {
        let controller = fixture()
        defer { controller.cancel() }
        let source = try XCTUnwrap(controller.session?.window)
        let hidden = window(2)
        let target = window(3)
        let workspace = try XCTUnwrap(controller.session?.workspace)
        workspace.columns = [source, hidden, target]
        let targetFrame = CGRect(x: 650, y: 0, width: 500, height: 800)
        let items = [
            LayoutItem(window: source, frame: targetFrame, visible: true),
            LayoutItem(window: hidden, frame: targetFrame, visible: false),
            LayoutItem(window: target, frame: targetFrame, visible: true),
        ]
        controller.updatePointer(CGPoint(x: 700, y: 200))
        controller.observeFrame(frame.offsetBy(dx: 20, dy: 0))
        guard case let .swap(actual, highlight) = controller.updatePreview(
            items: items, viewport: viewport, scrollBounds: 0...500, now: 0
        ) else { return XCTFail("Expected swap") }
        XCTAssertTrue(actual === target)
        XCTAssertEqual(highlight, targetFrame)
        XCTAssertTrue(workspace.columns[0] === source)
        XCTAssertTrue(workspace.columns[2] === target)
        XCTAssertNil(workspace.scrollOffset)
        controller.markEnding()
        assertNone(controller.updatePreview(items: items, viewport: viewport, scrollBounds: 0...500))
        XCTAssertNil(controller.advanceScroll(viewport: viewport, bounds: 0...500, now: 1))
    }

    func testDwellScrollBothDirectionsClampsIncludingNegativeCameraAndStopsOnExit() throws {
        for direction in [MouseScrollDirection.left, .right] {
            let controller = fixture(scrollOffset: 0)
            defer { controller.cancel() }
            let point = CGPoint(x: direction == .left ? 1 : 999, y: 200)
            controller.updatePointer(point)
            controller.observeFrame(frame.offsetBy(dx: 10, dy: 0))
            let bounds: ClosedRange<CGFloat> = -200...200
            guard case let .scroll(actual, canScroll) = controller.updatePreview(
                items: [], viewport: viewport, scrollBounds: bounds, now: 10
            ) else { return XCTFail("Expected edge preview") }
            XCTAssertEqual(actual, direction)
            XCTAssertTrue(canScroll)
            XCTAssertNil(controller.advanceScroll(viewport: viewport, bounds: bounds, now: 10.24))
            let offset = try XCTUnwrap(controller.advanceScroll(viewport: viewport, bounds: bounds, now: 10.35))
            XCTAssertEqual(offset, direction == .left ? -70.125 : 70.125, accuracy: 0.001)
            controller.updatePointer(CGPoint(x: point.x, y: -1))
            XCTAssertNil(controller.advanceScroll(viewport: viewport, bounds: bounds, now: 11))
            controller.updatePointer(point)
            XCTAssertNil(controller.advanceScroll(viewport: viewport, bounds: bounds, now: 12))
            XCTAssertNil(controller.advanceScroll(viewport: viewport, bounds: bounds, now: 12.24))
            XCTAssertEqual(controller.advanceScroll(viewport: viewport, bounds: bounds, now: 13), direction == .left ? -200 : 200)
            XCTAssertNil(controller.advanceScroll(viewport: viewport, bounds: bounds, now: 14))
            guard case let .scroll(_, possible) = controller.updatePreview(
                items: [], viewport: viewport, scrollBounds: bounds, now: 14
            ) else { return XCTFail("Expected bounded edge preview") }
            XCTAssertFalse(possible)
        }
    }

    func testScrollSpeedScalesBothDirectionsAndChangesDuringHeldDrag() throws {
        for direction in [MouseScrollDirection.left, .right] {
            let controller = fixture(scrollOffset: 0)
            defer { controller.cancel() }
            let sign: CGFloat = direction == .left ? -1 : 1
            controller.updatePointer(CGPoint(x: direction == .left ? 16 : 984, y: 200))
            controller.observeFrame(frame.offsetBy(dx: 10, dy: 0))
            let bounds: ClosedRange<CGFloat> = -400...400
            _ = controller.updatePreview(items: [], viewport: viewport, scrollBounds: bounds, now: 10)
            XCTAssertNil(controller.advanceScroll(viewport: viewport, bounds: bounds, speedPercent: 50, now: 10.24))
            let slow = try XCTUnwrap(controller.advanceScroll(
                viewport: viewport, bounds: bounds, speedPercent: 50, now: 10.35
            ))
            // Halfway through the edge zone: 420 pt/s × 50% × 0.1s.
            XCTAssertEqual(slow, sign * 21, accuracy: 0.001)
            let faster = try XCTUnwrap(controller.advanceScroll(
                viewport: viewport, bounds: bounds, speedPercent: 175, now: 10.45
            ))
            XCTAssertEqual(faster, sign * 94.5, accuracy: 0.001)
            let maximumSpeed = try XCTUnwrap(controller.advanceScroll(
                viewport: viewport, bounds: bounds, speedPercent: 500, now: 10.55
            ))
            XCTAssertEqual(maximumSpeed, sign * 304.5, accuracy: 0.001)
            XCTAssertEqual(controller.advanceScroll(
                viewport: viewport, bounds: bounds, speedPercent: 500, now: 10.65
            ), sign * 400)
            controller.updatePointer(CGPoint(x: 500, y: 200))
            XCTAssertNil(controller.advanceScroll(viewport: viewport, bounds: bounds, speedPercent: 500, now: 11))
        }
    }

    func testFinishCancelAndNewSessionUseIncreasingGeneration() throws {
        let controller = fixture()
        let first = try XCTUnwrap(controller.session?.generation)
        controller.markEnding()
        XCTAssertTrue(controller.isActive)
        XCTAssertEqual(controller.finish()?.generation, first)
        XCTAssertFalse(controller.isActive)
        let next = controller.begin(window: window(2), workspace: Workspace(), logicalSpaceID: 2,
                                    frame: frame, scrollOffset: -50, pointer: frame.origin)
        XCTAssertGreaterThan(next, first)
        XCTAssertEqual(controller.cancel()?.initialScrollOffset, -50)
        XCTAssertNil(controller.finish())
    }

    func testFinalFrameCanIdentifyResizeWithoutStartingScrollOrSwapAfterRelease() {
        let controller = fixture()
        controller.updatePointer(CGPoint(x: 999, y: 100))
        controller.markEnding()
        controller.observeFrame(CGRect(x: 90, y: 100, width: 310, height: 500), finishing: true)
        XCTAssertEqual(controller.session?.phase, .resizing)
        XCTAssertNil(controller.advanceScroll(viewport: viewport, bounds: 0...500, now: 10))
        assertNone(controller.updatePreview(items: [], viewport: viewport, scrollBounds: 0...500))
        controller.finish()
    }

    func testSwapChangesOnlyTheTwoPositionsAndKeepsWidthsAndSourceFocus() throws {
        let management = WindowManagement(axOperations: AXOperationController(log: { _ in }), emit: { _ in })
        let workspace = try XCTUnwrap(management.activeWorkspaceObject())
        let source = window(1)
        let middle = window(2)
        let target = window(3)
        source.manualWidthRatio = 0.3
        target.manualWidthRatio = 0.7
        workspace.columns = [source, middle, target]
        workspace.scrollOffset = 275
        XCTAssertTrue(management.swapWindows(source, with: target, in: workspace))
        XCTAssertTrue(workspace.columns[0] === target)
        XCTAssertTrue(workspace.columns[1] === middle)
        XCTAssertTrue(workspace.columns[2] === source)
        XCTAssertEqual(workspace.activeColumn, 2)
        XCTAssertEqual(workspace.scrollOffset, 275)
        XCTAssertEqual(source.manualWidthRatio, 0.3)
        XCTAssertEqual(target.manualWidthRatio, 0.7)
        XCTAssertFalse(management.swapWindows(source, with: window(4), in: workspace))
        XCTAssertFalse(management.swapWindows(source, with: target, in: Workspace()))
    }

    func testDragCameraOverridesBothCenteredAlignmentModes() {
        let windows = [window(1), window(2), window(3)]
        let workspace = LayoutEngineWorkspace(
            columns: zip(windows, [CGFloat(0.3), 0.55, 0.8]).map {
                LayoutEngineWindow(window: $0.0, widthRatio: $0.1, renderedOutsets: (0, 0, 0, 0))
            }, activeColumn: 0, scrollOffset: 450
        )
        for alignment in [FocusAlignment.centered, .centeredSmart] {
            let items = LayoutEngine.project(LayoutEngineInput(
                workspaces: [workspace],
                state: LayoutState(activeWorkspace: 0, activeColumns: [0], scrollOffsets: [450]),
                viewport: CGRect(x: 100, y: 80, width: 1000, height: 800),
                settings: LayoutEngineSettings(focusAlignment: alignment, innerGap: 0,
                                              parkedSliverWidth: 1, physicalPixelScale: 1),
                parkHidden: false, interactiveCameraOffset: 450
            ))
            XCTAssertEqual(items.map { $0.frame.minX }, [-350, -50, 500])
        }
    }

    func testSwapPreviewStaysBelowSourceAndEdgeIndicatorRestoresFloatingLevel() async throws {
        _ = NSApplication.shared
        guard let screen = NSScreen.screens.first else { throw XCTSkip("Requires a WindowServer session") }
        let sourceFrame = CGRect(x: screen.frame.minX + 80, y: screen.frame.minY + 120, width: 120, height: 100)
        let source = NSPanel(contentRect: sourceFrame, styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        source.level = .normal
        source.orderFrontRegardless()
        let controller = MouseInteractionOverlayController()
        defer { controller.hide(); source.orderOut(nil) }
        let visibleWindows = {
            (CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? [])
                .filter { ($0[kCGWindowOwnerPID as String] as? Int32) == ProcessInfo.processInfo.processIdentifier }
        }
        try await Task.sleep(for: .milliseconds(100))
        let sourceID = UInt32(source.windowNumber)
        let existingIDs = Set(visibleWindows().compactMap { $0[kCGWindowNumber as String] as? UInt32 })
        XCTAssertTrue(existingIDs.contains(sourceID))
        let viewport = CGRect(x: sourceFrame.minX, y: screen.frame.maxY - sourceFrame.maxY,
                              width: sourceFrame.width, height: sourceFrame.height)
        controller.render(.swap(target: window(2), frame: viewport), viewport: viewport, draggedWindowID: sourceID)
        try await Task.sleep(for: .milliseconds(100))
        let swapIDs = visibleWindows().compactMap { $0[kCGWindowNumber as String] as? UInt32 }
        let overlayID = try XCTUnwrap(swapIDs.first { !existingIDs.contains($0) })
        XCTAssertLessThan(try XCTUnwrap(swapIDs.firstIndex(of: sourceID)),
                          try XCTUnwrap(swapIDs.firstIndex(of: overlayID)))
        controller.render(.scroll(direction: .right, canScroll: true), viewport: viewport, draggedWindowID: sourceID)
        try await Task.sleep(for: .milliseconds(100))
        let indicator = try XCTUnwrap(visibleWindows().first { ($0[kCGWindowNumber as String] as? UInt32) == overlayID })
        XCTAssertEqual(indicator[kCGWindowLayer as String] as? Int, NSWindow.Level.floating.rawValue)
        controller.render(.none, viewport: viewport, draggedWindowID: sourceID)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(visibleWindows().contains { ($0[kCGWindowNumber as String] as? UInt32) == overlayID })
    }

    private func fixture(scrollOffset: CGFloat = 0) -> MouseInteractionController {
        let controller = MouseInteractionController(emitTick: { _ in })
        controller.begin(window: window(1), workspace: Workspace(), logicalSpaceID: 1,
                         frame: frame, scrollOffset: scrollOffset, pointer: frame.origin)
        return controller
    }

    private func window(_ id: Int32) -> ManagedWindow {
        ManagedWindow(element: AXUIElementCreateApplication(id), pid: id, windowID: nil,
                      bundleID: nil, appName: "Test", title: "Window")
    }

    private func assertNone(_ preview: MouseInteractionPreview, file: StaticString = #filePath, line: UInt = #line) {
        guard case .none = preview else { return XCTFail("Expected no preview", file: file, line: line) }
    }
}
