import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

/// Immutable result of an AX enumeration. Reconciliation converts this into a
/// canonical `ManagedWindow` only when the logical model adopts the window.
struct DiscoveredWindowObservation {
    let element: AXUIElement
    let pid: pid_t
    let windowID: UInt32?
    let bundleID: String?
    let appName: String
    let title: String
}

private struct WindowDiscoverySnapshot {
    let observations: [DiscoveredWindowObservation]
    let unavailablePIDs: Set<pid_t>
}

private struct MissingWindowContext {
    let isFullScan: Bool
    let axEnumerationUnavailable: Bool
    let reason: String
}

private struct MissingWindowResult {
    let changed: Bool
    let removedActive: Bool
    let canSaveLogicalSpace: Bool
}

@MainActor
private final class FullWindowDiscoveryAccumulator {
    let generation: UInt64
    let completion: (Bool) -> Void
    var remaining: Int
    var observations: [DiscoveredWindowObservation] = []
    var unavailablePIDs = Set<pid_t>()
    var staleRescanRequested = false

    init(generation: UInt64, remaining: Int, completion: @escaping (Bool) -> Void) {
        self.generation = generation
        self.remaining = remaining
        self.completion = completion
    }
}

extension Miri {
    func applicationActivatedImplementation(_ app: NSRunningApplication) {
        guard appPhase == .running,
              sessionController.isLayoutTrackingAllowed else { return }
        refreshTransientSystemWindowState { [weak self, weak app] in
            guard let self,
                  let app,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
            else { return }
            self.finishApplicationActivationAfterTransientRefresh(app)
        }
    }

    func finishApplicationActivationAfterTransientRefresh(_ app: NSRunningApplication) {
        guard sessionController.isLayoutTrackingAllowed,
              !windowManagement.observation.transientWindowActive
        else { return }
        let previousPID = lastActivatedApplicationPID
        lastActivatedApplicationPID = app.processIdentifier

        if let previousPID, previousPID != app.processIdentifier {
            requestReconciliation(
                .application(
                    pid: previousPID,
                    adoptFocused: false,
                    source: .workspace,
                    reason: "NSWorkspaceDidActivate:previous-app"
                )
            )
        }

        windowManagement.observation.scheduleApplicationActivationSettled(app)
        guard !layoutController.isActive else { return }
        guard CFAbsoluteTimeGetCurrent() >= suppressFocusedWindowNotificationsUntil else {
            return
        }
        requestFocusedWindowAdoption(
            pid: app.processIdentifier,
            animateIfSameWorkspace: true,
            reason: "NSWorkspaceDidActivate"
        )
    }

    func applicationActivationSettledImplementation(_ app: NSRunningApplication) {
        guard appPhase == .running,
              sessionController.isLayoutTrackingAllowed else { return }
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard frontmostPID == app.processIdentifier else {
            let frontmostDescription = frontmostPID.map(String.init) ?? "nil"
            debugLog(
                "activation settle ignored reason=stale-app pid=\(app.processIdentifier) frontmostPID=\(frontmostDescription)"
            )
            return
        }
        requestReconciliation(
            .application(
                pid: app.processIdentifier,
                adoptFocused: true,
                source: .workspace,
                reason: "NSWorkspaceDidActivate:settle"
            )
        )
    }

    func applicationLaunchedImplementation(_ app: NSRunningApplication) {
        windowManagement.observation.noteWindowStateChange(pid: app.processIdentifier)
        guard appPhase == .running,
              sessionController.isLayoutTrackingAllowed else {
            if (sessionController.isAwaitingRecoveryInteraction || appPhase == .sessionRecovering),
               app.activationPolicy == .regular {
                pendingSessionRecoveryLaunchedPIDs.insert(app.processIdentifier)
                debugLog("session recovery noted launched app pid=\(app.processIdentifier) bundle='\(app.bundleIdentifier ?? "nil")'")
            }
            return
        }
        beginAppLaunchSettling(for: app, reason: "NSWorkspaceDidLaunch")
    }

    func applicationTerminatedImplementation(_ app: NSRunningApplication) {
        pendingSessionRecoveryLaunchedPIDs.remove(app.processIdentifier)
        finishAppLaunchSettling(
            pid: app.processIdentifier,
            reason: "NSWorkspaceDidTerminate",
            allowFutureLaunch: true
        )
        removeWindows(
            forPID: app.processIdentifier,
            applyLayout: appPhase == .running
                && sessionController.isLayoutTrackingAllowed
                && !axReconciliationShouldDefer
        )
        if appPhase == .running,
           sessionController.isLayoutTrackingAllowed,
           axReconciliationShouldDefer {
            requestReconciliation(
                .all(adoptFocused: true, source: .workspace, reason: "application-terminated")
            )
        }
    }

