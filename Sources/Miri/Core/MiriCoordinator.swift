import AppKit
import Darwin
import Foundation

extension Miri {
    /// All cross-domain asynchronous inputs enter this main-thread queue. AppKit,
    /// AX and the installed input sources are attached to the main run loop.
    func enqueue(_ event: AppEvent) {
        dispatchPrecondition(condition: .onQueue(.main))

        MainActor.assumeIsolated {
            enqueueOnMainActor(event)
        }
    }

    @MainActor private func enqueueOnMainActor(_ event: AppEvent) {
        nextCoordinatorSequence &+= 1
        let sequenced = SequencedAppEvent(
            sequence: EventSequence(rawValue: nextCoordinatorSequence),
            event: event
        )
        coordinatorEventQueue.append(sequenced)
        #if DEBUG
        assert(coordinatorEventQueue.count < 1_024, "Coordinator event queue is unexpectedly unbounded")
        #endif
        debugLog(
            "coordinator event queued sequence=\(sequenced.sequence) phase=\(appPhase.rawValue) event=\(event.logName) depth=\(coordinatorEventQueue.count)"
        )
        drainCoordinatorEvents()
    }

    @MainActor private func drainCoordinatorEvents() {
        precondition(Thread.isMainThread)
        guard !isHandlingCoordinatorEvent else {
            return
        }

        isHandlingCoordinatorEvent = true
        defer {
            isHandlingCoordinatorEvent = false
            assertCoordinatorInvariants()
        }

        while !coordinatorEventQueue.isEmpty {
            let next = coordinatorEventQueue.removeFirst()
            activeCoordinatorSequence = next.sequence
            debugLog(
                "coordinator event begin sequence=\(next.sequence) phase=\(appPhase.rawValue) event=\(next.event.logName)"
            )
            handleCoordinatorEvent(next.event, sequence: next.sequence)
            debugLog(
                "coordinator event end sequence=\(next.sequence) phase=\(appPhase.rawValue) event=\(next.event.logName)"
            )
            activeCoordinatorSequence = nil
        }
    }

    @MainActor private func handleCoordinatorEvent(_ event: AppEvent, sequence: EventSequence) {
        if appPhase == .terminated {
            debugLog("coordinator event ignored sequence=\(sequence) reason=terminated event=\(event.logName)")
            return
        }
        if appPhase == .terminating {
            switch event {
            case .terminate:
                prepareForTermination(reason: "repeated-request")
            default:
                debugLog("coordinator event ignored sequence=\(sequence) reason=terminating event=\(event.logName)")
            }
            return
        }
        if appPhase == .starting {
            switch event {
            case .session:
                break
            case .input(.command), .windows(.reconciliationRequested), .terminate:
                break
            default:
                debugLog("coordinator event ignored sequence=\(sequence) reason=starting event=\(event.logName)")
                return
            }
        }
        if appPhase == .sessionUnavailable {
            switch event {
            case .timer:
                debugLog("coordinator event ignored sequence=\(sequence) reason=session-unavailable event=\(event.logName)")
                return
            default:
                break
            }
        }

        switch event {
        case .input(let input):
            handleCoordinatorInput(input)
        case .session(let session):
            handleCoordinatorSession(session)
        case .workspace(let workspace):
            handleCoordinatorWorkspace(workspace)
        case .windows(.accessibilityNotification(let name, let element)):
            handleAXNotificationImplementation(name, element: element)
        case .windows(.reconciliationRequested(var intent)):
            intent.id = sequence
            admitReconciliation(intent)
        case .windows(.removeTerminatedApplication(let pid)):
            removeWindows(forPID: pid)
        case .layout(let layout):
            handleCoordinatorLayout(layout)
        case .config(let config):
            handleCoordinatorConfig(config)
        case .persistence(let persistence):
            handleCoordinatorPersistence(persistence)
        case .timer(let timer):
            handleCoordinatorTimer(timer)
        case .ui(let action):
            handleCoordinatorUI(action)
        case .terminate(let reason):
            prepareForTermination(reason: reason)
        }
    }

