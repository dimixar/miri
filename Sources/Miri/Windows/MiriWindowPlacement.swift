import ApplicationServices
import CoreGraphics
import Foundation

extension Miri {
    func insertNewWindow(_ window: ManagedWindow, applyLayout: Bool = true, focusNewWindow: Bool = true) {
        let workspace = targetWorkspace(for: window)
        workspace.clampFocus()

        let insertionIndex = newWindowInsertionIndex(in: workspace, for: window)
        insertWindow(window, in: workspace, at: insertionIndex, applyLayout: applyLayout, focusNewWindow: focusNewWindow)
    }

    func insertRestoredWindowNearFocused(
        _ window: ManagedWindow,
        applyLayout: Bool = true,
        focusNewWindow: Bool = false
    ) {
        let workspace = activeWorkspaceObject() ?? targetWorkspace(for: window)
        workspace.clampFocus()
        let insertionIndex = workspace.columns.isEmpty ? 0 : min(workspace.activeColumn + 1, workspace.columns.count)
        insertWindow(window, in: workspace, at: insertionIndex, applyLayout: applyLayout, focusNewWindow: focusNewWindow)
    }

    func insertWindow(
        _ window: ManagedWindow,
        in workspace: Workspace,
        at insertionIndex: Int,
        applyLayout: Bool,
        focusNewWindow: Bool
    ) {
        let completedEmptyWorkspaceProtection = windowManagement.emptyWorkspaceFocusAuthority === workspace
        _ = windowManagement.insert(window, in: workspace, at: insertionIndex, focus: focusNewWindow)
        if completedEmptyWorkspaceProtection {
            debugLog("empty workspace focus protection completed reason=window-inserted")
        }
        reconcileWorkspaceCapacity()
        if applyLayout {
            projectLayout(focusActiveWindow: focusNewWindow)
        }
    }

    func targetWorkspace(for window: ManagedWindow) -> Workspace {
        if let oneBased = rule(for: window)?.workspace {
            let index = max(0, oneBased - 1)
            ensureWorkspaceExists(index)
            return windowManagement.workspaces[index]
        }

        return activeWorkspaceObject() ?? windowManagement.workspaces[0]
    }

    func ensureWorkspaceExists(_ index: Int) {
        windowManagement.ensureWorkspaceExists(index)
    }

    func newWindowInsertionIndex(in workspace: Workspace, for window: ManagedWindow) -> Int {
        guard !workspace.columns.isEmpty else {
            return 0
        }

        switch rule(for: window)?.openPosition ?? newWindowPosition {
        case .beforeActive:
            return min(max(workspace.activeColumn, 0), workspace.columns.count)
        case .afterActive:
            return min(max(workspace.activeColumn + 1, 0), workspace.columns.count)
        case .end:
            return workspace.columns.count
        }
    }

    func insertFloatingWindow(_ window: ManagedWindow, applyLayout: Bool = true) {
        _ = windowManagement.insertFloating(window)
        if applyLayout {
            projectLayout(focusActiveWindow: false)
        }
    }

    func removeWindow(_ window: ManagedWindow, preferRightFocus: Bool = false) {
        let id = ObjectIdentifier(window)
        layoutController.removeTracking(for: window)
        windowManagement.clearPendingFullscreenTransition(for: id)
        windowManagement.remove(window, preferRightFocus: preferRightFocus)
        reconcileWorkspaceCapacity()
    }

    func rememberFullscreenWindowState(_ window: ManagedWindow) {
        guard let location = tiledWindowLocation(for: window.element) else {
            return
        }
        let workspace = location.workspace
        let leftWindow = location.columnIndex > 0 ? workspace.columns[location.columnIndex - 1] : nil
        let rightWindow = location.columnIndex + 1 < workspace.columns.count ? workspace.columns[location.columnIndex + 1] : nil
        let left = leftWindow.map(persistentIdentity(for:))
        let right = rightWindow.map(persistentIdentity(for:))
        let identity = persistentIdentity(for: window)
        windowManagement.rememberFullscreenState(FullscreenWindowState(
            identity: identity,
            element: window.element,
            pid: window.pid,
            windowID: window.windowID,
            bundleID: window.bundleID,
            appName: window.appName,
            title: window.title,
            workspace: location.workspaceIndex,
            column: location.columnIndex,
            leftNeighborID: leftWindow.map(ObjectIdentifier.init),
            rightNeighborID: rightWindow.map(ObjectIdentifier.init),
            leftNeighbor: left,
            rightNeighbor: right,
            widthRatio: widthRatio(for: window),
            wasActive: windowManagement.activeWorkspace == location.workspaceIndex
                && workspace.activeColumn == location.columnIndex
        ))
    }

