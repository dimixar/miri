import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

extension Miri {
    func handleMousePointer(_ event: MousePointerEvent) {
        guard appPhase == .running, sessionController.isLayoutTrackingAllowed else { return }
        switch event.kind {
        case .down:
            cancelMouseInteraction()
            guard !windowManagement.observation.transientWindowActive,
                  let workspace = activeWorkspaceObject(),
                  workspace.fullscreenState == .off,
                  let windowID = event.windowID ?? sessionRecoveryFrontmostWindowID(at: event.location),
                  let window = workspace.windows.first(where: { $0.windowID == windowID }),
                  let frame = layoutController.windowServerFrame(for: windowID)
            else { return }
            let viewport = currentViewport()
            let offset = horizontalCameraOffset(for: workspace, viewport: viewport)
            mouseInteractionLayoutViewport = viewport
            mouseInteractionController.begin(
                window: window, workspace: workspace,
                logicalSpaceID: windowManagement.activeLogicalSpaceContextID,
                frame: frame, scrollOffset: offset, pointer: event.location
            )
            // Close admission before cancellation emits layout-completed events.
            fullWindowScanGeneration &+= 1
            focusedWindowAdoptionGeneration &+= 1
            focusStateGeneration &+= 1
            manualResizeController.cancel()
            layoutController.beginUserInteraction(window)
        case .dragged:
            guard mouseInteractionIsValid else { cancelMouseInteraction(); return }
            updateMouseInteraction(at: event.location)
        case .up:
            endMouseInteraction(at: event.location)
        }
    }

    var mouseInteractionIsValid: Bool {
        guard let session = mouseInteractionController.session else { return false }
        return appPhase == .running && sessionController.isLayoutTrackingAllowed
            && session.logicalSpaceID == windowManagement.activeLogicalSpaceContextID
            && activeWorkspaceObject() === session.workspace
            && session.workspace.windows.contains(where: { $0 === session.window })
            && !session.window.isMinimized && !session.window.isFullscreen
    }

    func handleMouseInteractionTick(generation: UInt64) {
        guard let session = mouseInteractionController.session,
              session.generation == generation, !session.ending else { return }
        guard mouseInteractionIsValid else { cancelMouseInteraction(); return }
        let pointer = CGEvent(source: nil)?.location ?? session.pointer
        // This also recovers a missed mouse-up or an event tap disabled mid-drag.
        guard CGEventSource.buttonState(.combinedSessionState, button: .left) else {
            endMouseInteraction(at: pointer)
            return
        }
        updateMouseInteraction(at: pointer)
        guard let viewport = mouseInteractionLayoutViewport,
              let offset = mouseInteractionController.advanceScroll(
                viewport: mouseEdgeViewport(viewport), bounds: mouseScrollBounds(viewport),
                speedPercent: dragScrollSpeedPercent
              ) else { return }
        windowManagement.setScrollOffset(offset, in: session.workspace)
        layoutController.applyInteractiveLayout(
            viewport: viewport, state: captureLayoutState(), cameraOffset: offset
        )
        refreshMouseInteraction()
    }

    private func updateMouseInteraction(at pointer: CGPoint) {
        let previousPreview = mouseInteractionController.session?.preview
        mouseInteractionController.updatePointer(pointer)
        observeMouseWindowFrame()
        refreshMouseInteraction()
        if case let .scroll(previousDirection, _) = previousPreview {
            if case let .scroll(direction, _) = mouseInteractionController.session?.preview,
               direction == previousDirection { return }
            // Discard lagging neighbor writes as soon as the pointer leaves or
            // changes edge. They must not keep scrolling beneath a swap preview.
            layoutController.stopInteractiveScroll()
            refreshMouseInteraction()
        }
    }

    func observeMouseWindowFrame() {
        guard let session = mouseInteractionController.session, !session.ending,
              let windowID = session.window.windowID else { return }
        guard let frame = layoutController.windowServerFrame(for: windowID) else {
            cancelMouseInteraction()
            requestReconciliation(.all(adoptFocused: true, source: .accessibility, reason: "mouse-window-missing"))
            return
        }
        mouseInteractionController.observeFrame(frame)
        layoutController.recordPresentationFrame(frame, for: session.window)
    }

    func refreshMouseInteraction() {
        guard let session = mouseInteractionController.session, !session.ending,
              let viewport = mouseInteractionLayoutViewport else { return }
        if session.phase == .resizing {
            if updateManualWidthRatio(for: session.window.element, observedFrame: session.latestFrame) {
                layoutController.applyInteractiveLayout(
                    viewport: viewport, state: captureLayoutState(),
                    cameraOffset: session.workspace.scrollOffset ?? session.initialScrollOffset
                )
            }
        }
        let preview = mouseInteractionController.updatePreview(
            items: session.phase == .dragging ? mouseDisplayedLayout(viewport) : [],
            viewport: mouseEdgeViewport(viewport),
            scrollBounds: mouseScrollBounds(viewport)
        )
        mouseInteractionOverlayController.render(
            preview, viewport: mouseEdgeViewport(viewport), draggedWindowID: session.window.windowID
        )
    }