    @MainActor private func handleCoordinatorInput(_ event: InputEvent) {
        switch event {
        case .command(let command, let animateWorkspace):
            admitCommand(command, animateWorkspace: animateWorkspace)
        case .sessionRecoveryRequested(let reason, let command):
            requestSessionRecoveryImplementation(reason: reason, command: command)
        case .userInteraction:
            scheduleActiveRescanForUserInputImplementation()
        case .focusedWindowProbeRequested(let reason):
            scheduleFocusedWindowProbeImplementation(reason: reason)
        case .focusedWindowProbeDue(let reason, let generation):
            handleFocusedWindowProbeDue(reason: reason, generation: generation)
        case .eventTapDisabled(let type):
            handleEventTapDisabledImplementation(type)
        case .sessionRecoveryEventTapDisabled:
            handleSessionRecoveryEventTapDisabledImplementation()
        case .sessionRecoveryCandidate(let event, let type):
            handleSessionRecoveryInput(event, type: type)
        }
    }

    @MainActor private func handleCoordinatorSession(_ event: SessionEvent) {
        switch event {
        case .stateChanged(let locked, let active, let sleeping, let reason):
            updateSessionStateImplementation(
                screenLocked: locked,
                workspaceActive: active,
                systemSleeping: sleeping,
                reason: reason
            )
            appPhase = isLayoutTrackingAllowed ? .running : .sessionUnavailable
        case .recoveryReady(let generation, let reason):
            completeSessionRecoveryImplementation(generation: generation, reason: reason)
            appPhase = isLayoutTrackingAllowed ? .running : .sessionUnavailable
            drainPendingCoordinatorWorkIfPossibleImplementation()
        }
    }

    @MainActor private func handleCoordinatorWorkspace(_ event: WorkspaceEvent) {
        switch event {
        case .applicationActivated(let app):
            applicationActivatedImplementation(app)
        case .applicationActivationSettled(let app):
            applicationActivationSettledImplementation(app)
        case .applicationLaunched(let app):
            applicationLaunchedImplementation(app)
        case .applicationTerminated(let app):
            applicationTerminatedImplementation(app)
        case .activeSpaceChanged:
            activeSpaceChangedImplementation()
        }
    }

    @MainActor private func handleCoordinatorTimer(_ event: TimerEvent) {
        switch event {
        case .periodicReconciliation:
            handlePeriodicTickImplementation()
        case .activeRescan:
            handleActiveRescanTickImplementation()
        case .appLaunchSettling:
            handleAppLaunchSettlingTickImplementation()
        case .appLaunchSettlingProbe(let pid, let reason):
            performAppLaunchSettlingReconciliation(pid: pid, reason: reason)
        case .manualResizeEnded(let element):
            handleManualResizeEnded(element: element)
        case .reconciliationDrain(let generation):
            guard generation == reconciliationDrainGeneration else {
                debugLog("reconciliation drain ignored generation=\(generation) current=\(reconciliationDrainGeneration)")
                return
            }
            reconciliationDrainScheduled = false
            drainPendingCoordinatorWorkIfPossibleImplementation()
        }
    }

    @MainActor private func handleCoordinatorLayout(_ event: LayoutEvent) {
        switch event {
        case .completed(let requestID), .cancelled(let requestID):
            debugLog("layout result request=\(requestID) event=\(event.logName)")
            drainPendingCoordinatorWorkIfPossibleImplementation()
        case .captureFailed(let requestID, let reason):
            debugLog("layout result request=\(requestID) event=capture-failed reason=\(reason)")
            drainPendingCoordinatorWorkIfPossibleImplementation()
        case .externallyResized:
            break
        }
    }

    @MainActor private func handleCoordinatorConfig(_ event: ConfigEvent) {
        switch event {
        case .loaded(let source):
            debugLog("config adopted source=\(source?.path ?? "fallback")")
        case .saved(let source):
            debugLog("config saved source=\(source.path)")
        case .reloadFailed(let reason), .saveFailed(let reason):
            debugLog("config operation failed reason=\(reason)")
        }
    }