    func activeSpaceChangedImplementation() {
        windowManagement.observation.noteGlobalStateChange()
        guard appPhase == .running,
              sessionController.isLayoutTrackingAllowed else {
            return
        }
        if activeContextHasBufferedSourceWindows() {
            debugLog("skipping logical macOS space save during switch because active context has buffered source windows")
        } else {
            saveActiveLogicalSpaceContext()
        }
        windowManagement.beginLogicalSpaceSwitch()
        spaceChangeGeneration &+= 1
        debugLog("active macOS space changed generation=\(spaceChangeGeneration)")
        windowManagement.observation.scheduleReconciliation(
            .all(adoptFocused: true, source: .workspace, reason: "active-space-settle"),
            delay: 0.12
        )
    }

    func reconcileWindows(
        forPID pid: pid_t,
        adoptFocused: Bool,
        priority: AXOperationPriority = .normal
    ) {
        guard let app = NSRunningApplication(processIdentifier: pid) else {
            debugLog("reconcile skipped reason=no-running-app pid=\(pid)")
            return
        }
        reconcileWindows(for: app, adoptFocused: adoptFocused, priority: priority)
    }

    func reconcileWindows(
        for app: NSRunningApplication,
        adoptFocused: Bool,
        priority: AXOperationPriority = .normal
    ) {
        guard sessionController.isLayoutTrackingAllowed else {
            return
        }
        guard !layoutController.isActive else {
            requestReconciliation(
                .application(
                    pid: app.processIdentifier,
                    adoptFocused: adoptFocused,
                    source: .accessibility,
                    reason: "reconcile-gate"
                )
            )
            return
        }
        guard app.activationPolicy == .regular else {
            debugLog("reconcile skipped reason=non-regular-app app='\(app.localizedName ?? "pid \(app.processIdentifier)")' bundle='\(app.bundleIdentifier ?? "nil")' pid=\(app.processIdentifier) activationPolicy=\(app.activationPolicy.rawValue)")
            return
        }
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            debugLog("reconcile skipped reason=self pid=\(app.processIdentifier)")
            return
        }
        if app.isHidden {
            windowManagement.observation.noteWindowStateChange(pid: app.processIdentifier)
            reconcileDiscoveredWindows(
                [],
                replacingPID: app.processIdentifier,
                layoutLockDelay: 0.02
            )
            return
        }
        guard !windowManagement.observation.transientWindowActive else {
            debugLog("reconcile skipped reason=transient-system-window-active app='\(app.localizedName ?? "pid \(app.processIdentifier)")' bundle='\(app.bundleIdentifier ?? "nil")' pid=\(app.processIdentifier)")
            return
        }

