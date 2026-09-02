import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

extension Miri {
    func handleFullscreenTransitionIfNeeded(
        _ element: AXUIElement,
        isFullscreen: Bool
    ) -> Bool {
        if isFullscreen, let location = tiledWindowLocation(for: element) {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == location.window.pid {
                lastKnownFocusedElements[location.window.pid] = element
            }
            windowManagement.clearPendingFullscreenTransition(for: ObjectIdentifier(location.window))
            fullscreenTransitionGuardUntil = max(fullscreenTransitionGuardUntil, CFAbsoluteTimeGetCurrent() + fullscreenTransitionGrace)
            rememberFullscreenWindowState(location.window)
            removeWindow(location.window, preferRightFocus: true)
            projectLayout(focusActiveWindow: location.workspace.columns.isEmpty ? false : true, layoutLockDelay: 0.02)
            schedulePersistentLayoutSnapshotWrite()
            return true
        }

        if let location = tiledWindowLocation(for: element), !windowHasCGInfo(location.window) {
            beginPendingFullscreenTransition(for: location.window)
            return true
        }

        if !isFullscreen, isRememberedFullscreenWindow(element) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                self?.requestReconciliation(
                    .all(adoptFocused: true, source: .delayedProbe, reason: "fullscreen-enter-settle")
                )
            }
            return true
        }

        return false
    }

    func beginPendingFullscreenTransition(for window: ManagedWindow) {
        let id = ObjectIdentifier(window)
        let now = CFAbsoluteTimeGetCurrent()
        if windowManagement.pendingFullscreenTransition(for: id) == nil {
            windowManagement.recordPendingFullscreenTransition(for: id, at: now)
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

    func focusedRememberedFullscreenWindowState() -> FullscreenWindowState? {
        guard !windowManagement.fullscreenWindowStates.isEmpty,
              let frontmost = NSWorkspace.shared.frontmostApplication
        else {
            return nil
        }

        // Keep this focus-critical guard AX-IPC-free while retaining exact
        // identity from the most recent asynchronous focused-window snapshot.
        guard let focusedElement = lastKnownFocusedElements[frontmost.processIdentifier] else {
            return nil
        }
        return windowManagement.fullscreenWindowStates.values.first { state in
            state.pid == frontmost.processIdentifier
                && sameWindow(state.element, focusedElement)
        }
    }

    var focusedRememberedFullscreenWindowIsActive: Bool {
        focusedRememberedFullscreenWindowState() != nil
    }

    func enforceRememberedFullscreenWorkspaceIfNeeded(_ state: FullscreenWindowState) {
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
        if let location = tiledWindowLocation(for: element) {
            let wasActiveWorkspace = windowManagement.activeWorkspace == location.workspaceIndex
            let wasActiveWindow = wasActiveWorkspace && location.workspace.activeColumn == location.columnIndex
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
              let frame
        else {
            return false
        }

        let viewport = currentViewport()
        guard viewport.width > 0 else {
            return false
        }

        let ratio = (frame.width / viewport.width).clampedManualWidthRatio
        let previousRatio = location.window.manualWidthRatio
        let oldScrollOffset = location.workspace.scrollOffset
        windowManagement.setWidthRatio(ratio, for: location.window)

        let metrics = stripMetrics(for: location.workspace, viewport: viewport)
        let virtualOrigin = metrics.origins[location.columnIndex]
        let newScrollOffset = virtualOrigin - (frame.minX - viewport.minX)

        windowManagement.setScrollOffset(newScrollOffset, in: location.workspace)
        setActiveWorkspace(location.workspaceIndex)
        windowManagement.setActiveColumn(location.columnIndex, in: location.workspace)
        layoutController.recordPresentationFrame(frame, for: location.window)

        if let previousRatio,
           abs(previousRatio - ratio) < 0.005,
           let oldScrollOffset,
           abs(oldScrollOffset - newScrollOffset) < 0.5
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
