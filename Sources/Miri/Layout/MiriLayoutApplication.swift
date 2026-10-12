import Foundation

extension Miri {
    /// Captures the window-management-owned logical state, then hands one immutable
    /// projection request to the presentation owner.
    func projectLayout(
        focusActiveWindow: Bool,
        animated: Bool = false,
        from previousState: LayoutState? = nil,
        layoutLockDelay: TimeInterval = 0.08
    ) {
        if mouseInteractionController.isActive {
            requestReconciliation(.all(adoptFocused: false, source: .accessibility, reason: "mouse-layout-deferred"))
            return
        }
        guard sessionController.isLayoutTrackingAllowed else {
            debugLog("layout skipped because user session is unavailable")
            return
        }
        defer {
            notifyWorkspaceBarNeedsRefresh()
            refreshManualFloatingOutlines()
        }
        enforceFullscreenSpaceGuardWorkspace()
        let viewport = currentViewport()
        if windowManagement.enforceRowHeights(height: viewport.height, gap: points(forPhysicalPixels: innerGap, in: viewport)) {
            cancelWorkspaceBoundaryHold()
            schedulePersistentLayoutSnapshotWrite()
        }
        // The cleanup watcher must always describe the model that is about to
        // be projected, including changes made since the preceding layout.
        writeRestoreSnapshot(viewport: viewport)
        syncActiveRescanTimer()
        layoutController.submit(
            previousState: previousState,
            targetState: captureLayoutState(),
            viewport: viewport,
            focusActiveWindow: focusActiveWindow,
            animated: animated,
            lockDelay: layoutLockDelay
        )
    }
}
