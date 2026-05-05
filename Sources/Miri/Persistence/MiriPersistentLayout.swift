import CoreGraphics
import Foundation

extension Miri {
    var persistLayoutEnabled: Bool {
        config.persistLayout ?? MiriConfig.fallback.persistLayout ?? true
    }

    var persistentLayoutStateURL: URL {
        if let statePath = config.statePath, !statePath.isEmpty {
            return URL(fileURLWithPath: NSString(string: statePath).expandingTildeInPath)
        }

        let stateHome = ProcessInfo.processInfo.environment["XDG_STATE_HOME"]
            .map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) }
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local")
                .appendingPathComponent("state")
        return stateHome
            .appendingPathComponent("miri", isDirectory: true)
            .appendingPathComponent("layout.json")
    }

    func readPersistentLayoutSnapshot() -> PersistentLayoutSnapshot? {
        guard persistLayoutEnabled,
              let data = try? Data(contentsOf: persistentLayoutStateURL),
              let snapshot = try? JSONDecoder().decode(PersistentLayoutSnapshot.self, from: data),
              (1...2).contains(snapshot.version)
        else {
            return nil
        }
        return snapshot
    }

    func schedulePersistentLayoutSnapshotWrite() {
        snapshotWriteTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(300), leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            guard let self else {
                return
            }
            writePersistentLayoutSnapshot()
            snapshotWriteTimer?.cancel()
            snapshotWriteTimer = nil
        }
        snapshotWriteTimer = timer
        timer.resume()
    }

    func writePersistentLayoutSnapshot() {
        guard persistLayoutEnabled else {
            try? FileManager.default.removeItem(at: persistentLayoutStateURL)
            return
        }

        let states = workspaces.enumerated().flatMap { workspaceIndex, workspace in
            workspace.columns.enumerated().map { columnIndex, window in
                PersistentWindowState(
                    identity: persistentIdentity(for: window),
                    workspace: workspaceIndex,
                    column: columnIndex,
                    manualWidthRatio: widthRatio(for: window)
                )
            }
        }
        guard !states.isEmpty else {
            try? FileManager.default.removeItem(at: persistentLayoutStateURL)
            return
        }

        let snapshot = PersistentLayoutSnapshot(
            version: 2,
            activeWorkspace: min(max(activeWorkspace, 0), max(workspaces.count - 1, 0)),
            activeColumns: workspaces.map(\.activeColumn),
            scrollOffsets: workspaces.map(\.scrollOffset),
            focusedWindow: activeWindow().map(persistentIdentity(for:)),
            windows: states
        )

        do {
            let url = persistentLayoutStateURL
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: url, options: [.atomic])
        } catch {
            debugLog("failed to write persistent layout: \(error)")
        }
    }

    @discardableResult
    func applyPersistentLayoutSnapshotIfNeeded() -> Bool {
        guard needsPersistentLayoutRestore else {
            return false
        }

        guard let snapshot = persistentLayoutSnapshot else {
            needsPersistentLayoutRestore = false
            return false
        }

        var usedSnapshotIndices = Set<Int>()
        var placements: [(state: PersistentWindowState, window: ManagedWindow)] = []
        for (workspaceIndex, workspace) in workspaces.enumerated() {
            for (columnIndex, window) in workspace.columns.enumerated() {
                guard let state = persistentWindowState(
                    for: window,
                    currentWorkspace: workspaceIndex,
                    currentColumn: columnIndex,
                    in: snapshot,
                    used: &usedSnapshotIndices
                ) else {
                    continue
                }
                window.manualWidthRatio = state.manualWidthRatio
                placements.append((state, window))
            }
        }

        guard !placements.isEmpty else {
            return false
        }
        needsPersistentLayoutRestore = false

        let placedIDs = Set(placements.map { ObjectIdentifier($0.window) })
        let workspaceCount = max(
            workspaces.count,
            (placements.map(\.state.workspace).max() ?? 0) + 1,
            snapshot.activeWorkspace + 1,
            1
        )
        let nextWorkspaces = (0..<workspaceCount).map { _ in Workspace() }

        for (workspaceIndex, workspace) in workspaces.enumerated() {
            let targetWorkspace = nextWorkspaces[min(workspaceIndex, nextWorkspaces.count - 1)]
            for window in workspace.columns where !placedIDs.contains(ObjectIdentifier(window)) {
                targetWorkspace.columns.append(window)
            }
        }

        let sortedPlacements = placements.sorted {
            if $0.state.workspace != $1.state.workspace {
                return $0.state.workspace < $1.state.workspace
            }
            return $0.state.column < $1.state.column
        }
        for placement in sortedPlacements {
            let workspaceIndex = min(max(placement.state.workspace, 0), nextWorkspaces.count - 1)
            let workspace = nextWorkspaces[workspaceIndex]
            workspace.columns.insert(placement.window, at: min(max(placement.state.column, 0), workspace.columns.count))
        }

        workspaces = nextWorkspaces
        activeWorkspace = min(max(snapshot.activeWorkspace, 0), workspaces.count - 1)
        for (index, workspace) in workspaces.enumerated() {
            if snapshot.activeColumns.indices.contains(index) {
                workspace.activeColumn = snapshot.activeColumns[index]
            }
            if let scrollOffsets = snapshot.scrollOffsets, scrollOffsets.indices.contains(index) {
                workspace.scrollOffset = scrollOffsets[index]
            } else {
                workspace.scrollOffset = nil
            }
            workspace.clampFocus()
        }
        return true
    }

    func restorePersistentFocusedWindow() -> Bool {
        guard let focusedWindow = persistentLayoutSnapshot?.focusedWindow,
              let location = tiledWindowLocation(matching: focusedWindow)
        else {
            return false
        }

        setActiveWorkspace(location.workspaceIndex)
        location.workspace.activeColumn = location.columnIndex
        return true
    }

    func persistentWindowState(
        for window: ManagedWindow,
        currentWorkspace: Int,
        currentColumn: Int,
        in snapshot: PersistentLayoutSnapshot,
        used: inout Set<Int>
    ) -> PersistentWindowState? {
        let identity = persistentIdentity(for: window)
        if let exact = bestPersistentWindowState(
            in: snapshot,
            used: used,
            currentWorkspace: currentWorkspace,
            currentColumn: currentColumn,
            matches: { $0.identity == identity }
        ) {
            used.insert(exact.index)
            return exact.state
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
            return bundleMatch.state
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
            return appMatch.state
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
