import AppKit
import Foundation

extension Miri {
    func syncActiveRescanTimer() {
        let trackedPIDs = isLayoutTrackingAllowed ? activeRescanTrackedPIDs() : []
        windowManagement.observation.configureActiveRescanTimer(pids: trackedPIDs)
    }

    func scheduleActiveRescanForUserInput() {
        enqueue(.input(.userInteraction))
    }

    func scheduleActiveRescanForUserInputImplementation() {
        guard isLayoutTrackingAllowed, activeRescanEnabled else {
            return
        }

        performActiveRescan(reason: "user-input")
    }

    private func performActiveRescan(reason: String) {
        let pids = activeRescanTrackedPIDs()
        guard !pids.isEmpty else {
            windowManagement.observation.configureActiveRescanTimer(pids: [])
            return
        }

        debugLog("active rescan reason=\(reason) pids=\(pids.sorted())")
        requestReconciliation(
            ReconciliationIntent(
                id: nil,
                scope: .applications(pids),
                adoptFocused: true,
                source: .activeRescan,
                reason: reason
            )
        )
        syncActiveRescanTimer()
    }

    private func activeRescanTrackedPIDs() -> Set<pid_t> {
        guard activeRescanEnabled else {
            return []
        }
        let bundleIDs = activeRescanBundleIDs
        guard !bundleIDs.isEmpty else {
            return []
        }

        return Set(tiledWindows().compactMap { window in
            guard let bundleID = window.bundleID, bundleIDs.contains(bundleID) else {
                return nil
            }
            return window.pid
        })
    }
}
