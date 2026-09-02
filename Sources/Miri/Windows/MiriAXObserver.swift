import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

extension Miri {
    var axReconciliationShouldDefer: Bool {
        layoutController.isActive
    }

    func deferAXReconciliation(
        pid: pid_t,
        adoptFocused: Bool,
        needsFullRescan: Bool = false,
        reason: String
    ) {
        let intent: ReconciliationIntent
        if needsFullRescan || pid == 0 {
            intent = .all(
                adoptFocused: adoptFocused,
                source: .accessibility,
                reason: reason
            )
        } else {
            intent = .application(
                pid: pid,
                adoptFocused: adoptFocused,
                source: .accessibility,
                reason: reason
            )
        }
        requestReconciliation(intent)
    }

    func shouldRateLimitAXCreatedPlaceholderProbe(pid: pid_t) -> Bool {
        let cooldown = axCreatedPlaceholderProbeCooldown
        let result = windowManagement.observation.placeholderProbeIsRateLimited(
            pid: pid,
            cooldown: cooldown
        )
        if result.limited {
            debugLog(
                "ax created placeholder probe skipped reason=rate-limited pid=\(pid) cooldown=\(String(format: "%.1f", cooldown))s elapsed=\(String(format: "%.2f", result.elapsed ?? 0))s"
            )
            return true
        }
        return false
    }

    func handleAXCreatedNotification(
        _ element: AXUIElement,
        pid: pid_t,
        reason: String
    ) {
        if pid == 0 || isKnownWindow(element) {
            windowManagement.observation.noteWindowStateChange(pid: pid)
            scheduleAXCreationReconciliation(pid: pid, adoptFocused: true, reason: reason)
            return
        }
        let stateGeneration = windowManagement.observation.stateGeneration(for: pid)
        // Window-ID resolution uses a private synchronous AX call. Created
        // notifications may safely begin with pointer identity and enrich the
        // ID during a later application snapshot on this PID's worker lane.
        let handle = AXElementHandle(element: element, pid: pid, windowID: nil)
        axOperations.readWindow(handle: handle, priority: .background) { [weak self] result in
            guard let self else { return }
            guard stateGeneration == self.windowManagement.observation.stateGeneration(for: pid) else {
                self.scheduleAXCreationReconciliation(pid: pid, adoptFocused: true, reason: reason)
                return
            }
            guard result.disposition == .completed, let snapshot = result.value else {
                self.scheduleAXCreationReconciliation(pid: pid, adoptFocused: true, reason: reason)
                return
            }
            if self.isManageableWindow(snapshot) {
                self.windowManagement.observation.noteWindowStateChange(pid: pid)
                self.scheduleAXCreationReconciliation(pid: pid, adoptFocused: true, reason: reason)
                return
            }
            let placeholder = snapshot.role == kAXWindowRole
                && (snapshot.subrole == nil || snapshot.subrole == kAXStandardWindowSubrole)
                && snapshot.minimized != true
                && snapshot.fullscreen != true
            guard placeholder else {
                self.debugLog("ax created ignored reason=unmanageable-created pid=\(pid) title='\(snapshot.title)' role=\(snapshot.role ?? "nil") subrole=\(snapshot.subrole ?? "nil") frame=\(snapshot.frame.map { String(describing: $0) } ?? "nil")")
                return
            }
            let knownWindowCount = self.allWindows().filter { $0.pid == pid }.count
            guard knownWindowCount > 0 else {
                self.windowManagement.observation.noteWindowStateChange(pid: pid)
                self.scheduleAXCreationReconciliation(pid: pid, adoptFocused: true, reason: reason)
                return
            }
            guard !self.shouldRateLimitAXCreatedPlaceholderProbe(pid: pid) else { return }
            self.windowManagement.observation.noteWindowStateChange(pid: pid)
            self.scheduleAXCreationReconciliation(
                pid: pid,
                adoptFocused: true,
                reason: "\(reason):placeholder-probe",
                delays: [0.12, 0.45]
            )
        }
    }

    func scheduleAXCreationReconciliation(
        pid: pid_t,
        adoptFocused: Bool,
        reason: String,
        delays overrideDelays: [TimeInterval]? = nil
    ) {
        guard pid != 0 else {
            deferAXReconciliation(pid: pid, adoptFocused: adoptFocused, needsFullRescan: true, reason: reason)
            return
        }
        guard let app = NSRunningApplication(processIdentifier: pid) else {
            debugLog("ax creation reconciliation skipped reason=no-running-app source=\(reason) pid=\(pid)")
            return
        }
        guard app.activationPolicy == .regular else {
            debugLog("ax creation reconciliation skipped reason=non-regular-app source=\(reason) app='\(app.localizedName ?? "pid \(pid)")' bundle='\(app.bundleIdentifier ?? "nil")' pid=\(pid) activationPolicy=\(app.activationPolicy.rawValue)")
            return
        }

        let originalWindowCount = allWindows().filter { $0.pid == pid }.count
        let delays: [TimeInterval] = overrideDelays ?? (originalWindowCount == 0
            ? [0.12, 0.45, 1.0, 2.5, 5.0, 10.0, 20.0, 35.0]
            : [0.12, 0.45, 1.0, 2.5])
        debugLog("ax creation reconciliation scheduled reason=\(reason) pid=\(pid) knownWindows=\(originalWindowCount) attempts=\(delays.count)")
        windowManagement.observation.scheduleCreationReconciliation(
            pid: pid,
            adoptFocused: adoptFocused,
            sourceReason: reason,
            delays: delays
        )
    }

