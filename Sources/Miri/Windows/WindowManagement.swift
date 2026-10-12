import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

struct WorkspaceModelSnapshot {
    struct ColumnSnapshot {
        let id: UUID
        let windows: [ManagedWindow]
        let activeRow: Int
        let widthRatio: CGFloat?
        let heightRatios: [CGFloat]
        var activeWindow: ManagedWindow? { windows.indices.contains(activeRow) ? windows[activeRow] : nil }
    }
    struct WorkspaceSnapshot {
        let columns: [ColumnSnapshot]
        var windows: [ManagedWindow] { columns.flatMap(\.windows) }
        let activeColumn: Int
        let scrollOffset: CGFloat?
        let fullscreenState: WorkspaceFullscreenState
    }

    let workspaces: [WorkspaceSnapshot]
    let floatingWindows: [ManagedWindow]
    let activeWorkspace: Int

    var layoutState: LayoutState {
        LayoutState(
            activeWorkspace: activeWorkspace,
            activeColumns: workspaces.map(\.activeColumn),
            scrollOffsets: workspaces.map(\.scrollOffset),
            fullscreenWorkspaces: workspaces.map { $0.fullscreenState == .active },
            activeRows: workspaces.map { $0.columns.map(\.activeRow) }
        )
    }

    var tiledWindows: [ManagedWindow] {
        workspaces.flatMap(\.windows)
    }

    var allWindows: [ManagedWindow] {
        tiledWindows + floatingWindows
    }
}

struct GlobalWindowCleanupResult {
    let removedWindows: [ManagedWindow]
    let changed: Bool
}

struct MissingWindowFacts {
    let axEnumerationUnavailable: Bool
    let hasCGInfo: Bool
    let isFullscreen: Bool
    let pendingFullscreenWithinGrace: Bool
    let isFullScan: Bool
    let runningApplicationExists: Bool
    let temporarilyHidden: Bool
    let behaviorIsIgnored: Bool
    let fullscreenGuardActive: Bool
    let appearsInUnknownSpace: Bool
    let launchRemovalDeferred: Bool
}

enum MissingWindowDisposition {
    case preserveCGVisible
    case preservePendingFullscreen
    case preserveFullscreenGuard
    case preserveLaunchSettling
    case moveToFullscreenState
    case bufferUnknownSpace
    case remove(rememberMinimized: Bool)
}

/// The authoritative mutable graph for managed windows and logical Spaces.
/// The active workspace projection is backed directly by its active context,
/// so a window never lives in a coordinator-owned mirror of the model.
@MainActor
final class WorkspaceModel {
    fileprivate var logicalSpaceContexts: [LogicalSpaceContext]
    fileprivate var activeLogicalSpaceContextID: Int
    fileprivate var nextLogicalSpaceContextID: Int
    fileprivate weak var previousWorkspace: Workspace?
    fileprivate weak var emptyWorkspaceFocusAuthority: Workspace?
    fileprivate var pendingLogicalSpaceSwitch = false
    fileprivate var spaceBufferedWindows: [UInt32: BufferedSpaceWindow] = [:]

    init() {
        let initial = LogicalSpaceContext(id: 0)
        logicalSpaceContexts = [initial]
        activeLogicalSpaceContextID = initial.id
        nextLogicalSpaceContextID = 1
    }

    fileprivate var activeContext: LogicalSpaceContext {
        if let context = logicalSpaceContexts.first(where: { $0.id == activeLogicalSpaceContextID }) {
            return context
        }
        let replacement = LogicalSpaceContext(id: max(activeLogicalSpaceContextID, 0))
        logicalSpaceContexts.append(replacement)
        activeLogicalSpaceContextID = replacement.id
        nextLogicalSpaceContextID = max(nextLogicalSpaceContextID, replacement.id + 1)
        return replacement
    }
}

/// Window-domain boundary. The model owns canonical logical state while the
/// observation controller owns OS callbacks and discovery timer bookkeeping.
/// Layout, persistence, and UI publication stay outside.
@MainActor
final class WindowManagement {
    private let model = WorkspaceModel()
    let observation: WindowObservationController

    private struct ManualTiledPlacement {
        let contextID: Int
        let workspaceIndex: Int
        let columnIndex: Int
        let leftNeighbor: AXUIElement?
        let rightNeighbor: AXUIElement?
    }

    private struct ManualWindowOverride {
        var window: ManagedWindow
        var behavior: WindowBehavior
        var tiledPlacement: ManualTiledPlacement?
    }

    // Live AX identity only: these overrides are never serialized or matched by title/app.
    private var manualWindowOverrides: [ManualWindowOverride] = []
    private struct RemovedRowPlacement {
        let element: AXUIElement
        let contextID: Int
        weak var workspace: Workspace?
        weak var column: Column?
        let row: Int
        let share: CGFloat
    }
    private var removedRowPlacements: [RemovedRowPlacement] = []
    private var rowCapacity = 1
    private var persistentRowsByContext: [Int: [PersistentLogicalSpaceWindow]] = [:]
    private var pendingPersistentRowIdentities: [Int: Set<PersistentWindowIdentity>] = [:]

    func registerPersistentRows(_ context: PersistentLogicalSpaceContext, pending: Set<PersistentWindowIdentity>) {
        persistentRowsByContext[context.id] = context.tiledWindows
        pendingPersistentRowIdentities[context.id] = pending
    }

