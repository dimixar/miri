import ApplicationServices
import CoreGraphics
import Darwin

struct RuleAppInfo {
    let bundleID: String
    let appName: String
}

struct MiriStatus {
    let workspace: Int
    let workspaceCount: Int
    let focusedWindow: String
    let widthPercent: Int?
}

struct MiriWorkspaceSummary: Equatable {
    let workspace: Int
    let isActive: Bool
    let lastFocusedWindow: MiriWorkspaceBarWindow?
    let appNames: [String]
}

struct MiriWorkspaceBarStatus: Equatable {
    let workspace: Int
    let focusedIndex: Int?
    let windows: [MiriWorkspaceBarWindow]
    let occupiedWorkspaces: [MiriWorkspaceSummary]
    let fullscreenWindows: [MiriWorkspaceBarFullscreenWindow]
}

struct MiriWorkspaceBarWindow: Equatable {
    let bundleID: String?
    let appName: String
    let title: String
}

struct MiriWorkspaceBarFullscreenWindow: Equatable {
    let workspace: Int
    let window: MiriWorkspaceBarWindow
}

struct TransientSystemWindow {
    var element: AXUIElement
}

struct FullscreenWindowState {
    let identity: PersistentWindowIdentity
    let element: AXUIElement
    let pid: pid_t
    let windowID: UInt32?
    let bundleID: String?
    let appName: String
    let title: String
    let workspace: Int
    let column: Int
    let leftNeighborID: ObjectIdentifier?
    let rightNeighborID: ObjectIdentifier?
    let leftNeighbor: PersistentWindowIdentity?
    let rightNeighbor: PersistentWindowIdentity?
    let widthRatio: CGFloat
    let wasActive: Bool
}