    @discardableResult
    func removeMiniaturizedWindowImmediately(_ element: AXUIElement, pid: pid_t, reason: String) -> Bool {
        guard let window = tiledWindow(for: element) else {
            return false
        }

        let wasActiveWindow = activeWindow().map { $0 === window } == true
        debugLog(
            "removing miniaturized window reason=\(reason) app='\(window.appName)' bundle='\(window.bundleID ?? "nil")' pid=\(window.pid) title='\(window.title)' id=\(window.windowID.map(String.init) ?? "nil")"
        )
        rememberMinimizedWindowState(window)
        removeWindow(window, preferRightFocus: true)
        projectLayout(focusActiveWindow: wasActiveWindow, layoutLockDelay: 0.02)
        saveActiveLogicalSpaceContext()
        return true
    }

    func requestFocusedWindowAdoption(
        pid: pid_t?,
        applyLayout: Bool = true,
        animateIfSameWorkspace: Bool = false,
        forceLayoutIfAlreadyFocused: Bool = false,
        allowCachedFallback: Bool = true,
        reason: String = "focus-adoption",
        completion: @escaping (Bool) -> Void = { _ in }
    ) {
        focusedWindowAdoptionGeneration &+= 1
        let adoptionGeneration = focusedWindowAdoptionGeneration
        guard let pid else {
            completion(false)
            return
        }
        let requestGeneration = focusStateGeneration
        axOperations.readFocusedWindow(
            pid: pid,
            coalescingKey: "focus-adoption"
        ) { [weak self] result in
            guard let self,
                  adoptionGeneration == self.focusedWindowAdoptionGeneration,
                  requestGeneration == self.focusStateGeneration,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
            else {
                completion(false)
                return
            }
            let focusedElement: AXUIElement?
            if result.disposition == .completed,
               let current = result.value?.handle.element
            {
                focusedElement = current
            } else if allowCachedFallback,
                      let cached = self.lastKnownFocusedElements[pid],
                      self.isKnownWindow(cached)
            {
                focusedElement = cached
                self.debugLog("focus adoption using cached identity reason=\(reason) pid=\(pid)")
            } else if allowCachedFallback {
                let known = self.allWindows().filter { $0.pid == pid }
                focusedElement = known.count == 1 ? known[0].element : nil
                if focusedElement != nil {
                    self.debugLog("focus adoption using sole managed window reason=\(reason) pid=\(pid)")
                }
            } else {
                focusedElement = nil
            }
            guard let focusedElement else {
                completion(false)
                return
            }
            let adopted = self.adoptFocusedElement(
                focusedElement,
                pid: pid,
                applyLayout: applyLayout,
                animateIfSameWorkspace: animateIfSameWorkspace,
                forceLayoutIfAlreadyFocused: forceLayoutIfAlreadyFocused,
                reason: reason
            )
            completion(adopted)
        }
    }