    @MainActor private func handleCoordinatorPersistence(_ event: PersistenceEvent) {
        switch event {
        case .autosaveDue(.layout):
            writePersistentLayoutSnapshot()
        case .autosaveDue(.logicalSpaces):
            writePersistentLogicalSpaceSnapshotIfSafe()
        case .autosaveDue(.exitRestoration):
            break
        case .writeCompleted:
            break
        case .writeFailed(let kind, let reason):
            debugLog("persistence write failed kind=\(kind.rawValue) reason=\(reason)")
        }
    }

    @MainActor private func handleCoordinatorUI(_ action: UIAction) {
        switch action {
        case .showSettings:
            showSettingsFromMenuImplementation()
        case .openConfig:
            openConfigFromMenuImplementation()
        case .reloadConfig:
            reloadFromMenuImplementation()
        case .rescanWindows:
            requestReconciliation(
                .all(adoptFocused: true, source: .userInterface, reason: "menu-rescan")
            )
        case .saveConfig(let config, let closeOnSuccess):
            saveConfigFromSettingsImplementation(config, closeOnSuccess: closeOnSuccess)
        case .quit:
            prepareForTermination(reason: "menu")
            NSApp.terminate(nil)
        }
    }

    func requestReconciliation(_ intent: ReconciliationIntent) {
        enqueue(.windows(.reconciliationRequested(intent)))
    }

    @MainActor private func admitReconciliation(_ intent: ReconciliationIntent) {
        guard appPhase == .running, isLayoutTrackingAllowed else {
            coalescePendingReconciliation(intent, reason: "phase-\(appPhase.rawValue)")
            return
        }
        guard !reconciliationAdmissionClosed else {
            coalescePendingReconciliation(intent, reason: "layout-active")
            scheduleCoordinatorReconciliationDrain()
            return
        }
        executeReconciliation(intent)
    }

    @MainActor private var reconciliationAdmissionClosed: Bool {
        isApplyingLayout
            || animationTimer != nil
            || snapshotAnimationSession != nil
            || snapshotAnimationPreparing
            || pendingSnapshotDeferredLayout
    }

    @MainActor private func coalescePendingReconciliation(_ intent: ReconciliationIntent, reason: String) {
        if pendingCoordinatorReconciliation == nil {
            pendingCoordinatorReconciliation = intent
        } else {
            pendingCoordinatorReconciliation?.merge(intent)
        }
        debugLog(
            "reconciliation deferred request=\(intent.id?.description ?? "unassigned") source=\(intent.source.rawValue) reason=\(reason) pending=\(pendingCoordinatorReconciliation?.logScope ?? "none")"
        )
    }

    @MainActor private func executeReconciliation(_ intent: ReconciliationIntent) {
        debugLog(
            "reconciliation admitted request=\(intent.id?.description ?? "unassigned") source=\(intent.source.rawValue) scope=\(intent.logScope) adoptFocused=\(intent.adoptFocused) reason=\(intent.reason)"
        )
        switch intent.scope {
        case .allWindows:
            rescanWindows(adoptFocused: intent.adoptFocused)
        case .applications(let pids):
            let orderedPIDs = pids.sorted()
            for (index, pid) in orderedPIDs.enumerated() {
                if reconciliationAdmissionClosed {
                    var remainder = intent
                    remainder.scope = .applications(Set(orderedPIDs[index...]))
                    coalescePendingReconciliation(remainder, reason: "layout-started-during-batch")
                    scheduleCoordinatorReconciliationDrain()
                    return
                }
                reconcileWindows(forPID: pid, adoptFocused: intent.adoptFocused)
            }
        }
    }

