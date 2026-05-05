import ApplicationServices
import CoreGraphics
import Foundation

extension Miri {
    func location(of element: AXUIElement) -> (workspace: Int, column: Int)? {
        for (workspaceIndex, workspace) in workspaces.enumerated() {
            for (columnIndex, window) in workspace.columns.enumerated() where sameWindow(window.element, element) {
                return (workspaceIndex, columnIndex)
            }
        }
        return nil
    }

    func tiledWindowLocation(
        for element: AXUIElement
    ) -> (workspaceIndex: Int, workspace: Workspace, columnIndex: Int, window: ManagedWindow)? {
        for (workspaceIndex, workspace) in workspaces.enumerated() {
            if let columnIndex = workspace.columns.firstIndex(where: { sameWindow($0.element, element) }) {
                return (workspaceIndex, workspace, columnIndex, workspace.columns[columnIndex])
            }
        }
        return nil
    }

    func tiledWindowLocation(
        matching identity: PersistentWindowIdentity
    ) -> (workspaceIndex: Int, workspace: Workspace, columnIndex: Int, window: ManagedWindow)? {
        for (workspaceIndex, workspace) in workspaces.enumerated() {
            if let columnIndex = workspace.columns.firstIndex(where: { persistentIdentity(for: $0) == identity }) {
                return (workspaceIndex, workspace, columnIndex, workspace.columns[columnIndex])
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

    func axString(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    func axBool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? Bool
    }

    func axAttributeExists(_ element: AXUIElement, _ attribute: String) -> Bool {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success && value != nil
    }

    func isAXAttributeSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success && settable.boolValue
    }

    func axFrame(_ element: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionValue = positionRef,
              let sizeValue = sizeRef
        else {
            return nil
        }

        var point = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(positionValue as! AXValue, .cgPoint, &point)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        return CGRect(origin: point, size: size)
    }
}
