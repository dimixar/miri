import AppKit
import ApplicationServices
import Foundation

extension Miri {
    func requestFocusedWindowFloatingToggle() {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
        let focusGeneration = focusStateGeneration
        let sessionGeneration = sessionController.resumeGeneration
        let windowGeneration = windowManagement.observation.stateGeneration(for: pid)
        // Never substitute the last tiled column or a cached app-focused window.
        axOperations.readFocusedWindow(pid: pid, coalescingKey: "floating-toggle") { [weak self] result in
            guard let self,
                  self.appPhase == .running,
                  self.sessionController.isLayoutTrackingAllowed,
                  self.sessionController.resumeGeneration == sessionGeneration,
                  self.focusStateGeneration == focusGeneration,
                  self.windowManagement.observation.stateGeneration(for: pid) == windowGeneration,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                  !self.windowManagement.observation.transientWindowActive,
                  result.disposition == .completed,
                  let snapshot = result.value,
                  snapshot.minimized != true,
                  snapshot.fullscreenOS != true
            else { return }
            guard !self.axReconciliationShouldDefer else {
                self.pendingFocusCommands.append(.toggleWindowFloating)
                return
            }
            _ = self.toggleFloatingWindow(for: snapshot.handle.element)
        }
    }

    @discardableResult
    func toggleFloatingWindow(for element: AXUIElement) -> Bool {
        guard let window = allWindows().first(where: { sameWindow($0.element, element) }),
              !window.isMinimized, !window.fullscreenOS else { return false }
        windowManagement.setWidthRatio(widthRatio(for: window), for: window)
        guard windowManagement.toggleFloating(window) else { return false }
        focusStateGeneration &+= 1
        manualResizeController.cancel()
        layoutController.removeTracking(for: window)
        reconcileWorkspaceCapacity()
        let isFloating = windowManagement.manualBehavior(for: element) == .float
        if !isFloating, let workspace = activeWorkspaceObject() {
            revealActiveColumnIfNeeded(in: workspace, viewport: currentViewport())
        }
        // Floating preserves the OS focus. Retiling explicitly focuses its restored column.
        projectLayout(focusActiveWindow: !isFloating)
        saveActiveLogicalSpaceContext()
        schedulePersistentLayoutSnapshotWrite()
        refreshManualFloatingOutlines()
        return true
    }

    func refreshManualFloatingOutlines() {
        guard runtimeStarted else { return }
        let enabled = appPhase == .running
            && sessionController.isLayoutTrackingAllowed
            && !windowManagement.pendingLogicalSpaceSwitch
            && (configStore.effectiveConfig.manualFloatingOutlineEnabled ?? true)
        floatingWindowOutlineController.update(
            windows: windowManagement.manuallyFloatedWindows.filter { !$0.isMinimized && !$0.fullscreenOS },
            enabled: enabled,
            thickness: configStore.effectiveConfig.manualFloatingOutlineThickness ?? 2
        )
    }
}