    @MainActor private func scheduleCoordinatorReconciliationDrain() {
        guard !reconciliationDrainScheduled else {
            return
        }
        reconciliationDrainScheduled = true
        reconciliationDrainGeneration &+= 1
        let generation = reconciliationDrainGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.enqueue(.timer(.reconciliationDrain(generation: generation)))
        }
    }

    func drainPendingCoordinatorWorkIfPossible() {
        dispatchPrecondition(condition: .onQueue(.main))
        MainActor.assumeIsolated {
            drainPendingCoordinatorWorkIfPossibleImplementation()
        }
    }

    @MainActor private func drainPendingCoordinatorWorkIfPossibleImplementation() {
        guard appPhase == .running,
              isLayoutTrackingAllowed,
              !reconciliationAdmissionClosed
        else {
            if pendingCoordinatorReconciliation != nil {
                scheduleCoordinatorReconciliationDrain()
            }
            return
        }

        if let pending = pendingCoordinatorReconciliation {
            pendingCoordinatorReconciliation = nil
            executeReconciliation(pending)
        }
        drainPendingFocusCommands()
    }

    @MainActor private func admitCommand(_ command: Command, animateWorkspace: Bool = false) {
        guard appPhase == .running, isLayoutTrackingAllowed else {
            pendingFocusCommands.append(command)
            debugLog(
                "command deferred command=\(String(describing: command)) reason=phase-\(appPhase.rawValue) pending=\(pendingFocusCommands.count)"
            )
            return
        }
        if shouldQueueFocusCommand(command) {
            keyboardFocusAuthorityUntil = CFAbsoluteTimeGetCurrent() + 1.5
        }
        let shouldSerialize = animationStrategy != .snapshot
            && shouldQueueFocusCommand(command)
            && reconciliationAdmissionClosed
        guard shouldSerialize else {
            perform(command, animateWorkspace: animateWorkspace)
            return
        }
        pendingFocusCommands.append(command)
        debugLog("command deferred command=\(String(describing: command)) pending=\(pendingFocusCommands.count)")
    }

    @MainActor func prepareForTermination(reason: String) {
        guard !terminationPrepared else {
            debugLog("termination preparation ignored reason=already-prepared source=\(reason)")
            return
        }
        terminationPrepared = true
        appPhase = .terminating
        debugLog("termination preparation begin source=\(reason)")
        persistenceController.stopTimers()
        reconciliationTimer?.invalidate()
        activeRescanTimer?.invalidate()
        appLaunchSettlingTimer?.invalidate()
        uninstallFocusedWindowInputMonitor()
        sessionController.stop()
        uninstallEventTap()
        uninstallCarbonHotKeys()
        pendingSnapshotDeferredLayout = false
        pendingSnapshotDeferredLayoutGeneration &+= 1
        stopAnimation(clearPresentation: true)
        cancelActiveLayoutRequest(reason: "termination")
        writePersistentLayoutSnapshot()
        writePersistentLogicalSpaceSnapshot()
        restoreManagedWindowsForExit()
        persistenceController.stopCleanupWatcher(removeRestoreFile: true)
        appPhase = .terminated
        debugLog("termination preparation complete source=\(reason)")
    }

    @MainActor private func assertCoordinatorInvariants() {
        #if DEBUG
        assert(Thread.isMainThread, "Coordinator events must run on the main thread")
        assert(!isHandlingCoordinatorEvent || activeCoordinatorSequence == nil)
        assert(coordinatorEventQueue.count < 1_024, "Coordinator event queue is unexpectedly unbounded")
        assert(pendingFocusCommands.count < 256, "Pending command queue is unexpectedly unbounded")
        assert(
            isApplyingLayout == (activeLayoutRequestGeneration != nil),
            "Layout activity and request ownership must change together"
        )
        if let session = snapshotAnimationSession {
            assert(
                session.requestGeneration == activeLayoutRequestGeneration,
                "The snapshot session must belong to the active layout request"
            )
        }
        if snapshotAnimationPreparing {
            assert(
                snapshotAnimationPreparingRequestGeneration == activeLayoutRequestGeneration,
                "Snapshot preparation must belong to the active layout request"
            )
        } else {
            assert(
                snapshotAnimationPreparingRequestGeneration == nil,
                "Inactive snapshot preparation cannot retain a request"
            )
        }
        #endif
    }
}

