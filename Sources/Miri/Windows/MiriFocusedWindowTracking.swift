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
        focusedWindowProbeGeneration &+= 1
        let generation = focusedWindowProbeGeneration

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            self?.enqueue(.input(.focusedWindowProbeDue(reason: reason, generation: generation)))
        }
    }

    func handleFocusedWindowProbeDue(reason: String, generation: UInt64) {
        guard generation == focusedWindowProbeGeneration,
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
