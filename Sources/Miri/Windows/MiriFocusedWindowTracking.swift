import AppKit
import Foundation

extension Miri {
    func handleFocusedWindowProbeDue(reason: String, generation: UInt64) {
        guard windowManagement.observation.focusedWindowProbeIsCurrent(generation),
              sessionController.isLayoutTrackingAllowed,
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

        requestFocusedWindowAdoption(
            pid: pid,
            animateIfSameWorkspace: true,
            reason: "focused-window-probe:\(reason)"
        )
    }
}
