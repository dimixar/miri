import CoreGraphics
import Foundation

enum IntelligentResizeAnchor {
    case left
    case right
}

enum IntelligentResizeDirection {
    case left
    case right
}

extension Miri {
    func submit(_ command: Command, animateWorkspace: Bool = false) {
        if shouldQueueFocusCommand(command) {
            keyboardFocusAuthorityUntil = CFAbsoluteTimeGetCurrent() + 1.5
        }
        let shouldSerialize = animationStrategy != .snapshot
            && shouldQueueFocusCommand(command)
            && (isApplyingLayout || animationTimer != nil || snapshotAnimationSession != nil)
        guard shouldSerialize else {
            perform(command, animateWorkspace: animateWorkspace)
            return
        }
        pendingFocusCommands.append(command)
    }

    func drainPendingFocusCommands() {
        guard !pendingFocusCommands.isEmpty,
              !isApplyingLayout,
              animationTimer == nil,
              snapshotAnimationSession == nil
        else {
            return
        }
        let command = pendingFocusCommands.removeFirst()
        perform(command)
    }

    func shouldQueueFocusCommand(_ command: Command) -> Bool {
        switch command {
        case .columnLeft, .columnRight, .columnFirst, .columnLast:
            return true
        default:
            return false
        }
    }

    func perform(_ command: Command, animateWorkspace: Bool = false) {
        let previousState = captureLayoutState()
        var animated = false
        var frameAnimated = false
        var duration = keyboardAnimationDuration

        switch command {
        case .focusWorkspace(let oneBasedIndex):
            focusWorkspace(oneBasedIndex)
        case .focusPreviousWorkspace:
            guard focusPreviousWorkspace() else {
                return
            }
        case .workspaceDown:
            guard setActiveWorkspace(activeWorkspace + 1) else {
                return
            }
            activeWorkspaceObject()?.clampFocus()
            animated = animateWorkspace
        case .workspaceUp:
            guard setActiveWorkspace(activeWorkspace - 1) else {
                return
            }
            activeWorkspaceObject()?.clampFocus()
            animated = animateWorkspace
        case .columnLeft:
            lastHorizontalFocusDirection = -1
            guard let workspace = activeWorkspaceObject(), !workspace.columns.isEmpty else {
                return
            }
            workspace.activeColumn = max(workspace.activeColumn - 1, 0)
            revealActiveColumnIfNeeded(in: workspace, viewport: currentViewport())
            animated = true
        case .columnRight:
            lastHorizontalFocusDirection = 1
            guard let workspace = activeWorkspaceObject(), !workspace.columns.isEmpty else {
                return
            }
            workspace.activeColumn = min(workspace.activeColumn + 1, workspace.columns.count - 1)
            revealActiveColumnIfNeeded(in: workspace, viewport: currentViewport())
            animated = true
        case .columnFirst:
            guard focusColumn(at: 0) else {
                return
            }
            animated = true
        case .columnLast:
            guard let workspace = activeWorkspaceObject() else {
                return
            }
            guard focusColumn(at: workspace.columns.count - 1) else {
                return
            }
            animated = true
        case .moveColumnLeft:
            duration = moveColumnAnimationDuration
            seedPresentationFrames(from: previousState)
            animated = moveActiveColumnHorizontally(by: -1)
        case .moveColumnRight:
            duration = moveColumnAnimationDuration
            seedPresentationFrames(from: previousState)
            animated = moveActiveColumnHorizontally(by: 1)
        case .moveColumnToFirst:
            duration = moveColumnAnimationDuration
            seedPresentationFrames(from: previousState)
            animated = moveActiveColumn(to: 0)
        case .moveColumnToLast:
            duration = moveColumnAnimationDuration
            seedPresentationFrames(from: previousState)
            guard let workspace = activeWorkspaceObject() else {
                return
            }
            animated = moveActiveColumn(to: workspace.columns.count - 1)
        case .moveColumnToWorkspace(let oneBasedIndex):
            moveActiveColumnToWorkspace(oneBasedIndex: oneBasedIndex)
        case .moveColumnToWorkspaceDown:
            moveActiveColumnToWorkspace(relativeOffset: 1)
        case .moveColumnToWorkspaceUp:
            moveActiveColumnToWorkspace(relativeOffset: -1)
        case .cycleWidthPresetBackward:
            duration = widthAnimationDuration
            guard performAnimatedWidthChange(from: previousState, { cycleActiveWidthPreset(direction: -1) }) else {
                return
            }
            animated = true
            frameAnimated = true
        case .cycleWidthPresetForward:
            duration = widthAnimationDuration
            guard performAnimatedWidthChange(from: previousState, { cycleActiveWidthPreset(direction: 1) }) else {
                return
            }
            animated = true
            frameAnimated = true
        case .nudgeWidthNarrower:
            duration = widthAnimationDuration
            guard performAnimatedWidthChange(from: previousState, { nudgeActiveWidth(by: -0.1) }) else {
                return
            }
            animated = true
            frameAnimated = true
        case .nudgeWidthWider:
            duration = widthAnimationDuration
            guard performAnimatedWidthChange(from: previousState, { nudgeActiveWidth(by: 0.1) }) else {
                return
            }
            animated = true
            frameAnimated = true
        case .cycleAllWidthPresetsBackward:
            duration = widthAnimationDuration
            guard performAnimatedWidthChange(from: previousState, { cycleAllWidthPresets(direction: -1) }) else {
                return
            }
            animated = true
            frameAnimated = true
        case .cycleAllWidthPresetsForward:
            duration = widthAnimationDuration
            guard performAnimatedWidthChange(from: previousState, { cycleAllWidthPresets(direction: 1) }) else {
                return
            }
            animated = true
            frameAnimated = true
        case .nudgeAllWidthsNarrower:
            duration = widthAnimationDuration
            guard performAnimatedWidthChange(from: previousState, { nudgeAllWidths(by: -0.1) }) else {
                return
            }
            animated = true
            frameAnimated = true
        case .nudgeAllWidthsWider:
            duration = widthAnimationDuration
            guard performAnimatedWidthChange(from: previousState, { nudgeAllWidths(by: 0.1) }) else {
                return
            }
            animated = true
            frameAnimated = true
        }

        let newState = captureLayoutState()
        let newFocusedWindowID = activeWindow().map(ObjectIdentifier.init)
        projectLayout(
            focusActiveWindow: true,
            animated: animated && (previousState != newState || frameAnimated),
            from: previousState,
            animationDuration: duration,
            animatedWindowIDs: nil,
            resizingWindowID: newFocusedWindowID
        )
    }

