import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

extension Miri {
    func handleFullscreenOSTransitionIfNeeded(
        _ element: AXUIElement,
        fullscreenOS: Bool
    ) -> Bool {
        if fullscreenOS, let location = tiledWindowLocation(for: element) {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == location.window.pid {
                lastKnownFocusedElements[location.window.pid] = element
            }
            windowManagement.clearPendingFullscreenOSTransition(for: ObjectIdentifier(location.window))
            fullscreenTransitionGuardUntil = max(fullscreenTransitionGuardUntil, CFAbsoluteTimeGetCurrent() + fullscreenTransitionGrace)
            rememberFullscreenOSWindowState(location.window)
            removeWindow(location.window, preferRightFocus: true)
            projectLayout(focusActiveWindow: location.workspace.columns.isEmpty ? false : true, layoutLockDelay: 0.02)
            schedulePersistentLayoutSnapshotWrite()
            return true
        }

        if let location = tiledWindowLocation(for: element), !windowHasCGInfo(location.window) {
            beginPendingFullscreenOSTransition(for: location.window)
            return true
        }

        if !fullscreenOS, isRememberedFullscreenOSWindow(element) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                self?.requestReconciliation(
                    .all(adoptFocused: true, source: .delayedProbe, reason: "fullscreen-enter-settle")
                )
            }
            return true
        }

        return false
    }

    func beginPendingFullscreenOSTransition(for window: ManagedWindow) {
        let id = ObjectIdentifier(window)
        let now = CFAbsoluteTimeGetCurrent()
        if windowManagement.pendingFullscreenOSTransition(for: id) == nil {
            windowManagement.recordPendingFullscreenOSTransition(for: id, at: now)
            debugLog("pending fullscreen transition app='\(window.appName)' bundle='\(window.bundleID ?? "nil")' title='\(window.title)'")
            DispatchQueue.main.asyncAfter(deadline: .now() + fullscreenTransitionGrace) { [weak self] in
                self?.requestReconciliation(
                    .all(adoptFocused: true, source: .delayedProbe, reason: "fullscreen-exit-grace")
                )
            }
        }
        fullscreenTransitionGuardUntil = max(fullscreenTransitionGuardUntil, now + fullscreenTransitionGrace)
    }

    func fullscreenSpaceChangeGuardIsActive() -> Bool {
        CFAbsoluteTimeGetCurrent() < fullscreenSpaceChangeGuardUntil
    }

    func focusedRememberedFullscreenOSWindowState() -> FullscreenOSWindowState? {
        guard !windowManagement.fullscreenOSWindowStates.isEmpty,
              let frontmost = NSWorkspace.shared.frontmostApplication
        else {
            return nil
        }

        // Keep this focus-critical guard AX-IPC-free while retaining exact
        // identity from the most recent asynchronous focused-window snapshot.
        guard let focusedElement = lastKnownFocusedElements[frontmost.processIdentifier] else {
            return nil
        }
        return windowManagement.fullscreenOSWindowStates.values.first { state in
            state.pid == frontmost.processIdentifier
                && sameWindow(state.element, focusedElement)
        }
    }

    var focusedRememberedFullscreenOSWindowIsActive: Bool {
        focusedRememberedFullscreenOSWindowState() != nil
    }

    func enforceRememberedFullscreenOSWorkspaceIfNeeded(_ state: FullscreenOSWindowState) {
        guard windowManagement.workspaces.indices.contains(state.workspace),
              windowManagement.activeWorkspace != state.workspace
        else {
            return
        }
        debugLog("restoring fullscreen miri workspace=\(state.workspace + 1) while focused on remembered fullscreen app='\(state.appName)' bundle='\(state.bundleID ?? "nil")'")
        _ = windowManagement.selectWorkspace(state.workspace)
    }

    func enforceFullscreenSpaceGuardWorkspace() {
        guard fullscreenSpaceChangeGuardIsActive(),
              let workspace = windowManagement.fullscreenSpaceChangeGuardWorkspace,
              windowManagement.workspaces.indices.contains(workspace),
              windowManagement.activeWorkspace != workspace
        else {
            return
        }
        debugLog("restoring guarded miri workspace=\(workspace + 1) during fullscreen space guard")
        _ = windowManagement.selectWorkspace(workspace)
    }

    func beginFullscreenSpaceChangeGuard() {
        let now = CFAbsoluteTimeGetCurrent()
        let wasActive = now < fullscreenSpaceChangeGuardUntil
        fullscreenSpaceChangeGuardUntil = max(fullscreenSpaceChangeGuardUntil, now + fullscreenSpaceChangeGuardDuration)
        fullscreenTransitionGuardUntil = max(fullscreenTransitionGuardUntil, fullscreenSpaceChangeGuardUntil)
        if !wasActive {
            fullscreenSpaceChangeGuardStartedGeneration = spaceChangeGeneration
            windowManagement.setFullscreenSpaceChangeGuardWorkspace(windowManagement.activeWorkspace)
            debugLog("fullscreen space helper guard started workspace=\(windowManagement.activeWorkspace + 1) generation=\(spaceChangeGeneration)")
            DispatchQueue.main.asyncAfter(deadline: .now() + fullscreenSpaceChangeGuardDuration) { [weak self] in
                self?.finishFullscreenSpaceChangeGuardIfExpired()
            }
        }
    }

    func finishFullscreenSpaceChangeGuardIfExpired() {
        let now = CFAbsoluteTimeGetCurrent()
        guard now >= fullscreenSpaceChangeGuardUntil else {
            DispatchQueue.main.asyncAfter(deadline: .now() + (fullscreenSpaceChangeGuardUntil - now)) { [weak self] in
                self?.finishFullscreenSpaceChangeGuardIfExpired()
            }
            return
        }
        let changed = spaceChangeGeneration != fullscreenSpaceChangeGuardStartedGeneration
        debugLog("fullscreen space helper guard ended spaceChanged=\(changed) generation=\(spaceChangeGeneration)")
        windowManagement.setFullscreenSpaceChangeGuardWorkspace(nil)
    }

    func windowHasCGInfo(_ window: ManagedWindow) -> Bool {
        guard let windowID = window.windowID else {
            return true
        }
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(windowID)) as? [[String: Any]] else {
            return false
        }
        return !list.isEmpty
    }

    func removeDestroyedWindowImmediately(_ element: AXUIElement) -> Bool {
        windowManagement.forgetManualBehavior(for: element)
        windowManagement.forgetWindowFullscreen(for: element)
        if let location = tiledWindowLocation(for: element) {
            let wasActiveWorkspace = windowManagement.activeWorkspace == location.workspaceIndex
            let wasActiveWindow = wasActiveWorkspace && location.workspace.activeWindow === location.window
            removeWindow(location.window, preferRightFocus: true)
            if wasActiveWindow {
                projectLayout(focusActiveWindow: true, layoutLockDelay: 0.02)
            } else {
                projectLayout(focusActiveWindow: false, layoutLockDelay: 0.02)
            }
            return true
        }

        if let window = windowManagement.floatingWindows.first(where: { sameWindow($0.element, element) }) {
            removeWindow(window)
            projectLayout(focusActiveWindow: false, layoutLockDelay: 0.02)
            return true
        }

        return false
    }

    func updateManualWidthRatio(
        for element: AXUIElement,
        observedFrame frame: CGRect?
    ) -> Bool {
        guard let location = tiledWindowLocation(for: element),
              windowManagement.fullscreenState(in: location.workspace) == .off,
              let frame
        else {
            return false
        }

        let viewport = currentViewport()
        guard viewport.width > 0 else {
            return false
        }

        let ratio = (frame.width / viewport.width).clampedManualWidthRatio
        let previousRatio = widthRatio(for: location.window)
        let oldScrollOffset = location.workspace.scrollOffset
        let column = location.workspace.columns[location.columnIndex]
        let row = column.windows.firstIndex { $0 === location.window } ?? 0
        let gap = points(forPhysicalPixels: innerGap, in: viewport)
        let usableHeight = max(1, viewport.height - gap * CGFloat(column.windows.count - 1))
        let heightChanged = column.setHeightRatio(frame.height / usableHeight, row: row, minimums: column.windows.map { $0.minimumHeight / usableHeight })
        windowManagement.setWidthRatio(ratio, for: location.window)

        let metrics = stripMetrics(for: location.workspace, viewport: viewport)
        let virtualOrigin = metrics.origins[location.columnIndex]
        let newScrollOffset = virtualOrigin - (frame.minX - viewport.minX)

        // Resizing changes the geometry; retain smart alignment even when the
        // resized window happens to fit at its observed position.
        let resolvedScrollOffset = LayoutEngine.resolveScrollOffset(
            metrics: metrics,
            activeColumn: location.columnIndex,
            viewport: viewport,
            focusAlignment: focusAlignment,
            preferredScrollOffset: newScrollOffset,
            preserveVisibleFocus: false
        )
        windowManagement.setScrollOffset(resolvedScrollOffset, in: location.workspace)
        setActiveWorkspace(location.workspaceIndex)
        windowManagement.setActiveColumn(location.columnIndex, in: location.workspace)
        location.workspace.columns[location.columnIndex].activeRow = location.workspace.columns[location.columnIndex].windows.firstIndex { $0 === location.window } ?? 0
        layoutController.recordPresentationFrame(frame, for: location.window)

        if !heightChanged, abs(previousRatio - ratio) < 0.005,
           let oldScrollOffset,
           abs(oldScrollOffset - resolvedScrollOffset) < 0.5
        {
            return false
        }

        layoutController.externalResizeObserved(frame: frame, window: location.window)
        return true
    }

    func beginOrContinueManualResize(
        for element: AXUIElement,
        observedFrame: CGRect?
    ) {
        guard tiledWindow(for: element) != nil else {
            layoutController.restoreFloatingVisibility()
            return
        }

        guard manualResizeController.beginOrContinue(element, frame: observedFrame) else { return }
        layoutController.cancel(reason: "manual-resize-interrupt")

        if updateManualWidthRatio(for: element, observedFrame: observedFrame) {
            schedulePersistentLayoutSnapshotWrite()
            projectLayout(focusActiveWindow: false, layoutLockDelay: 0)
        }
        drainPendingCoordinatorWorkIfPossible()

        manualResizeController.scheduleEnd(for: element)
    }

    func handleManualResizeEnded(element: AXUIElement) {
        guard let finalFrame = manualResizeController.finish(element) else { return }
        if updateManualWidthRatio(for: element, observedFrame: finalFrame) {
            schedulePersistentLayoutSnapshotWrite()
        }
        projectLayout(focusActiveWindow: false, layoutLockDelay: 0.02)
    }

    func isManualResizeElement(_ element: AXUIElement) -> Bool {
        manualResizeController.isCurrent(element)
    }

    func frameWidthDiffersFromLayout(
        for element: AXUIElement,
        observedFrame frame: CGRect?
    ) -> Bool {
        guard let window = tiledWindow(for: element),
              let frame
        else {
            return false
        }

        let viewport = currentViewport()
        guard viewport.width > 0 else {
            return false
        }

        let frameRatio = (frame.width / viewport.width).clampedManualWidthRatio
        return abs(frameRatio - widthRatio(for: window)) >= 0.005
    }

}
