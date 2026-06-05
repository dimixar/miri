import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

extension Miri {
    func handleFullscreenTransitionIfNeeded(_ element: AXUIElement) -> Bool {
        if isFullscreenWindow(element), let location = tiledWindowLocation(for: element) {
            pendingFullscreenTransitionSince.removeValue(forKey: ObjectIdentifier(location.window))
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

        if !isFullscreenWindow(element), isRememberedFullscreenWindow(element) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                self?.rescanWindows(adoptFocused: true)
            }
            return true
        }

        return false
    }

    func beginPendingFullscreenTransition(for window: ManagedWindow) {
        let id = ObjectIdentifier(window)
        let now = CFAbsoluteTimeGetCurrent()
        if pendingFullscreenTransitionSince[id] == nil {
            pendingFullscreenTransitionSince[id] = now
            debugLog("pending fullscreen transition app='\(window.appName)' bundle='\(window.bundleID ?? "nil")' title='\(window.title)'")
            DispatchQueue.main.asyncAfter(deadline: .now() + fullscreenTransitionGrace) { [weak self] in
                self?.rescanWindows(adoptFocused: true)
            }
        }
        fullscreenTransitionGuardUntil = max(fullscreenTransitionGuardUntil, now + fullscreenTransitionGrace)
    }

    func fullscreenSpaceChangeGuardIsActive() -> Bool {
        CFAbsoluteTimeGetCurrent() < fullscreenSpaceChangeGuardUntil
    }

    func focusedRememberedFullscreenWindowState() -> FullscreenWindowState? {
        guard !fullscreenWindowStates.isEmpty,
              let frontmost = NSWorkspace.shared.frontmostApplication
        else {
            return nil
        }

        let pid = frontmost.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let focused = value
        else {
            return fullscreenWindowStates.values.first { state in
                state.pid == pid && state.bundleID == frontmost.bundleIdentifier && isFullscreenWindow(state.element)
            }
        }

        let focusedElement = focused as! AXUIElement
        guard isFullscreenWindow(focusedElement) else {
            return nil
        }

        let focusedWindowID = SkyLight.shared.windowID(for: focusedElement)
        let focusedTitle = axString(focusedElement, kAXTitleAttribute) ?? ""
        return fullscreenWindowStates.values.first { state in
            guard state.pid == pid else {
                return false
            }
            if sameWindow(state.element, focusedElement) {
                return true
            }
            if let stateWindowID = state.windowID,
               let focusedWindowID,
               stateWindowID == focusedWindowID
            {
                return true
            }
            if state.bundleID == frontmost.bundleIdentifier,
               state.title == focusedTitle
            {
                return true
            }
            return false
        }
    }

    var focusedRememberedFullscreenWindowIsActive: Bool {
        focusedRememberedFullscreenWindowState() != nil
    }

    func enforceRememberedFullscreenWorkspaceIfNeeded(_ state: FullscreenWindowState) {
        guard workspaces.indices.contains(state.workspace), activeWorkspace != state.workspace else {
            return
        }
        debugLog("restoring fullscreen miri workspace=\(state.workspace + 1) while focused on remembered fullscreen app='\(state.appName)' bundle='\(state.bundleID ?? "nil")'")
        activeWorkspace = state.workspace
    }

    func enforceFullscreenSpaceGuardWorkspace() {
        guard fullscreenSpaceChangeGuardIsActive(),
              let workspace = fullscreenSpaceChangeGuardWorkspace,
              workspaces.indices.contains(workspace),
              activeWorkspace != workspace
        else {
            return
        }
        debugLog("restoring guarded miri workspace=\(workspace + 1) during fullscreen space guard")
        activeWorkspace = workspace
    }

    func noteFullscreenSpaceHelperIfNeeded(_ element: AXUIElement) {
        guard axString(element, kAXRoleAttribute) == kAXWindowRole,
              axString(element, kAXSubroleAttribute) == "AXUnknown",
              isLikelyFullscreenFrame(element)
        else {
            return
        }
        beginFullscreenSpaceChangeGuard()
    }

    func beginFullscreenSpaceChangeGuard() {
        let now = CFAbsoluteTimeGetCurrent()
        let wasActive = now < fullscreenSpaceChangeGuardUntil
        fullscreenSpaceChangeGuardUntil = max(fullscreenSpaceChangeGuardUntil, now + fullscreenSpaceChangeGuardDuration)
        fullscreenTransitionGuardUntil = max(fullscreenTransitionGuardUntil, fullscreenSpaceChangeGuardUntil)
        if !wasActive {
            fullscreenSpaceChangeGuardStartedGeneration = spaceChangeGeneration
            fullscreenSpaceChangeGuardWorkspace = activeWorkspace
            debugLog("fullscreen space helper guard started workspace=\(activeWorkspace + 1) generation=\(spaceChangeGeneration)")
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
        fullscreenSpaceChangeGuardWorkspace = nil
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
            let wasActiveWorkspace = activeWorkspace == location.workspaceIndex
            let wasActiveWindow = wasActiveWorkspace && location.workspace.activeColumn == location.columnIndex
            removeWindow(location.window, preferRightFocus: true)
            if wasActiveWindow {
                projectLayout(focusActiveWindow: true, layoutLockDelay: 0.02)
            } else {
                projectLayout(focusActiveWindow: false, layoutLockDelay: 0.02)
            }
            return true
        }

        if let window = floatingWindows.first(where: { sameWindow($0.element, element) }) {
            removeWindow(window)
            projectLayout(focusActiveWindow: false, layoutLockDelay: 0.02)
            return true
        }

        return false
    }

    func updateManualWidthRatio(for element: AXUIElement) -> Bool {
        guard !isFullscreenWindow(element),
              let location = tiledWindowLocation(for: element),
              let frame = axFrame(element)
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
        location.window.manualWidthRatio = ratio

        let metrics = stripMetrics(for: location.workspace, viewport: viewport)
        let virtualOrigin = metrics.origins[location.columnIndex]
        let newScrollOffset = virtualOrigin - (frame.minX - viewport.minX)

        location.workspace.scrollOffset = newScrollOffset
        setActiveWorkspace(location.workspaceIndex)
        location.workspace.activeColumn = location.columnIndex
        presentationFrames[ObjectIdentifier(location.window)] = frame

        if let previousRatio,
           abs(previousRatio - ratio) < 0.005,
           let oldScrollOffset,
           abs(oldScrollOffset - newScrollOffset) < 0.5
        {
            return false
        }

        return true
    }

    func beginOrContinueManualResize(for element: AXUIElement) {
        guard !isFullscreenWindow(element) else {
            _ = handleFullscreenTransitionIfNeeded(element)
            return
        }
        guard tiledWindow(for: element) != nil else {
            restoreFloatingVisibility()
            return
        }

        if let manualResizeElement, !sameWindow(manualResizeElement, element) {
            return
        }

        manualResizeElement = element
        manualResizeEndTimer?.cancel()
        stopAnimation(clearPresentation: false)

        if updateManualWidthRatio(for: element) {
            schedulePersistentLayoutSnapshotWrite()
            projectLayout(focusActiveWindow: false, layoutLockDelay: 0)
        }

        scheduleManualResizeEnd(for: element)
    }

    var manualResizeNotificationsSuppressed: Bool {
        CFAbsoluteTimeGetCurrent() < manualResizeSuppressedUntil
    }

    func suppressManualResizeNotifications(for duration: TimeInterval) {
        guard duration > 0 else {
            return
        }
        manualResizeSuppressedUntil = max(manualResizeSuppressedUntil, CFAbsoluteTimeGetCurrent() + duration)
    }

    func scheduleManualResizeEnd(for element: AXUIElement) {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(140), leeway: .milliseconds(20))
        timer.setEventHandler { [weak self] in
            guard let self else {
                return
            }

            manualResizeEndTimer?.cancel()
            manualResizeEndTimer = nil

            if manualResizeElement.map({ sameWindow($0, element) }) == true {
                if updateManualWidthRatio(for: element) {
                    schedulePersistentLayoutSnapshotWrite()
                }
                projectLayout(focusActiveWindow: false, layoutLockDelay: 0.02)
                manualResizeElement = nil
            }
        }

        manualResizeEndTimer = timer
        timer.resume()
    }

    func isManualResizeElement(_ element: AXUIElement) -> Bool {
        manualResizeElement.map { sameWindow($0, element) } ?? false
    }

    func frameWidthDiffersFromLayout(for element: AXUIElement) -> Bool {
        guard let window = tiledWindow(for: element),
              let frame = axFrame(element)
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
