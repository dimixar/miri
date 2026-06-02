import Foundation

extension Miri {
    var persistentLogicalSpaceStateURL: URL {
        persistentLayoutStateURL
            .deletingLastPathComponent()
            .appendingPathComponent("logical-spaces.json")
    }

    func readPersistentLogicalSpaceSnapshot() -> PersistentLogicalSpaceSnapshot? {
        guard persistLayoutEnabled,
              let data = try? Data(contentsOf: persistentLogicalSpaceStateURL),
              let snapshot = try? JSONDecoder().decode(PersistentLogicalSpaceSnapshot.self, from: data),
              snapshot.version == 1
        else {
            return nil
        }
        return sanitizedPersistentLogicalSpaceSnapshot(snapshot)
    }

    func sanitizedPersistentLogicalSpaceSnapshot(_ snapshot: PersistentLogicalSpaceSnapshot) -> PersistentLogicalSpaceSnapshot? {
        var seen = Set<Int>()
        let contexts = snapshot.contexts.filter { context in
            guard context.id >= 0, !seen.contains(context.id) else {
                debugLog("skipping invalid persisted logical macOS space id=\(context.id)")
                return false
            }
            seen.insert(context.id)
            return true
        }
        guard !contexts.isEmpty else {
            return nil
        }
        let maxID = contexts.map(\.id).max() ?? 0
        let activeID = contexts.contains(where: { $0.id == snapshot.activeContextID }) ? snapshot.activeContextID : contexts[0].id
        return PersistentLogicalSpaceSnapshot(
            version: snapshot.version,
            activeContextID: activeID,
            nextContextID: max(maxID + 1, snapshot.nextContextID, 0),
            contexts: contexts
        )
    }

    func schedulePeriodicLogicalSpaceSnapshotWrite() {
        logicalSpaceSnapshotTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        let interval = max(60, Int(logicalSpaceAutosaveInterval.rounded()))
        timer.schedule(deadline: .now() + .seconds(interval), repeating: .seconds(interval), leeway: .seconds(30))
        timer.setEventHandler { [weak self] in
            self?.writePersistentLogicalSpaceSnapshotIfSafe()
        }
        logicalSpaceSnapshotTimer = timer
        timer.resume()
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
        guard persistLayoutEnabled else {
            try? FileManager.default.removeItem(at: persistentLogicalSpaceStateURL)
            return
        }
        if logicalSpacePersistenceIsSafe() {
            saveActiveLogicalSpaceContext()
        }
        let validContexts = logicalSpaceContexts.filter { $0.id >= 0 }
        guard !validContexts.isEmpty else {
            try? FileManager.default.removeItem(at: persistentLogicalSpaceStateURL)
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
        do {
            let url = persistentLogicalSpaceStateURL
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: url, options: [.atomic])
        } catch {
            debugLog("failed to write persistent logical macOS spaces: \(error)")
        }
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
