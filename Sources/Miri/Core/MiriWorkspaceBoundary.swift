import AppKit
import CoreGraphics
import Foundation

/// A monotonic, one-shot gate. Repeats cannot create a gate, even if an earlier
/// repeat navigated to the last row. The owner retains a committed gate until release.
struct WorkspaceBoundaryGate {
    let startedAt: TimeInterval
    let duration: TimeInterval
    private(set) var committed = false

    init?(now: TimeInterval, milliseconds: Int, isRepeat: Bool) {
        guard !isRepeat else { return nil }
        startedAt = now
        duration = Double(min(max(milliseconds, 10), 2000)) / 1000
    }

    func progress(now: TimeInterval) -> CGFloat {
        CGFloat(min(max((now - startedAt) / duration, 0), 1))
    }

    mutating func commitIfReady(now: TimeInterval, held: Bool, sourceValid: Bool) -> Bool {
        guard !committed, held, sourceValid, now - startedAt >= duration else { return false }
        committed = true
        return true
    }
}

struct WorkspaceBoundaryHold {
    var gate: WorkspaceBoundaryGate
    var thresholdFocusValidated = false
    var thresholdValidationPending = false
    let command: Command
    let direction: WorkspaceBoundaryDirection
    let movesWindow: Bool
    let keyCode: Int64
    let modifiers: CGEventFlags
    let workspace: Workspace
    let window: ManagedWindow?
    let sourceIndex: Int
    let targetIndex: Int
    let targetWorkspace: Workspace?
    let contextID: Int
    let focusGeneration: UInt64
    let sessionGeneration: UInt64

    var requiresRowBoundary: Bool {
        switch command {
        case .rowDown, .rowUp, .moveWindowDown, .moveWindowUp: return true
        default: return false
        }
    }
}

extension Miri {
    func cancelWorkspaceBoundaryHold() {
        workspaceBoundaryTimer?.invalidate()
        workspaceBoundaryTimer = nil
        if let hold = workspaceBoundaryHold, !hold.gate.committed {
            workspaceBoundaryFeedbackController.cancel()
        }
        workspaceBoundaryHold = nil
    }