    @discardableResult
    func restorePendingPersistentRow(
        _ window: ManagedWindow,
        identity: (ManagedWindow) -> PersistentWindowIdentity,
        focus: Bool,
        capacity: Int
    ) -> Bool {
        guard let records = persistentRowsByContext[activeLogicalSpaceContextID],
              let state = records.first(where: { $0.identity == identity(window) }),
              pendingPersistentRowIdentities[activeLogicalSpaceContextID]?.contains(state.identity) == true,
              let group = state.groupID,
              workspaces.indices.contains(state.workspace) else { return false }
        let workspace = workspaces[state.workspace]
        let column = workspace.columns.first(where: { $0.id == group })
            ?? Column(windows: [], widthRatio: state.columnWidthRatio, id: group)
        guard column.windows.count < min(max(capacity, 1), 3),
              !column.windows.contains(where: { identity($0) == state.identity }) else { return false }
        pendingPersistentRowIdentities[activeLogicalSpaceContextID]?.remove(state.identity)
        removeCanonicalDuplicate(of: window)
        let row = column.windows.prefix { peer in
            let peerRow = records.first { $0.groupID == group && $0.identity == identity(peer) }?.row ?? 0
            return peerRow < (state.row ?? 0)
        }.count
        column.windows.insert(window, at: row)
        column.heightRatios = column.windows.map { peer in
            records.first { $0.groupID == group && $0.identity == identity(peer) }?.heightRatio ?? 1
        }
        window.manualWidthRatio = state.manualWidthRatio
        let columnIndex: Int
        if let existing = workspace.columns.firstIndex(where: { $0 === column }) {
            columnIndex = existing
        } else {
            columnIndex = min(max(state.column, 0), workspace.columns.count)
            workspace.columns.insert(column, at: columnIndex)
            if !focus, workspace.columns.count > 1, workspace.activeColumn >= columnIndex {
                workspace.activeColumn += 1
            }
        }
        if focus {
            column.activeRow = row
            workspace.activeColumn = columnIndex
            _ = selectWorkspace(state.workspace, rememberPrevious: false)
        } else if column.activeRow >= row { column.activeRow += 1 }
        column.normalize()
        workspace.scrollOffset = nil
        assertInvariants()
        return true
    }

    private func rememberRowPlacement(_ window: ManagedWindow, context: LogicalSpaceContext, workspace: Workspace, column: Column) {
        guard let row = column.windows.firstIndex(where: { $0 === window }) else { return }
        removedRowPlacements.removeAll { CFEqual($0.element, window.element) }
        removedRowPlacements.append(RemovedRowPlacement(element: window.element, contextID: context.id, workspace: workspace, column: column, row: row, share: column.heightRatios[row]))
    }

    @discardableResult
    func restoreRemovedRow(_ window: ManagedWindow, focus: Bool, capacity: Int? = nil) -> Bool {
        guard let index = removedRowPlacements.firstIndex(where: { CFEqual($0.element, window.element) }) else { return false }
        let placement = removedRowPlacements.remove(at: index)
        guard let workspace = placement.workspace, let column = placement.column,
              placement.contextID == activeLogicalSpaceContextID,
              workspaces.contains(where: { $0 === workspace }),
              let columnIndex = workspace.columns.firstIndex(where: { $0 === column }),
              column.windows.count < min(max(capacity ?? rowCapacity, 1), 3) else { return false }
        removeCanonicalDuplicate(of: window)
        let row = min(placement.row, column.windows.count)
        let share = min(max(placement.share, 0.05), 0.95)
        column.heightRatios = column.heightRatios.map { $0 * (1 - share) }
        column.windows.insert(window, at: row)
        column.heightRatios.insert(share, at: row)
        if focus {
            column.activeRow = row
            workspace.activeColumn = columnIndex
            if let index = workspaces.firstIndex(where: { $0 === workspace }) { _ = selectWorkspace(index, rememberPrevious: false) }
        } else if column.activeRow >= row { column.activeRow += 1 }
        column.normalize()
        workspace.scrollOffset = nil
        assertInvariants()
        return true
    }

    init(
        axOperations: AXOperationController,
        emit: @escaping WindowObservationController.EventSink
    ) {
        observation = WindowObservationController(axOperations: axOperations, emit: emit)
    }

    var workspaces: [Workspace] { model.activeContext.workspaces }
    var floatingWindows: [ManagedWindow] { model.activeContext.floatingWindows }
    var activeWorkspace: Int { model.activeContext.activeWorkspace }
    var emptyWorkspaceFocusAuthority: Workspace? { model.emptyWorkspaceFocusAuthority }
    var logicalSpaceContexts: [LogicalSpaceContext] { model.logicalSpaceContexts }
    var activeLogicalSpaceContextID: Int { model.activeLogicalSpaceContextID }
    var pendingLogicalSpaceSwitch: Bool { model.pendingLogicalSpaceSwitch }
    var spaceBufferedWindows: [UInt32: BufferedSpaceWindow] { model.spaceBufferedWindows }
    var fullscreenWindowStates: [PersistentWindowIdentity: FullscreenWindowState] { model.activeContext.fullscreenWindowStates }
    var fullscreenSpaceChangeGuardWorkspace: Int? { model.activeContext.fullscreenSpaceChangeGuardWorkspace }

    var hasKnownWindowState: Bool {
        !model.spaceBufferedWindows.isEmpty || model.logicalSpaceContexts.contains { context in
            context.workspaces.contains { !$0.columns.isEmpty }
                || !context.floatingWindows.isEmpty
                || !context.fullscreenWindowStates.isEmpty
                || !context.minimizedWindowPIDs.isEmpty
        }
    }

    func snapshot() -> WorkspaceModelSnapshot {
        let workspaces = model.activeContext.workspaces
        let activeIndex = min(max(model.activeContext.activeWorkspace, 0), max(workspaces.count - 1, 0))
        return WorkspaceModelSnapshot(
            workspaces: workspaces.map {
                WorkspaceModelSnapshot.WorkspaceSnapshot(
                    columns: $0.columns.map { WorkspaceModelSnapshot.ColumnSnapshot(id: $0.id, windows: $0.windows, activeRow: $0.activeRow, widthRatio: $0.widthRatio, heightRatios: $0.heightRatios) },
                    activeColumn: $0.activeColumn,
                    scrollOffset: $0.scrollOffset,
                    fullscreenState: $0.fullscreenState
                )
            },
            floatingWindows: model.activeContext.floatingWindows,
            activeWorkspace: activeIndex
        )
    }