        startObservingApp(pid: app.processIdentifier)
        let pid = app.processIdentifier
        let stateGeneration = windowManagement.observation.stateGeneration(for: pid)
        let supplementalHandles = allWindows().filter { $0.pid == pid }.map {
            AXElementHandle(element: $0.element, pid: $0.pid, windowID: $0.windowID)
        }
        axOperations.readApplication(
            pid: pid,
            priority: priority,
            supplementalHandles: supplementalHandles,
            coalescingKey: "targeted-reconciliation"
        ) { [weak self] result in
            guard let self,
                  self.sessionController.isLayoutTrackingAllowed,
                  NSRunningApplication(processIdentifier: pid) != nil
            else { return }
            guard stateGeneration == self.windowManagement.observation.stateGeneration(for: pid) else {
                self.debugLog("reconcile result discarded reason=stale-state pid=\(pid)")
                self.requestReconciliation(.application(
                    pid: pid,
                    adoptFocused: false,
                    source: .delayedProbe,
                    reason: "stale-async-reconcile"
                ))
                return
            }
            let mayAdoptFocused = adoptFocused
                && NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
            guard !self.layoutController.isActive else {
                self.requestReconciliation(.application(
                    pid: pid,
                    adoptFocused: mayAdoptFocused,
                    source: .accessibility,
                    reason: "async-reconcile-layout-active"
                ))
                return
            }
            guard result.disposition == .completed, let snapshot = result.value,
                  let liveApp = NSRunningApplication(processIdentifier: pid)
            else {
                self.debugLog("reconcile ax-windows unavailable app='\(app.localizedName ?? "pid \(pid)")' bundle='\(app.bundleIdentifier ?? "nil")' pid=\(pid)")
                self.removeVanishedWindows(
                    forPID: pid,
                    adoptFocused: mayAdoptFocused,
                    reason: "reconcile AXWindows unavailable"
                )
                return
            }
            guard !liveApp.isHidden else {
                self.windowManagement.observation.noteWindowStateChange(pid: pid)
                self.reconcileDiscoveredWindows(
                    [],
                    replacingPID: pid,
                    layoutLockDelay: 0.02
                )
                return
            }
            let observations = self.discoveredWindows(from: snapshot, app: liveApp)
            let discovered = self.canonicalWindows(from: observations)
            self.reconcileDiscoveredWindows(
                discovered,
                replacingPID: pid,
                layoutLockDelay: 0.08
            )
            if mayAdoptFocused {
                self.requestFocusedWindowAdoption(
                    pid: pid,
                    animateIfSameWorkspace: true,
                    reason: "targeted-reconciliation"
                )
            }
        }
    }

    func removeVanishedWindows(forPID pid: pid_t, adoptFocused: Bool, reason: String) {
        var changed = false
        var removedActive = false

        for window in allWindows().filter({ $0.pid == pid }) {
            let result = reconcileMissingWindow(
                window,
                context: MissingWindowContext(
                    isFullScan: false,
                    axEnumerationUnavailable: true,
                    reason: reason
                )
            )
            changed = result.changed || changed
            removedActive = result.removedActive || removedActive
        }

        if changed {
            projectLayout(focusActiveWindow: adoptFocused || removedActive, layoutLockDelay: 0.02)
            saveActiveLogicalSpaceContext()
        }
    }

    func reconcileDiscoveredWindows(
        _ discovered: [ManagedWindow],
        replacingPID pid: pid_t,
        layoutLockDelay: TimeInterval
    ) {
        if let fullscreenState = focusedRememberedFullscreenWindowState() {
            enforceRememberedFullscreenWorkspaceIfNeeded(fullscreenState)
            debugLog("skipping app reconciliation while focused on remembered fullscreen app='\(fullscreenState.appName)' bundle='\(fullscreenState.bundleID ?? "nil")'")
            return
        }

        var changed = false
        var shouldSaveLogicalSpaceContext = true

        for found in discovered {
            noteAppLaunchSettlingWindowObserved(found)
        }

        for window in allWindows().filter({ $0.pid == pid }) {
            if discovered.contains(where: { sameWindow($0.element, window.element) }) {
                continue
            }

            let result = reconcileMissingWindow(
                window,
                context: MissingWindowContext(
                    isFullScan: false,
                    axEnumerationUnavailable: false,
                    reason: "valid-ax-enumeration"
                )
            )
            changed = result.changed || changed
            shouldSaveLogicalSpaceContext = result.canSaveLogicalSpace && shouldSaveLogicalSpaceContext
        }

        restoreExitedFullscreenWindows(discovered: discovered)

        for found in discovered {
            changed = upsertDiscoveredWindow(found) || changed
        }

        reconcileWorkspaceCapacity()
        if changed {
            projectLayout(focusActiveWindow: false, layoutLockDelay: layoutLockDelay)
        }
        if changed && shouldSaveLogicalSpaceContext {
            saveActiveLogicalSpaceContext()
        }
    }

    @discardableResult
    func upsertDiscoveredWindow(_ found: ManagedWindow) -> Bool {
        if let existing = allWindows().first(where: { sameWindow($0.element, found.element) }) {
            windowManagement.clearPendingFullscreenTransition(for: ObjectIdentifier(existing))
            consumeBufferedWindowIfNeeded(existing)
            let previousBehavior = behavior(for: existing)
            let metadataChanged = existing.title != found.title
                || existing.appName != found.appName
                || existing.bundleID != found.bundleID
            existing.title = found.title
            existing.appName = found.appName
            existing.bundleID = found.bundleID

            if metadataChanged {
                notifyWorkspaceBarNeedsRefresh()
            }

            let nextBehavior = behavior(for: existing)
            let shouldFloat = nextBehavior == .float
            let isFloating = windowManagement.floatingWindows.contains(where: { $0 === existing })
            guard previousBehavior != nextBehavior || shouldFloat != isFloating else {
                return false
            }
            removeWindow(existing)
            if shouldFloat {
                insertFloatingWindow(existing, applyLayout: false)
            } else {
                insertNewWindow(existing, applyLayout: false, focusNewWindow: false)
            }
            return true
        }

        consumeBufferedWindowIfNeeded(found)
        if behavior(for: found) == .float {
            insertFloatingWindow(found, applyLayout: false)
        } else {
            restoreMinimizedWindowStateIfAvailable(for: found)
            // Discovery mutates lifecycle state only. A separate current,
            // frontmost-validated focused-window read decides focus afterward.
            insertRestoredWindowNearFocused(
                found,
                applyLayout: false,
                focusNewWindow: false
            )
        }
        return true
    }

    func removeWindows(forPID pid: pid_t, applyLayout: Bool = true) {
        let cleanup = windowManagement.removeGlobally(pid: pid)
        for window in cleanup.removedWindows { layoutController.removeTracking(for: window) }
        reconcileWorkspaceCapacity()
        windowManagement.observation.removeApplication(pid: pid)
        if cleanup.changed, applyLayout {
            projectLayout(focusActiveWindow: false, layoutLockDelay: 0.08)
            saveActiveLogicalSpaceContext()
        } else if cleanup.changed {
            saveActiveLogicalSpaceContext()
            schedulePersistentLayoutSnapshotWrite()
            notifyWorkspaceBarNeedsRefresh()
        }
    }

    func rescanWindows(
        adoptFocused: Bool,
        completion: @escaping (Bool) -> Void = { _ in }
    ) {
        guard sessionController.isLayoutTrackingAllowed else {
            completion(false)
            return
        }
        guard !layoutController.isActive else {
            requestReconciliation(
                .all(adoptFocused: adoptFocused, source: .periodicTimer, reason: "rescan-gate")
            )
            completion(false)
            return
        }
        guard !windowManagement.observation.transientWindowActive else {
            completion(false)
            return
        }

        fullWindowScanGeneration &+= 1
        let generation = fullWindowScanGeneration
        let stateGeneration = windowManagement.observation.globalStateGeneration
        let apps = NSWorkspace.shared.runningApplications
            .filter {
                $0.activationPolicy == .regular
                    && !$0.isHidden
                    && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
            }
            .sorted { $0.processIdentifier < $1.processIdentifier }
        let accumulator = FullWindowDiscoveryAccumulator(
            generation: generation,
            remaining: apps.count,
            completion: completion
        )
        guard !apps.isEmpty else {
            completeRescanWindows(
                WindowDiscoverySnapshot(observations: [], unavailablePIDs: []),
                adoptFocused: adoptFocused,
                completion: completion
            )
            return
        }

        for app in apps {
            startObservingApp(pid: app.processIdentifier)
            let pid = app.processIdentifier
            let supplementalHandles = allWindows().filter { $0.pid == pid }.map {
                AXElementHandle(element: $0.element, pid: $0.pid, windowID: $0.windowID)
            }
            axOperations.readApplication(
                pid: pid,
                priority: .normal,
                supplementalHandles: supplementalHandles,
                coalescingKey: "full-reconciliation"
            ) { [weak self, weak app] result in
                guard let self,
                      generation == self.fullWindowScanGeneration,
                      accumulator.generation == generation
                else { return }
                guard stateGeneration == self.windowManagement.observation.globalStateGeneration else {
                    if !accumulator.staleRescanRequested {
                        accumulator.staleRescanRequested = true
                        self.fullWindowScanGeneration &+= 1
                        accumulator.completion(false)
                        self.requestReconciliation(.all(
                            adoptFocused: false,
                            source: .delayedProbe,
                            reason: "stale-async-full-rescan"
                        ))
                    }
                    return
                }
                if result.disposition == .completed,
                   let snapshot = result.value,
                   let liveApp = app ?? NSRunningApplication(processIdentifier: pid)
                {
                    if liveApp.isHidden {
                        self.windowManagement.observation.noteWindowStateChange(pid: pid)
                        if !accumulator.staleRescanRequested {
                            accumulator.staleRescanRequested = true
                            self.fullWindowScanGeneration &+= 1
                            accumulator.completion(false)
                            self.requestReconciliation(.all(
                                adoptFocused: false,
                                source: .delayedProbe,
                                reason: "app-hidden-during-full-rescan"
                            ))
                        }
                        return
                    }
                    accumulator.observations.append(contentsOf: self.discoveredWindows(
                        from: snapshot,
                        app: liveApp
                    ))
                } else {
                    accumulator.unavailablePIDs.insert(pid)
                    accumulator.observations.append(contentsOf: self.allWindows()
                        .filter { $0.pid == pid }
                        .map(self.observationDescriptor))
                }
                accumulator.remaining -= 1
                guard accumulator.remaining == 0 else { return }
                self.completeRescanWindows(
                    WindowDiscoverySnapshot(
                        observations: accumulator.observations,
                        unavailablePIDs: accumulator.unavailablePIDs
                    ),
                    adoptFocused: adoptFocused,
                    completion: accumulator.completion
                )
            }
        }
    }

    private func completeRescanWindows(
        _ discovery: WindowDiscoverySnapshot,
        adoptFocused: Bool,
        completion: @escaping (Bool) -> Void
    ) {
        guard sessionController.isLayoutTrackingAllowed else {
            completion(false)
            return
        }
        guard !layoutController.isActive else {
            requestReconciliation(.all(
                adoptFocused: adoptFocused,
                source: .accessibility,
                reason: "async-full-rescan-layout-active"
            ))
            completion(false)
            return
        }

        let discovered = canonicalWindows(from: discovery.observations)
        for found in discovered {
            noteAppLaunchSettlingWindowObserved(found)
        }
        let restoredPersistentLogicalSpace = restorePersistentLogicalSpaceContextsIfNeeded(discovered: discovered)
        if let fullscreenState = focusedRememberedFullscreenWindowState() {
            enforceRememberedFullscreenWorkspaceIfNeeded(fullscreenState)
            debugLog("skipping rescan mutations while focused on remembered fullscreen app='\(fullscreenState.appName)' bundle='\(fullscreenState.bundleID ?? "nil")' workspace=\(fullscreenState.workspace + 1)")
            completion(true)
            return
        }
        if likelyFullscreenExitSettle(discovered: discovered) {
            debugLog("freezing logical macOS space during fullscreen settle visible=0 known=\(currentLogicalSpaceSignature().count)")
            windowManagement.observation.scheduleReconciliation(
                .all(adoptFocused: true, source: .delayedProbe, reason: "fullscreen-exit-settle"),
                delay: 0.25
            )
            completion(false)
            return
        }

        let switchedLogicalSpace = handlePendingLogicalSpaceSwitch(discovered: discovered)
        var changed = switchedLogicalSpace || restoredPersistentLogicalSpace
        var shouldSaveLogicalSpaceContext = true

        if likelyBulkTransientDisappearance(discovered: discovered) {
            debugLog("freezing logical macOS space during bulk transient disappearance visible=\(discoveredSignature(discovered).count) known=\(currentLogicalSpaceSignature().count)")
            windowManagement.observation.scheduleReconciliation(
                .all(adoptFocused: true, source: .delayedProbe, reason: "bulk-disappearance-settle"),
                delay: 0.25
            )
            completion(false)
            return
        }

        for window in allWindows() {
            if !discovered.contains(where: { sameWindow($0.element, window.element) }) {
                let result = reconcileMissingWindow(
                    window,
                    context: MissingWindowContext(
                        isFullScan: true,
                        axEnumerationUnavailable: discovery.unavailablePIDs.contains(window.pid),
                        reason: "full-rescan"
                    )
                )
                changed = result.changed || changed
                shouldSaveLogicalSpaceContext = result.canSaveLogicalSpace && shouldSaveLogicalSpaceContext
            }
        }

        restoreExitedFullscreenWindows(discovered: discovered)

        for found in discovered {
            changed = upsertDiscoveredWindow(found) || changed
        }

        let restoredPersistentLayout = applyPersistentLayoutSnapshotIfNeeded()
        reconcileWorkspaceCapacity()

        if adoptFocused {
            let layoutDelay = restoredPersistentLayout ? 0.4 : 0.08
            if fullscreenSpaceChangeGuardIsActive() {
                enforceFullscreenSpaceGuardWorkspace()
                projectLayout(focusActiveWindow: false, layoutLockDelay: layoutDelay)
            } else {
                projectLayout(focusActiveWindow: false, layoutLockDelay: layoutDelay)
                let focusRequestGeneration = focusStateGeneration
                requestFocusedWindowAdoption(
                    pid: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                    animateIfSameWorkspace: false,
                    reason: "full-reconciliation"
                ) { [weak self] adopted in
                    guard let self else {
                        completion(false)
                        return
                    }
                    if !adopted,
                       self.focusStateGeneration == focusRequestGeneration,
                       self.restorePersistentFocusedWindow()
                    {
                        self.projectLayout(focusActiveWindow: true, layoutLockDelay: layoutDelay)
                    }
                    completion(true)
                }
                if shouldSaveLogicalSpaceContext {
                    saveActiveLogicalSpaceContext()
                }
                return
            }
        } else if changed || restoredPersistentLayout {
            projectLayout(focusActiveWindow: false, layoutLockDelay: restoredPersistentLayout ? 0.4 : 0.08)
        }
        if shouldSaveLogicalSpaceContext {
            saveActiveLogicalSpaceContext()
        }
        completion(true)
    }

    private func missingWindowDisposition(
        _ window: ManagedWindow,
        context: MissingWindowContext
    ) -> MissingWindowDisposition {
        let now = CFAbsoluteTimeGetCurrent()
        let identity = ObjectIdentifier(window)
        let runningApp = NSRunningApplication(processIdentifier: window.pid)
        let temporarilyHidden = runningApp?.isHidden == true || window.isMinimized
        let pendingFullscreenWithinGrace = windowManagement
            .pendingFullscreenTransition(for: identity)
            .map { now - $0 < fullscreenTransitionGrace } == true
        let hasCGInfo = windowHasCGInfo(window)
        let fullscreen = window.isFullscreen
        let behaviorIsIgnored = behavior(for: window) == .ignore
        let fullscreenGuardActive = now < fullscreenTransitionGuardUntil
        let appearsInUnknownSpace = windowAppearsInUnknownSpace(window)
        let eligibleForLaunchDeferral = !(context.axEnumerationUnavailable && hasCGInfo)
            && !fullscreen
            && !pendingFullscreenWithinGrace
            && !(context.isFullScan
                && runningApp != nil
                && !temporarilyHidden
                && !behaviorIsIgnored
                && fullscreenGuardActive)
            && !appearsInUnknownSpace
            && !temporarilyHidden
        let launchRemovalDeferred = eligibleForLaunchDeferral
            && shouldDeferMissingWindowRemovalDuringAppLaunchSettling(
                window,
                reason: context.reason
            )
        return windowManagement.classifyMissingWindow(MissingWindowFacts(
            axEnumerationUnavailable: context.axEnumerationUnavailable,
            hasCGInfo: hasCGInfo,
            isFullscreen: fullscreen,
            pendingFullscreenWithinGrace: pendingFullscreenWithinGrace,
            isFullScan: context.isFullScan,
            runningApplicationExists: runningApp != nil,
            temporarilyHidden: temporarilyHidden,
            behaviorIsIgnored: behaviorIsIgnored,
            fullscreenGuardActive: fullscreenGuardActive,
            appearsInUnknownSpace: appearsInUnknownSpace,
            launchRemovalDeferred: launchRemovalDeferred
        ))
    }

    private func reconcileMissingWindow(
        _ window: ManagedWindow,
        context: MissingWindowContext
    ) -> MissingWindowResult {
        let wasActive = activeWindow().map { $0 === window } == true
        let identity = ObjectIdentifier(window)
        switch missingWindowDisposition(window, context: context) {
        case .preserveCGVisible, .preserveLaunchSettling:
            return MissingWindowResult(changed: false, removedActive: false, canSaveLogicalSpace: true)
        case .preservePendingFullscreen:
            debugLog("preserving pending fullscreen transition app='\(window.appName)' bundle='\(window.bundleID ?? "nil")' title='\(window.title)'")
            return MissingWindowResult(changed: false, removedActive: false, canSaveLogicalSpace: true)
        case .preserveFullscreenGuard:
            windowManagement.clearPendingFullscreenTransition(for: identity)
            debugLog("preserving window during fullscreen transition app='\(window.appName)' bundle='\(window.bundleID ?? "nil")' title='\(window.title)'")
            return MissingWindowResult(changed: false, removedActive: false, canSaveLogicalSpace: true)
        case .moveToFullscreenState:
            windowManagement.clearPendingFullscreenTransition(for: identity)
            fullscreenTransitionGuardUntil = max(
                fullscreenTransitionGuardUntil,
                CFAbsoluteTimeGetCurrent() + fullscreenTransitionGrace
            )
            rememberFullscreenWindowState(window)
            removeWindow(window, preferRightFocus: true)
            return MissingWindowResult(changed: true, removedActive: wasActive, canSaveLogicalSpace: true)
        case .bufferUnknownSpace:
            _ = bufferWindowInUnknownSpaceIfNeeded(window)
            return MissingWindowResult(changed: true, removedActive: wasActive, canSaveLogicalSpace: false)
        case .remove(let rememberMinimized):
            windowManagement.clearPendingFullscreenTransition(for: identity)
            if rememberMinimized { rememberMinimizedWindowState(window) }
            debugLog(
                "removing missing window reason=\(context.reason) fullScan=\(context.isFullScan) app='\(window.appName)' bundle='\(window.bundleID ?? "nil")' pid=\(window.pid) title='\(window.title)' id=\(window.windowID.map(String.init) ?? "nil")"
            )
            removeWindow(window, preferRightFocus: rememberMinimized)
            return MissingWindowResult(changed: true, removedActive: wasActive, canSaveLogicalSpace: true)
        }
    }

    func discoveredWindows(
        from snapshot: AXApplicationReadSnapshot,
        app: NSRunningApplication
    ) -> [DiscoveredWindowObservation] {
        let pid = snapshot.pid
        let windowSnapshots = snapshot.windows.filter { $0.role == kAXWindowRole }
        let knownWindows = allWindows().filter { $0.pid == pid }
        for windowSnapshot in windowSnapshots + snapshot.supplementalWindows {
            if let known = knownWindows.first(where: {
                sameWindow($0.element, windowSnapshot.handle.element)
            }) {
                known.isMinimized = windowSnapshot.minimized == true
                known.isFullscreen = windowSnapshot.fullscreen == true
            }
        }

        if snapshot.containsApplicationRoot, windowSnapshots.isEmpty {
            debugLog("ignoring malformed root-only ax-windows response app='\(app.localizedName ?? "pid \(pid)")' bundle='\(app.bundleIdentifier ?? "nil")' pid=\(pid)")
            return knownWindows.map(observationDescriptor)
        }

        var windows = windowSnapshots.compactMap {
            discoveredWindow(from: $0, app: app, source: "async-scan")
        }
        if snapshot.containsApplicationRoot {
            for knownWindow in knownWindows where !windows.contains(where: {
                sameWindow($0.element, knownWindow.element)
            }) {
                windows.append(observationDescriptor(for: knownWindow))
            }
            debugLog("accepted windows from malformed mixed ax-windows response app='\(app.localizedName ?? "pid \(pid)")' bundle='\(app.bundleIdentifier ?? "nil")' pid=\(pid) reported=\(windowSnapshots.count) accepted=\(windows.count)")
        }
        return windows.sorted(by: observationSortOrder)
    }

    func discoveredWindow(
        from snapshot: AXWindowReadSnapshot,
        app: NSRunningApplication,
        source: String
    ) -> DiscoveredWindowObservation? {
        let element = snapshot.handle.element
        if debugLogging {
            debugLog(
                "raw ax window source=\(source) app='\(app.localizedName ?? "pid \(snapshot.handle.pid)")' bundle='\(app.bundleIdentifier ?? "nil")' pid=\(snapshot.handle.pid) title='\(snapshot.title)' id=\(snapshot.handle.windowID.map(String.init) ?? "nil") role=\(snapshot.role ?? "nil") subrole=\(snapshot.subrole ?? "nil") frame=\(snapshot.frame.map { String(describing: $0) } ?? "nil") minimized=\(snapshot.minimized.map(String.init) ?? "nil") fullscreen=\(snapshot.fullscreen.map(String.init) ?? "nil") manageable=\(isManageableWindow(snapshot)) known=\(isKnownWindow(element))"
            )
        }
        noteFullscreenSpaceHelperIfNeeded(snapshot)
        guard snapshot.subrole != "AXUnknown",
              snapshot.minimized != true,
              snapshot.fullscreen != true,
              isManageableWindow(snapshot) || isKnownWindow(element) || isRememberedFullscreenWindow(element)
        else {
            return nil
        }

        let pid = snapshot.handle.pid
        let window = ManagedWindow(
            element: element,
            pid: pid,
            windowID: snapshot.handle.windowID,
            bundleID: app.bundleIdentifier,
            appName: app.localizedName ?? "pid \(pid)",
            title: snapshot.title
        )
        if !isKnownWindow(element), isLikelyTransientPopup(window, app: app, frame: snapshot.frame) {
            logTransientPopupIfNeeded(window, app: app, frame: snapshot.frame)
            return nil
        }
        if !isKnownWindow(element), isPictureInPictureWindow(window) {
            logIgnoredPictureInPictureIfNeeded(window, app: app, frame: snapshot.frame)
            return nil
        }
        guard behavior(for: window) != .ignore else { return nil }
        return observationDescriptor(for: window)
    }

    func isManageableWindow(_ snapshot: AXWindowReadSnapshot) -> Bool {
        guard snapshot.role == kAXWindowRole else { return false }
        if let subrole = snapshot.subrole, subrole != kAXStandardWindowSubrole { return false }
        guard let frame = snapshot.frame, frame.width >= 120, frame.height >= 80 else { return false }
        return snapshot.positionSettable && snapshot.sizeSettable
    }

    func noteFullscreenSpaceHelperIfNeeded(_ snapshot: AXWindowReadSnapshot) {
        guard snapshot.role == kAXWindowRole,
              snapshot.subrole == "AXUnknown",
              let frame = snapshot.frame,
              isLikelyFullscreenFrame(frame)
        else { return }
        beginFullscreenSpaceChangeGuard()
    }

    func canonicalWindows(from observations: [DiscoveredWindowObservation]) -> [ManagedWindow] {
        observations.map { observation in
            return ManagedWindow(
                element: observation.element,
                pid: observation.pid,
                windowID: observation.windowID,
                bundleID: observation.bundleID,
                appName: observation.appName,
                title: observation.title
            )
        }
    }

    func observationDescriptor(for window: ManagedWindow) -> DiscoveredWindowObservation {
        DiscoveredWindowObservation(
            element: window.element,
            pid: window.pid,
            windowID: window.windowID,
            bundleID: window.bundleID,
            appName: window.appName,
            title: window.title
        )
    }

    func observationSortOrder(
        _ lhs: DiscoveredWindowObservation,
        _ rhs: DiscoveredWindowObservation
    ) -> Bool {
        if lhs.pid != rhs.pid { return lhs.pid < rhs.pid }
        switch (lhs.windowID, rhs.windowID) {
        case let (left?, right?) where left != right: return left < right
        case (_?, nil): return true
        case (nil, _?): return false
        default: return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    func isRememberedFullscreenWindow(_ element: AXUIElement) -> Bool {
        windowManagement.fullscreenWindowStates.values.contains { sameWindow($0.element, element) }
    }

    func isLikelyFullscreenFrame(_ frame: CGRect) -> Bool {
        for screen in NSScreen.screens {
            let screenFrame = screen.frame
            let widthMatches = abs(frame.width - screenFrame.width) <= 4
            let heightMatches = abs(frame.height - screenFrame.height) <= 4
            let originMatches = abs(frame.minX - screenFrame.minX) <= 4 && abs(frame.minY - screenFrame.minY) <= 4
            if widthMatches && heightMatches && originMatches {
                return true
            }
        }

        let viewport = currentViewport()
        return frame.width >= viewport.width * 1.2 || frame.height >= viewport.height * 1.2
    }

    func isManageableWindow(_ element: AXUIElement) -> Bool {
        guard axString(element, kAXRoleAttribute) == kAXWindowRole else {
            return false
        }

        let subrole = axString(element, kAXSubroleAttribute)
        if let subrole, subrole != kAXStandardWindowSubrole {
            return false
        }

        if subrole == "AXUnknown" {
            return false
        }

        if axBool(element, kAXMinimizedAttribute) == true {
            return false
        }

        guard let frame = axFrame(element), frame.width >= 120, frame.height >= 80 else {
            return false
        }

        var positionSettable = DarwinBoolean(false)
        var sizeSettable = DarwinBoolean(false)
        let positionError = AXUIElementIsAttributeSettable(element, kAXPositionAttribute as CFString, &positionSettable)
        let sizeError = AXUIElementIsAttributeSettable(element, kAXSizeAttribute as CFString, &sizeSettable)
        return positionError == .success && sizeError == .success && positionSettable.boolValue && sizeSettable.boolValue
    }

    func isKnownWindow(_ element: AXUIElement) -> Bool {
        allWindows().contains { sameWindow($0.element, element) }
    }

}