    @discardableResult
    func adoptFocusedElement(
        _ focusedElement: AXUIElement,
        pid: pid_t,
        applyLayout: Bool = true,
        animateIfSameWorkspace: Bool = false,
        forceLayoutIfAlreadyFocused: Bool = false,
        reason: String = "focus-adoption"
    ) -> Bool {
        lastKnownFocusedElements[pid] = focusedElement
        guard !activeEmptyWorkspaceHasFocusAuthority else {
            debugLog("focus adoption suppressed reason=explicit-empty-workspace pid=\(pid) workspace=\(windowManagement.activeWorkspace + 1)")
            return false
        }
        if fullscreenSpaceChangeGuardIsActive() {
            debugLog("suppressing focus adoption during fullscreen space guard")
            return false
        }
        if let fullscreenState = windowManagement.fullscreenWindowStates.values.first(where: {
            $0.pid == pid && sameWindow($0.element, focusedElement)
        }) {
            enforceRememberedFullscreenWorkspaceIfNeeded(fullscreenState)
            debugLog("suppressing focus adoption while focused on remembered fullscreen app='\(fullscreenState.appName)' bundle='\(fullscreenState.bundleID ?? "nil")'")
            return false
        }

        if windowManagement.floatingWindows.contains(where: { sameWindow($0.element, focusedElement) }) {
            if applyLayout {
                projectLayout(focusActiveWindow: false)
            }
            return true
        }

        if let loc = location(of: focusedElement) {
            if let active = activeWindow(),
               !sameWindow(active.element, focusedElement)
            {
                let now = CFAbsoluteTimeGetCurrent()
                let isStaleAuthoredActivation = forceLayoutIfAlreadyFocused
                    && active.pid == pid
                    && now < authoredPhysicalFocusUntil
                    && authoredPhysicalFocusElement.map {
                        sameWindow($0, active.element)
                    } == true
                if isStaleAuthoredActivation {
                    let delay = max(authoredPhysicalFocusUntil - now, 0.05)
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                        guard let self,
                              self.sessionController.isLayoutTrackingAllowed,
                              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
                        else { return }
                        self.requestFocusedWindowAdoption(
                            pid: pid,
                            animateIfSameWorkspace: true,
                            forceLayoutIfAlreadyFocused: true,
                            reason: "authored-activation-settle"
                        )
                    }
                    return false
                }
                if !forceLayoutIfAlreadyFocused && now < keyboardFocusAuthorityUntil {
                    return false
                }
            }
            let previousState = captureLayoutState()
            let previousWorkspace = windowManagement.activeWorkspace
            let workspace = windowManagement.workspaces[loc.workspace]
            let changedFocus = windowManagement.activeWorkspace != loc.workspace || workspace.activeColumn != loc.column
            setActiveWorkspace(loc.workspace)
            windowManagement.setActiveColumn(loc.column, in: workspace)
            if changedFocus {
                focusStateGeneration &+= 1
            }
            let shouldProject = changedFocus || forceLayoutIfAlreadyFocused
            if shouldProject {
                revealActiveColumnIfNeeded(in: workspace, viewport: currentViewport())
            }
            if applyLayout, shouldProject {
                let shouldAnimate = animateIfSameWorkspace
                    && previousWorkspace == loc.workspace
                debugLog(
                    "focus adopted reason=\(reason) animated=\(shouldAnimate) workspace=\(loc.workspace + 1) column=\(loc.column + 1)"
                )
                projectLayout(
                    focusActiveWindow: false,
                    animated: shouldAnimate,
                    from: shouldAnimate ? previousState : nil
                )
            }
            return true
        }

