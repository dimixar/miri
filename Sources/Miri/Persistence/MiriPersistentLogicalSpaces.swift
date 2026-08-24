import Foundation

extension Miri {
    func schedulePeriodicLogicalSpaceSnapshotWrite() {
        persistenceController.schedulePeriodicLogicalSpaceAutosave()
    }

    func writePersistentLogicalSpaceSnapshotIfSafe() {
        guard logicalSpacePersistenceIsSafe() else {
            return
        }
        writePersistentLogicalSpaceSnapshot()
    }

    func logicalSpacePersistenceIsSafe() -> Bool {
        !fullscreenSpaceChangeGuardIsActive()
            && CFAbsoluteTimeGetCurrent() >= fullscreenTransitionGuardUntil
            && !focusedRememberedFullscreenWindowIsActive
            && !windowManagement.pendingLogicalSpaceSwitch
            && windowManagement.spaceBufferedWindows.isEmpty
    }

    func writePersistentLogicalSpaceSnapshot() {
        if logicalSpacePersistenceIsSafe() {
            saveActiveLogicalSpaceContext()
        }
        let snapshot = windowManagement.persistentLogicalSpaceSnapshot(
            identity: persistentIdentity(for:)
        )
        persistenceController.writeLogicalSpaces(snapshot)
    }

}
