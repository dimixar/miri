import AppKit
import Carbon.HIToolbox
import Foundation

extension Miri {
    func installFocusedWindowInputMonitor() {
        guard focusedWindowInputMonitor == nil else {
            return
        }

        focusedWindowInputMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]
        ) { [weak self] event in
            guard let self else {
                return
            }

            switch event.type {
            case .leftMouseDown, .rightMouseDown, .otherMouseDown:
                scheduleFocusedWindowProbe(reason: "mouse-down")
            case .keyDown:
                let isCommandWindowSwitch = event.modifierFlags.contains(.command)
                    && (event.keyCode == UInt16(kVK_ANSI_Grave) || event.keyCode == UInt16(kVK_Tab))
                if isCommandWindowSwitch {
                    scheduleFocusedWindowProbe(reason: "command-window-switch")
                }
            default:
                break
            }
        }
    }

    func uninstallFocusedWindowInputMonitor() {
        guard let focusedWindowInputMonitor else {
            return
        }
        NSEvent.removeMonitor(focusedWindowInputMonitor)
        self.focusedWindowInputMonitor = nil
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
