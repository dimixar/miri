import CoreGraphics
import Darwin
import Foundation

struct WorkspaceModelSnapshot {
    struct WorkspaceSnapshot {
        let columns: [ManagedWindow]
        let activeColumn: Int
        let scrollOffset: CGFloat?
    }

    let workspaces: [WorkspaceSnapshot]
    let floatingWindows: [ManagedWindow]
    let activeWorkspace: Int

    var layoutState: LayoutState {
        LayoutState(
            activeWorkspace: activeWorkspace,
            activeColumns: workspaces.map(\.activeColumn),
            scrollOffsets: workspaces.map(\.scrollOffset)
        )
    }

    var tiledWindows: [ManagedWindow] {
        workspaces.flatMap(\.columns)
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

    func snapshot() -> WorkspaceModelSnapshot {
        let workspaces = model.activeContext.workspaces
        let activeIndex = min(max(model.activeContext.activeWorkspace, 0), max(workspaces.count - 1, 0))
        return WorkspaceModelSnapshot(
            workspaces: workspaces.map {
                WorkspaceModelSnapshot.WorkspaceSnapshot(
                    columns: $0.columns,
                    activeColumn: $0.activeColumn,
                    scrollOffset: $0.scrollOffset
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
        return workspace.columns[workspace.activeColumn]
    }

    func allWindows() -> [ManagedWindow] { snapshot().allWindows }
    func tiledWindows() -> [ManagedWindow] { snapshot().tiledWindows }

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
        return projection
    }

    func persistentLayoutSnapshot(
        identity: (ManagedWindow) -> PersistentWindowIdentity,
        widthRatio: (ManagedWindow) -> CGFloat
    ) -> PersistentLayoutSnapshot? {
        let snapshot = snapshot()
        let states = snapshot.workspaces.enumerated().flatMap { workspaceIndex, workspace in
            workspace.columns.enumerated().map { columnIndex, window in
                PersistentWindowState(
                    identity: identity(window),
                    workspace: workspaceIndex,
                    column: columnIndex,
                    manualWidthRatio: widthRatio(window)
                )
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
                workspace.columns.enumerated().map { columnIndex, window in
                    PersistentLogicalSpaceWindow(
                        windowID: window.windowID,
                        identity: identity(window),
                        workspace: workspaceIndex,
                        column: columnIndex,
                        manualWidthRatio: window.manualWidthRatio
                    )
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
        workspace.columns.insert(window, at: index)
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
                workspace.columns.removeAll { ObjectIdentifier($0) == id }
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
            guard let index = workspace.columns.firstIndex(where: { $0 === window }) else { continue }
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

    func setWidthRatio(_ ratio: CGFloat?, for window: ManagedWindow) {
        window.manualWidthRatio = ratio
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

    func removeWindowID(_ windowID: UInt32, from context: LogicalSpaceContext) {
        context.floatingWindows.removeAll { $0.windowID == windowID }
        for workspace in context.workspaces {
            workspace.columns.removeAll { $0.windowID == windowID }
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
        var removed: [ManagedWindow] = []
        var seen = Set<ObjectIdentifier>()
        var changed = false
        for context in model.logicalSpaceContexts {
            for workspace in context.workspaces {
                let matches = workspace.columns.filter { $0.pid == pid }
                changed = changed || !matches.isEmpty
                for window in matches where seen.insert(ObjectIdentifier(window)).inserted { removed.append(window) }
                workspace.columns.removeAll { $0.pid == pid }
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
                for window in workspace.columns {
                    assert(contextMembership.insert(ObjectIdentifier(window)).inserted, "A window cannot occupy two placements in one logical Space")
                }
            }
            for window in context.floatingWindows {
                assert(contextMembership.insert(ObjectIdentifier(window)).inserted, "A tiled window cannot also float")
            }
            for id in contextMembership {
                let windowID = context.workspaces.lazy.flatMap(\.columns).first(where: { ObjectIdentifier($0) == id })?.windowID
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
