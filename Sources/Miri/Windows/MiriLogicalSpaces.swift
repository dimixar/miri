import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

extension Miri {
    func saveActiveLogicalSpaceContext() {
        guard let context = logicalSpaceContexts.first(where: { $0.id == activeLogicalSpaceContextID }) else {
            return
        }
        context.workspaces = cloneWorkspaces(workspaces)
        context.floatingWindows = floatingWindows
        context.activeWorkspace = activeWorkspace
        context.signature = currentLogicalSpaceSignature()
    }

    func loadLogicalSpaceContext(_ context: LogicalSpaceContext) {
        activeLogicalSpaceContextID = context.id
        workspaces = cloneWorkspaces(context.workspaces)
        floatingWindows = context.floatingWindows
        activeWorkspace = min(max(context.activeWorkspace, 0), max(workspaces.count - 1, 0))
        previousWorkspace = nil
        appliedFrames.removeAll()
        appliedVisibility.removeAll()
        hiddenWorkspaceWindowIDs.removeAll()
        ensureTrailingEmptyWorkspace()
    }

    func cloneWorkspaces(_ source: [Workspace]) -> [Workspace] {
        source.map { workspace in
            let clone = Workspace()
            clone.columns = workspace.columns
            clone.activeColumn = workspace.activeColumn
            clone.scrollOffset = workspace.scrollOffset
            return clone
        }
    }

    func currentLogicalSpaceSignature() -> Set<UInt32> {
        Set(allWindows().compactMap(\.windowID))
    }

    func discoveredSignature(_ discovered: [ManagedWindow]) -> Set<UInt32> {
        Set(discovered.compactMap(\.windowID))
    }

    func handlePendingLogicalSpaceSwitch(discovered: [ManagedWindow]) -> Bool {
        guard pendingLogicalSpaceSwitch else {
            return false
        }
        pendingLogicalSpaceSwitch = false

        let visibleSignature = discoveredSignature(discovered)
        let bufferedVisibleIDs = visibleSignature.intersection(Set(spaceBufferedWindows.keys))
        let context = bestLogicalSpaceContext(for: visibleSignature, bufferedVisibleIDs: bufferedVisibleIDs, discovered: discovered)
        loadLogicalSpaceContext(context)
        debugLog(
            "logical macOS space activated id=\(context.id) visible=\(visibleSignature.count) buffered=\(bufferedVisibleIDs.count) known=\(context.signature.count)"
        )
        return true
    }

    func bestLogicalSpaceContext(
        for visibleSignature: Set<UInt32>,
        bufferedVisibleIDs: Set<UInt32>,
        discovered: [ManagedWindow]
    ) -> LogicalSpaceContext {
        if visibleSignature.isEmpty,
           let empty = logicalSpaceContexts.first(where: { $0.signature.isEmpty && $0.id != activeLogicalSpaceContextID })
        {
            return empty
        }

        let anchorSignature = visibleSignature.subtracting(bufferedVisibleIDs)
        if let match = bestLogicalSpaceContextMatching(anchorSignature) {
            return match
        }
        if bufferedVisibleIDs.isEmpty, let match = bestLogicalSpaceContextMatching(visibleSignature) {
            return match
        }
        if let promoted = promotePendingPersistentLogicalSpaceContext(for: visibleSignature, discovered: discovered) {
            return promoted
        }

        nextLogicalSpaceContextID = max(nextLogicalSpaceContextID, 0)
        let context = LogicalSpaceContext(id: nextLogicalSpaceContextID, signature: visibleSignature)
        nextLogicalSpaceContextID += 1
        logicalSpaceContexts.append(context)
        debugLog(
            "logical macOS space created id=\(context.id) visible=\(visibleSignature.count) buffered=\(bufferedVisibleIDs.count)"
        )
        return context
    }

    func bestLogicalSpaceContextMatching(_ signature: Set<UInt32>) -> LogicalSpaceContext? {
        guard !signature.isEmpty else {
            return nil
        }
        var best: (context: LogicalSpaceContext, score: Int)?
        for context in logicalSpaceContexts {
            let score = context.signature.intersection(signature).count
            if score > 0, best == nil || score > best!.score {
                best = (context, score)
            }
        }
        return best?.context
    }

    func likelyFullscreenExitSettle(discovered: [ManagedWindow]) -> Bool {
        guard discoveredSignature(discovered).isEmpty,
              !fullscreenWindowStates.isEmpty
        else {
            return false
        }
        let now = CFAbsoluteTimeGetCurrent()
        return fullscreenSpaceChangeGuardIsActive() || now < fullscreenTransitionGuardUntil
    }