    func activeWorkspaceObject() -> Workspace? {
        let context = model.activeContext
        guard context.workspaces.indices.contains(context.activeWorkspace) else { return nil }
        return context.workspaces[context.activeWorkspace]
    }

    func activeWindow() -> ManagedWindow? {
        guard let workspace = activeWorkspaceObject(), !workspace.columns.isEmpty else { return nil }
        workspace.clampFocus()
        return workspace.activeWindow
    }

    func allWindows() -> [ManagedWindow] { snapshot().allWindows }
    func tiledWindows() -> [ManagedWindow] { snapshot().tiledWindows }

    func manualBehavior(for element: AXUIElement) -> WindowBehavior? {
        manualWindowOverrides.first { CFEqual($0.window.element, element) }?.behavior
    }

    var manuallyFloatedWindows: [ManagedWindow] {
        floatingWindows.filter { manualBehavior(for: $0.element) == .float }
    }

    func restoreManualWindowState(to window: ManagedWindow) {
        guard let index = manualWindowOverrides.firstIndex(where: { CFEqual($0.window.element, window.element) }) else { return }
        window.manualWidthRatio = manualWindowOverrides[index].window.manualWidthRatio
        manualWindowOverrides[index].window = window
    }

    func forgetManualBehavior(for element: AXUIElement) {
        manualWindowOverrides.removeAll { CFEqual($0.window.element, element) }
    }

    func discardClosedManualWindows(liveWindowIDs: Set<UInt32>) {
        manualWindowOverrides.removeAll { override in
            override.window.windowID.map { !liveWindowIDs.contains($0) } ?? false
        }
    }

    @discardableResult
    func toggleFloating(_ window: ManagedWindow) -> Bool {
        let context = model.activeContext
        let isFloating = context.floatingWindows.contains { $0 === window }
        let source = context.workspaces.enumerated().first { $0.element.windows.contains { $0 === window } }
        guard isFloating || source != nil else { return false }
        var override = manualWindowOverrides.first { CFEqual($0.window.element, window.element) }
            ?? ManualWindowOverride(window: window, behavior: .tile)
        override.window = window

        if let source, let column = source.element.columns.firstIndex(where: { $0.windows.contains { $0 === window } }) {
            override.tiledPlacement = ManualTiledPlacement(
                contextID: context.id,
                workspaceIndex: source.offset,
                columnIndex: column,
                leftNeighbor: column > 0 ? source.element.columns[column - 1].activeWindow?.element : nil,
                rightNeighbor: column + 1 < source.element.columns.count ? source.element.columns[column + 1].activeWindow?.element : nil
            )
            // Floating focus must not leave a different tiled window maximized.
            source.element.fullscreenState = .off
            override.behavior = .float
            _ = insertFloating(window)
        } else {
            override.behavior = .tile
            let placement = override.tiledPlacement.flatMap { $0.contextID == context.id ? $0 : nil }
            let workspaceIndex = placement?.workspaceIndex ?? context.activeWorkspace
            ensureWorkspaceExists(workspaceIndex)
            let workspace = context.workspaces[workspaceIndex]
            var column = placement?.columnIndex ?? (workspace.columns.isEmpty ? 0 : workspace.activeColumn + 1)
            if let right = placement?.rightNeighbor,
               let index = workspace.columns.firstIndex(where: { $0.windows.contains { CFEqual($0.element, right) } }) {
                column = index
            } else if let left = placement?.leftNeighbor,
                      let index = workspace.columns.firstIndex(where: { $0.windows.contains { CFEqual($0.element, left) } }) {
                column = index + 1
            }
            workspace.fullscreenState = .off
            if !restoreRemovedRow(window, focus: true) { _ = insert(window, in: workspace, at: column, focus: true) }
        }

        forgetManualBehavior(for: window.element)
        manualWindowOverrides.append(override)
        return true
    }

    func classifyMissingWindow(_ facts: MissingWindowFacts) -> MissingWindowDisposition {
        if facts.axEnumerationUnavailable, facts.hasCGInfo { return .preserveCGVisible }
        if facts.isFullscreen { return .moveToFullscreenState }
        if facts.pendingFullscreenWithinGrace { return .preservePendingFullscreen }
        if facts.isFullScan,
           facts.runningApplicationExists,
           !facts.temporarilyHidden,
           !facts.behaviorIsIgnored,
           facts.fullscreenGuardActive
        {
            return .preserveFullscreenGuard
        }
        if facts.appearsInUnknownSpace { return .bufferUnknownSpace }
        if !facts.temporarilyHidden, facts.launchRemovalDeferred {
            return .preserveLaunchSettling
        }
        return .remove(rememberMinimized: facts.temporarilyHidden)
    }

    func workspaceProjection(at index: Int) -> Workspace? {
        let workspaces = model.activeContext.workspaces
        guard workspaces.indices.contains(index) else { return nil }
        let source = workspaces[index]
        let projection = Workspace()
        projection.columns = source.columns
        projection.activeColumn = source.activeColumn
        projection.scrollOffset = source.scrollOffset
        projection.fullscreenState = source.fullscreenState
        return projection
    }

    func persistentLayoutSnapshot(
        identity: (ManagedWindow) -> PersistentWindowIdentity,
        widthRatio: (ManagedWindow) -> CGFloat
    ) -> PersistentLayoutSnapshot? {
        let snapshot = snapshot()
        let states = snapshot.workspaces.enumerated().flatMap { workspaceIndex, workspace in
            workspace.columns.enumerated().flatMap { columnIndex, column in
                column.windows.enumerated().map { row, window in
                PersistentWindowState(
                    identity: identity(window),
                    workspace: workspaceIndex,
                    column: columnIndex,
                    manualWidthRatio: window.manualWidthRatio,
                    groupID: column.id,
                    row: row,
                    heightRatio: column.heightRatios[row],
                    columnWidthRatio: column.widthRatio ?? column.windows.first.map(widthRatio),
                    activeRow: column.activeRow
                )
                }
            }
        }
        guard !states.isEmpty else { return nil }
        return PersistentLayoutSnapshot(
            version: 2,
            activeWorkspace: snapshot.activeWorkspace,
            activeColumns: snapshot.workspaces.map(\.activeColumn),
            scrollOffsets: snapshot.workspaces.map(\.scrollOffset),
            focusedWindow: activeWindow().map(identity),
            windows: states
        )
    }