    /// Returns true only when a boundary command was consumed (including repeats).
    func handleWorkspaceBoundaryShortcut(
        _ requestedCommand: Command, keyCode: Int64, modifiers: CGEventFlags, isRepeat: Bool
    ) -> Bool {
        var command = requestedCommand
        if let workspace = activeWorkspaceObject(), workspace.fullscreenState != .off {
            // Fullscreen has no visible row neighbors. Use workspace navigation
            // so neither the source nor destination's remembered row changes.
            switch command {
            case .rowDown: command = .workspaceDown
            case .rowUp: command = .workspaceUp
            default: break
            }
        }
        if let hold = workspaceBoundaryHold {
            if hold.keyCode == keyCode, hold.modifiers == modifiers { return true }
            cancelWorkspaceBoundaryHold()
        }
        let direction: WorkspaceBoundaryDirection
        let movesWindow: Bool
        switch command {
        case .rowDown: direction = .down; movesWindow = false
        case .rowUp: direction = .up; movesWindow = false
        case .moveWindowDown: direction = .down; movesWindow = true
        case .moveWindowUp: direction = .up; movesWindow = true
        case .workspaceDown: direction = .down; movesWindow = false
        case .workspaceUp: direction = .up; movesWindow = false
        case .moveColumnToWorkspaceDown: direction = .down; movesWindow = true
        case .moveColumnToWorkspaceUp: direction = .up; movesWindow = true
        default: return false
        }
        guard let workspace = activeWorkspaceObject() else { return true }
        let window = workspace.activeWindow
        if movesWindow, window == nil { return true }
        switch command {
        case .rowDown, .rowUp, .moveWindowDown, .moveWindowUp:
            guard workspace.fullscreenState == .off else { return false }
            if workspace.columns.indices.contains(workspace.activeColumn) {
                let column = workspace.columns[workspace.activeColumn]
                let boundary = direction == .down ? column.windows.count - 1 : 0
                guard column.activeRow == boundary else { return false }
            }
        default: break
        }
        // Boundary repeats are consumed, never promoted into new holds.
        let target = windowManagement.activeWorkspace + direction.rawValue
        guard appPhase == .running, sessionController.isLayoutTrackingAllowed,
              !mouseInteractionController.isActive,
              !windowManagement.observation.transientWindowActive,
              target >= 0,
              windowManagement.workspaces.indices.contains(target) || (movesWindow && target == windowManagement.workspaces.count),
              let gate = WorkspaceBoundaryGate(
                now: ProcessInfo.processInfo.systemUptime,
                milliseconds: configStore.effectiveConfig.workspaceBoundaryHoldMS ?? 750,
                isRepeat: isRepeat
              )
        else { return true }
        workspaceBoundaryHold = WorkspaceBoundaryHold(
            gate: gate, command: command, direction: direction, movesWindow: movesWindow,
            keyCode: keyCode, modifiers: modifiers, workspace: workspace, window: window,
            sourceIndex: windowManagement.activeWorkspace, targetIndex: target,
            targetWorkspace: windowManagement.workspaces.indices.contains(target) ? windowManagement.workspaces[target] : nil,
            contextID: windowManagement.activeLogicalSpaceContextID,
            focusGeneration: focusStateGeneration, sessionGeneration: sessionController.resumeGeneration
        )
        workspaceBoundaryTimer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickWorkspaceBoundaryHold() }
        }
        if let timer = workspaceBoundaryTimer { RunLoop.main.add(timer, forMode: .common) }
        tickWorkspaceBoundaryHold()
        return true
    }

    func tickWorkspaceBoundaryHold() {
        guard var hold = workspaceBoundaryHold, !hold.gate.committed else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let held = CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(hold.keyCode))
            && Self.boundaryModifiers(CGEventSource.flagsState(.combinedSessionState)) == Self.boundaryModifiers(hold.modifiers)
        let focusedSourceValid = hold.window.map { window in
            NSWorkspace.shared.frontmostApplication?.processIdentifier == window.pid
                && lastKnownFocusedElements[window.pid].map { sameWindow($0, window.element) } == true
        } ?? hold.workspace.isEmpty
        let targetValid = hold.targetWorkspace.map { target in
            windowManagement.workspaces.indices.contains(hold.targetIndex)
                && windowManagement.workspaces[hold.targetIndex] === target
        } ?? (hold.movesWindow && hold.targetIndex == windowManagement.workspaces.count)
        let valid = appPhase == .running && sessionController.isLayoutTrackingAllowed
            && sessionController.resumeGeneration == hold.sessionGeneration
            && focusStateGeneration == hold.focusGeneration
            && !windowManagement.observation.transientWindowActive
            && !windowManagement.pendingLogicalSpaceSwitch
            && !mouseInteractionController.isActive
            && windowManagement.activeLogicalSpaceContextID == hold.contextID
            && windowManagement.activeWorkspace == hold.sourceIndex
            && activeWorkspaceObject() === hold.workspace
            && hold.workspace.activeWindow === hold.window
            && (!hold.requiresRowBoundary || hold.workspace.fullscreenState == .off)
            && targetValid
            && focusedSourceValid
        guard held, valid else {
            cancelWorkspaceBoundaryHold()
            return
        }
        if hold.requiresRowBoundary, hold.workspace.columns.indices.contains(hold.workspace.activeColumn) {
            let column = hold.workspace.columns[hold.workspace.activeColumn]
            guard column.activeRow == (hold.direction == .down ? column.windows.count - 1 : 0) else {
                cancelWorkspaceBoundaryHold()
                return
            }
        }
        if let screen = NSScreen.main {
            workspaceBoundaryFeedbackController.render(direction: hold.direction, targetWorkspace: hold.targetIndex + 1,
                progress: hold.gate.progress(now: now), on: screen)
        }
        // Cached focus is enough to cancel early, never enough to authorize a
        // cross-workspace mutation. Re-read the exact AX focus at the threshold.
        if hold.gate.progress(now: now) >= 1, let window = hold.window, !hold.thresholdFocusValidated {
            guard !hold.thresholdValidationPending else { return }
            hold.thresholdValidationPending = true
            workspaceBoundaryHold = hold
            let startedAt = hold.gate.startedAt
            axOperations.readFocusedWindow(pid: window.pid, priority: .interactive,
                coalescingKey: "workspace-boundary-threshold-focus") { [weak self] result in
                guard let self, var current = self.workspaceBoundaryHold,
                      current.gate.startedAt == startedAt else { return }
                guard result.disposition == .completed, let snapshot = result.value,
                      current.window.map({ self.sameWindow(snapshot.handle.element, $0.element) }) == true else {
                    self.cancelWorkspaceBoundaryHold()
                    return
                }
                current.thresholdFocusValidated = true
                current.thresholdValidationPending = false
                self.workspaceBoundaryHold = current
                self.tickWorkspaceBoundaryHold()
            }
            return
        }
        guard hold.gate.commitIfReady(now: now, held: held, sourceValid: valid) else { return }
        workspaceBoundaryHold = hold
        workspaceBoundaryTimer?.invalidate()
        workspaceBoundaryTimer = nil
        performWorkspaceBoundaryTransition(hold)
    }

    /// Apply a committed crossing after physical input and focus validation.
    func performWorkspaceBoundaryTransition(_ hold: WorkspaceBoundaryHold) {
        if hold.movesWindow {
            let previous = captureLayoutState()
            seedPresentationFrames(from: previous)
            let moved: Bool
            switch hold.command {
            case .moveColumnToWorkspaceDown, .moveColumnToWorkspaceUp:
                moved = windowManagement.moveActiveColumn(toWorkspace: hold.targetIndex)
            default:
                moved = windowManagement.moveActiveWindow(toWorkspace: hold.targetIndex)
            }
            guard moved else {
                workspaceBoundaryFeedbackController.cancel()
                cancelWorkspaceBoundaryHold()
                return
            }
            reconcileWorkspaceCapacity()
            applyModelChange(ModelChange(previousLayout: previous, layoutRequired: true, focusRequested: true,
                persistenceChanged: true, statusChanged: true), animated: true)
        } else {
            let destination = windowManagement.workspaces[hold.targetIndex]
            if hold.requiresRowBoundary, destination.fullscreenState == .off,
               destination.columns.indices.contains(destination.activeColumn) {
                let destinationColumn = destination.columns[destination.activeColumn]
                destinationColumn.activeRow = hold.direction == .down ? 0 : max(0, destinationColumn.windows.count - 1)
            }
            perform(hold.direction == .down ? .workspaceDown : .workspaceUp, animateWorkspace: true)
        }
        workspaceBoundaryFeedbackController.complete()
    }

    private static func boundaryModifiers(_ flags: CGEventFlags) -> CGEventFlags {
        flags.intersection([.maskCommand, .maskControl, .maskShift, .maskAlternate, .maskSecondaryFn,
                            CGEventFlags(rawValue: 0x20), CGEventFlags(rawValue: 0x40)])
    }
}