    func performAnimatedWidthChange(from state: LayoutState, _ change: () -> Bool) -> Bool {
        seedPresentationFrames(from: state)
        guard change() else {
            presentationFrames.removeAll()
            return false
        }
        return true
    }

    func focusWorkspace(_ oneBasedIndex: Int) {
        guard !workspaces.isEmpty else {
            return
        }

        let requestedIndex = min(max(oneBasedIndex - 1, 0), workspaces.count - 1)
        let targetIndex = workspaceAutoBackAndForth && requestedIndex == activeWorkspace
            ? previousWorkspaceIndex() ?? requestedIndex
            : requestedIndex

        setActiveWorkspace(targetIndex)
        activeWorkspaceObject()?.clampFocus()
    }

    func focusPreviousWorkspace() -> Bool {
        guard let previousIndex = previousWorkspaceIndex(),
              previousIndex != activeWorkspace
        else {
            return false
        }

        setActiveWorkspace(previousIndex)
        activeWorkspaceObject()?.clampFocus()
        return true
    }

    @discardableResult
    func setActiveWorkspace(_ requestedIndex: Int, rememberPrevious: Bool = true) -> Bool {
        guard !workspaces.isEmpty else {
            activeWorkspace = 0
            previousWorkspace = nil
            return false
        }

        let targetIndex = min(max(requestedIndex, 0), workspaces.count - 1)
        guard targetIndex != activeWorkspace else {
            return false
        }

        let currentWorkspace = activeWorkspaceObject()
        activeWorkspace = targetIndex
        if rememberPrevious {
            previousWorkspace = currentWorkspace
        }
        return true
    }

