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
            && !pendingLogicalSpaceSwitch
            && spaceBufferedWindows.isEmpty
    }

    func writePersistentLogicalSpaceSnapshot() {
        if logicalSpacePersistenceIsSafe() {
            saveActiveLogicalSpaceContext()
        }
        let validContexts = logicalSpaceContexts.filter { $0.id >= 0 }
        guard !validContexts.isEmpty else {
            persistenceController.writeLogicalSpaces(nil)
            return
        }
        let contexts = validContexts.map(persistentLogicalSpaceContext(from:))
        let maxID = contexts.map(\.id).max() ?? 0
        let snapshot = PersistentLogicalSpaceSnapshot(
            version: 1,
            activeContextID: max(activeLogicalSpaceContextID, 0),
            nextContextID: max(nextLogicalSpaceContextID, maxID + 1, 0),
            contexts: contexts
        )
        persistenceController.writeLogicalSpaces(snapshot)
    }

    func persistentLogicalSpaceContext(from context: LogicalSpaceContext) -> PersistentLogicalSpaceContext {
        let tiled = context.workspaces.enumerated().flatMap { workspaceIndex, workspace in
            workspace.columns.enumerated().map { columnIndex, window in
                PersistentLogicalSpaceWindow(
                    windowID: window.windowID,
                    identity: persistentIdentity(for: window),
                    workspace: workspaceIndex,
                    column: columnIndex,
                    manualWidthRatio: window.manualWidthRatio
                )
            }
        }
        let floating = context.floatingWindows.enumerated().map { index, window in
            PersistentLogicalSpaceFloatingWindow(
                windowID: window.windowID,
                identity: persistentIdentity(for: window),
                index: index
            )
        }
        return PersistentLogicalSpaceContext(
            id: context.id,
            activeWorkspace: context.activeWorkspace,
            activeColumns: context.workspaces.map(\.activeColumn),
            scrollOffsets: context.workspaces.map(\.scrollOffset),
            signatureWindowIDs: Array(context.signature),
            tiledWindows: tiled,
            floatingWindows: floating
        )
    }
}