private extension ReconciliationIntent {
    var logScope: String {
        switch scope {
        case .allWindows:
            return "all"
        case .applications(let pids):
            return "pids:\(pids.sorted().map(String.init).joined(separator: ","))"
        }
    }
}

private extension AppEvent {
    var logName: String {
        switch self {
        case .input(let event): return event.logName
        case .session(let event): return event.logName
        case .workspace(let event): return event.logName
        case .windows(let event): return event.logName
        case .layout(let event): return event.logName
        case .config(let event): return event.logName
        case .persistence(let event): return event.logName
        case .timer(let event): return event.logName
        case .ui(let event): return event.logName
        case .terminate: return "app.terminate"
        }
    }
}

private extension InputEvent {
    var logName: String {
        switch self {
        case .command: return "input.command"
        case .sessionRecoveryRequested: return "input.session-recovery"
        case .userInteraction: return "input.interaction"
        case .focusedWindowProbeRequested: return "input.focused-window-probe-requested"
        case .focusedWindowProbeDue: return "input.focused-window-probe-due"
        case .eventTapDisabled: return "input.tap-disabled"
        case .sessionRecoveryEventTapDisabled: return "input.recovery-tap-disabled"
        case .sessionRecoveryCandidate: return "input.recovery-candidate"
        }
    }
}

private extension SessionEvent {
    var logName: String {
        switch self {
        case .stateChanged: return "session.state-changed"
        case .recoveryReady: return "session.recovery-ready"
        }
    }
}

private extension WorkspaceEvent {
    var logName: String {
        switch self {
        case .applicationActivated: return "workspace.application-activated"
        case .applicationActivationSettled: return "workspace.application-activation-settled"
        case .applicationLaunched: return "workspace.application-launched"
        case .applicationTerminated: return "workspace.application-terminated"
        case .activeSpaceChanged: return "workspace.active-space-changed"
        }
    }
}

private extension WindowEvent {
    var logName: String {
        switch self {
        case .accessibilityNotification: return "windows.ax-notification"
        case .reconciliationRequested: return "windows.reconciliation-requested"
        case .removeTerminatedApplication: return "windows.remove-terminated-application"
        }
    }
}

private extension TimerEvent {
    var logName: String {
        switch self {
        case .periodicReconciliation: return "timer.periodic-reconciliation"
        case .activeRescan: return "timer.active-rescan"
        case .appLaunchSettling: return "timer.launch-settling"
        case .appLaunchSettlingProbe: return "timer.launch-settling-probe"
        case .manualResizeEnded: return "timer.manual-resize-ended"
        case .reconciliationDrain: return "timer.reconciliation-drain"
        }
    }
}

private extension UIAction {
    var logName: String {
        switch self {
        case .showSettings: return "ui.show-settings"
        case .openConfig: return "ui.open-config"
        case .reloadConfig: return "ui.reload-config"
        case .rescanWindows: return "ui.rescan-windows"
        case .saveConfig: return "ui.save-config"
        case .quit: return "ui.quit"
        }
    }
}

private extension LayoutEvent {
    var logName: String {
        switch self {
        case .completed: return "layout.completed"
        case .cancelled: return "layout.cancelled"
        case .captureFailed: return "layout.capture-failed"
        case .externallyResized: return "layout.externally-resized"
        }
    }
}

private extension ConfigEvent {
    var logName: String {
        switch self {
        case .loaded: return "config.loaded"
        case .reloadFailed: return "config.reload-failed"
        case .saved: return "config.saved"
        case .saveFailed: return "config.save-failed"
        }
    }
}

private extension PersistenceEvent {
    var logName: String {
        switch self {
        case .autosaveDue: return "persistence.autosave-due"
        case .writeCompleted: return "persistence.write-completed"
        case .writeFailed: return "persistence.write-failed"
        }
    }
}
