import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

private struct WindowStackEntry {
    let index: Int
    let windowID: UInt32
    let pid: pid_t
    let layer: Int
    let bounds: CGRect
    let ownerName: String
}

extension Miri {
    func projectLayout(
        focusActiveWindow: Bool,
        animated: Bool = false,
        from previousState: LayoutState? = nil,
        animationDuration: TimeInterval? = nil,
        layoutLockDelay: TimeInterval = 0.08,
        animatedWindowIDs: Set<ObjectIdentifier>? = nil,
        resizingWindowID: ObjectIdentifier? = nil
    ) {
        guard isLayoutTrackingAllowed else {
            debugLog("layout skipped because user session is unavailable")
            return
        }
        defer {
            notifyWorkspaceBarNeedsRefresh()
        }
        enforceFullscreenSpaceGuardWorkspace()
        if !animated, snapshotAnimationSession != nil || snapshotAnimationPreparing {
            deferLayoutUntilSnapshotSettles(
                focusActiveWindow: focusActiveWindow,
                layoutLockDelay: layoutLockDelay
            )
            return
        }
        layoutRequestGeneration &+= 1
        let viewport = currentViewport()

        let targetState = captureLayoutState()
        debugLog("layout workspace=\(targetState.activeWorkspace + 1) tiled=\(tiledWindows().count) floating=\(floatingWindows.count) animated=\(animated)")
        hideInactiveWorkspaceWindows(activeWorkspace: targetState.activeWorkspace)
        syncActiveRescanTimer()
        let duration = animationDuration ?? self.animationDuration
        let shouldAnimate = animated && (animationStrategy == .snapshot || duration > 0)
        suppressManualResizeNotifications(for: (shouldAnimate ? max(duration, 0.25) : 0) + max(layoutLockDelay, 0.25))
        if shouldAnimate, let previousState {
            animateLayout(
                from: previousState,
                to: targetState,
                viewport: viewport,
                focusActiveWindow: focusActiveWindow,
                duration: duration,
                animatedWindowIDs: animatedWindowIDs,
                resizingWindowID: resizingWindowID
            )
            return
        }

        stopAnimation(clearPresentation: true)
        isApplyingLayout = true
        let layout = layoutItems(viewport: viewport, state: targetState, parkHidden: true)
        applyLayout(layout, focusActiveWindow: focusActiveWindow)
        restoreFloatingVisibility(raise: true, deferred: focusActiveWindow)
        releaseLayoutLock(after: layoutLockDelay)
    }

    func deferLayoutUntilSnapshotSettles(focusActiveWindow: Bool, layoutLockDelay: TimeInterval) {
        pendingSnapshotDeferredFocusActiveWindow = focusActiveWindow
        pendingSnapshotDeferredLayoutLockDelay = layoutLockDelay
        guard !pendingSnapshotDeferredLayout else {
            debugLog("layout deferred during snapshot already pending")
            return
        }
        pendingSnapshotDeferredLayout = true
        debugLog("layout deferred during snapshot focus=\(focusActiveWindow) lockDelay=\(String(format: "%.2f", layoutLockDelay))")
        pollDeferredSnapshotLayout()
    }