    func previousWorkspaceIndex() -> Int? {
        guard let previousWorkspace else {
            return nil
        }

        return workspaces.firstIndex(where: { $0 === previousWorkspace })
    }

    func focusColumn(at requestedIndex: Int) -> Bool {
        guard let workspace = activeWorkspaceObject(), !workspace.columns.isEmpty else {
            return false
        }

        let sourceIndex = workspace.activeColumn
        let targetIndex = min(max(requestedIndex, 0), workspace.columns.count - 1)
        if targetIndex < sourceIndex {
            lastHorizontalFocusDirection = -1
            clearIntelligentResizeMemory()
        } else if targetIndex > sourceIndex {
            lastHorizontalFocusDirection = 1
            clearIntelligentResizeMemory()
        }
        workspace.activeColumn = targetIndex
        workspace.scrollOffset = nil
        return true
    }

    func moveActiveColumnHorizontally(by delta: Int) -> Bool {
        guard let workspace = activeWorkspaceObject(), !workspace.columns.isEmpty else {
            return false
        }

        workspace.clampFocus()
        return moveActiveColumn(to: workspace.activeColumn + delta)
    }

    func moveActiveColumn(to requestedIndex: Int) -> Bool {
        guard let workspace = activeWorkspaceObject(), !workspace.columns.isEmpty else {
            return false
        }

        workspace.clampFocus()
        let sourceIndex = workspace.activeColumn
        let targetIndex = min(max(requestedIndex, 0), workspace.columns.count - 1)
        guard sourceIndex != targetIndex else {
            return false
        }
        guard workspace.columns.indices.contains(targetIndex) else {
            return false
        }

        let window = workspace.columns.remove(at: sourceIndex)
        workspace.columns.insert(window, at: targetIndex)
        workspace.activeColumn = targetIndex
        lastHorizontalFocusDirection = targetIndex < sourceIndex ? -1 : 1
        clearIntelligentResizeMemory()
        workspace.scrollOffset = nil
        schedulePersistentLayoutSnapshotWrite()
        return true
    }

    func cycleActiveWidthPreset(direction: Int) -> Bool {
        guard let window = activeWindow() else {
            return false
        }

        guard let target = widthPreset(after: widthRatio(for: window), direction: direction) else {
            return false
        }

        return setActiveWindowWidthRatio(target)
    }

    func cycleAllWidthPresets(direction: Int) -> Bool {
        guard let window = activeWindow(),
              let target = widthPreset(after: widthRatio(for: window), direction: direction)
        else {
            return false
        }

        return setAllWindowWidthRatios(target)
    }

    func widthPreset(after current: CGFloat, direction: Int) -> CGFloat? {
        let presets = widthPresetRatios
        guard !presets.isEmpty else {
            return nil
        }

        if direction >= 0 {
            return presets.first(where: { $0 > current + 0.005 }) ?? presets[0]
        }

        return presets.last(where: { $0 < current - 0.005 }) ?? presets[presets.count - 1]
    }

    func nudgeActiveWidth(by delta: CGFloat) -> Bool {
        guard let window = activeWindow() else {
            return false
        }
        return setActiveWindowWidthRatio(widthRatio(for: window) + delta)
    }

    func nudgeAllWidths(by delta: CGFloat) -> Bool {
        var changed = false
        for window in tiledWindows() {
            changed = setWidthRatio(widthRatio(for: window) + delta, for: window) || changed
        }

        guard changed else {
            return false
        }

        for workspace in workspaces {
            workspace.scrollOffset = nil
        }
        return true
    }

    func setActiveWindowWidthRatio(_ ratio: CGFloat) -> Bool {
        guard let workspace = activeWorkspaceObject(),
              !workspace.columns.isEmpty
        else {
            return false
        }

        workspace.clampFocus()
        let window = workspace.columns[workspace.activeColumn]
        let oldRatio = widthRatio(for: window)
        let oldScrollOffset = horizontalCameraOffset(for: workspace, viewport: currentViewport())
        guard setWidthRatio(ratio, for: window) else {
            return false
        }

        if widthResizeMode == .intelligent {
            applyIntelligentWidthResizeScrollOffset(
                in: workspace,
                activeColumn: workspace.activeColumn,
                oldRatio: oldRatio,
                oldScrollOffset: oldScrollOffset,
                newRatio: widthRatio(for: window),
                windowID: ObjectIdentifier(window)
            )
        } else {
            workspace.scrollOffset = nil
        }
        return true
    }

