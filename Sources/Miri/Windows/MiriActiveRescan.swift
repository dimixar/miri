import AppKit
import Foundation

extension Miri {
    func syncActiveRescanTimer() {
        let shouldRun = isLayoutTrackingAllowed && activeRescanTrackedPIDs().isEmpty == false
        if shouldRun, activeRescanTimer == nil {
            activeRescanTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.enqueue(.timer(.activeRescan))
            }
            debugLog("active rescan timer started")
        } else if !shouldRun, activeRescanTimer != nil {
            activeRescanTimer?.invalidate()
            activeRescanTimer = nil
            debugLog("active rescan timer stopped")
        }
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

    func handleActiveRescanTickImplementation() {
        guard isLayoutTrackingAllowed else {
            syncActiveRescanTimer()
            return
        }
        guard !reloadConfigIfNeeded() else {
            syncActiveRescanTimer()
            return
        }
        performActiveRescan(reason: "timer")
    }

    private func performActiveRescan(reason: String) {
        let pids = activeRescanTrackedPIDs()
        guard !pids.isEmpty else {
            syncActiveRescanTimer()
            return
        }

        debugLog("active rescan reason=\(reason) pids=\(pids.sorted())")
        for pid in pids {
            requestReconciliation(
                .application(
                    pid: pid,
                    adoptFocused: true,
                    source: .activeRescan,
                    reason: reason
                )
            )
        }
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
