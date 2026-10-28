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
    var fullscreenOS = false
    var fullscreenLayout = false
    var manualWidthRatio: CGFloat?
    // Learned from frame readback when an app refuses a smaller stacked row.
    var minimumHeight: CGFloat = 64

    init(element: AXUIElement, pid: pid_t, windowID: UInt32?, bundleID: String?, appName: String, title: String) {
        self.element = element
        self.pid = pid
        self.windowID = windowID
        self.bundleID = bundleID
        self.appName = appName
        self.title = title
    }
}

enum WorkspaceFullscreenState {
    case off
    case active
    case suspended
}

@MainActor
final class Column {
    let id: UUID
    var windows: [ManagedWindow]
    var activeRow: Int
    var widthRatio: CGFloat?
    var heightRatios: [CGFloat]

    init(windows: [ManagedWindow], activeRow: Int = 0, widthRatio: CGFloat? = nil, heightRatios: [CGFloat] = [], id: UUID = UUID()) {
        self.id = id
        self.windows = windows
        self.activeRow = activeRow
        self.widthRatio = widthRatio ?? windows.first?.manualWidthRatio
        self.heightRatios = heightRatios
        normalize()
    }

    var activeWindow: ManagedWindow? {
        windows.indices.contains(activeRow) ? windows[activeRow] : nil
    }

    func normalize() {
        activeRow = min(max(activeRow, 0), max(0, windows.count - 1))
        guard !windows.isEmpty else { heightRatios = []; return }
        if heightRatios.count != windows.count { heightRatios = Array(repeating: 1, count: windows.count) }
        heightRatios = heightRatios.map { $0.isFinite && $0 > 0 ? $0 : 1 }
        let total = heightRatios.reduce(0, +)
        heightRatios = heightRatios.map { $0 / total }
    }

    @discardableResult
    func remove(_ window: ManagedWindow) -> Bool {
        guard let row = windows.firstIndex(where: { $0 === window }) else { return false }
        windows.remove(at: row)
        heightRatios.remove(at: row)
        if activeRow > row { activeRow -= 1 }
        normalize()
        return true
    }

    func append(_ window: ManagedWindow) {
        let share = 1 / CGFloat(windows.count + 1)
        heightRatios = heightRatios.map { $0 * (1 - share) } + [share]
        windows.append(window)
        activeRow = windows.count - 1
        normalize()
    }

    @discardableResult
    func setHeightRatio(_ ratio: CGFloat, row: Int, minimum: CGFloat = 0.05, minimums: [CGFloat]? = nil) -> Bool {
        guard windows.count > 1, heightRatios.indices.contains(row) else { return false }
        normalize()
        let floor = min(max(minimum, 0), 1 / CGFloat(windows.count))
        let floors = minimums ?? Array(repeating: floor, count: windows.count)
        guard floors.count == windows.count, floors.reduce(0, +) <= 1 else { return false }
        let target = min(max(ratio, floors[row]), 1 - floors.enumerated().filter { $0.offset != row }.reduce(0) { $0 + $1.element })
        let old = heightRatios[row]
        guard abs(old - target) > 0.0001 else { return false }
        let peers = heightRatios.indices.filter { $0 != row }
        redistributeHeights(indices: peers, remaining: 1 - target, minimums: floors)
        heightRatios[row] = target
        return true
    }

    func fitHeightRatios(minimums: [CGFloat]) {
        redistributeHeights(indices: Array(heightRatios.indices), remaining: 1, minimums: minimums)
    }

    private func redistributeHeights(indices: [Int], remaining: CGFloat, minimums: [CGFloat]) {
        // Preserve proportions, reserving each constrained row's minimum first.
        var remaining = remaining
        var pending = indices
        while !pending.isEmpty {
            let total = pending.reduce(CGFloat(0)) { $0 + heightRatios[$1] }
            let constrained = pending.filter { remaining * heightRatios[$0] / total < minimums[$0] }
            if constrained.isEmpty {
                for index in pending { heightRatios[index] = remaining * heightRatios[index] / total }
                break
            }
            for index in constrained { heightRatios[index] = minimums[index]; remaining -= minimums[index] }
            pending.removeAll { constrained.contains($0) }
        }
    }
}

@MainActor
final class Workspace {
    var columns: [Column] = []
    var activeColumn: Int = 0
    var scrollOffset: CGFloat?
    var fullscreenState: WorkspaceFullscreenState = .off
    var windowFullscreenSuspended = false

    var isEmpty: Bool {
        columns.isEmpty
    }

    var windows: [ManagedWindow] { columns.flatMap(\.windows) }
    var activeWindow: ManagedWindow? {
        columns.indices.contains(activeColumn) ? columns[activeColumn].activeWindow : nil
    }

    func clampFocus() {
        if columns.isEmpty {
            activeColumn = 0
            scrollOffset = nil
            fullscreenState = .off
        } else {
            activeColumn = min(max(activeColumn, 0), columns.count - 1)
            columns.forEach { $0.normalize() }
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
    var fullscreenOSWindowStates: [PersistentWindowIdentity: FullscreenOSWindowState]
    var pendingFullscreenOSTransitionSince: [ObjectIdentifier: CFAbsoluteTime]
    var fullscreenSpaceChangeGuardWorkspace: Int?

    init(
        id: Int,
        workspaces: [Workspace] = [Workspace()],
        floatingWindows: [ManagedWindow] = [],
        activeWorkspace: Int = 0,
        signature: Set<UInt32> = [],
        minimizedWindowStates: [PersistentWindowIdentity: PersistentWindowState] = [:],
        minimizedWindowPIDs: [PersistentWindowIdentity: pid_t] = [:],
        fullscreenOSWindowStates: [PersistentWindowIdentity: FullscreenOSWindowState] = [:],
        pendingFullscreenOSTransitionSince: [ObjectIdentifier: CFAbsoluteTime] = [:],
        fullscreenSpaceChangeGuardWorkspace: Int? = nil
    ) {
        self.id = id
        self.workspaces = workspaces
        self.floatingWindows = floatingWindows
        self.activeWorkspace = activeWorkspace
        self.signature = signature
        self.minimizedWindowStates = minimizedWindowStates
        self.minimizedWindowPIDs = minimizedWindowPIDs
        self.fullscreenOSWindowStates = fullscreenOSWindowStates
        self.pendingFullscreenOSTransitionSince = pendingFullscreenOSTransitionSince
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
    var groupID: UUID? = nil
    var row: Int? = nil
    var heightRatio: CGFloat? = nil
    var columnWidthRatio: CGFloat? = nil
    var activeRow: Int? = nil
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
    var groupID: UUID? = nil
    var row: Int? = nil
    var heightRatio: CGFloat? = nil
    var columnWidthRatio: CGFloat? = nil
    var activeRow: Int? = nil
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
    var fullscreenWorkspaces: [Bool] = []
    var activeRows: [[Int]] = []
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