    func applyIntelligentWidthResizeScrollOffset(
        in workspace: Workspace,
        activeColumn: Int,
        oldRatio: CGFloat,
        oldScrollOffset: CGFloat,
        newRatio: CGFloat,
        windowID: ObjectIdentifier
    ) {
        let viewport = currentViewport()
        guard viewport.width > 0,
              workspace.columns.indices.contains(activeColumn)
        else {
            workspace.scrollOffset = nil
            return
        }

        let oldMetrics = stripMetrics(for: workspace, viewport: viewport)
        guard oldMetrics.origins.indices.contains(activeColumn),
              oldMetrics.widths.indices.contains(activeColumn)
        else {
            workspace.scrollOffset = nil
            return
        }

        let oldFrame = CGRect(
            x: viewport.minX + oldMetrics.origins[activeColumn] - oldScrollOffset,
            y: viewport.minY,
            width: viewport.width * oldRatio,
            height: viewport.height
        )
        let measuredGrowDirection = intelligentGrowDirection(for: oldFrame, viewport: viewport)
        let growDirection: IntelligentResizeDirection
        let anchor: IntelligentResizeAnchor
        if newRatio >= oldRatio {
            if lastIntelligentResizeWindowID == windowID, let lastIntelligentGrowDirection {
                growDirection = lastIntelligentGrowDirection
            } else {
                growDirection = measuredGrowDirection
            }
            lastIntelligentResizeWindowID = windowID
            lastIntelligentGrowDirection = growDirection
            anchor = growDirection == .right ? .left : .right
        } else if oldRatio >= 1.0 {
            clearIntelligentResizeMemory()
            if activeColumn == 0 {
                anchor = .left
            } else if activeColumn == workspace.columns.count - 1 {
                anchor = .right
            } else {
                anchor = lastHorizontalFocusDirection < 0 ? .left : .right
            }
        } else {
            clearIntelligentResizeMemory()
            anchor = measuredGrowDirection == .right ? .left : .right
        }

        let newMetrics = stripMetrics(for: workspace, viewport: viewport)
        guard newMetrics.origins.indices.contains(activeColumn),
              newMetrics.widths.indices.contains(activeColumn)
        else {
            workspace.scrollOffset = nil
            return
        }

        var targetOffset: CGFloat
        switch anchor {
        case .left:
            targetOffset = newMetrics.origins[activeColumn] - (oldFrame.minX - viewport.minX)
        case .right:
            targetOffset = newMetrics.origins[activeColumn] + newMetrics.widths[activeColumn] - (oldFrame.maxX - viewport.minX)
        }

        targetOffset = scrollOffsetEnsuringFullVisibility(
            ofColumn: activeColumn,
            metrics: newMetrics,
            viewport: viewport,
            preferredOffset: targetOffset
        )
        workspace.scrollOffset = min(max(targetOffset, 0), maxHorizontalCameraOffset(for: workspace, viewport: viewport))
    }

    func scrollOffsetEnsuringFullVisibility(
        ofColumn activeColumn: Int,
        metrics: (origins: [CGFloat], widths: [CGFloat]),
        viewport: CGRect,
        preferredOffset: CGFloat
    ) -> CGFloat {
        guard metrics.origins.indices.contains(activeColumn),
              metrics.widths.indices.contains(activeColumn),
              metrics.widths[activeColumn] <= viewport.width
        else {
            return preferredOffset
        }

        var offset = preferredOffset
        let columnMinX = metrics.origins[activeColumn]
        let columnMaxX = columnMinX + metrics.widths[activeColumn]
        let visibleMinX = offset
        let visibleMaxX = offset + viewport.width

        if columnMinX < visibleMinX {
            offset = columnMinX
        } else if columnMaxX > visibleMaxX {
            offset = columnMaxX - viewport.width
        }

        return offset
    }