        return false
    }

    func startObservingApp(pid: pid_t) {
        windowManagement.observation.observeApplication(pid: pid, log: debugLog)
    }

    func handleAXNotificationImplementation(_ name: String, element: AXUIElement) {
        guard appPhase == .running,
              sessionController.isLayoutTrackingAllowed else {
            return
        }
        var notificationPID: pid_t = 0
        AXUIElementGetPid(element, &notificationPID)
        let authoredResize = name == kAXWindowResizedNotification
            && tiledWindow(for: element).map {
                layoutController.shouldIgnoreAuthoredFrameNotification(for: $0)
            } == true
        let isLifecycleChange = name == kAXUIElementDestroyedNotification
            || name == kAXWindowMiniaturizedNotification
            || name == kAXWindowDeminiaturizedNotification
            || name == kAXApplicationHiddenNotification
            || name == kAXApplicationShownNotification
            || (name == kAXWindowResizedNotification
                && !authoredResize
                && !layoutController.isActive
                && !manualResizeController.notificationsSuppressed)
        if isLifecycleChange {
            windowManagement.observation.noteWindowStateChange(pid: notificationPID)
        }
        if debugLogging {
            debugLog("ax notification name=\(name) pid=\(notificationPID)")
        }
        if windowManagement.observation.transientWindowActive {
            return
        }

        switch name {
        case kAXFocusedWindowChangedNotification,
             kAXMainWindowChangedNotification:
            var pid: pid_t = 0
            AXUIElementGetPid(element, &pid)
            let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let isFrontmost = frontmostPID == pid
            if !isKnownWindow(element) {
                // The asynchronous app scan performs manageability and rule
                // checks without blocking this main-run-loop AX callback.
                scheduleAXCreationReconciliation(
                    pid: pid,
                    adoptFocused: isFrontmost,
                    reason: name
                )
            }
            guard isFrontmost else {
                let frontmostDescription = frontmostPID.map(String.init) ?? "nil"
                debugLog(
                    "ax focus adoption ignored reason=non-frontmost notification=\(name) pid=\(pid) frontmostPID=\(frontmostDescription)"
                )
                return
            }
            guard !axReconciliationShouldDefer,
                  CFAbsoluteTimeGetCurrent() >= suppressFocusedWindowNotificationsUntil
            else {
                deferAXReconciliation(pid: pid, adoptFocused: true, reason: name)
                return
            }
            _ = adoptFocusedElement(
                element,
                pid: pid,
                animateIfSameWorkspace: true,
                reason: name
            )
        case kAXUIElementDestroyedNotification:
            var pid: pid_t = 0
            AXUIElementGetPid(element, &pid)
            guard !axReconciliationShouldDefer else {
                guard isKnownWindow(element) else {
                    debugLog("ax notification ignored during snapshot reason=\(name) pid=\(pid) known=false")
                    return
                }
                deferAXReconciliation(pid: pid, adoptFocused: true, needsFullRescan: true, reason: name)
                return
            }
            if removeDestroyedWindowImmediately(element) {
                saveActiveLogicalSpaceContext()
            } else {
                windowManagement.observation.scheduleReconciliation(
                    .application(pid: pid, adoptFocused: true, source: .delayedProbe, reason: "destroyed-settle"),
                    delay: 0.08
                )
            }
        case kAXCreatedNotification,
             kAXWindowMiniaturizedNotification,
             kAXWindowDeminiaturizedNotification,
             kAXApplicationHiddenNotification,
             kAXApplicationShownNotification:
            var pid: pid_t = 0
            AXUIElementGetPid(element, &pid)
            if name == kAXCreatedNotification {
                handleAXCreatedNotification(element, pid: pid, reason: name)
                return
            }
            if name == kAXWindowMiniaturizedNotification {
                guard !axReconciliationShouldDefer else {
                    deferAXReconciliation(pid: pid, adoptFocused: true, reason: name)
                    return
                }
                if removeMiniaturizedWindowImmediately(element, pid: pid, reason: name) {
                    return
                }
                windowManagement.observation.scheduleReconciliation(
                    .application(pid: pid, adoptFocused: true, source: .delayedProbe, reason: "miniaturized-settle"),
                    delay: 0.08
                )
                return
            }
            guard !axReconciliationShouldDefer else {
                deferAXReconciliation(pid: pid, adoptFocused: true, reason: name)
                return
            }
            windowManagement.observation.scheduleReconciliation(
                .application(pid: pid, adoptFocused: true, source: .delayedProbe, reason: "ax-state-settle"),
                delay: 0.08
            )
        case kAXWindowResizedNotification, kAXWindowMovedNotification:
            var pid: pid_t = 0
            AXUIElementGetPid(element, &pid)
            guard !axReconciliationShouldDefer else {
                guard tiledWindow(for: element) != nil else {
                    debugLog("ax notification ignored during snapshot reason=\(name) pid=\(pid) tracked=false")
                    return
                }
                deferAXReconciliation(pid: pid, adoptFocused: false, reason: name)
                return
            }
            // Reuse model identity when available. Never invoke private AX
            // window-ID mapping from the main-run-loop notification callback.
            let knownWindowID = self.allWindows().first {
                self.sameWindow($0.element, element)
            }?.windowID
            let handle = AXElementHandle(
                element: element,
                pid: pid,
                windowID: knownWindowID
            )
            let sessionGeneration = sessionController.resumeGeneration
            axOperations.readWindow(handle: handle) { [weak self] result in
                guard let self,
                      self.appPhase == .running,
                      self.sessionController.isLayoutTrackingAllowed,
                      self.sessionController.resumeGeneration == sessionGeneration,
                      result.disposition == .completed,
                      let snapshot = result.value
                else { return }
                self.handleWindowFrameNotification(name, snapshot: snapshot)
            }
        default:
            break
        }
    }

    func handleWindowFrameNotification(
        _ name: String,
        snapshot: AXWindowReadSnapshot
    ) {
        let element = snapshot.handle.element
        noteFullscreenSpaceHelperIfNeeded(snapshot)
        if handleFullscreenTransitionIfNeeded(
            element,
            isFullscreen: snapshot.fullscreen == true
        ) {
            return
        }
        guard let window = tiledWindow(for: element) else {
            layoutController.restoreFloatingVisibility()
            return
        }
        if layoutController.shouldIgnoreAuthoredFrameNotification(for: window) {
            if let frame = snapshot.frame {
                layoutController.recordPresentationFrame(frame, for: window)
            }
            return
        }
        guard !manualResizeController.notificationsSuppressed else { return }

        if manualResizeController.isTracking {
            guard isManualResizeElement(element) else { return }
            beginOrContinueManualResize(for: element, observedFrame: snapshot.frame)
            return
        }
        guard !layoutController.isActive else { return }

        if name == kAXWindowResizedNotification
            || frameWidthDiffersFromLayout(for: element, observedFrame: snapshot.frame)
        {
            beginOrContinueManualResize(for: element, observedFrame: snapshot.frame)
            return
        }
        if let frame = snapshot.frame {
            layoutController.recordPresentationFrame(frame, for: window)
        }
        projectLayout(focusActiveWindow: false)
    }
}