    func persistentLogicalSpaceSnapshot(
        identity: (ManagedWindow) -> PersistentWindowIdentity
    ) -> PersistentLogicalSpaceSnapshot? {
        let validContexts = model.logicalSpaceContexts.filter { $0.id >= 0 }
        guard !validContexts.isEmpty else { return nil }
        let contexts = validContexts.map { context in
            let tiled = context.workspaces.enumerated().flatMap { workspaceIndex, workspace in
                workspace.columns.enumerated().flatMap { columnIndex, column in
                    column.windows.enumerated().map { row, window in
                    PersistentLogicalSpaceWindow(
                        windowID: window.windowID,
                        identity: identity(window),
                        workspace: workspaceIndex,
                        column: columnIndex,
                        manualWidthRatio: window.manualWidthRatio,
                        groupID: column.id,
                        row: row,
                        heightRatio: column.heightRatios[row],
                        columnWidthRatio: column.widthRatio,
                        activeRow: column.activeRow
                    )
                    }
                }
            }
            let floating = context.floatingWindows.enumerated().map { index, window in
                PersistentLogicalSpaceFloatingWindow(
                    windowID: window.windowID,
                    identity: identity(window),
                    index: index
                )
            }
            return PersistentLogicalSpaceContext(
                id: context.id,
                activeWorkspace: context.activeWorkspace,
                activeColumns: context.workspaces.map(\.activeColumn),
                scrollOffsets: context.workspaces.map(\.scrollOffset),
                signatureWindowIDs: Array(context.signature),
                tiledWindows: tiled,
                floatingWindows: floating
            )
        }
        let maxID = contexts.map(\.id).max() ?? 0
        return PersistentLogicalSpaceSnapshot(
            version: 1,
            activeContextID: max(model.activeLogicalSpaceContextID, 0),
            nextContextID: max(model.nextLogicalSpaceContextID, maxID + 1, 0),
            contexts: contexts
        )
    }

    @discardableResult
    func selectWorkspace(_ requestedIndex: Int, rememberPrevious: Bool = true) -> Bool {
        let context = model.activeContext
        let oldIndex = context.activeWorkspace
        guard context.workspaces.indices.contains(requestedIndex), requestedIndex != oldIndex else {
            return false
        }
        let oldWorkspace = context.workspaces[oldIndex]
        model.emptyWorkspaceFocusAuthority = nil
        context.activeWorkspace = requestedIndex
        if rememberPrevious { model.previousWorkspace = oldWorkspace }
        assertInvariants()
        return true
    }

    func previousWorkspaceIndex() -> Int? {
        guard let previous = model.previousWorkspace else { return nil }
        return model.activeContext.workspaces.firstIndex(where: { $0 === previous })
    }

    func protectActiveEmptyWorkspace() -> Bool {
        guard let workspace = activeWorkspaceObject(), workspace.isEmpty else {
            model.emptyWorkspaceFocusAuthority = nil
            return false
        }
        model.emptyWorkspaceFocusAuthority = workspace
        return true
    }

    var activeEmptyWorkspaceHasFocusAuthority: Bool {
        guard let authority = model.emptyWorkspaceFocusAuthority,
              authority.isEmpty,
              activeWorkspaceObject() === authority else { return false }
        return true
    }

    func ensureWorkspaceExists(_ index: Int) {
        guard index >= 0 else { return }
        let context = model.activeContext
        while context.workspaces.count <= index { context.workspaces.append(Workspace()) }
    }

    func reconcileWorkspaceCapacity(minimumCount: Int) {
        let context = model.activeContext
        if context.workspaces.isEmpty {
            context.workspaces = [Workspace()]
            context.activeWorkspace = 0
            model.previousWorkspace = nil
            model.emptyWorkspaceFocusAuthority = nil
        }
        ensureWorkspaceExists(max(minimumCount, 1) - 1)
        let highestOccupiedIndex = context.workspaces.lastIndex(where: { !$0.isEmpty }) ?? 0
        let requiredLastIndex = max(max(minimumCount, 1) - 1, highestOccupiedIndex, context.activeWorkspace)
        while context.workspaces.count - 1 > requiredLastIndex, context.workspaces.last?.isEmpty == true {
            context.workspaces.removeLast()
        }
        context.activeWorkspace = min(max(context.activeWorkspace, 0), context.workspaces.count - 1)
        context.workspaces.forEach { $0.clampFocus() }
        assertInvariants()
    }

    func insert(
        _ window: ManagedWindow,
        in workspace: Workspace,
        at requestedIndex: Int,
        focus: Bool
    ) -> Int {
        removeCanonicalDuplicate(of: window)
        let index = min(max(requestedIndex, 0), workspace.columns.count)
        workspace.columns.insert(Column(windows: [window]), at: index)
        if focus {
            workspace.activeColumn = index
        } else if workspace.columns.count > 1, workspace.activeColumn >= index {
            workspace.activeColumn += 1
        }
        workspace.scrollOffset = nil
        if model.emptyWorkspaceFocusAuthority === workspace { model.emptyWorkspaceFocusAuthority = nil }
        if focus, let workspaceIndex = model.activeContext.workspaces.firstIndex(where: { $0 === workspace }) {
            _ = selectWorkspace(workspaceIndex, rememberPrevious: false)
        }
        assertInvariants()
        return index
    }

    private func removeCanonicalDuplicate(of window: ManagedWindow) {
        let id = ObjectIdentifier(window)
        for context in model.logicalSpaceContexts {
            for workspace in context.workspaces {
                for column in workspace.columns {
                    for matching in column.windows.filter({ ObjectIdentifier($0) == id }) {
                        rememberRowPlacement(matching, context: context, workspace: workspace, column: column)
                        column.remove(matching)
                    }
                }
                workspace.columns.removeAll { $0.windows.isEmpty }
                workspace.clampFocus()
            }
            context.floatingWindows.removeAll { ObjectIdentifier($0) == id }
        }
        if let windowID = window.windowID {
            model.spaceBufferedWindows.removeValue(forKey: windowID)
        }
    }

