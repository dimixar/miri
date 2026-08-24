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
        guard sessionController.isLayoutTrackingAllowed else {
            debugLog("layout skipped because user session is unavailable")
            return
        }
        defer { notifyWorkspaceBarNeedsRefresh() }
        enforceFullscreenSpaceGuardWorkspace()
        let viewport = currentViewport()
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
