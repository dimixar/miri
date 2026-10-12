import CoreGraphics
import Foundation

extension Miri {
    func schedulePersistentLayoutSnapshotWrite() {
        persistenceController.scheduleLayoutAutosave()
    }

    func writePersistentLayoutSnapshot() {
        let snapshot = windowManagement.persistentLayoutSnapshot(
            identity: persistentIdentity(for:),
            widthRatio: widthRatio(for:)
        )
        persistenceController.writeLayout(snapshot)
    }

    @discardableResult
    func applyPersistentLayoutSnapshotIfNeeded(finalize: Bool = true) -> Bool {
        guard persistenceController.needsLayoutRestore else {
            return false
        }

        guard let snapshot = persistenceController.layoutSnapshot else {
            persistenceController.finishLayoutRestore()
            return false
        }

        let workspaces = windowManagement.workspaces
        let liveWindowIDs = Set(workspaces.flatMap(\.windows).map(ObjectIdentifier.init))
        persistentLayoutRestoreAssignments = persistentLayoutRestoreAssignments.filter {
            liveWindowIDs.contains($0.key)
        }
        persistentLayoutRestoreConsideredWindows.formIntersection(liveWindowIDs)
        var usedSnapshotIndices = Set(persistentLayoutRestoreAssignments.values)
        var placements: [(snapshotIndex: Int, state: PersistentWindowState, window: ManagedWindow)] = []
        for (workspaceIndex, workspace) in workspaces.enumerated() {
            for (columnIndex, column) in workspace.columns.enumerated() {
                for window in column.windows {
                    let windowID = ObjectIdentifier(window)
                    if let assignment = persistentLayoutRestoreAssignments[windowID], snapshot.windows.indices.contains(assignment) {
                        placements.append((assignment, snapshot.windows[assignment], window))
                        continue
                    }
                    guard !persistentLayoutRestoreConsideredWindows.contains(windowID) else {
                        continue
                    }
                    persistentLayoutRestoreConsideredWindows.insert(windowID)
                    guard let match = persistentWindowState(
                        for: window,
                        currentWorkspace: workspaceIndex,
                        currentColumn: columnIndex,
                        in: snapshot,
                        used: &usedSnapshotIndices
                    ) else {
                        continue
                    }
                    window.manualWidthRatio = match.state.manualWidthRatio
                    persistentLayoutRestoreAssignments[windowID] = match.index
                    placements.append((match.index, match.state, window))
                }
            }
        }

        guard !placements.isEmpty else {
            if finalize, persistentLayoutInitialStateApplied {
                persistenceController.finishLayoutRestore()
                persistentLayoutRestoreAssignments.removeAll()
                persistentLayoutRestoreConsideredWindows.removeAll()
            }
            return false
        }
        if finalize {
            persistenceController.finishLayoutRestore()
        }

        let placedIDs = Set(placements.map { ObjectIdentifier($0.window) })
        let priorActiveWindows = workspaces.map { workspace -> ManagedWindow? in
            guard !workspace.columns.isEmpty else { return nil }
            workspace.clampFocus()
            return workspace.activeWindow
        }
        let priorScrollOffsets = workspaces.map(\.scrollOffset)
        let workspaceCount = max(
            workspaces.count,
            (placements.map(\.state.workspace).max() ?? 0) + 1,
            snapshot.activeWorkspace + 1,
            1
        )
        let nextWorkspaces = (0..<workspaceCount).map { _ in Workspace() }

        for (workspaceIndex, workspace) in workspaces.enumerated() {
            let targetWorkspace = nextWorkspaces[min(workspaceIndex, nextWorkspaces.count - 1)]
            for column in workspace.columns {
                let remaining = column.windows.filter { !placedIDs.contains(ObjectIdentifier($0)) }
                if !remaining.isEmpty { targetWorkspace.columns.append(Column(windows: remaining, widthRatio: column.widthRatio)) }
            }
        }

        let sortedPlacements = placements.sorted {
            if $0.state.workspace != $1.state.workspace {
                return $0.state.workspace < $1.state.workspace
            }
            if $0.state.column != $1.state.column { return $0.state.column < $1.state.column }
            return ($0.state.row ?? 0) < ($1.state.row ?? 0)
        }
        for placement in sortedPlacements {
            let workspaceIndex = min(max(placement.state.workspace, 0), nextWorkspaces.count - 1)
            let workspace = nextWorkspaces[workspaceIndex]
            restoreGroupedWindow(placement.window, state: placement.state, in: workspace)
        }

        let restoredActiveWorkspace = min(max(snapshot.activeWorkspace, 0), nextWorkspaces.count - 1)
        for (index, workspace) in nextWorkspaces.enumerated() {
            if !persistentLayoutInitialStateApplied {
                if snapshot.activeColumns.indices.contains(index) {
                    workspace.activeColumn = snapshot.activeColumns[index]
                }
                if let scrollOffsets = snapshot.scrollOffsets, scrollOffsets.indices.contains(index) {
                    workspace.scrollOffset = scrollOffsets[index]
                } else {
                    workspace.scrollOffset = nil
                }
            } else {
                if priorActiveWindows.indices.contains(index),
                   let priorActive = priorActiveWindows[index],
                   let activeColumn = workspace.columns.firstIndex(where: { $0.windows.contains { $0 === priorActive } })
                {
                    workspace.activeColumn = activeColumn
                    workspace.columns[activeColumn].activeRow = workspace.columns[activeColumn].windows.firstIndex { $0 === priorActive } ?? 0
                }
                workspace.scrollOffset = priorScrollOffsets.indices.contains(index)
                    ? priorScrollOffsets[index]
                    : nil
            }
            workspace.clampFocus()
        }
        let nextActiveWorkspace = persistentLayoutInitialStateApplied
            ? min(windowManagement.activeWorkspace, nextWorkspaces.count - 1)
            : restoredActiveWorkspace
        windowManagement.replaceActiveProjection(
            workspaces: nextWorkspaces,
            activeWorkspace: nextActiveWorkspace
        )
        cancelWorkspaceBoundaryHold()
        windowManagement.enforceRowCapacity(configStore.effectiveConfig.rowsPerColumn ?? 1)
        persistentLayoutInitialStateApplied = true
        if finalize {
            persistentLayoutRestoreAssignments.removeAll()
            persistentLayoutRestoreConsideredWindows.removeAll()
        }
        return true
    }