    func insertFloating(_ window: ManagedWindow) -> Bool {
        if model.activeContext.floatingWindows.contains(where: { $0 === window }) { return false }
        removeCanonicalDuplicate(of: window)
        model.activeContext.floatingWindows.append(window)
        assertInvariants()
        return true
    }

    func remove(_ window: ManagedWindow, preferRightFocus: Bool = false) {
        let context = model.activeContext
        if let index = context.floatingWindows.firstIndex(where: { $0 === window }) {
            context.floatingWindows.remove(at: index)
            assertInvariants()
            return
        }
        for workspace in context.workspaces {
            guard let index = workspace.columns.firstIndex(where: { $0.windows.contains { $0 === window } }) else { continue }
            let column = workspace.columns[index]
            rememberRowPlacement(window, context: context, workspace: workspace, column: column)
            column.remove(window)
            if !column.windows.isEmpty { workspace.clampFocus(); assertInvariants(); return }
            let wasActive = workspace.activeColumn == index
            workspace.columns.remove(at: index)
            if wasActive && preferRightFocus {
                workspace.activeColumn = min(index, max(0, workspace.columns.count - 1))
            } else if workspace.activeColumn >= index {
                workspace.activeColumn = max(0, workspace.activeColumn - 1)
            }
            workspace.scrollOffset = nil
            workspace.clampFocus()
            assertInvariants()
            return
        }
    }

    func moveActiveColumn(to requestedIndex: Int) -> Bool {
        guard let workspace = activeWorkspaceObject(), !workspace.columns.isEmpty else { return false }
        workspace.clampFocus()
        let sourceIndex = workspace.activeColumn
        let targetIndex = min(max(requestedIndex, 0), workspace.columns.count - 1)
        guard sourceIndex != targetIndex else { return false }
        let window = workspace.columns.remove(at: sourceIndex)
        workspace.columns.insert(window, at: targetIndex)
        workspace.activeColumn = targetIndex
        workspace.scrollOffset = nil
        assertInvariants()
        return true
    }

    @discardableResult
    func swapWindows(_ source: ManagedWindow, with target: ManagedWindow, in workspace: Workspace) -> Bool {
        guard model.activeContext.workspaces.contains(where: { $0 === workspace }),
              source !== target,
              let sourceIndex = workspace.columns.firstIndex(where: { $0.windows.contains { $0 === source } }),
              let targetIndex = workspace.columns.firstIndex(where: { $0.windows.contains { $0 === target } })
        else { return false }
        let sourceColumn = workspace.columns[sourceIndex]
        let targetColumn = workspace.columns[targetIndex]
        if sourceColumn === targetColumn {
            let sourceRow = sourceColumn.windows.firstIndex { $0 === source }!
            let targetRow = sourceColumn.windows.firstIndex { $0 === target }!
            sourceColumn.windows.swapAt(sourceRow, targetRow)
            sourceColumn.heightRatios.swapAt(sourceRow, targetRow)
            sourceColumn.activeRow = targetRow
            workspace.activeColumn = targetIndex
            assertInvariants()
            return true
        }
        if sourceColumn.windows.count == 1 && targetColumn.windows.count == 1 {
            workspace.columns.swapAt(sourceIndex, targetIndex)
            workspace.activeColumn = targetIndex
            assertInvariants()
            return true
        }
        let sourceRow = sourceColumn.windows.firstIndex { $0 === source }!
        let targetRow = targetColumn.windows.firstIndex { $0 === target }!
        sourceColumn.windows[sourceRow] = target
        targetColumn.windows[targetRow] = source
        if sourceColumn.windows.count == 1 { sourceColumn.widthRatio = target.manualWidthRatio }
        if targetColumn.windows.count == 1 { targetColumn.widthRatio = source.manualWidthRatio }
        targetColumn.activeRow = targetRow
        workspace.activeColumn = targetIndex
        assertInvariants()
        return true
    }

    func focusColumn(at requestedIndex: Int) -> (changed: Bool, source: Int, target: Int) {
        guard let workspace = activeWorkspaceObject(), !workspace.columns.isEmpty else {
            return (false, 0, 0)
        }
        workspace.clampFocus()
        let source = workspace.activeColumn
        let target = min(max(requestedIndex, 0), workspace.columns.count - 1)
        workspace.activeColumn = target
        workspace.scrollOffset = nil
        assertInvariants()
        return (source != target, source, target)
    }

    func resetAllScrollOffsets() {
        model.activeContext.workspaces.forEach { $0.scrollOffset = nil }
    }

    @discardableResult
    func focusRow(by delta: Int) -> Bool {
        guard let workspace = activeWorkspaceObject(), workspace.fullscreenState == .off,
              workspace.columns.indices.contains(workspace.activeColumn) else { return false }
        let column = workspace.columns[workspace.activeColumn]
        let target = column.activeRow + delta
        guard column.windows.indices.contains(target) else { return false }
        column.activeRow = target
        return true
    }

    @discardableResult
    func moveActiveRow(by delta: Int) -> Bool {
        guard let workspace = activeWorkspaceObject(), workspace.fullscreenState == .off,
              workspace.columns.indices.contains(workspace.activeColumn) else { return false }
        let column = workspace.columns[workspace.activeColumn]
        let target = column.activeRow + delta
        guard column.windows.indices.contains(target) else { return false }
        column.windows.swapAt(column.activeRow, target)
        column.heightRatios.swapAt(column.activeRow, target)
        column.activeRow = target
        return true
    }

