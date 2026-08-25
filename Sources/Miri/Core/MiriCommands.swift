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
        enqueue(.input(.command(command, animateWorkspace: animateWorkspace)))
    }

    func drainPendingFocusCommands() {
        guard !pendingFocusCommands.isEmpty,
              !layoutController.isActive
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

        switch command {
        case .focusWorkspace(let oneBasedIndex):
            guard focusWorkspace(oneBasedIndex) else {
                return
            }
        case .focusPreviousWorkspace:
            guard focusPreviousWorkspace() else {
                return
            }
        case .workspaceDown:
            guard setActiveWorkspace(windowManagement.activeWorkspace + 1) else {
                return
            }
            activeWorkspaceObject()?.clampFocus()
            protectActiveEmptyWorkspaceIfNeeded()
            reconcileWorkspaceCapacity()
            animated = animateWorkspace
        case .workspaceUp:
            guard setActiveWorkspace(windowManagement.activeWorkspace - 1) else {
                return
            }
            activeWorkspaceObject()?.clampFocus()
            protectActiveEmptyWorkspaceIfNeeded()
            reconcileWorkspaceCapacity()
            animated = animateWorkspace
        case .columnLeft:
            lastHorizontalFocusDirection = -1
            guard let workspace = activeWorkspaceObject(), !workspace.columns.isEmpty else {
                return
            }
            _ = windowManagement.focusColumn(at: workspace.activeColumn - 1)
            revealActiveColumnIfNeeded(in: workspace, viewport: currentViewport())
            animated = true
        case .columnRight:
            lastHorizontalFocusDirection = 1
            guard let workspace = activeWorkspaceObject(), !workspace.columns.isEmpty else {
                return
            }
            _ = windowManagement.focusColumn(at: workspace.activeColumn + 1)
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
            seedPresentationFrames(from: previousState)
            animated = moveActiveColumnHorizontally(by: -1)
        case .moveColumnRight:
            seedPresentationFrames(from: previousState)
            animated = moveActiveColumnHorizontally(by: 1)
        case .moveColumnToFirst:
            seedPresentationFrames(from: previousState)
            animated = moveActiveColumn(to: 0)
        case .moveColumnToLast:
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
            guard performAnimatedWidthChange(from: previousState, { cycleActiveWidthPreset(direction: -1) }) else {
                return
            }
            animated = true
            frameAnimated = true
        case .cycleWidthPresetForward:
            guard performAnimatedWidthChange(from: previousState, { cycleActiveWidthPreset(direction: 1) }) else {
                return
            }
            animated = true
            frameAnimated = true
        case .nudgeWidthNarrower:
            guard performAnimatedWidthChange(from: previousState, { nudgeActiveWidth(by: -0.1) }) else {
                return
            }
            animated = true
            frameAnimated = true
        case .nudgeWidthWider:
            guard performAnimatedWidthChange(from: previousState, { nudgeActiveWidth(by: 0.1) }) else {
                return
            }
            animated = true
            frameAnimated = true
        case .cycleAllWidthPresetsBackward:
            guard performAnimatedWidthChange(from: previousState, { cycleAllWidthPresets(direction: -1) }) else {
                return
            }
            animated = true
            frameAnimated = true
        case .cycleAllWidthPresetsForward:
            guard performAnimatedWidthChange(from: previousState, { cycleAllWidthPresets(direction: 1) }) else {
                return
            }
            animated = true
            frameAnimated = true
        case .nudgeAllWidthsNarrower:
            guard performAnimatedWidthChange(from: previousState, { nudgeAllWidths(by: -0.1) }) else {
                return
            }
            animated = true
            frameAnimated = true
        case .nudgeAllWidthsWider:
            guard performAnimatedWidthChange(from: previousState, { nudgeAllWidths(by: 0.1) }) else {
                return
            }
            animated = true
            frameAnimated = true
        }

        let newState = captureLayoutState()
        applyModelChange(
            ModelChange(
                previousLayout: previousState,
                layoutRequired: true,
                focusRequested: true,
                persistenceChanged: previousState != newState || frameAnimated,
                statusChanged: true
            ),
            animated: animated && (previousState != newState || frameAnimated)
        )
    }

    func applyModelChange(_ change: ModelChange, animated: Bool) {
        if change.layoutRequired {
            projectLayout(
                focusActiveWindow: change.focusRequested,
                animated: animated,
                from: change.previousLayout
            )
        }
        if change.persistenceChanged {
            schedulePersistentLayoutSnapshotWrite()
        }
        if change.statusChanged, !change.layoutRequired {
            notifyWorkspaceBarNeedsRefresh()
        }
    }

    func performAnimatedWidthChange(from state: LayoutState, _ change: () -> Bool) -> Bool {
        seedPresentationFrames(from: state)
        guard change() else {
            layoutController.clearPresentationFrames()
            return false
        }
        return true
    }

    @discardableResult
    func focusWorkspace(_ oneBasedIndex: Int) -> Bool {
        let requestedIndex = oneBasedIndex - 1
        guard windowManagement.workspaces.indices.contains(requestedIndex) else {
            debugLog("workspace focus ignored reason=not-created requested=\(oneBasedIndex) available=\(windowManagement.workspaces.count)")
            return false
        }

        let targetIndex = workspaceAutoBackAndForth && requestedIndex == windowManagement.activeWorkspace
            ? previousWorkspaceIndex() ?? requestedIndex
            : requestedIndex

        guard setActiveWorkspace(targetIndex) else {
            protectActiveEmptyWorkspaceIfNeeded()
            return false
        }
        activeWorkspaceObject()?.clampFocus()
        protectActiveEmptyWorkspaceIfNeeded()
        reconcileWorkspaceCapacity()
        return true
    }

    func focusPreviousWorkspace() -> Bool {
        guard let previousIndex = previousWorkspaceIndex(),
              previousIndex != windowManagement.activeWorkspace
        else {
            return false
        }

        setActiveWorkspace(previousIndex)
        activeWorkspaceObject()?.clampFocus()
        protectActiveEmptyWorkspaceIfNeeded()
        reconcileWorkspaceCapacity()
        return true
    }

    @discardableResult
    func setActiveWorkspace(_ requestedIndex: Int, rememberPrevious: Bool = true) -> Bool {
        windowManagement.selectWorkspace(requestedIndex, rememberPrevious: rememberPrevious)
    }

    func previousWorkspaceIndex() -> Int? {
        windowManagement.previousWorkspaceIndex()
    }

    func protectActiveEmptyWorkspaceIfNeeded() {
        if windowManagement.protectActiveEmptyWorkspace() {
            debugLog("empty workspace focus protected workspace=\(windowManagement.activeWorkspace + 1)")
        }
    }

    var activeEmptyWorkspaceHasFocusAuthority: Bool {
        windowManagement.activeEmptyWorkspaceHasFocusAuthority
    }

    func focusColumn(at requestedIndex: Int) -> Bool {
        let result = windowManagement.focusColumn(at: requestedIndex)
        if result.target < result.source {
            lastHorizontalFocusDirection = -1
            clearIntelligentResizeMemory()
        } else if result.target > result.source {
            lastHorizontalFocusDirection = 1
            clearIntelligentResizeMemory()
        }
        return result.changed
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
        guard windowManagement.moveActiveColumn(to: targetIndex) else { return false }
        lastHorizontalFocusDirection = targetIndex < sourceIndex ? -1 : 1
        clearIntelligentResizeMemory()
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

        windowManagement.resetAllScrollOffsets()
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
            windowManagement.setScrollOffset(nil, in: workspace)
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
            windowManagement.setScrollOffset(nil, in: workspace)
            return
        }

        let oldMetrics = stripMetrics(for: workspace, viewport: viewport)
        guard oldMetrics.origins.indices.contains(activeColumn),
              oldMetrics.widths.indices.contains(activeColumn)
        else {
            windowManagement.setScrollOffset(nil, in: workspace)
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
            windowManagement.setScrollOffset(nil, in: workspace)
            return
        }

        if shouldCenterColumn(width: newMetrics.widths[activeColumn], viewport: viewport) {
            clearIntelligentResizeMemory()
            windowManagement.setScrollOffset(centeredScrollOffset(
                columnMinX: newMetrics.origins[activeColumn],
                columnWidth: newMetrics.widths[activeColumn],
                viewport: viewport
            ), in: workspace)
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
        windowManagement.setScrollOffset(
            min(max(targetOffset, 0), maxHorizontalCameraOffset(for: workspace, viewport: viewport)),
            in: workspace
        )
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

        windowManagement.resetAllScrollOffsets()
        return true
    }

    func setWidthRatio(_ ratio: CGFloat, for window: ManagedWindow) -> Bool {
        let oldRatio = widthRatio(for: window)
        let newRatio = ratio.clampedManualWidthRatio
        guard abs(oldRatio - newRatio) >= 0.005 else {
            return false
        }

        windowManagement.setWidthRatio(newRatio, for: window)
        return true
    }

    @discardableResult
    func moveActiveColumnToWorkspace(relativeOffset: Int) -> Bool {
        let targetIndex = windowManagement.activeWorkspace + relativeOffset
        return moveActiveColumnToWorkspace(zeroBasedIndex: targetIndex)
    }

    @discardableResult
    func moveActiveColumnToWorkspace(oneBasedIndex: Int) -> Bool {
        let zeroBased = max(0, oneBasedIndex - 1)
        return moveActiveColumnToWorkspace(zeroBasedIndex: zeroBased)
    }

    @discardableResult
    func moveActiveColumnToWorkspace(zeroBasedIndex requestedIndex: Int) -> Bool {
        guard windowManagement.moveActiveColumn(toWorkspace: requestedIndex) else { return false }
        reconcileWorkspaceCapacity()
        return true
    }

    func activeWorkspaceObject() -> Workspace? {
        windowManagement.activeWorkspaceObject()
    }

    func captureLayoutState() -> LayoutState {
        windowManagement.snapshot().layoutState
    }

    func seedPresentationFrames(from state: LayoutState) {
        let viewport = currentViewport()
        let layout = layoutController.projectItems(viewport: viewport, state: state, parkHidden: false)
        layoutController.seedPresentationFrames(
            Dictionary(uniqueKeysWithValues: layout.map { (ObjectIdentifier($0.window), $0.frame) })
        )
    }

}
