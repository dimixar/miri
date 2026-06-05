import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

final class ManagedWindow: @unchecked Sendable {
    let element: AXUIElement
    let pid: pid_t
    let windowID: UInt32?
    var bundleID: String?
    var appName: String
    var title: String
    var manualWidthRatio: CGFloat?

    init(element: AXUIElement, pid: pid_t, windowID: UInt32?, bundleID: String?, appName: String, title: String) {
        self.element = element
        self.pid = pid
        self.windowID = windowID
        self.bundleID = bundleID
        self.appName = appName
        self.title = title
    }
}

final class Workspace {
    var columns: [ManagedWindow] = []
    var activeColumn: Int = 0
    var scrollOffset: CGFloat?

    var isEmpty: Bool {
        columns.isEmpty
    }

    func clampFocus() {
        if columns.isEmpty {
            activeColumn = 0
            scrollOffset = nil
        } else {
            activeColumn = min(max(activeColumn, 0), columns.count - 1)
        }
    }
}

final class LogicalSpaceContext {
    let id: Int
    var workspaces: [Workspace]
    var floatingWindows: [ManagedWindow]
    var activeWorkspace: Int
    var signature: Set<UInt32>

    init(
        id: Int,
        workspaces: [Workspace] = [Workspace()],
        floatingWindows: [ManagedWindow] = [],
        activeWorkspace: Int = 0,
        signature: Set<UInt32> = []
    ) {
        self.id = id
        self.workspaces = workspaces
        self.floatingWindows = floatingWindows
        self.activeWorkspace = activeWorkspace
        self.signature = signature
    }
}

struct BufferedSpaceWindow {
    var window: ManagedWindow
    var sourceContextID: Int
    var sourceWorkspace: Int?
    var sourceColumn: Int?
    var sourceFloatingIndex: Int?
    var bufferedAt: CFAbsoluteTime
}

struct RestoreSnapshot: Codable {
    var windowIDs: [UInt32]
    var floatingWindowIDs: [UInt32]?
    var viewport: RectSnapshot
}

struct PersistentLayoutSnapshot: Codable {
    var version: Int
    var activeWorkspace: Int
    var activeColumns: [Int]
    var scrollOffsets: [CGFloat?]?
    var focusedWindow: PersistentWindowIdentity?
    var windows: [PersistentWindowState]
}

struct PersistentLogicalSpaceSnapshot: Codable {
    var version: Int
    var activeContextID: Int
    var nextContextID: Int
    var contexts: [PersistentLogicalSpaceContext]
}

struct PersistentLogicalSpaceContext: Codable {
    var id: Int
    var activeWorkspace: Int
    var activeColumns: [Int]
    var scrollOffsets: [CGFloat?]?
    var signatureWindowIDs: [UInt32]
    var tiledWindows: [PersistentLogicalSpaceWindow]
    var floatingWindows: [PersistentLogicalSpaceFloatingWindow]
}

struct PersistentLogicalSpaceWindow: Codable {
    var windowID: UInt32?
    var identity: PersistentWindowIdentity
    var workspace: Int
    var column: Int
    var manualWidthRatio: CGFloat?
}

struct PersistentLogicalSpaceFloatingWindow: Codable {
    var windowID: UInt32?
    var identity: PersistentWindowIdentity
    var index: Int
}

struct PersistentWindowState: Codable {
    var identity: PersistentWindowIdentity
    var workspace: Int
    var column: Int
    var manualWidthRatio: CGFloat?
}

struct PersistentWindowIdentity: Codable, Hashable {
    var bundleID: String?
    var appName: String
    var title: String
}

struct RectSnapshot: Codable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(_ rect: CGRect) {
        x = rect.origin.x
        y = rect.origin.y
        width = rect.width
        height = rect.height
    }

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

struct LayoutState: Equatable {
    var activeWorkspace: Int
    var activeColumns: [Int]
    var scrollOffsets: [CGFloat?]
}

struct LayoutItem: Sendable {
    var window: ManagedWindow
    var frame: CGRect
    var visible: Bool
}

struct WindowMotion: Sendable {
    var window: ManagedWindow
    var startFrame: CGRect
    var endFrame: CGRect
    var startsVisible: Bool
    var endsVisible: Bool
    var participates: Bool
    var sizeStable: Bool
}