    @discardableResult
    func moveActiveWindowHorizontally(by delta: Int, capacity: Int) -> Bool {
        guard delta != 0, let workspace = activeWorkspaceObject(), workspace.fullscreenState == .off,
              let window = workspace.activeWindow else { return false }
        let sourceIndex = workspace.activeColumn
        let source = workspace.columns[sourceIndex]
        let direction = delta < 0 ? -1 : 1
        let neighborIndex = sourceIndex + direction
        let neighbor = workspace.columns.indices.contains(neighborIndex) ? workspace.columns[neighborIndex] : nil
        if neighbor == nil && source.windows.count == 1 { return false }
        source.remove(window)
        if let neighbor, neighbor.windows.count < min(max(capacity, 1), 3) {
            if neighbor.widthRatio == nil { neighbor.widthRatio = neighbor.windows.first?.manualWidthRatio }
            neighbor.append(window)
            if source.windows.isEmpty { workspace.columns.remove(at: sourceIndex) }
            workspace.activeColumn = workspace.columns.firstIndex { $0 === neighbor }!
        } else {
            if source.windows.isEmpty { workspace.columns.remove(at: sourceIndex) }
            let insertion: Int
            if let neighbor, let index = workspace.columns.firstIndex(where: { $0 === neighbor }) {
                insertion = index + (direction > 0 ? 1 : 0)
            } else { insertion = direction > 0 ? workspace.columns.count : 0 }
            workspace.columns.insert(Column(windows: [window]), at: insertion)
            workspace.activeColumn = insertion
        }
        workspace.scrollOffset = nil
        workspace.clampFocus()
        assertInvariants()
        return true
    }

    @discardableResult
    func moveActiveWindow(toWorkspace requestedIndex: Int) -> Bool {
        guard requestedIndex >= 0, requestedIndex != activeWorkspace,
              let source = activeWorkspaceObject(), let window = source.activeWindow else { return false }
        ensureWorkspaceExists(requestedIndex)
        remove(window, preferRightFocus: true)
        let target = workspaces[requestedIndex]
        _ = insert(window, in: target, at: target.isEmpty ? 0 : target.activeColumn + 1, focus: false)
        target.activeColumn = target.columns.firstIndex { $0.windows.contains { $0 === window } } ?? 0
        _ = selectWorkspace(requestedIndex)
        assertInvariants()
        return true
    }

    func enforceRowCapacity(_ capacity: Int) {
        let capacity = min(max(capacity, 1), 3)
        rowCapacity = capacity
        for context in logicalSpaceContexts {
            for workspace in context.workspaces {
                guard workspace.columns.contains(where: { $0.windows.count > capacity }) else { continue }
                let focused = workspace.activeWindow
                var rebuilt: [Column] = []
                for column in workspace.columns {
                    let excess = Array(column.windows.dropFirst(capacity))
                    excess.forEach { column.remove($0) }
                    rebuilt.append(column)
                    rebuilt.append(contentsOf: excess.map { Column(windows: [$0]) })
                }
                workspace.columns = rebuilt
                if let focused, let index = rebuilt.firstIndex(where: { $0.windows.contains { $0 === focused } }) {
                    workspace.activeColumn = index
                    rebuilt[index].activeRow = rebuilt[index].windows.firstIndex { $0 === focused } ?? 0
                }
                workspace.clampFocus()
                workspace.scrollOffset = nil
            }
        }
        assertInvariants()
    }

    @discardableResult
    func enforceRowHeights(height: CGFloat, gap: CGFloat) -> Bool {
        var changed = false
        for workspace in workspaces {
            let focused = workspace.activeWindow
            var rebuilt: [Column] = []
            for column in workspace.columns {
                var detached: [ManagedWindow] = []
                while column.windows.count > 1,
                      column.windows.reduce(0, { $0 + $1.minimumHeight }) > height - gap * CGFloat(column.windows.count - 1) {
                    let window = column.windows.last!
                    column.remove(window)
                    detached.insert(window, at: 0)
                }
                let usable = max(1, height - gap * CGFloat(column.windows.count - 1))
                let previous = column.heightRatios
                if column.windows.count > 1 {
                    column.fitHeightRatios(minimums: column.windows.map { $0.minimumHeight / usable })
                }
                changed = changed || !detached.isEmpty || zip(previous, column.heightRatios).contains { abs($0 - $1) > 0.0001 }
                rebuilt.append(column)
                rebuilt.append(contentsOf: detached.map { Column(windows: [$0]) })
            }
            if rebuilt.count != workspace.columns.count {
                workspace.columns = rebuilt
                workspace.scrollOffset = nil
                if let focused, let index = rebuilt.firstIndex(where: { $0.windows.contains { $0 === focused } }) {
                    workspace.activeColumn = index
                    rebuilt[index].activeRow = rebuilt[index].windows.firstIndex { $0 === focused } ?? 0
                }
            }
        }
        assertInvariants()
        return changed
    }

    func setWidthRatio(_ ratio: CGFloat?, for window: ManagedWindow) {
        if let column = logicalSpaceContexts.flatMap(\.workspaces).flatMap(\.columns).first(where: { $0.windows.contains { $0 === window } }) {
            column.widthRatio = ratio
            if column.windows.count == 1 { window.manualWidthRatio = ratio }
        } else { window.manualWidthRatio = ratio }
    }

    func setActiveColumn(_ index: Int, in workspace: Workspace) {
        workspace.activeColumn = workspace.columns.isEmpty
            ? 0
            : min(max(index, 0), workspace.columns.count - 1)
        assertInvariants()
    }

    func setScrollOffset(_ offset: CGFloat?, in workspace: Workspace) {
        workspace.scrollOffset = offset
    }

    @discardableResult
    func toggleWorkspaceFullscreen() -> Bool {
        guard let workspace = activeWorkspaceObject(), !workspace.isEmpty else { return false }
        workspace.fullscreenState = workspace.fullscreenState == .off ? .active : .off
        return true
    }

    @discardableResult
    func suspendWorkspaceFullscreen() -> Bool {
        guard let workspace = activeWorkspaceObject(), workspace.fullscreenState == .active else { return false }
        workspace.fullscreenState = .suspended
        return true
    }