    private func mouseDisplayedLayout(_ viewport: CGRect) -> [LayoutItem] {
        guard let session = mouseInteractionController.session,
              let windows = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
              ) as? [[String: Any]] else { return [] }
        // AX writes can lag behind camera ticks. Preview actual displayed windows,
        // not their requested future positions or offscreen parking locations.
        return windows.compactMap { info in
            guard let windowID = info[kCGWindowNumber as String] as? UInt32,
                  let window = session.workspace.windows.first(where: { $0.windowID == windowID }),
                  window !== session.window,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary else { return nil }
            var frame = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(bounds as CFDictionary, &frame),
                  frame.intersects(viewport) else { return nil }
            return LayoutItem(window: window, frame: frame, visible: true)
        }
    }

    private func mouseScrollBounds(_ viewport: CGRect) -> ClosedRange<CGFloat> {
        guard let session = mouseInteractionController.session else { return 0...0 }
        let maximum = maxHorizontalCameraOffset(for: session.workspace, viewport: viewport)
        return min(0, session.initialScrollOffset)...max(maximum, session.initialScrollOffset)
    }

    private func mouseEdgeViewport(_ viewport: CGRect) -> CGRect {
        // Layout outer gaps are not dead zones: scrolling activates at screen edges.
        let displayID = screenContaining(viewport)?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32
        let screen = CGDisplayBounds(displayID ?? CGMainDisplayID())
        return CGRect(x: screen.minX, y: viewport.minY, width: screen.width, height: viewport.height)
    }

    func endMouseInteraction(at pointer: CGPoint) {
        guard let session = mouseInteractionController.session, !session.ending else { return }
        guard mouseInteractionIsValid else { cancelMouseInteraction(); return }
        if session.phase != .pending { layoutController.stopInteractiveScroll() }
        updateMouseInteraction(at: pointer)
        guard let release = mouseInteractionController.session else { return }
        mouseInteractionController.markEnding()
        mouseInteractionOverlayController.hide()
        let resumeGeneration = sessionController.resumeGeneration
        // A blocked application's AX lane must not retain gesture ownership forever.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.sessionController.resumeGeneration == resumeGeneration else { return }
            self.commitMouseInteraction(release, finalFrame: nil)
        }
        axOperations.readWindow(
            handle: AXElementHandle(element: session.window.element, pid: session.window.pid, windowID: session.window.windowID),
            priority: .interactive
        ) { [weak self] result in
            guard let self,
                  self.mouseInteractionController.session?.generation == release.generation,
                  self.sessionController.resumeGeneration == resumeGeneration else { return }
            guard self.mouseInteractionIsValid else { self.cancelMouseInteraction(); return }
            if let snapshot = result.value,
               snapshot.minimized == true || snapshot.fullscreen == true {
                self.cancelMouseInteraction()
                self.requestReconciliation(.all(adoptFocused: true, source: .accessibility, reason: "mouse-window-unavailable"))
                return
            }
            self.commitMouseInteraction(release, finalFrame: result.value?.frame)
        }
    }

    func commitMouseInteraction(_ release: MouseInteractionSession, finalFrame: CGRect?) {
        guard mouseInteractionController.session?.generation == release.generation,
              mouseInteractionIsValid else { return }
        guard let sourceID = release.window.windowID,
              layoutController.windowServerFrame(for: sourceID) != nil else {
            cancelMouseInteraction()
            requestReconciliation(.all(adoptFocused: true, source: .accessibility, reason: "mouse-source-closed"))
            return
        }
        if let finalFrame { mouseInteractionController.observeFrame(finalFrame, finishing: true) }
        let phase = mouseInteractionController.session?.phase ?? release.phase
        if phase == .resizing {
            _ = updateManualWidthRatio(for: release.window.element, observedFrame: finalFrame ?? release.latestFrame)
        } else if phase == .dragging {
            if case let .swap(target, _) = release.preview,
               !target.isMinimized, !target.isFullscreen,
               let targetID = target.windowID,
               let targetFrame = layoutController.windowServerFrame(for: targetID),
               targetFrame.intersects(mouseInteractionLayoutViewport ?? currentViewport()),
               windowManagement.swapWindows(release.window, with: target, in: release.workspace) {
                // Preserve the scrolled view where possible; normal final projection
                // may reveal/align the source at its new column.
                windowManagement.setScrollOffset(release.scrollOffset, in: release.workspace)
            } else {
                windowManagement.setScrollOffset(release.initialScrollOffset, in: release.workspace)
            }
            if let index = release.workspace.columns.firstIndex(where: { $0.windows.contains { $0 === release.window } }) {
                release.workspace.columns[index].activeRow = release.workspace.columns[index].windows.firstIndex { $0 === release.window } ?? 0
                windowManagement.setActiveColumn(index, in: release.workspace)
            }
        }
        mouseInteractionController.finish()
        mouseInteractionLayoutViewport = nil
        layoutController.endUserInteraction()
        if phase != .pending {
            projectLayout(focusActiveWindow: true)
            schedulePersistentLayoutSnapshotWrite()
            saveActiveLogicalSpaceContext()
        } else {
            requestReconciliation(.all(adoptFocused: true, source: .accessibility, reason: "mouse-click-ended"))
        }
        drainPendingCoordinatorWorkIfPossible()
    }

    func cancelMouseInteraction() {
        if mouseInteractionController.isActive { layoutController.stopInteractiveScroll() }
        guard let cancelled = mouseInteractionController.cancel() else { return }
        if cancelled.phase == .dragging {
            windowManagement.setScrollOffset(cancelled.initialScrollOffset, in: cancelled.workspace)
        }
        mouseInteractionOverlayController.hide()
        mouseInteractionLayoutViewport = nil
        layoutController.endUserInteraction()
    }
}