    @discardableResult
    func restoreExitedFullscreenWindows(discovered: [ManagedWindow]) -> Bool {
        var restored = false
        for found in discovered {
            guard let state = windowManagement.takeFullscreenState(matching: { identity, state in
                sameWindow(state.element, found.element) || persistentIdentity(for: found) == identity
            }) else {
                continue
            }
            windowManagement.setWidthRatio(state.widthRatio, for: found)
            insertRestoredFullscreenWindow(found, state: state)
            restored = true
        }
        return restored
    }

    func insertRestoredFullscreenWindow(_ window: ManagedWindow, state: FullscreenWindowState) {
        windowManagement.ensureWorkspaceExists(state.workspace)
        let workspaces = windowManagement.workspaces
        let workspace = workspaces[min(max(state.workspace, 0), workspaces.count - 1)]
        let index = restoredFullscreenInsertionIndex(in: workspace, state: state)
        insertWindow(window, in: workspace, at: index, applyLayout: false, focusNewWindow: state.wasActive)
    }

    func restoredFullscreenInsertionIndex(in workspace: Workspace, state: FullscreenWindowState) -> Int {
        let leftIndex = neighborIndex(id: state.leftNeighborID, identity: state.leftNeighbor, in: workspace)
        let rightIndex = neighborIndex(id: state.rightNeighborID, identity: state.rightNeighbor, in: workspace)
        if let leftIndex, let rightIndex, leftIndex < rightIndex {
            return rightIndex
        }
        if let leftIndex {
            return min(leftIndex + 1, workspace.columns.count)
        }
        if let rightIndex, state.leftNeighbor == nil {
            return rightIndex
        }
        if let rightIndex, rightIndex > 0 {
            return rightIndex
        }
        return workspace.columns.count
    }

    func neighborIndex(id: ObjectIdentifier?, identity: PersistentWindowIdentity?, in workspace: Workspace) -> Int? {
        if let id,
           let index = workspace.columns.firstIndex(where: { ObjectIdentifier($0) == id }) {
            return index
        }
        guard let identity else {
            return nil
        }
        if let exact = workspace.columns.firstIndex(where: { persistentIdentity(for: $0) == identity }) {
            return exact
        }
        if let bundleID = identity.bundleID,
           let bundle = workspace.columns.firstIndex(where: { $0.bundleID == bundleID }) {
            return bundle
        }
        return workspace.columns.firstIndex { $0.appName.caseInsensitiveCompare(identity.appName) == .orderedSame }
    }

    func rememberMinimizedWindowState(_ window: ManagedWindow) {
        guard let location = tiledWindowLocation(for: window.element) else {
            return
        }
        windowManagement.rememberMinimizedState(
            PersistentWindowState(
                identity: persistentIdentity(for: window),
                workspace: location.workspaceIndex,
                column: location.columnIndex,
                manualWidthRatio: widthRatio(for: window)
            ),
            pid: window.pid
        )
    }

    func restoreMinimizedWindowStateIfAvailable(for window: ManagedWindow) {
        let identity = persistentIdentity(for: window)
        guard let state = windowManagement.takeMinimizedState(identity: identity) else {
            return
        }
        windowManagement.setWidthRatio(state.manualWidthRatio, for: window)
    }

    func reconcileWorkspaceCapacity() {
        windowManagement.reconcileWorkspaceCapacity(minimumCount: minimumWorkspaceCount)
    }

}