    @discardableResult
    func resumeWorkspaceFullscreen(in target: Workspace) -> Bool {
        let source = activeWorkspaceObject()
        let previousState = target.fullscreenState
        if let source, source !== target, source.fullscreenState != .off {
            source.fullscreenState = .off
            target.fullscreenState = .active
            return true
        }
        if target.fullscreenState == .suspended {
            target.fullscreenState = .active
        }
        return previousState != target.fullscreenState
    }

    func removeWindowID(_ windowID: UInt32, from context: LogicalSpaceContext) {
        context.floatingWindows.removeAll { $0.windowID == windowID }
        for workspace in context.workspaces {
            for column in workspace.columns { column.windows.filter { $0.windowID == windowID }.forEach { column.remove($0) } }
            workspace.columns.removeAll { $0.windows.isEmpty }
            workspace.clampFocus()
            workspace.scrollOffset = nil
        }
        context.signature.remove(windowID)
        assertInvariants()
    }

    func beginLogicalSpaceSwitch() { model.pendingLogicalSpaceSwitch = true }

    func consumePendingLogicalSpaceSwitch() -> Bool {
        guard model.pendingLogicalSpaceSwitch else { return false }
        model.pendingLogicalSpaceSwitch = false
        return true
    }

    func buffer(_ buffered: BufferedSpaceWindow, windowID: UInt32) {
        model.spaceBufferedWindows[windowID] = buffered
    }

    func takeBufferedWindow(windowID: UInt32) -> BufferedSpaceWindow? {
        model.spaceBufferedWindows.removeValue(forKey: windowID)
    }

    func pendingFullscreenTransition(for id: ObjectIdentifier) -> CFAbsoluteTime? {
        model.activeContext.pendingFullscreenTransitionSince[id]
    }

    func recordPendingFullscreenTransition(for id: ObjectIdentifier, at time: CFAbsoluteTime) {
        model.activeContext.pendingFullscreenTransitionSince[id] = time
    }

    func clearPendingFullscreenTransition(for id: ObjectIdentifier) {
        model.activeContext.pendingFullscreenTransitionSince.removeValue(forKey: id)
    }

    func setFullscreenSpaceChangeGuardWorkspace(_ index: Int?) {
        model.activeContext.fullscreenSpaceChangeGuardWorkspace = index
    }

    func rememberFullscreenState(_ state: FullscreenWindowState) {
        model.activeContext.fullscreenWindowStates[state.identity] = state
    }

    func takeFullscreenState(
        matching predicate: (PersistentWindowIdentity, FullscreenWindowState) -> Bool
    ) -> FullscreenWindowState? {
        guard let match = model.activeContext.fullscreenWindowStates.first(where: { predicate($0.key, $0.value) }) else {
            return nil
        }
        model.activeContext.fullscreenWindowStates.removeValue(forKey: match.key)
        return match.value
    }

    func rememberMinimizedState(_ state: PersistentWindowState, pid: pid_t) {
        model.activeContext.minimizedWindowStates[state.identity] = state
        model.activeContext.minimizedWindowPIDs[state.identity] = pid
    }

    func takeMinimizedState(identity: PersistentWindowIdentity) -> PersistentWindowState? {
        model.activeContext.minimizedWindowPIDs.removeValue(forKey: identity)
        return model.activeContext.minimizedWindowStates.removeValue(forKey: identity)
    }

    func moveActiveColumn(toWorkspace requestedIndex: Int) -> Bool {
        guard requestedIndex >= 0,
              let source = activeWorkspaceObject(),
              !source.columns.isEmpty else { return false }
        ensureWorkspaceExists(requestedIndex)
        let context = model.activeContext
        guard requestedIndex != context.activeWorkspace else { return false }
        source.clampFocus()
        let target = context.workspaces[requestedIndex]
        let window = source.columns.remove(at: source.activeColumn)
        source.scrollOffset = nil
        source.clampFocus()
        target.clampFocus()
        let insertionIndex = target.columns.isEmpty ? 0 : min(target.activeColumn + 1, target.columns.count)
        target.columns.insert(window, at: insertionIndex)
        target.activeColumn = insertionIndex
        target.scrollOffset = nil
        _ = selectWorkspace(requestedIndex)
        assertInvariants()
        return true
    }

    func replaceActiveProjection(workspaces: [Workspace], activeWorkspace: Int, floatingWindows: [ManagedWindow]? = nil) {
        let context = model.activeContext
        context.workspaces = workspaces.isEmpty ? [Workspace()] : workspaces
        context.activeWorkspace = min(max(activeWorkspace, 0), context.workspaces.count - 1)
        if let floatingWindows { context.floatingWindows = floatingWindows }
        model.previousWorkspace = nil
        model.emptyWorkspaceFocusAuthority = nil
        assertInvariants()
    }

    func activateContext(_ context: LogicalSpaceContext) {
        if !model.logicalSpaceContexts.contains(where: { $0 === context }) {
            model.logicalSpaceContexts.removeAll { $0.id == context.id }
            model.logicalSpaceContexts.append(context)
        }
        model.activeLogicalSpaceContextID = context.id
        context.activeWorkspace = min(max(context.activeWorkspace, 0), max(context.workspaces.count - 1, 0))
        model.previousWorkspace = nil
        model.emptyWorkspaceFocusAuthority = nil
        assertInvariants()
    }

    func saveActiveContext(signature: Set<UInt32>) {
        model.activeContext.signature = signature
        assertInvariants()
    }

    func appendContext(_ context: LogicalSpaceContext) {
        model.logicalSpaceContexts.removeAll { $0.id == context.id }
        model.logicalSpaceContexts.append(context)
        model.nextLogicalSpaceContextID = max(model.nextLogicalSpaceContextID, context.id + 1, 0)
        assertInvariants()
    }

