import ApplicationServices
import CoreGraphics
import Foundation

@MainActor
enum RestoreSnapshotFactory {
    static func records(
        tiledWindows: [ManagedWindow],
        floatingWindows: [ManagedWindow]
    ) -> [RestoreWindowRecord] {
        var recordsByID: [UInt32: RestoreWindowRecord] = [:]
        for window in tiledWindows {
            guard let windowID = window.windowID else { continue }
            recordsByID[windowID] = RestoreWindowRecord(
                windowID: windowID,
                ownerPID: window.pid,
                kind: .tiled
            )
        }
        for window in floatingWindows {
            guard let windowID = window.windowID,
                  recordsByID[windowID] == nil
            else { continue }
            recordsByID[windowID] = RestoreWindowRecord(
                windowID: windowID,
                ownerPID: window.pid,
                kind: .floating
            )
        }
        return recordsByID.values.sorted {
            if $0.ownerPID != $1.ownerPID {
                return ($0.ownerPID ?? 0) < ($1.ownerPID ?? 0)
            }
            return $0.windowID < $1.windowID
        }
    }
}

extension Miri {
    /// Quiesces every existing AX lane and restores tiled frames through one
    /// independent final worker batch per PID. Compositor state is local to
    /// WindowServer and is normalized before asynchronous target-app IPC.
    func restoreManagedWindowsForExit(
        completion: @escaping @MainActor (AXTerminationRestoreSummary) -> Void
    ) {
        let viewport = currentViewport()
        let tiled = tiledWindows()
        let floating = windowManagement.floatingWindows

        // Keep a current fallback document until every final AX batch reports
        // success. If Miri exits early, the watcher consumes this snapshot.
        writeRestoreSnapshot(viewport: viewport)
        layoutController.preparePresentationForTermination(windows: tiled + floating)

        let requests: [AXTerminationRestoreRequest]
        if restoreOnExit {
            requests = tiled.map {
                AXTerminationRestoreRequest(
                    handle: AXElementHandle(
                        element: $0.element,
                        pid: $0.pid,
                        windowID: $0.windowID
                    ),
                    frame: viewport
                )
            }
        } else {
            requests = []
        }

        axOperations.restoreFramesForTermination(requests, completion: completion)
    }

    func writeRestoreSnapshot(viewport: CGRect) {
        guard restoreOnExit else {
            persistenceController.writeRestoreSnapshot(nil)
            return
        }

        let records = RestoreSnapshotFactory.records(
            tiledWindows: tiledWindows(),
            floatingWindows: windowManagement.floatingWindows
        )
        guard !records.isEmpty else {
            persistenceController.writeRestoreSnapshot(nil)
            return
        }

        persistenceController.writeRestoreSnapshot(
            RestoreSnapshot(records: records, viewport: RectSnapshot(viewport))
        )
    }
}