    func pollDeferredSnapshotLayout() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self else {
                return
            }
            guard snapshotAnimationSession == nil, !snapshotAnimationPreparing else {
                pollDeferredSnapshotLayout()
                return
            }
            let focusActiveWindow = pendingSnapshotDeferredFocusActiveWindow
            let layoutLockDelay = pendingSnapshotDeferredLayoutLockDelay
            pendingSnapshotDeferredLayout = false
            projectLayout(focusActiveWindow: focusActiveWindow, layoutLockDelay: layoutLockDelay)
        }
    }

    func layoutItems(viewport: CGRect, state: LayoutState, parkHidden: Bool) -> [LayoutItem] {
        let stateActiveWorkspace = min(max(state.activeWorkspace, 0), max(workspaces.count - 1, 0))
        var layout: [LayoutItem] = []

        for (workspaceIndex, workspace) in workspaces.enumerated() {
            let activeColumn = activeColumn(in: workspace, workspaceIndex: workspaceIndex, state: state)
            let scrollOffset = scrollOffset(in: workspace, workspaceIndex: workspaceIndex, state: state)
            let strip = stripFrames(
                for: workspace,
                viewport: viewport,
                activeColumn: activeColumn,
                scrollOffset: scrollOffset
            )
            let rowOffset = CGFloat(workspaceIndex - stateActiveWorkspace) * viewport.height

            for (columnIndex, window) in workspace.columns.enumerated() {
                let frame: CGRect
                var projected = strip[columnIndex]
                projected.origin.y += rowOffset
                projected = visualFrame(projected, viewport: viewport)

                let visible = projected.intersects(viewport)
                if visible || !parkHidden {
                    frame = projected
                } else if workspaceIndex == stateActiveWorkspace {
                    frame = parkedFrame(for: window, viewport: viewport, beforeActive: columnIndex < activeColumn)
                } else {
                    frame = parkedFrame(
                        for: window,
                        viewport: viewport,
                        beforeActive: workspaceIndex < stateActiveWorkspace
                    )
                }

                layout.append(LayoutItem(window: window, frame: frame, visible: visible))
            }
        }

        return layout
    }

    func activeColumn(in workspace: Workspace, workspaceIndex: Int, state: LayoutState) -> Int {
        let activeColumn = state.activeColumns.indices.contains(workspaceIndex)
            ? state.activeColumns[workspaceIndex]
            : workspace.activeColumn

        guard !workspace.columns.isEmpty else {
            return 0
        }

        return min(max(activeColumn, 0), workspace.columns.count - 1)
    }

    func scrollOffset(in workspace: Workspace, workspaceIndex: Int, state: LayoutState) -> CGFloat? {
        if state.scrollOffsets.indices.contains(workspaceIndex) {
            return state.scrollOffsets[workspaceIndex]
        }
        return workspace.scrollOffset
    }

    func applyLayout(_ layout: [LayoutItem], focusActiveWindow: Bool) {
        if focusActiveWindow, let activeWindow = self.activeWindow() {
            let inactiveVisible = layout.filter { $0.visible && $0.window !== activeWindow }
            for item in inactiveVisible {
                applyLayoutItem(item)
            }

            if let activeItem = layout.first(where: { $0.window === activeWindow }) {
                applyLayoutItem(activeItem, forceFrame: true)
            }
        } else {
            for item in layout where item.visible {
                applyLayoutItem(item)
            }
        }

        for item in layout where !item.visible {
            applyLayoutItem(item)
        }

        if focusActiveWindow, let activeWindow = self.activeWindow() {
            focus(activeWindow)
        }
    }

    func applyLayoutItem(_ item: LayoutItem, forceFrame: Bool = false) {
        let id = ObjectIdentifier(item.window)
        let wasVisible = appliedVisibility[id]
        let previousFrame = appliedFrames[id]
        let shouldApplyFrame = forceFrame
            || item.visible
            || wasVisible != false
            || previousFrame.map { frameDelta(from: $0, to: item.frame) >= animationPixelThreshold } ?? true

        let visibilityChanged = wasVisible != item.visible
        if visibilityChanged && !item.visible {
            appliedVisibility[id] = false
        }

        if shouldApplyFrame {
            resetCompositorTransform(for: item.window)
            setAXFrame(item.frame, for: item.window)
            if !item.visible {
                applyCompositorParkingCorrection(to: item.frame, for: item.window)
            }
            appliedFrames[id] = item.frame
        }

        if visibilityChanged && item.visible {
            appliedVisibility[id] = true
        }
    }

    func restoreFloatingVisibility(raise: Bool = false, deferred: Bool = false) {
        for window in floatingWindows {
            if raise {
                setWindowLevel(floatingWindowLevel, for: window.windowID)
            }
        }

        if raise && deferred {
            scheduleFloatingWindowRaise()
        }
    }

    func setWindowLevel(_ level: Int32, for windowID: UInt32?) {
        _ = SkyLight.shared.setLevel(level, for: windowID)
    }

    func resetCompositorTransform(for window: ManagedWindow) {
        guard let windowID = window.windowID,
              let originalTransform = originalWindowTransforms[windowID]
        else {
            return
        }

        if SkyLight.shared.setTransform(originalTransform, for: windowID) {
            originalWindowTransforms.removeValue(forKey: windowID)
        }
    }

    func applyCompositorParkingCorrection(to targetFrame: CGRect, for window: ManagedWindow) {
        guard let windowID = window.windowID,
              let observedFrame = axFrame(window.element)
        else {
            return
        }

        let viewport = currentViewport()
        let parksBeforeViewport = targetFrame.midX < viewport.midX
        let correctedOrigin = CGPoint(
            x: parksBeforeViewport
                ? targetFrame.maxX - observedFrame.width
                : targetFrame.minX,
            y: targetFrame.minY
        )

        if SkyLight.shared.moveWithTransaction(windowID, to: correctedOrigin) {
            debugLog(
                "parking correction method=transaction id=\(windowID) target=(\(correctedOrigin.x),\(correctedOrigin.y)) observed=(\(observedFrame.minX),\(observedFrame.minY),\(observedFrame.width),\(observedFrame.height))"
            )
            return
        }
        if SkyLight.shared.move(windowID, to: correctedOrigin) {
            debugLog("parking correction method=direct-move id=\(windowID) target=(\(correctedOrigin.x),\(correctedOrigin.y))")
            return
        }

        let offset = CGPoint(
            x: correctedOrigin.x - observedFrame.minX,
            y: correctedOrigin.y - observedFrame.minY
        )
        guard abs(offset.x) >= 0.001 || abs(offset.y) >= 0.001 else {
            return
        }
        let originalTransform = originalWindowTransforms[windowID]
            ?? SkyLight.shared.transform(for: windowID)
            ?? CGAffineTransform(translationX: -observedFrame.minX, y: -observedFrame.minY)
        if SkyLight.shared.translate(windowID, from: originalTransform, by: offset) {
            originalWindowTransforms[windowID] = originalTransform
            debugLog("parking correction method=transform id=\(windowID) offset=(\(offset.x),\(offset.y))")
        } else {
            debugLog("parking correction failed id=\(windowID) target=(\(correctedOrigin.x),\(correctedOrigin.y))")
        }
    }

    func cancelTiledStackAudit() {
        tiledStackAuditGeneration &+= 1
        tiledAppReactivationFocusSuppressionUntil = 0
    }

    func scheduleTiledStackAudit() {
        tiledStackAuditGeneration &+= 1
        guard bringTiledAppsForwardOnFocus else {
            return
        }
        let generation = tiledStackAuditGeneration
        scheduleTiledStackAudit(
            generation: generation,
            after: 0.08,
            settleAttempt: 0,
            correctionAttempt: 0
        )
    }

    private func scheduleTiledStackAudit(
        generation: UInt64,
        after delay: TimeInterval,
        settleAttempt: Int,
        correctionAttempt: Int
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.auditTiledWindowStack(
                generation: generation,
                settleAttempt: settleAttempt,
                correctionAttempt: correctionAttempt
            )
        }
    }

    private func auditTiledWindowStack(
        generation: UInt64,
        settleAttempt: Int,
        correctionAttempt: Int
    ) {
        guard bringTiledAppsForwardOnFocus,
              generation == tiledStackAuditGeneration,
              isLayoutTrackingAllowed
        else {
            return
        }

        let axWorkPending = axReconciliationShouldDefer
            || pendingAXReconciliationDrainScheduled
            || pendingAXReconciliationNeedsFullRescan
            || !pendingAXReconciliationPIDs.isEmpty
        guard !axWorkPending else {
            scheduleTiledStackAudit(
                generation: generation,
                after: 0.08,
                settleAttempt: settleAttempt,
                correctionAttempt: correctionAttempt
            )
            return
        }

        guard let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier else {
            return
        }
        let appElement = AXUIElementCreateApplication(frontmostPID)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &value
        ) == .success,
            let value
        else {
            return
        }

        let focusedElement = value as! AXUIElement
        guard let focusedLocation = location(of: focusedElement),
              focusedLocation.workspace == activeWorkspace,
              workspaces.indices.contains(focusedLocation.workspace),
              workspaces[focusedLocation.workspace].columns.indices.contains(focusedLocation.column)
        else {
            return
        }

        let focusedWindow = workspaces[focusedLocation.workspace].columns[focusedLocation.column]
        let layout = layoutItems(
            viewport: currentViewport(),
            state: captureLayoutState(),
            parkHidden: true
        )
        let visibleItems = layout.filter {
            $0.visible
                && location(of: $0.window.element)?.workspace == activeWorkspace
                && $0.window.windowID != nil
        }
        guard !visibleItems.isEmpty else {
            return
        }

        let stack = currentWindowStack()
        let stackIndexByWindowID = Dictionary(
            uniqueKeysWithValues: stack.map { ($0.windowID, $0.index) }
        )
        let missingVisibleIDs = visibleItems.compactMap(\.window.windowID).filter {
            stackIndexByWindowID[$0] == nil
        }
        if !missingVisibleIDs.isEmpty, settleAttempt < 3 {
            debugLog(
                "tiled stack audit waiting attempt=\(settleAttempt + 1) missingVisible=\(missingVisibleIDs)"
            )
            scheduleTiledStackAudit(
                generation: generation,
                after: 0.05,
                settleAttempt: settleAttempt + 1,
                correctionAttempt: correctionAttempt
            )
            return
        }

        let allManagedIDs = Set(allWindows().compactMap(\.windowID))
        let parkedIDs = Set(layout.filter { !$0.visible }.compactMap(\.window.windowID))
        let floatingIDs = Set(floatingWindows.compactMap(\.windowID))
        let viewport = currentViewport()
        let blockers = stack.filter { entry in
            guard entry.layer == 0,
                  !entry.bounds.isEmpty,
                  entry.bounds.intersects(viewport),
                  !floatingIDs.contains(entry.windowID)
            else {
                return false
            }
            return parkedIDs.contains(entry.windowID)
                || !allManagedIDs.contains(entry.windowID)
        }
        guard !blockers.isEmpty else {
            return
        }

        let affectedItems = visibleItems.filter { item in
            guard let windowID = item.window.windowID,
                  let tileIndex = stackIndexByWindowID[windowID]
            else {
                return false
            }
            return blockers.contains { $0.index < tileIndex }
        }
        guard !affectedItems.isEmpty else {
            debugLog(
                "tiled stack audit clean visible=\(visibleItems.count) blockers=\(blockers.count)"
            )
            return
        }

        var affectedPIDs: [pid_t] = []
        for item in affectedItems where !affectedPIDs.contains(item.window.pid) {
            affectedPIDs.append(item.window.pid)
        }
        var orderedPIDs = affectedPIDs.filter { $0 != focusedWindow.pid }
        if !orderedPIDs.isEmpty || affectedPIDs.contains(focusedWindow.pid) {
            orderedPIDs.append(focusedWindow.pid)
        }
        guard !orderedPIDs.isEmpty else {
            return
        }

        tiledAppReactivationFocusSuppressionUntil = CFAbsoluteTimeGetCurrent() + 0.35
        var activationFailures: [pid_t] = []
        for pid in orderedPIDs {
            guard let app = NSRunningApplication(processIdentifier: pid),
                  app.activationPolicy == .regular,
                  app.activate()
            else {
                activationFailures.append(pid)
                continue
            }

            var appWindows = affectedItems
                .filter { $0.window.pid == pid }
                .map(\.window)
            if pid == focusedWindow.pid,
               !appWindows.contains(where: { $0 === focusedWindow }) {
                appWindows.append(focusedWindow)
            } else if pid == focusedWindow.pid,
                      let focusedIndex = appWindows.firstIndex(where: { $0 === focusedWindow }) {
                appWindows.remove(at: focusedIndex)
                appWindows.append(focusedWindow)
            }
            for window in appWindows {
                AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
            }
        }
        AXUIElementSetAttributeValue(
            focusedWindow.element,
            kAXFocusedAttribute as CFString,
            kCFBooleanTrue
        )
        let blockerSummary = blockers.map {
            "\($0.ownerName):\($0.windowID)@\($0.index)"
        }.joined(separator: ",")
        debugLog(
            "tiled stack correction attempt=\(correctionAttempt + 1) focused=\(focusedWindow.windowID.map(String.init) ?? "nil") affectedWindows=\(affectedItems.count) pids=\(orderedPIDs) blockers=[\(blockerSummary)] failures=\(activationFailures)"
        )
        if correctionAttempt == 0 {
            scheduleTiledStackAudit(
                generation: generation,
                after: 0.08,
                settleAttempt: 0,
                correctionAttempt: 1
            )
        }
    }

    private func currentWindowStack() -> [WindowStackEntry] {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]]
        else {
            return []
        }

        return list.enumerated().compactMap { index, info in
            guard let windowNumber = info[kCGWindowNumber as String] as? NSNumber,
                  let ownerPID = info[kCGWindowOwnerPID as String] as? NSNumber,
                  let layerNumber = info[kCGWindowLayer as String] as? NSNumber,
                  let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary
            else {
                return nil
            }
            if let alpha = info[kCGWindowAlpha as String] as? NSNumber,
               alpha.doubleValue <= 0 {
                return nil
            }
            var bounds = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(
                boundsDictionary as CFDictionary,
                &bounds
            ) else {
                return nil
            }
            return WindowStackEntry(
                index: index,
                windowID: windowNumber.uint32Value,
                pid: ownerPID.int32Value,
                layer: layerNumber.intValue,
                bounds: bounds,
                ownerName: info[kCGWindowOwnerName as String] as? String ?? "pid \(ownerPID.int32Value)"
            )
        }
    }

    func scheduleFloatingWindowRaise() {
        guard !floatingWindows.isEmpty else {
            return
        }

        floatingRaiseGeneration &+= 1
        let generation = floatingRaiseGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self, generation == floatingRaiseGeneration else {
                return
            }
            restoreFloatingVisibility(raise: true)
        }
    }

    func focus(_ window: ManagedWindow) {
        focusRequestGeneration &+= 1
        let generation = focusRequestGeneration
        suppressFocusedWindowNotificationsUntil = CFAbsoluteTimeGetCurrent() + 1.0
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self,
                  let window,
                  generation == focusRequestGeneration,
                  activeWindow() === window
            else {
                return
            }
            suppressFocusedWindowNotificationsUntil = CFAbsoluteTimeGetCurrent() + 1.0
            if let app = NSRunningApplication(processIdentifier: window.pid) {
                app.activate(options: [.activateIgnoringOtherApps])
            }
            AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(window.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        }
    }

}
