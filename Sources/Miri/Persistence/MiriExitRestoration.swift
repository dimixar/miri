import ApplicationServices
import CoreGraphics
import Foundation

extension Miri {
    func restoreManagedWindowsForExit() {
        for (windowID, transform) in originalWindowTransforms {
            _ = SkyLight.shared.setTransform(transform, for: windowID)
        }
        originalWindowTransforms.removeAll()

        guard restoreOnExit else {
            return
        }

        let viewport = currentViewport()
        for window in tiledWindows() {
            setAXFrame(viewport, for: window)
        }
        restoreFloatingVisibility(raise: true)
        persistenceController.removeRestoreSnapshot()
    }

    func writeRestoreSnapshot(viewport: CGRect) {
        guard restoreOnExit else {
            persistenceController.writeRestoreSnapshot(nil)
            return
        }

        let ids = Array(Set(tiledWindows().compactMap(\.windowID))).sorted()
        let floatingIDs = Array(Set(floatingWindows.compactMap(\.windowID))).sorted()
        guard !ids.isEmpty || !floatingIDs.isEmpty else {
            persistenceController.writeRestoreSnapshot(nil)
            return
        }

        let snapshot = RestoreSnapshot(windowIDs: ids, floatingWindowIDs: floatingIDs, viewport: RectSnapshot(viewport))
        persistenceController.writeRestoreSnapshot(snapshot)
    }

}