    func makeContext(signature: Set<UInt32>) -> LogicalSpaceContext {
        let id = max(model.nextLogicalSpaceContextID, 0)
        model.nextLogicalSpaceContextID = id + 1
        let context = LogicalSpaceContext(id: id, signature: signature)
        model.logicalSpaceContexts.append(context)
        assertInvariants()
        return context
    }

    func replaceContexts(_ contexts: [LogicalSpaceContext], activeID: Int, nextID: Int) {
        model.logicalSpaceContexts = contexts.isEmpty ? [LogicalSpaceContext(id: max(activeID, 0))] : contexts
        model.activeLogicalSpaceContextID = model.logicalSpaceContexts.contains(where: { $0.id == activeID })
            ? activeID
            : model.logicalSpaceContexts[0].id
        model.nextLogicalSpaceContextID = max(nextID, (model.logicalSpaceContexts.map(\.id).max() ?? 0) + 1, 0)
        model.previousWorkspace = nil
        model.emptyWorkspaceFocusAuthority = nil
        assertInvariants()
    }

    @discardableResult
    func removeGlobally(pid: pid_t) -> GlobalWindowCleanupResult {
        manualWindowOverrides.removeAll { $0.window.pid == pid }
        var removed: [ManagedWindow] = []
        var seen = Set<ObjectIdentifier>()
        var changed = false
        for context in model.logicalSpaceContexts {
            for workspace in context.workspaces {
                let matches = workspace.windows.filter { $0.pid == pid }
                changed = changed || !matches.isEmpty
                for window in matches where seen.insert(ObjectIdentifier(window)).inserted { removed.append(window) }
                for column in workspace.columns { matches.forEach { column.remove($0) } }
                workspace.columns.removeAll { $0.windows.isEmpty }
                workspace.clampFocus()
                workspace.scrollOffset = nil
            }
            let matches = context.floatingWindows.filter { $0.pid == pid }
            changed = changed || !matches.isEmpty
            for window in matches where seen.insert(ObjectIdentifier(window)).inserted { removed.append(window) }
            context.floatingWindows.removeAll { $0.pid == pid }
            context.signature.subtract(removed.compactMap(\.windowID))
        }
        let buffered = model.spaceBufferedWindows.values.filter { $0.window.pid == pid }.map(\.window)
        for window in buffered where seen.insert(ObjectIdentifier(window)).inserted { removed.append(window) }
        changed = changed || !buffered.isEmpty
        model.spaceBufferedWindows = model.spaceBufferedWindows.filter { $0.value.window.pid != pid }
        for context in model.logicalSpaceContexts {
            let fullscreenCount = context.fullscreenWindowStates.count
            let minimizedCount = context.minimizedWindowStates.count
            context.fullscreenWindowStates = context.fullscreenWindowStates.filter { $0.value.pid != pid }
            let terminatedMinimizedIdentities = Set(
                context.minimizedWindowPIDs.compactMap { identity, trackedPID in
                    trackedPID == pid ? identity : nil
                }
            )
            context.minimizedWindowStates = context.minimizedWindowStates.filter {
                !terminatedMinimizedIdentities.contains($0.key)
            }
            context.minimizedWindowPIDs = context.minimizedWindowPIDs.filter { $0.value != pid }
            changed = changed || context.fullscreenWindowStates.count != fullscreenCount
                || context.minimizedWindowStates.count != minimizedCount
            for window in removed { context.pendingFullscreenTransitionSince.removeValue(forKey: ObjectIdentifier(window)) }
        }
        assertInvariants()
        return GlobalWindowCleanupResult(removedWindows: removed, changed: changed)
    }

    func assertInvariants() {
#if DEBUG
        let contexts = model.logicalSpaceContexts
        assert(!contexts.isEmpty, "WorkspaceModel must retain at least one logical Space")
        assert(Set(contexts.map(\.id)).count == contexts.count, "Logical Space IDs must be unique")
        assert(contexts.contains(where: { $0.id == model.activeLogicalSpaceContextID }), "Active logical Space must exist")
        var globalMembership: [ObjectIdentifier: (contextID: Int, windowID: UInt32?)] = [:]
        for context in contexts {
            assert(!context.workspaces.isEmpty, "Every logical Space must retain a workspace")
            assert(context.workspaces.indices.contains(context.activeWorkspace), "Active workspace index must be valid")
            var contextMembership = Set<ObjectIdentifier>()
            for workspace in context.workspaces {
                assert(workspace.columns.isEmpty ? workspace.activeColumn == 0 : workspace.columns.indices.contains(workspace.activeColumn), "Active column index must be valid")
                for column in workspace.columns {
                    assert(!column.windows.isEmpty && column.windows.indices.contains(column.activeRow), "Every column must have a focused row")
                    assert(column.heightRatios.count == column.windows.count, "Every row must have a height share")
                    assert(abs(column.heightRatios.reduce(0, +) - 1) < 0.0001, "Height shares must be normalized")
                }
                for window in workspace.windows {
                    assert(contextMembership.insert(ObjectIdentifier(window)).inserted, "A window cannot occupy two placements in one logical Space")
                }
            }
            for window in context.floatingWindows {
                assert(contextMembership.insert(ObjectIdentifier(window)).inserted, "A tiled window cannot also float")
            }
            for id in contextMembership {
                let windowID = context.workspaces.lazy.flatMap(\.windows).first(where: { ObjectIdentifier($0) == id })?.windowID
                    ?? context.floatingWindows.first(where: { ObjectIdentifier($0) == id })?.windowID
                if let previous = globalMembership[id] {
                    let isBufferedTransition = (previous.windowID.map { model.spaceBufferedWindows[$0] != nil } ?? false)
                        || (windowID.map { model.spaceBufferedWindows[$0] != nil } ?? false)
                    if !isBufferedTransition {
                        assertionFailure("A window cannot belong to logical Spaces \(previous.contextID) and \(context.id)")
                    }
                }
                globalMembership[id] = (context.id, windowID)
            }
        }
#endif
    }

    func setNextLogicalSpaceContextID(_ value: Int) { model.nextLogicalSpaceContextID = max(value, 0) }
}
