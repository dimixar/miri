import ApplicationServices
import CoreGraphics
import Foundation

extension Miri {
    func location(of element: AXUIElement) -> (workspace: Int, column: Int)? {
        for (workspaceIndex, workspace) in windowManagement.workspaces.enumerated() {
            for (columnIndex, column) in workspace.columns.enumerated() where column.windows.contains(where: { sameWindow($0.element, element) }) {
                return (workspaceIndex, columnIndex)
            }
        }
        return nil
    }

    func tiledWindowLocation(
        for element: AXUIElement
    ) -> (workspaceIndex: Int, workspace: Workspace, columnIndex: Int, window: ManagedWindow)? {
        for (workspaceIndex, workspace) in windowManagement.workspaces.enumerated() {
            if let columnIndex = workspace.columns.firstIndex(where: { $0.windows.contains { sameWindow($0.element, element) } }),
               let window = workspace.columns[columnIndex].windows.first(where: { sameWindow($0.element, element) }) {
                return (workspaceIndex, workspace, columnIndex, window)
            }
        }
        return nil
    }

    func tiledWindowLocation(
        matching identity: PersistentWindowIdentity
    ) -> (workspaceIndex: Int, workspace: Workspace, columnIndex: Int, window: ManagedWindow)? {
        for (workspaceIndex, workspace) in windowManagement.workspaces.enumerated() {
            if let columnIndex = workspace.columns.firstIndex(where: { $0.windows.contains { persistentIdentity(for: $0) == identity } }),
               let window = workspace.columns[columnIndex].windows.first(where: { persistentIdentity(for: $0) == identity }) {
                return (workspaceIndex, workspace, columnIndex, window)
            }
        }
        return nil
    }

    func tiledWindow(for element: AXUIElement) -> ManagedWindow? {
        tiledWindowLocation(for: element)?.window
    }

    func sameWindow(_ left: AXUIElement, _ right: AXUIElement) -> Bool {
        CFEqual(left, right)
    }
}