    func likelyBulkTransientDisappearance(discovered: [ManagedWindow]) -> Bool {
        let existing = allWindows().filter { $0.windowID != nil }
        guard existing.count >= 3 else {
            return false
        }
        let discoveredIDs = discoveredSignature(discovered)
        let missing = existing.filter { window in
            guard let windowID = window.windowID else {
                return false
            }
            return !discoveredIDs.contains(windowID)
        }
        guard missing.count >= 3 || Double(missing.count) / Double(existing.count) >= 0.5 else {
            return false
        }
        let transientMissing = missing.filter { window in
            guard let windowID = window.windowID,
                  let runningApp = NSRunningApplication(processIdentifier: window.pid)
            else {
                return false
            }
            return !runningApp.isHidden
                && !isHiddenOrMinimizedWindow(window.element)
                && cgWindowExists(windowID)
                && !cgWindowIsOnScreen(windowID)
        }
        return transientMissing.count == missing.count
    }

    func bufferWindowInUnknownSpaceIfNeeded(_ window: ManagedWindow) -> Bool {
        guard let windowID = window.windowID,
              let runningApp = NSRunningApplication(processIdentifier: window.pid),
              !runningApp.isHidden,
              !isHiddenOrMinimizedWindow(window.element),
              cgWindowExists(windowID),
              !cgWindowIsOnScreen(windowID)
        else {
            return false
        }

        let placement = currentPlacement(for: window)
        spaceBufferedWindows[windowID] = BufferedSpaceWindow(
            window: window,
            sourceContextID: activeLogicalSpaceContextID,
            sourceWorkspace: placement.workspace,
            sourceColumn: placement.column,
            sourceFloatingIndex: placement.floatingIndex,
            bufferedAt: CFAbsoluteTimeGetCurrent()
        )
        debugLog(
            "buffering window in unknown macOS space app='\(window.appName)' bundle='\(window.bundleID ?? "nil")' title='\(window.title)' id=\(windowID) sourceContext=\(activeLogicalSpaceContextID)"
        )
        removeWindow(window, preferRightFocus: true)
        return true
    }

    func currentPlacement(for window: ManagedWindow) -> (workspace: Int?, column: Int?, floatingIndex: Int?) {
        if let floatingIndex = floatingWindows.firstIndex(where: { $0 === window }) {
            return (nil, nil, floatingIndex)
        }
        if let location = tiledWindowLocation(for: window.element) {
            return (location.workspaceIndex, location.columnIndex, nil)
        }
        return (nil, nil, nil)
    }

    @discardableResult
    func consumeBufferedWindowIfNeeded(_ window: ManagedWindow) -> BufferedSpaceWindow? {
        guard let windowID = window.windowID,
              let buffered = spaceBufferedWindows.removeValue(forKey: windowID)
        else {
            return nil
        }
        if buffered.sourceContextID != activeLogicalSpaceContextID,
           let source = logicalSpaceContexts.first(where: { $0.id == buffered.sourceContextID })
        {
            removeWindowID(windowID, from: source)
        }
        debugLog(
            "restoring buffered window into logical macOS space id=\(activeLogicalSpaceContextID) sourceContext=\(buffered.sourceContextID) app='\(window.appName)' bundle='\(window.bundleID ?? "nil")' title='\(window.title)' id=\(windowID)"
        )
        return buffered
    }

    func removeWindowID(_ windowID: UInt32, from context: LogicalSpaceContext) {
        if let index = context.floatingWindows.firstIndex(where: { $0.windowID == windowID }) {
            context.floatingWindows.remove(at: index)
        }
        for workspace in context.workspaces {
            if let index = workspace.columns.firstIndex(where: { $0.windowID == windowID }) {
                workspace.columns.remove(at: index)
                workspace.clampFocus()
                workspace.scrollOffset = nil
                break
            }
        }
        context.signature.remove(windowID)
    }

    func activeContextHasBufferedSourceWindows() -> Bool {
        spaceBufferedWindows.values.contains { $0.sourceContextID == activeLogicalSpaceContextID }
    }

    func cgWindowExists(_ windowID: UInt32) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(windowID)) as? [[String: Any]] else {
            return false
        }
        return !list.isEmpty
    }

    func cgWindowIsOnScreen(_ windowID: UInt32) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        return list.contains { info in
            if let number = info[kCGWindowNumber as String] as? UInt32 {
                return number == windowID
            }
            if let number = info[kCGWindowNumber as String] as? Int {
                return UInt32(number) == windowID
            }
            return false
        }
    }
}
