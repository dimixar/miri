import AppKit
import Foundation

extension Miri {
    func syncActiveRescanTimer() {
        let shouldRun = activeRescanTrackedPIDs().isEmpty == false
        if shouldRun, activeRescanTimer == nil {
            activeRescanTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.handleActiveRescanTick()
            }
            debugLog("active rescan timer started")
        } else if !shouldRun, activeRescanTimer != nil {
            activeRescanTimer?.invalidate()
            activeRescanTimer = nil
            debugLog("active rescan timer stopped")
        }
    }

    func scheduleActiveRescanForUserInput() {
        guard activeRescanEnabled else {
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.performActiveRescan(reason: "user-input")
        }
    }

    private func handleActiveRescanTick() {
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
            if axReconciliationShouldDefer {
                deferAXReconciliation(pid: pid, adoptFocused: true, reason: "active-rescan-\(reason)")
            } else {
                reconcileWindows(forPID: pid, adoptFocused: true)
            }
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