    func restorePersistentFocusedWindow() -> Bool {
        guard let focusedWindow = persistenceController.layoutSnapshot?.focusedWindow,
              let location = tiledWindowLocation(matching: focusedWindow)
        else {
            return false
        }

        setActiveWorkspace(location.workspaceIndex)
        windowManagement.setActiveColumn(location.columnIndex, in: location.workspace)
        location.workspace.columns[location.columnIndex].activeRow = location.workspace.columns[location.columnIndex].windows.firstIndex { $0 === location.window } ?? 0
        return true
    }

    func restoreGroupedWindow(_ window: ManagedWindow, state: PersistentWindowState, in workspace: Workspace) {
        let column: Column
        if let group = state.groupID, let existing = workspace.columns.first(where: { $0.id == group }) {
            column = existing
            column.windows.append(window)
            column.heightRatios.append(state.heightRatio ?? 1)
        } else {
            column = Column(windows: [window], widthRatio: state.columnWidthRatio ?? state.manualWidthRatio, id: state.groupID ?? UUID())
            column.heightRatios = [state.heightRatio ?? 1]
            workspace.columns.insert(column, at: min(max(state.column, 0), workspace.columns.count))
        }
        // Defer normalization until the complete (or partially available) group is assembled.
        if state.row == state.activeRow { column.activeRow = column.windows.count - 1 }
    }

    func persistentWindowState(
        for window: ManagedWindow,
        currentWorkspace: Int,
        currentColumn: Int,
        in snapshot: PersistentLayoutSnapshot,
        used: inout Set<Int>
    ) -> (index: Int, state: PersistentWindowState)? {
        let identity = persistentIdentity(for: window)
        if let exact = bestPersistentWindowState(
            in: snapshot,
            used: used,
            currentWorkspace: currentWorkspace,
            currentColumn: currentColumn,
            matches: { $0.identity == identity }
        ) {
            used.insert(exact.index)
            return exact
        }

        if let bundleID = identity.bundleID,
           let bundleMatch = bestPersistentWindowState(
               in: snapshot,
               used: used,
               currentWorkspace: currentWorkspace,
               currentColumn: currentColumn,
               matches: { $0.identity.bundleID == bundleID }
           )
        {
            used.insert(bundleMatch.index)
            return bundleMatch
        }

        let normalizedAppName = identity.appName.lowercased()
        if let appMatch = bestPersistentWindowState(
            in: snapshot,
            used: used,
            currentWorkspace: currentWorkspace,
            currentColumn: currentColumn,
            matches: { $0.identity.appName.lowercased() == normalizedAppName }
        ) {
            used.insert(appMatch.index)
            return appMatch
        }

        return nil
    }

    func bestPersistentWindowState(
        in snapshot: PersistentLayoutSnapshot,
        used: Set<Int>,
        currentWorkspace: Int,
        currentColumn: Int,
        matches: (PersistentWindowState) -> Bool
    ) -> (index: Int, state: PersistentWindowState)? {
        var best: (index: Int, state: PersistentWindowState, score: Int)?
        for (index, state) in snapshot.windows.enumerated() where !used.contains(index) && matches(state) {
            let score = abs(state.workspace - currentWorkspace) * 100 + abs(state.column - currentColumn)
            if best == nil || score < best!.score {
                best = (index, state, score)
            }
        }
        return best.map { ($0.index, $0.state) }
    }

    func persistentIdentity(for window: ManagedWindow) -> PersistentWindowIdentity {
        PersistentWindowIdentity(bundleID: window.bundleID, appName: window.appName, title: window.title)
    }

}
