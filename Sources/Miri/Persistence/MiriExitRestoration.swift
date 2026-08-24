import ApplicationServices
import CoreGraphics
import Foundation

extension Miri {
    func restoreManagedWindowsForExit() {
        let viewport = currentViewport()
        layoutController.restoreForTermination(
            tiledWindows: tiledWindows(),
            floatingWindows: windowManagement.floatingWindows,
            viewport: viewport,
            restoreFrames: restoreOnExit
        )
        if restoreOnExit { persistenceController.removeRestoreSnapshot() }
    }

    func writeRestoreSnapshot(viewport: CGRect) {
        guard restoreOnExit else {
            persistenceController.writeRestoreSnapshot(nil)
            return
        }

        let ids = Array(Set(tiledWindows().compactMap(\.windowID))).sorted()
        let floatingIDs = Array(Set(windowManagement.floatingWindows.compactMap(\.windowID))).sorted()
        guard !ids.isEmpty || !floatingIDs.isEmpty else {
            persistenceController.writeRestoreSnapshot(nil)
            return
        }

        let snapshot = RestoreSnapshot(windowIDs: ids, floatingWindowIDs: floatingIDs, viewport: RectSnapshot(viewport))
        persistenceController.writeRestoreSnapshot(snapshot)
    }

}
