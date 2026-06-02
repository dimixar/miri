import Foundation

extension Miri {
    @discardableResult
    func restorePersistentLogicalSpaceContextsIfNeeded(discovered: [ManagedWindow]) -> Bool {
        guard needsPersistentLogicalSpaceRestore else {
            return false
        }
        needsPersistentLogicalSpaceRestore = false
        guard let snapshot = persistentLogicalSpaceSnapshot else {
            return false
        }

        let visibleSignature = discoveredSignature(discovered)
        guard let selected = bestPersistentLogicalSpaceContext(for: discovered, visibleSignature: visibleSignature, in: snapshot.contexts) else {
            pendingPersistentLogicalSpaceContexts = snapshot.contexts
            nextLogicalSpaceContextID = max(snapshot.nextContextID, (snapshot.contexts.map(\.id).max() ?? 0) + 1, 0)
            return false
        }

        let activeContext = logicalSpaceContext(from: selected, discovered: discovered)
        logicalSpaceContexts = [activeContext]
        activeLogicalSpaceContextID = activeContext.id
        pendingPersistentLogicalSpaceContexts = snapshot.contexts.filter { $0.id != selected.id }
        nextLogicalSpaceContextID = max(snapshot.nextContextID, (snapshot.contexts.map(\.id).max() ?? 0) + 1, 0)
        loadLogicalSpaceContext(activeContext)
        needsPersistentLayoutRestore = false
        debugLog("restored persisted logical macOS space id=\(activeContext.id) visible=\(visibleSignature.count) pending=\(pendingPersistentLogicalSpaceContexts.count)")
        return true
    }

    func promotePendingPersistentLogicalSpaceContext(
        for visibleSignature: Set<UInt32>,
        discovered: [ManagedWindow]
    ) -> LogicalSpaceContext? {
        guard let pending = bestPersistentLogicalSpaceContext(
            for: discovered,
            visibleSignature: visibleSignature,
            in: pendingPersistentLogicalSpaceContexts
        ) else {
            return nil
        }
        pendingPersistentLogicalSpaceContexts.removeAll { $0.id == pending.id }
        let context = logicalSpaceContext(from: pending, discovered: discovered)
        logicalSpaceContexts.removeAll { $0.id == context.id }
        logicalSpaceContexts.append(context)
        nextLogicalSpaceContextID = max(nextLogicalSpaceContextID, context.id + 1, 0)
        debugLog("promoted persisted logical macOS space id=\(context.id) visible=\(visibleSignature.count) pending=\(pendingPersistentLogicalSpaceContexts.count)")
        return context
    }

    func bestPersistentLogicalSpaceContext(
        for discovered: [ManagedWindow],
        visibleSignature: Set<UInt32>,
        in contexts: [PersistentLogicalSpaceContext]
    ) -> PersistentLogicalSpaceContext? {
        guard !contexts.isEmpty else {
            return nil
        }
        let identities = discovered.map(persistentIdentity(for:))
        var best: (context: PersistentLogicalSpaceContext, score: Int)?
        for context in contexts where context.id >= 0 {
            let idOverlap = Set(context.signatureWindowIDs).intersection(visibleSignature).count
            let identityOverlap = identities.reduce(0) { count, identity in
                count + (persistentLogicalSpaceContext(context, contains: identity) ? 1 : 0)
            }
            let score = idOverlap * 100 + identityOverlap
            guard score > 0 else {
                continue
            }
            if best == nil || score > best!.score {
                best = (context, score)
            }
        }
        return best?.context
    }

    func persistentLogicalSpaceContext(_ context: PersistentLogicalSpaceContext, contains identity: PersistentWindowIdentity) -> Bool {
        context.tiledWindows.contains { persistentIdentity($0.identity, matches: identity) }
            || context.floatingWindows.contains { persistentIdentity($0.identity, matches: identity) }
    }

    func persistentIdentity(_ lhs: PersistentWindowIdentity, matches rhs: PersistentWindowIdentity) -> Bool {
        if let leftBundle = lhs.bundleID, let rightBundle = rhs.bundleID, leftBundle == rightBundle {
            if lhs.title == rhs.title || lhs.title.isEmpty || rhs.title.isEmpty {
                return true
            }
        }
        return lhs.appName.lowercased() == rhs.appName.lowercased() && (lhs.title == rhs.title || lhs.title.isEmpty || rhs.title.isEmpty)
    }

    func logicalSpaceContext(from persisted: PersistentLogicalSpaceContext, discovered: [ManagedWindow]) -> LogicalSpaceContext {
        let workspaceCount = max(
            1,
            persisted.activeWorkspace + 1,
            (persisted.tiledWindows.map(\.workspace).max() ?? 0) + 1
        )
        let workspaces = (0..<workspaceCount).map { _ in Workspace() }
        var used = Set<ObjectIdentifier>()

        let sortedTiled = persisted.tiledWindows.sorted {
            if $0.workspace != $1.workspace {
                return $0.workspace < $1.workspace
            }
            return $0.column < $1.column
        }
        for state in sortedTiled {
            guard let window = bestDiscoveredWindow(for: state.windowID, identity: state.identity, discovered: discovered, used: used) else {
                continue
            }
            used.insert(ObjectIdentifier(window))
            window.manualWidthRatio = state.manualWidthRatio
            let workspaceIndex = min(max(state.workspace, 0), workspaces.count - 1)
            let workspace = workspaces[workspaceIndex]
            workspace.columns.insert(window, at: min(max(state.column, 0), workspace.columns.count))
        }

        let floating = persisted.floatingWindows.sorted { $0.index < $1.index }.compactMap { state -> ManagedWindow? in
            guard let window = bestDiscoveredWindow(for: state.windowID, identity: state.identity, discovered: discovered, used: used) else {
                return nil
            }
            used.insert(ObjectIdentifier(window))
            return window
        }

        for window in discovered where !used.contains(ObjectIdentifier(window)) {
            workspaces[0].columns.append(window)
        }
        for (index, workspace) in workspaces.enumerated() {
            if persisted.activeColumns.indices.contains(index) {
                workspace.activeColumn = persisted.activeColumns[index]
            }
            if let scrollOffsets = persisted.scrollOffsets, scrollOffsets.indices.contains(index) {
                workspace.scrollOffset = scrollOffsets[index]
            }
            workspace.clampFocus()
        }

        return LogicalSpaceContext(
            id: max(persisted.id, 0),
            workspaces: workspaces,
            floatingWindows: floating,
            activeWorkspace: min(max(persisted.activeWorkspace, 0), workspaces.count - 1),
            signature: Set(discovered.compactMap(\.windowID))
        )
    }

    func bestDiscoveredWindow(
        for windowID: UInt32?,
        identity: PersistentWindowIdentity,
        discovered: [ManagedWindow],
        used: Set<ObjectIdentifier>
    ) -> ManagedWindow? {
        if let windowID,
           let exact = discovered.first(where: { $0.windowID == windowID && !used.contains(ObjectIdentifier($0)) })
        {
            return exact
        }
        return discovered.first { window in
            !used.contains(ObjectIdentifier(window))
                && persistentIdentity(persistentIdentity(for: window), matches: identity)
        }
    }
}
