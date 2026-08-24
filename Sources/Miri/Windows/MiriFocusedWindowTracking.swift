import AppKit
import Foundation

extension Miri {
    func installFocusedWindowInputMonitor() {
        inputController.installFocusedWindowMonitor()
    }

    func uninstallFocusedWindowInputMonitor() {
        inputController.uninstallFocusedWindowMonitor()
    }

    func scheduleFocusedWindowProbe(reason: String) {
        enqueue(.input(.focusedWindowProbeRequested(reason: reason)))
    }

    func scheduleFocusedWindowProbeImplementation(reason: String) {
        windowManagement.observation.scheduleFocusedWindowProbe(reason: reason)
    }

    func handleFocusedWindowProbeDue(reason: String, generation: UInt64) {
        guard windowManagement.observation.focusedWindowProbeIsCurrent(generation),
              isLayoutTrackingAllowed,
              let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        else {
            return
        }

        if axReconciliationShouldDefer {
            deferAXReconciliation(
                pid: pid,
                adoptFocused: true,
                reason: "focused-window-probe:\(reason)"
            )
            return
        }

        _ = adoptFocusedWindow(
            pid: pid,
            animateIfSameWorkspace: true,
            reason: "focused-window-probe:\(reason)"
        )
    }
}
