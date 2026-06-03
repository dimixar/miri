import Foundation

extension Miri {
    func workspaceWindowIDs(workspaceIndex: Int) -> Set<ObjectIdentifier> {
        guard workspaces.indices.contains(workspaceIndex) else {
            return []
        }
        return Set(workspaces[workspaceIndex].columns.map(ObjectIdentifier.init))
    }

    func hideInactiveWorkspaceWindows(activeWorkspace activeIndex: Int) {
        let activeIDs = workspaceWindowIDs(workspaceIndex: activeIndex)
        for (workspaceIndex, workspace) in workspaces.enumerated() where workspaceIndex != activeIndex {
            for window in workspace.columns {
                let id = ObjectIdentifier(window)
                appliedVisibility[id] = false
                hiddenWorkspaceWindowIDs.insert(id)
            }
        }

        hiddenWorkspaceWindowIDs = hiddenWorkspaceWindowIDs.filter { !activeIDs.contains($0) }
    }

    func isHiddenForInactiveWorkspace(_ window: ManagedWindow) -> Bool {
        hiddenWorkspaceWindowIDs.contains(ObjectIdentifier(window))
    }
}
