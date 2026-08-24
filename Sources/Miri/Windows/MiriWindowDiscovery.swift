import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

enum AXCreatedReconciliationAction {
    case ignore
    case normal
    case shortProbe
}

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

extension Miri {
    func applicationActivatedImplementation(_ app: NSRunningApplication) {
        guard isLayoutTrackingAllowed else {
            return
        }
        guard !transientSystemWindowIsActive(forceRefresh: true) else {
            return
        }
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
        guard !layoutController.activity.isActive else { return }
        guard CFAbsoluteTimeGetCurrent() >= suppressFocusedWindowNotificationsUntil else {
            return
        }
        adoptFocusedWindow(
            pid: app.processIdentifier,
            animateIfSameWorkspace: true,
            reason: "NSWorkspaceDidActivate"
        )
    }

    func applicationActivationSettledImplementation(_ app: NSRunningApplication) {
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
        guard isLayoutTrackingAllowed else {
            if isAwaitingSessionRecoveryInteraction, app.activationPolicy == .regular {
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
        windowManagement.observation.removeApplication(pid: app.processIdentifier)
        removeWindows(
            forPID: app.processIdentifier,
            applyLayout: isLayoutTrackingAllowed && !axReconciliationShouldDefer
        )
        if isLayoutTrackingAllowed, axReconciliationShouldDefer {
            requestReconciliation(
                .all(adoptFocused: true, source: .workspace, reason: "application-terminated")
            )
        }
    }

    func activeSpaceChangedImplementation() {
        guard isLayoutTrackingAllowed else {
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

    func reconcileWindows(for element: AXUIElement, adoptFocused: Bool) {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success,
              pid != 0
        else {
            debugLog("reconcile skipped reason=missing-pid")
            return
        }
        reconcileWindows(forPID: pid, adoptFocused: adoptFocused)
    }

    func reconcileWindows(forPID pid: pid_t, adoptFocused: Bool) {
        guard let app = NSRunningApplication(processIdentifier: pid) else {
            debugLog("reconcile skipped reason=no-running-app pid=\(pid)")
            return
        }
        reconcileWindows(for: app, adoptFocused: adoptFocused)
    }

    func reconcileWindows(for app: NSRunningApplication, adoptFocused: Bool) {
        guard isLayoutTrackingAllowed else {
            return
        }
        guard !layoutController.activity.isActive else {
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
        guard !transientSystemWindowIsActive() else {
            debugLog("reconcile skipped reason=transient-system-window-active app='\(app.localizedName ?? "pid \(app.processIdentifier)")' bundle='\(app.bundleIdentifier ?? "nil")' pid=\(app.processIdentifier)")
            return
        }

        startObservingApp(pid: app.processIdentifier)
        guard let observations = discoverWindows(for: app) else {
            debugLog("reconcile ax-windows unavailable app='\(app.localizedName ?? "pid \(app.processIdentifier)")' bundle='\(app.bundleIdentifier ?? "nil")' pid=\(app.processIdentifier)")
            removeVanishedWindows(
                forPID: app.processIdentifier,
                adoptFocused: adoptFocused,
                reason: "reconcile AXWindows unavailable"
            )
            return
        }
        let discovered = canonicalWindows(from: observations)
        reconcileDiscoveredWindows(
            discovered,
            replacingPID: app.processIdentifier,
            adoptFocused: adoptFocused,
            layoutLockDelay: 0.08
        )
    }

    @discardableResult
    func removeVanishedWindows(forPID pid: pid_t, adoptFocused: Bool, reason: String) -> Bool {
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
        return changed
    }

    func reconcileDiscoveredWindows(
        _ discovered: [ManagedWindow],
        replacingPID pid: pid_t,
        adoptFocused: Bool,
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
        if adoptFocused {
            let previousWorkspace = activeWorkspace
            let previousActiveColumn = workspaces[activeWorkspace].activeColumn
            let adoptedFocusedWindow = adoptFocusedWindow(
                pid: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                applyLayout: false
            )
            let focusChanged = adoptedFocusedWindow
                && (activeWorkspace != previousWorkspace
                    || workspaces[activeWorkspace].activeColumn != previousActiveColumn)
            if changed || focusChanged {
                projectLayout(focusActiveWindow: false, layoutLockDelay: layoutLockDelay)
            }
        } else if changed {
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
            _ = consumeBufferedWindowIfNeeded(existing)
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
            let isFloating = floatingWindows.contains(where: { $0 === existing })
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
            let isFrontmostApp = found.pid == NSWorkspace.shared.frontmostApplication?.processIdentifier
            insertRestoredWindowNearFocused(
                found,
                applyLayout: false,
                focusNewWindow: isFrontmostApp
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

    func rescanWindows(adoptFocused: Bool) {
        guard isLayoutTrackingAllowed else {
            return
        }
        guard !layoutController.activity.isActive else {
            requestReconciliation(
                .all(adoptFocused: adoptFocused, source: .periodicTimer, reason: "rescan-gate")
            )
            return
        }
        guard !transientSystemWindowIsActive() else {
            return
        }

        let discovered = canonicalWindows(from: discoverWindows())
        for found in discovered {
            noteAppLaunchSettlingWindowObserved(found)
        }
        let restoredPersistentLogicalSpace = restorePersistentLogicalSpaceContextsIfNeeded(discovered: discovered)
        if let fullscreenState = focusedRememberedFullscreenWindowState() {
            enforceRememberedFullscreenWorkspaceIfNeeded(fullscreenState)
            debugLog("skipping rescan mutations while focused on remembered fullscreen app='\(fullscreenState.appName)' bundle='\(fullscreenState.bundleID ?? "nil")' workspace=\(fullscreenState.workspace + 1)")
            return
        }
        if likelyFullscreenExitSettle(discovered: discovered) {
            debugLog("freezing logical macOS space during fullscreen settle visible=0 known=\(currentLogicalSpaceSignature().count)")
            windowManagement.observation.scheduleReconciliation(
                .all(adoptFocused: true, source: .delayedProbe, reason: "fullscreen-exit-settle"),
                delay: 0.25
            )
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
            return
        }

        for window in allWindows() {
            if !discovered.contains(where: { sameWindow($0.element, window.element) }) {
                let result = reconcileMissingWindow(
                    window,
                    context: MissingWindowContext(
                        isFullScan: true,
                        axEnumerationUnavailable: false,
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
            let restoredPersistentFocus: Bool
            if fullscreenSpaceChangeGuardIsActive() {
                enforceFullscreenSpaceGuardWorkspace()
                restoredPersistentFocus = false
            } else {
                let adoptedFocusedWindow = adoptFocusedWindow(
                    pid: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                    applyLayout: false
                )
                restoredPersistentFocus = adoptedFocusedWindow ? false : restorePersistentFocusedWindow()
            }
            projectLayout(
                focusActiveWindow: restoredPersistentFocus,
                layoutLockDelay: restoredPersistentLayout ? 0.4 : 0.08
            )
        } else if changed || restoredPersistentLayout {
            projectLayout(focusActiveWindow: false, layoutLockDelay: restoredPersistentLayout ? 0.4 : 0.08)
        }
        if shouldSaveLogicalSpaceContext {
            saveActiveLogicalSpaceContext()
        }
    }

    private func missingWindowDisposition(
        _ window: ManagedWindow,
        context: MissingWindowContext
    ) -> MissingWindowDisposition {
        let now = CFAbsoluteTimeGetCurrent()
        let identity = ObjectIdentifier(window)
        let runningApp = NSRunningApplication(processIdentifier: window.pid)
        let temporarilyHidden = isHiddenOrMinimizedWindow(window.element)
            || runningApp?.isHidden == true
        let pendingFullscreenWithinGrace = windowManagement
            .pendingFullscreenTransition(for: identity)
            .map { now - $0 < fullscreenTransitionGrace } == true
        let hasCGInfo = windowHasCGInfo(window)
        let fullscreen = isFullscreenWindow(window.element)
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

    func discoverWindows() -> [DiscoveredWindowObservation] {
        var windows: [DiscoveredWindowObservation] = []

        for app in NSWorkspace.shared.runningApplications.sorted(by: {
            $0.processIdentifier < $1.processIdentifier
        }) {
            if let appWindows = discoverWindows(for: app) {
                windows.append(contentsOf: appWindows)
            }
        }

        return windows
    }

    func discoverWindows(for app: NSRunningApplication) -> [DiscoveredWindowObservation]? {
        guard app.activationPolicy == .regular, !app.isHidden else {
            return []
        }
        let pid = app.processIdentifier
        guard pid != ProcessInfo.processInfo.processIdentifier else {
            return []
        }

        startObservingApp(pid: pid)

        let appElement = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value)
        guard error == .success, let axWindows = value as? [AXUIElement] else {
            return nil
        }

        let containsApplicationRoot = axWindows.contains {
            axString($0, kAXRoleAttribute) == kAXApplicationRole
        }
        let windowElements = axWindows.filter {
            axString($0, kAXRoleAttribute) == kAXWindowRole
        }
        let knownWindows = allWindows().filter { $0.pid == pid }

        if containsApplicationRoot, windowElements.isEmpty {
            // Telegram can transiently return only its AXApplication root from AXWindows
            // while the session is locking. Preserve known windows until AX returns a
            // usable enumeration again.
            debugLog("ignoring malformed root-only ax-windows response app='\(app.localizedName ?? "pid \(pid)")' bundle='\(app.bundleIdentifier ?? "nil")' pid=\(pid)")
            return knownWindows.map(observationDescriptor)
        }

        var windows: [DiscoveredWindowObservation] = []
        for element in windowElements {
            if let window = discoveredWindow(from: element, app: app, source: "scan") {
                windows.append(window)
            }
        }

        if containsApplicationRoot {
            // A mixed AXApplication/AXWindow response is still structurally malformed.
            // Accept reported windows so newly launched apps can be discovered, but do
            // not trust the response to prove that an existing window disappeared.
            for knownWindow in knownWindows where !windows.contains(where: {
                sameWindow($0.element, knownWindow.element)
            }) {
                windows.append(observationDescriptor(for: knownWindow))
            }
            debugLog("accepted windows from malformed mixed ax-windows response app='\(app.localizedName ?? "pid \(pid)")' bundle='\(app.bundleIdentifier ?? "nil")' pid=\(pid) reported=\(windowElements.count) accepted=\(windows.count)")
        }

        return windows.sorted(by: observationSortOrder)
    }

    func discoveredWindow(
        from element: AXUIElement,
        app: NSRunningApplication,
        source: String
    ) -> DiscoveredWindowObservation? {
        logRawAXWindowIfNeeded(element, app: app, source: source)
        noteFullscreenSpaceHelperIfNeeded(element)
        guard !isUnknownSubroleWindow(element),
              !isHiddenOrMinimizedWindow(element),
              !isFullscreenWindow(element),
              isManageableWindow(element) || isKnownWindow(element) || isRememberedFullscreenWindow(element)
        else {
            return nil
        }
        let pid = app.processIdentifier
        let title = axString(element, kAXTitleAttribute) ?? ""
        let appName = app.localizedName ?? "pid \(pid)"
        let windowID = SkyLight.shared.windowID(for: element)
        let window = ManagedWindow(
            element: element,
            pid: pid,
            windowID: windowID,
            bundleID: app.bundleIdentifier,
            appName: appName,
            title: title
        )
        if !isKnownWindow(element), isLikelyTransientPopup(window, app: app) {
            logTransientPopupIfNeeded(window, app: app)
            return nil
        }
        if !isKnownWindow(element), isPictureInPictureWindow(window) {
            logIgnoredPictureInPictureIfNeeded(window, app: app)
            return nil
        }
        logDiscoveredWindowIfNeeded(window, app: app)
        guard behavior(for: window) != .ignore else {
            return nil
        }
        return observationDescriptor(for: window)
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

    func isHiddenOrMinimizedWindow(_ element: AXUIElement) -> Bool {
        axBool(element, kAXMinimizedAttribute) == true
    }

    func isFullscreenWindow(_ element: AXUIElement) -> Bool {
        axBool(element, "AXFullScreen") == true
    }

    func isRememberedFullscreenWindow(_ element: AXUIElement) -> Bool {
        fullscreenWindowStates.values.contains { sameWindow($0.element, element) }
    }

    func isLikelyFullscreenFrame(_ element: AXUIElement) -> Bool {
        guard let frame = axFrame(element) else {
            return false
        }

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

    func axCreatedReconciliationAction(for element: AXUIElement, pid: pid_t) -> AXCreatedReconciliationAction {
        if pid == 0 || isKnownWindow(element) || isManageableWindow(element) {
            return .normal
        }

        let knownWindowCount = allWindows().filter { $0.pid == pid }.count
        if isLikelyAXCreatedWindowPlaceholder(element) {
            return knownWindowCount == 0 ? .normal : .shortProbe
        }

        let role = axString(element, kAXRoleAttribute) ?? "nil"
        let subrole = axString(element, kAXSubroleAttribute) ?? "nil"
        let frameDescription = axFrame(element).map { String(describing: $0) } ?? "nil"
        let title = axString(element, kAXTitleAttribute) ?? ""
        debugLog("ax created ignored reason=unmanageable-created pid=\(pid) knownWindows=\(knownWindowCount) title='\(title)' role=\(role) subrole=\(subrole) frame=\(frameDescription)")
        return .ignore
    }

    func isLikelyAXCreatedWindowPlaceholder(_ element: AXUIElement) -> Bool {
        guard axString(element, kAXRoleAttribute) == kAXWindowRole else {
            return false
        }

        let subrole = axString(element, kAXSubroleAttribute)
        guard subrole == nil || subrole == kAXStandardWindowSubrole else {
            return false
        }

        return axBool(element, kAXMinimizedAttribute) != true
            && axBool(element, "AXFullScreen") != true
    }

    func isUnknownSubroleWindow(_ element: AXUIElement) -> Bool {
        axString(element, kAXSubroleAttribute) == "AXUnknown"
    }

    func isKnownWindow(_ element: AXUIElement) -> Bool {
        allWindows().contains { sameWindow($0.element, element) }
    }

}