    func intelligentGrowDirection(for frame: CGRect, viewport: CGRect) -> IntelligentResizeDirection {
        let leftFree = max(0, frame.minX - viewport.minX)
        let rightFree = max(0, viewport.maxX - frame.maxX)
        return rightFree >= leftFree ? .right : .left
    }

    func clearIntelligentResizeMemory() {
        lastIntelligentResizeWindowID = nil
        lastIntelligentGrowDirection = nil
    }

    func setAllWindowWidthRatios(_ ratio: CGFloat) -> Bool {
        var changed = false
        for window in tiledWindows() {
            changed = setWidthRatio(ratio, for: window) || changed
        }

        guard changed else {
            return false
        }

        for workspace in workspaces {
            workspace.scrollOffset = nil
        }
        return true
    }

    func setWidthRatio(_ ratio: CGFloat, for window: ManagedWindow) -> Bool {
        let oldRatio = widthRatio(for: window)
        let newRatio = ratio.clampedManualWidthRatio
        guard abs(oldRatio - newRatio) >= 0.005 else {
            return false
        }

        window.manualWidthRatio = newRatio
        schedulePersistentLayoutSnapshotWrite()
        return true
    }

    @discardableResult
    func moveActiveColumnToWorkspace(relativeOffset: Int) -> Bool {
        let targetIndex = activeWorkspace + relativeOffset
        return moveActiveColumnToWorkspace(zeroBasedIndex: targetIndex)
    }

    @discardableResult
    func moveActiveColumnToWorkspace(oneBasedIndex: Int) -> Bool {
        let zeroBased = max(0, oneBasedIndex - 1)
        return moveActiveColumnToWorkspace(zeroBasedIndex: zeroBased)
    }

    @discardableResult
    func moveActiveColumnToWorkspace(zeroBasedIndex requestedIndex: Int) -> Bool {
        guard workspaces.indices.contains(activeWorkspace),
              let sourceWorkspace = activeWorkspaceObject(),
              !sourceWorkspace.columns.isEmpty
        else {
            return false
        }

        sourceWorkspace.clampFocus()
        let targetIndex = min(max(requestedIndex, 0), workspaces.count - 1)
        guard targetIndex != activeWorkspace else {
            return false
        }

        let targetWorkspace = workspaces[targetIndex]
        let movingWindow = sourceWorkspace.columns.remove(at: sourceWorkspace.activeColumn)
        sourceWorkspace.scrollOffset = nil
        sourceWorkspace.clampFocus()

        targetWorkspace.clampFocus()
        let insertionIndex = targetWorkspace.columns.isEmpty
            ? 0
            : min(targetWorkspace.activeColumn + 1, targetWorkspace.columns.count)
        targetWorkspace.columns.insert(movingWindow, at: insertionIndex)
        targetWorkspace.activeColumn = insertionIndex
        targetWorkspace.scrollOffset = nil

        setActiveWorkspace(targetIndex)
        ensureTrailingEmptyWorkspace()
        activeWorkspace = workspaces.firstIndex(where: { $0 === targetWorkspace }) ?? activeWorkspace
        schedulePersistentLayoutSnapshotWrite()
        return true
    }

    func activeWorkspaceObject() -> Workspace? {
        guard workspaces.indices.contains(activeWorkspace) else {
            return nil
        }
        return workspaces[activeWorkspace]
    }

    func captureLayoutState() -> LayoutState {
        LayoutState(
            activeWorkspace: min(max(activeWorkspace, 0), max(workspaces.count - 1, 0)),
            activeColumns: workspaces.map(\.activeColumn),
            scrollOffsets: workspaces.map(\.scrollOffset)
        )
    }

    func seedPresentationFrames(from state: LayoutState) {
        let viewport = currentViewport()
        let layout = layoutItems(viewport: viewport, state: state, parkHidden: false)
        presentationFrames = Dictionary(uniqueKeysWithValues: layout.map { (ObjectIdentifier($0.window), $0.frame) })
    }

}
