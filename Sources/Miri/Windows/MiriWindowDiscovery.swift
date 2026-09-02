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
final class FullWindowDiscoveryAccumulator {
    let generation: UInt64
    let completion: (Bool) -> Void
    var remaining: Int
    var pendingPIDs: Set<pid_t>
    var observations: [DiscoveredWindowObservation] = []
    var unavailablePIDs = Set<pid_t>()
    var finished = false

    init(generation: UInt64, pids: Set<pid_t>, completion: @escaping (Bool) -> Void) {
        self.generation = generation
        pendingPIDs = pids
        remaining = pids.count
        self.completion = completion
    }

    @discardableResult
    func recordCompletion(pid: pid_t) -> Bool {
        guard !finished, pendingPIDs.remove(pid) != nil else { return false }
        remaining -= 1
        if remaining == 0 { finished = true }
        return finished
    }

    func expirePendingPIDs() -> Set<pid_t> {
        guard !finished else { return [] }
        finished = true
        unavailablePIDs.formUnion(pendingPIDs)
        return pendingPIDs
    }
}

extension Miri {
    func applicationActivatedImplementation(_ app: NSRunningApplication) {
        guard appPhase == .running,
              sessionController.isLayoutTrackingAllowed else { return }
        debugLog("application activated app='\(app.localizedName ?? "pid \(app.processIdentifier)")' bundle='\(app.bundleIdentifier ?? "nil")' pid=\(app.processIdentifier)")

        // Do not put first-activation focus behind the multi-application
        // transient refresh barrier. A fresh focused-window result is safe to
        // adopt immediately; cached fallback is disabled here so an actual
        // dialog cannot reveal the app's previous managed window. Lifecycle
        // reconciliation remains gated by the completed transient refresh.
        if !windowManagement.observation.transientWindowActive {
            requestFocusedWindowAdoption(
                pid: app.processIdentifier,
                animateIfSameWorkspace: true,
                forceLayoutIfAlreadyFocused: true,
                allowCachedFallback: false,
                reason: "NSWorkspaceDidActivate:immediate"
            )
        }

        refreshTransientSystemWindowState { [weak self, weak app] in
            guard let self, let app else { return }
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier {
                self.finishApplicationActivationAfterTransientRefresh(app)
            } else {
                // The bounded transient refresh can outlive a quick visit to an
                // app that was hidden when Miri started. Lifecycle discovery
                // must still admit its newly shown windows even though focus
                // has since moved elsewhere.
                self.requestReconciliation(.application(
                    pid: app.processIdentifier,
                    adoptFocused: false,
                    source: .workspace,
                    reason: "NSWorkspaceDidActivate:post-transient-background"
                ))
            }
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
            forceLayoutIfAlreadyFocused: true,
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
        // The immediate focused read handles known windows and must re-project
        // even if this was already Miri's logical active column. The targeted
        // reconciliation remains frontmost-validated before adopting so a
        // newly discovered activation target is handled as well.
        requestFocusedWindowAdoption(
            pid: app.processIdentifier,
            animateIfSameWorkspace: true,
            forceLayoutIfAlreadyFocused: true,
            reason: "NSWorkspaceDidActivate:settle"
        )
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
        // A full scan started for the previous macOS Space must never apply
        // after the active-Space event. PID-local lifecycle events are handled
        // independently and do not invalidate healthy peers.
        fullWindowScanGeneration &+= 1
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
            coalescingKey: "targeted-reconciliation:\(stateGeneration)",
            joinExisting: true
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
            let changed = self.reconcileDiscoveredWindows(
                discovered,
                replacingPID: pid,
                layoutLockDelay: 0.08,
                applyLayout: !mayAdoptFocused,
                enumerationComplete: snapshot.enumerationComplete
            )
            if mayAdoptFocused {
                self.requestFocusedWindowAdoption(
                    pid: pid,
                    applyLayout: false,
                    animateIfSameWorkspace: true,
                    reason: "targeted-reconciliation"
                ) { [weak self] adopted in
                    guard let self else { return }
                    if changed || adopted {
                        // Activation reconciliation is also a projection
                        // barrier: the focused window may already be Miri's
                        // logical column while its physical column is parked.
                        self.projectLayout(focusActiveWindow: false, layoutLockDelay: 0.08)
                    }
                }
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

    @discardableResult
    func reconcileDiscoveredWindows(
        _ discovered: [ManagedWindow],
        replacingPID pid: pid_t,
        layoutLockDelay: TimeInterval,
        applyLayout: Bool = true,
        enumerationComplete: Bool = true
    ) -> Bool {
        // A focused remembered fullscreen window may already be represented by
        // a normal post-exit snapshot. Restore it before consulting the guard;
        // otherwise the guard suppresses the only reconciliation capable of
        // clearing its remembered state until focus moves to a neighbor.
        var changed = restoreExitedFullscreenWindows(discovered: discovered)
        if let fullscreenState = focusedRememberedFullscreenWindowState() {
            enforceRememberedFullscreenWorkspaceIfNeeded(fullscreenState)
            debugLog("skipping app reconciliation while focused on remembered fullscreen app='\(fullscreenState.appName)' bundle='\(fullscreenState.bundleID ?? "nil")'")
            return changed
        }

        var shouldSaveLogicalSpaceContext = true

        for found in discovered {
            noteAppLaunchSettlingWindowObserved(found)
        }

        for window in allWindows().filter({ $0.pid == pid }) {
            if discovered.contains(where: { sameWindow($0.element, window.element) }) {
                continue
            }
            guard enumerationComplete else { continue }

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

        for found in discovered {
            changed = upsertDiscoveredWindow(found) || changed
        }

        reconcileWorkspaceCapacity()
        if changed, applyLayout {
            projectLayout(focusActiveWindow: false, layoutLockDelay: layoutLockDelay)
        }
        if changed && shouldSaveLogicalSpaceContext {
            saveActiveLogicalSpaceContext()
        }
        return changed
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
            let windowIDEnriched = existing.windowID == nil && found.windowID != nil
            existing.title = found.title
            existing.appName = found.appName
            existing.bundleID = found.bundleID
            if windowIDEnriched { existing.windowID = found.windowID }

            if metadataChanged || windowIDEnriched {
                notifyWorkspaceBarNeedsRefresh()
            }

            let nextBehavior = behavior(for: existing)
            let shouldFloat = nextBehavior == .float
            let isFloating = windowManagement.floatingWindows.contains(where: { $0 === existing })
            guard previousBehavior != nextBehavior || shouldFloat != isFloating else {
                return windowIDEnriched
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
        let regularApps = NSWorkspace.shared.runningApplications
            .filter {
                $0.activationPolicy == .regular
                    && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
            }
            .sorted { $0.processIdentifier < $1.processIdentifier }
        // Hidden applications have no discoverable windows yet, but observing
        // them is what makes AXApplicationShown authoritative when they become
        // visible without an application launch.
        for app in regularApps {
            startObservingApp(pid: app.processIdentifier)
        }
        let apps = regularApps.filter { !$0.isHidden }
        let stateGenerations = Dictionary(uniqueKeysWithValues: apps.map {
            ($0.processIdentifier, windowManagement.observation.stateGeneration(for: $0.processIdentifier))
        })
        let accumulator = FullWindowDiscoveryAccumulator(
            generation: generation,
            pids: Set(apps.map(\.processIdentifier)),
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

        // Per-operation budgets prevent a worker from monopolizing a PID lane;
        // this outer barrier additionally guarantees session recovery can make
        // progress if an underlying call never returns at all.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self, weak accumulator] in
            guard let self, let accumulator,
                  !accumulator.finished,
                  generation == self.fullWindowScanGeneration
            else { return }
            let expiredPIDs = accumulator.expirePendingPIDs()
            self.debugLog("full rescan deadline exhausted unavailablePIDs=\(expiredPIDs.sorted())")
            self.completeRescanWindows(
                WindowDiscoverySnapshot(
                    observations: accumulator.observations,
                    unavailablePIDs: accumulator.unavailablePIDs
                ),
                adoptFocused: adoptFocused,
                completion: accumulator.completion
            )
        }

        for app in apps {
            let pid = app.processIdentifier
            let supplementalHandles = allWindows().filter { $0.pid == pid }.map {
                AXElementHandle(element: $0.element, pid: $0.pid, windowID: $0.windowID)
            }
            axOperations.readApplication(
                pid: pid,
                priority: .normal,
                supplementalHandles: supplementalHandles,
                coalescingKey: "full-reconciliation"
            ) { [weak self] result in
                guard let self,
                      !accumulator.finished,
                      generation == self.fullWindowScanGeneration,
                      accumulator.generation == generation
                else { return }

                if let liveApp = NSRunningApplication(processIdentifier: pid),
                   !liveApp.isTerminated,
                   !liveApp.isHidden
                {
                    let expectedState = stateGenerations[pid] ?? 0
                    if expectedState != self.windowManagement.observation.stateGeneration(for: pid) {
                        // Preserve only this PID. An unrelated noisy app must
                        // not invalidate healthy results or restart the scan.
                        accumulator.unavailablePIDs.insert(pid)
                        self.debugLog("full rescan pid result discarded reason=stale-state pid=\(pid)")
                    } else if result.disposition == .completed, let snapshot = result.value {
                        accumulator.observations.append(contentsOf: self.discoveredWindows(
                            from: snapshot,
                            app: liveApp
                        ))
                        if !snapshot.enumerationComplete {
                            accumulator.unavailablePIDs.insert(pid)
                        }
                    } else {
                        accumulator.unavailablePIDs.insert(pid)
                    }
                }
                // A PID that terminated or became hidden during the scan is
                // intentionally absent and can be reconciled as unavailable=false.
                guard accumulator.recordCompletion(pid: pid) else { return }
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
        for pid in discovery.unavailablePIDs {
            if let app = NSRunningApplication(processIdentifier: pid) {
                // Bounded full reads can intentionally return partial progress.
                // Reuse the launch-settling retry window so a large healthy app
                // continues from its rotating cursor without creating an
                // unbounded permanent retry loop for a truly hung process.
                beginAppLaunchSettling(for: app, reason: "full-rescan-partial")
            }
        }
        // Unavailable windows are lifecycle-preserved below, but they are not
        // evidence of visibility on the current macOS Space. Include them only
        // in transient-disappearance heuristics, never in Space signatures.
        let stabilityDiscovered = discovered + allWindows().filter { window in
            discovery.unavailablePIDs.contains(window.pid)
                && !discovered.contains { sameWindow($0.element, window.element) }
        }
        for found in discovered {
            noteAppLaunchSettlingWindowObserved(found)
        }
        let restoredPersistentLogicalSpace = restorePersistentLogicalSpaceContextsIfNeeded(
            discovered: discovered,
            preservedWindows: stabilityDiscovered,
            finalizeLayoutRestore: discovery.unavailablePIDs.isEmpty
        )
        let restoredFullscreenExit = restoreExitedFullscreenWindows(discovered: discovered)
        if let fullscreenState = focusedRememberedFullscreenWindowState() {
            enforceRememberedFullscreenWorkspaceIfNeeded(fullscreenState)
            debugLog("skipping rescan mutations while focused on remembered fullscreen app='\(fullscreenState.appName)' bundle='\(fullscreenState.bundleID ?? "nil")' workspace=\(fullscreenState.workspace + 1)")
            completion(true)
            return
        }
        if likelyFullscreenExitSettle(discovered: stabilityDiscovered) {
            debugLog("freezing logical macOS space during fullscreen settle visible=0 known=\(currentLogicalSpaceSignature().count)")
            windowManagement.observation.scheduleReconciliation(
                .all(adoptFocused: true, source: .delayedProbe, reason: "fullscreen-exit-settle"),
                delay: 0.25
            )
            completion(false)
            return
        }

        if windowManagement.pendingLogicalSpaceSwitch,
           discovered.isEmpty,
           !discovery.unavailablePIDs.isEmpty
        {
            debugLog("deferring logical macOS space switch reason=no-authoritative-visible-windows unavailablePIDs=\(discovery.unavailablePIDs.sorted())")
            windowManagement.observation.scheduleReconciliation(
                .all(adoptFocused: true, source: .delayedProbe, reason: "active-space-unavailable"),
                delay: 0.25
            )
            completion(false)
            return
        }

        let switchedLogicalSpace = handlePendingLogicalSpaceSwitch(discovered: discovered)
        var changed = switchedLogicalSpace
            || restoredPersistentLogicalSpace
            || restoredFullscreenExit
        var shouldSaveLogicalSpaceContext = true

        if likelyBulkTransientDisappearance(discovered: stabilityDiscovered) {
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

        for found in discovered {
            changed = upsertDiscoveredWindow(found) || changed
        }

        let restoredPersistentLayout = applyPersistentLayoutSnapshotIfNeeded(
            finalize: discovery.unavailablePIDs.isEmpty
        )
        reconcileWorkspaceCapacity()

        if adoptFocused {
            let layoutDelay = restoredPersistentLayout ? 0.4 : 0.08
            if fullscreenSpaceChangeGuardIsActive() {
                enforceFullscreenSpaceGuardWorkspace()
                projectLayout(focusActiveWindow: false, layoutLockDelay: layoutDelay)
            } else {
                // Restore the pre-async ordering: adopt the authoritative focus
                // into the model first, then perform one projection. Projecting
                // before the read parks windows and queues same-PID frame writes
                // ahead of the focus query.
                let focusRequestGeneration = focusStateGeneration
                let scanGeneration = fullWindowScanGeneration
                requestFocusedWindowAdoption(
                    pid: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                    applyLayout: false,
                    animateIfSameWorkspace: false,
                    reason: "full-reconciliation"
                ) { [weak self] adopted in
                    guard let self,
                          scanGeneration == self.fullWindowScanGeneration,
                          self.sessionController.isLayoutTrackingAllowed
                    else {
                        completion(false)
                        return
                    }
                    let restoredPersistentFocus = !adopted
                        && self.focusStateGeneration == focusRequestGeneration
                        && self.restorePersistentFocusedWindow()
                    self.projectLayout(
                        focusActiveWindow: restoredPersistentFocus,
                        layoutLockDelay: layoutDelay
                    )
                    if shouldSaveLogicalSpaceContext {
                        self.saveActiveLogicalSpaceContext()
                    }
                    completion(true)
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
            guard snapshot.enumerationComplete else { return [] }
            debugLog("ignoring malformed root-only ax-windows response app='\(app.localizedName ?? "pid \(pid)")' bundle='\(app.bundleIdentifier ?? "nil")' pid=\(pid)")
            return knownWindows.map(observationDescriptor)
        }

        var windows = windowSnapshots.compactMap {
            discoveredWindow(from: $0, app: app, source: "async-scan")
        }
        if snapshot.containsApplicationRoot, snapshot.enumerationComplete {
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
        logRawAXWindowIfNeeded(snapshot, app: app, source: source)
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
        observations.sorted(by: observationSortOrder).map { observation in
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

    func isKnownWindow(_ element: AXUIElement) -> Bool {
        allWindows().contains { sameWindow($0.element, element) }
    }

}
