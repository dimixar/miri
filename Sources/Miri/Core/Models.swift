import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

@MainActor
final class ManagedWindow {
    let element: AXUIElement
    let pid: pid_t
    var windowID: UInt32?
    var bundleID: String?
    var appName: String
    var title: String
    var isMinimized = false
    var isFullscreen = false
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

@MainActor
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

@MainActor
final class LogicalSpaceContext {
    let id: Int
    var workspaces: [Workspace]
    var floatingWindows: [ManagedWindow]
    var activeWorkspace: Int
    var signature: Set<UInt32>
    var minimizedWindowStates: [PersistentWindowIdentity: PersistentWindowState]
    var minimizedWindowPIDs: [PersistentWindowIdentity: pid_t]
    var fullscreenWindowStates: [PersistentWindowIdentity: FullscreenWindowState]
    var pendingFullscreenTransitionSince: [ObjectIdentifier: CFAbsoluteTime]
    var fullscreenSpaceChangeGuardWorkspace: Int?

    init(
        id: Int,
        workspaces: [Workspace] = [Workspace()],
        floatingWindows: [ManagedWindow] = [],
        activeWorkspace: Int = 0,
        signature: Set<UInt32> = [],
        minimizedWindowStates: [PersistentWindowIdentity: PersistentWindowState] = [:],
        minimizedWindowPIDs: [PersistentWindowIdentity: pid_t] = [:],
        fullscreenWindowStates: [PersistentWindowIdentity: FullscreenWindowState] = [:],
        pendingFullscreenTransitionSince: [ObjectIdentifier: CFAbsoluteTime] = [:],
        fullscreenSpaceChangeGuardWorkspace: Int? = nil
    ) {
        self.id = id
        self.workspaces = workspaces
        self.floatingWindows = floatingWindows
        self.activeWorkspace = activeWorkspace
        self.signature = signature
        self.minimizedWindowStates = minimizedWindowStates
        self.minimizedWindowPIDs = minimizedWindowPIDs
        self.fullscreenWindowStates = fullscreenWindowStates
        self.pendingFullscreenTransitionSince = pendingFullscreenTransitionSince
        self.fullscreenSpaceChangeGuardWorkspace = fullscreenSpaceChangeGuardWorkspace
    }
}

struct BufferedSpaceWindow {
    var window: ManagedWindow
    var sourceContextID: Int
}

enum RestoreWindowKind: String, Codable, Sendable {
    case tiled
    case floating
}

struct RestoreWindowRecord: Codable, Sendable {
    var windowID: UInt32
    var ownerPID: pid_t?
    var kind: RestoreWindowKind
}

struct RestoreSnapshot: Codable, Sendable {
    static let currentVersion = 2

    var version: Int?
    var windows: [RestoreWindowRecord]?
    // Retained in version 2 so an older cleanup helper can still decode a
    // snapshot written immediately before an application update.
    var windowIDs: [UInt32]
    var floatingWindowIDs: [UInt32]?
    var viewport: RectSnapshot

    init(records: [RestoreWindowRecord], viewport: RectSnapshot) {
        version = Self.currentVersion
        windows = records
        windowIDs = records.filter { $0.kind == .tiled }.map(\.windowID)
        floatingWindowIDs = records.filter { $0.kind == .floating }.map(\.windowID)
        self.viewport = viewport
    }

    var restorationRecords: [RestoreWindowRecord] {
        if version == Self.currentVersion, let windows {
            return windows
        }
        let tiled = windowIDs.map {
            RestoreWindowRecord(windowID: $0, ownerPID: nil, kind: .tiled)
        }
        let floating = (floatingWindowIDs ?? []).map {
            RestoreWindowRecord(windowID: $0, ownerPID: nil, kind: .floating)
        }
        return tiled + floating
    }
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

struct RectSnapshot: Codable, Sendable {
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

struct LayoutItem {
    var window: ManagedWindow
    var frame: CGRect
    var visible: Bool
}

struct WindowMotion {
    var window: ManagedWindow
    var startFrame: CGRect
    var endFrame: CGRect
    var startsVisible: Bool
    var endsVisible: Bool
}
