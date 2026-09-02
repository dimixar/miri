import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

extension Miri {
    var sessionRecoveryInputEventMask: CGEventMask {
        var eventTypes: [CGEventType] = [
            .leftMouseDown,
            .rightMouseDown,
            .otherMouseDown,
            .scrollWheel,
        ]
        if keyboardShortcutBackend == .registeredHotKeys {
            eventTypes.append(.keyDown)
        }
        return eventTypes.reduce(CGEventMask(0)) { mask, type in
            mask | CGEventMask(1 << type.rawValue)
        }
    }

    func syncSessionRecoveryInputTracking() {
        if sessionController.isAwaitingRecoveryInteraction {
            installSessionRecoveryEventTap()
        } else {
            uninstallSessionRecoveryEventTap()
        }
    }

    func refreshSessionRecoveryInputTracking() {
        uninstallSessionRecoveryEventTap()
        syncSessionRecoveryInputTracking()
        inputController.reenableEventTap()
    }

    func installSessionRecoveryEventTap() {
        sessionController.installRecoveryInput(mask: sessionRecoveryInputEventMask)
        debugLog("session recovery input tracking enabled")
    }

    func uninstallSessionRecoveryEventTap() {
        sessionController.uninstallRecoveryInput()
    }

    func handleSessionRecoveryEventTapDisabledImplementation() {
        sessionController.reenableRecoveryInput()
    }

    func handleSessionRecoveryInput(_ event: CGEvent, type: CGEventType) {
        guard sessionController.isAwaitingRecoveryInteraction else { return }
        validateSessionRecoveryInput(event, type: type) { [weak self] valid in
            guard let self, valid else { return }
            let reason = type == .keyDown
                ? "managed-key-down"
                : "managed-pointer-event-\(type.rawValue)"
            self.requestSessionRecovery(reason: reason)
        }
    }

    func handleSessionRecoveryKeyEvent(_ event: CGEvent?, command: Command?) -> Bool {
        guard sessionController.isAwaitingRecoveryInteraction else { return false }
        let finish: (Bool) -> Void = { [weak self] valid in
            guard let self, valid else { return }
            self.requestSessionRecovery(reason: "managed-key-down", command: command)
        }
        if let event {
            validateSessionRecoveryInput(event, type: .keyDown, completion: finish)
        } else {
            validateSessionRecoveryFocusedLayoutTarget { finish($0 != nil) }
        }
        // A registered Miri command is consumed while its AX validation runs;
        // ordinary recovery-tap keys remain listen-only and continue to AppKit.
        return command != nil
    }

    func validateSessionRecoveryInput(
        _ event: CGEvent,
        type: CGEventType,
        completion: @escaping (Bool) -> Void
    ) {
        guard sessionRecoverySessionIsEligible else {
            completion(false)
            return
        }

        if type == .keyDown {
            let targetPID = pid_t(event.getIntegerValueField(.eventTargetUnixProcessID))
            validateSessionRecoveryFocusedLayoutTarget { target in
                guard let target else {
                    completion(false)
                    return
                }
                completion(targetPID <= 0 || targetPID == target.pid)
            }
            return
        }

        let handlingWindowID = event.getIntegerValueField(
            .mouseEventWindowUnderMousePointerThatCanHandleThisEvent
        )
        let pointedWindowID = event.getIntegerValueField(.mouseEventWindowUnderMousePointer)
        var candidateIDs = Array(Set([handlingWindowID, pointedWindowID]
            .filter { $0 > 0 && $0 <= Int64(UInt32.max) }
            .map(UInt32.init)))
        if candidateIDs.isEmpty,
           let hitWindowID = sessionRecoveryFrontmostWindowID(at: event.location)
        {
            candidateIDs = [hitWindowID]
        }
        guard !candidateIDs.isEmpty else {
            completion(false)
            return
        }

        if allWindows().contains(where: { window in
            guard let windowID = window.windowID,
                  candidateIDs.contains(windowID)
            else { return false }
            return cgWindowIsOnScreen(windowID)
        }) {
            completion(true)
            return
        }
        validateSessionRecoveryLayoutTargets(candidateIDs, completion: completion)
    }

    func sessionRecoveryFrontmostWindowID(at point: CGPoint) -> UInt32? {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]]
        else {
            return nil
        }

        for info in list {
            guard let number = info[kCGWindowNumber as String],
                  let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary
            else {
                continue
            }
            var bounds = CGRect.zero
            guard CGRectMakeWithDictionaryRepresentation(boundsDictionary as CFDictionary, &bounds),
                  bounds.contains(point)
            else {
                continue
            }
            if let windowID = number as? UInt32 {
                return windowID
            }
            if let windowID = number as? Int,
               windowID > 0,
               windowID <= Int(UInt32.max)
            {
                return UInt32(windowID)
            }
            return nil
        }
        return nil
    }

    var sessionRecoverySessionIsEligible: Bool {
        guard sessionController.isAwaitingRecoveryInteraction,
              sessionController.isAvailable,
              currentConsoleLockState() != true,
              currentConsoleSessionIsActive() != false
        else {
            return false
        }
        return true
    }

    func validateSessionRecoveryFocusedLayoutTarget(
        completion: @escaping ((pid: pid_t, windowID: UInt32?)?) -> Void
    ) {
        guard sessionRecoverySessionIsEligible,
              let app = NSWorkspace.shared.frontmostApplication,
              app.activationPolicy == .regular
        else {
            completion(nil)
            return
        }
        let generation = sessionController.resumeGeneration
        let pid = app.processIdentifier
        if sessionRecoveryFocusedValidationPID == pid,
           sessionRecoveryFocusedValidationGeneration == generation
        {
            sessionRecoveryFocusedValidationWaiters.append(completion)
            return
        }
        let staleWaiters = sessionRecoveryFocusedValidationWaiters
        sessionRecoveryFocusedValidationWaiters.removeAll()
        sessionRecoveryFocusedValidationPID = pid
        sessionRecoveryFocusedValidationGeneration = generation
        sessionRecoveryFocusedValidationWaiters.append(completion)
        for waiter in staleWaiters { waiter(nil) }

        axOperations.readFocusedWindow(
            pid: pid,
            priority: .interactive,
            coalescingKey: "session-recovery-focused-window"
        ) { [weak self] result in
            guard let self,
                  self.sessionRecoveryFocusedValidationPID == pid,
                  self.sessionRecoveryFocusedValidationGeneration == generation
            else { return }
            var target: (pid: pid_t, windowID: UInt32?)?
            if generation == self.sessionController.resumeGeneration,
               self.sessionRecoverySessionIsEligible,
               NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
               result.disposition == .completed,
               let snapshot = result.value
            {
                self.lastKnownFocusedElements[pid] = snapshot.handle.element
                let focusedWindowID = snapshot.handle.windowID
                if let known = self.allWindows().first(where: { window in
                    guard window.pid == pid else { return false }
                    if self.sameWindow(window.element, snapshot.handle.element) {
                        return window.windowID.map(self.cgWindowIsOnScreen) ?? true
                    }
                    guard let focusedWindowID, window.windowID == focusedWindowID else {
                        return false
                    }
                    return self.cgWindowIsOnScreen(focusedWindowID)
                }) {
                    target = (known.pid, known.windowID)
                } else if self.sessionRecoveryPIDIsLayoutRelevant(pid),
                          self.isManageableWindow(snapshot),
                          focusedWindowID.map(self.cgWindowIsOnScreen) ?? true
                {
                    target = (pid, focusedWindowID)
                }
            }
            let waiters = self.sessionRecoveryFocusedValidationWaiters
            self.sessionRecoveryFocusedValidationWaiters.removeAll()
            self.sessionRecoveryFocusedValidationPID = nil
            self.sessionRecoveryFocusedValidationGeneration = nil
            for waiter in waiters { waiter(target) }
        }
    }

    func validateSessionRecoveryLayoutTargets(
        _ windowIDs: [UInt32],
        completion: @escaping (Bool) -> Void
    ) {
        guard let windowID = windowIDs.first else {
            completion(false)
            return
        }
        validateSessionRecoveryLayoutTarget(windowID: windowID) { [weak self] valid in
            guard let self, !valid else {
                completion(valid)
                return
            }
            self.validateSessionRecoveryLayoutTargets(
                Array(windowIDs.dropFirst()),
                completion: completion
            )
        }
    }

    func validateSessionRecoveryLayoutTarget(
        windowID: UInt32,
        completion: @escaping (Bool) -> Void
    ) {
        guard sessionRecoverySessionIsEligible,
              cgWindowIsOnScreen(windowID),
              let ownerPID = cgWindowOwnerPID(windowID: windowID),
              sessionRecoveryPIDIsLayoutRelevant(ownerPID),
              let app = NSRunningApplication(processIdentifier: ownerPID),
              app.activationPolicy == .regular
        else {
            completion(false)
            return
        }
        let generation = sessionController.resumeGeneration
        axOperations.readApplication(
            pid: ownerPID,
            priority: .interactive,
            coalescingKey: "session-recovery-window-target"
        ) { [weak self] result in
            guard let self,
                  generation == self.sessionController.resumeGeneration,
                  self.sessionRecoverySessionIsEligible,
                  result.disposition == .completed,
                  let snapshot = result.value
            else {
                completion(false)
                return
            }
            completion(snapshot.windows.contains {
                $0.handle.windowID == windowID && self.isManageableWindow($0)
            })
        }
    }

    func sessionRecoveryPIDIsLayoutRelevant(_ pid: pid_t) -> Bool {
        pendingSessionRecoveryLaunchedPIDs.contains(pid) || allWindows().contains { $0.pid == pid }
    }

    func cgWindowOwnerPID(windowID: UInt32) -> pid_t? {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionIncludingWindow],
            CGWindowID(windowID)
        ) as? [[String: Any]],
            let info = list.first
        else {
            return nil
        }
        if let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t {
            return ownerPID
        }
        if let ownerPID = info[kCGWindowOwnerPID as String] as? Int {
            return pid_t(ownerPID)
        }
        return nil
    }

    func requestSessionRecovery(reason: String, command: Command? = nil) {
        enqueue(.input(.sessionRecoveryRequested(reason: reason, command: command)))
    }

    func requestSessionRecoveryImplementation(reason: String, command: Command? = nil) {
        guard sessionRecoverySessionIsEligible else {
            return
        }
        if let command {
            pendingSessionRecoveryCommands.append(command)
        }
        guard let generation = sessionController.scheduleRecoveryIfNeeded() else { return }
        debugLog("session recovery requested reason=\(reason) generation=\(generation)")
        DispatchQueue.main.async { [weak self] in
            self?.enqueue(.session(.recoveryReady(generation: generation, reason: reason)))
        }
    }

    func completeSessionRecoveryImplementation(generation: UInt64, reason: String) {
        guard sessionController.resumeGeneration == generation,
              sessionRecoverySessionIsEligible
        else {
            sessionController.cancelScheduledRecovery()
            appPhase = .sessionUnavailable
            return
        }
        refreshTransientSystemWindowState(allowDuringSessionRecovery: true) { [weak self] in
            self?.finishSessionRecoveryAfterTransientRefresh(
                generation: generation,
                reason: reason
            )
        }
    }

    func finishSessionRecoveryAfterTransientRefresh(generation: UInt64, reason: String) {
        guard sessionController.resumeGeneration == generation,
              sessionRecoverySessionIsEligible
        else {
            sessionController.cancelScheduledRecovery()
            appPhase = .sessionUnavailable
            return
        }
        guard !windowManagement.observation.transientWindowActive else {
            sessionController.cancelScheduledRecovery()
            appPhase = .sessionUnavailable
            debugLog("session recovery deferred reason=transient-system-window")
            return
        }

        afterSessionAXQuiescence { [weak self] in
            guard let self,
                  self.sessionController.resumeGeneration == generation,
                  self.sessionRecoverySessionIsEligible
            else {
                self?.sessionController.cancelScheduledRecovery()
                self?.appPhase = .sessionUnavailable
                return
            }
            guard self.sessionController.completeRecovery(generation: generation) else {
                self.appPhase = .sessionUnavailable
                return
            }
            self.appPhase = .sessionRecovering
            self.uninstallSessionRecoveryEventTap()
            self.axOperations.resetHealthForSessionRecovery()
            self.layoutController.resetForSessionRecovery()
            self.fullWindowScanGeneration &+= 1
            self.focusStateGeneration &+= 1
            self.lastKnownFocusedElements.removeAll()
            self.windowManagement.observation.invalidateAsyncStateForSessionTransition()
            self.refreshFocusedIdentityForSessionRecovery(
                generation: generation,
                reason: reason
            )
        }
    }

    func refreshFocusedIdentityForSessionRecovery(generation: UInt64, reason: String) {
        guard appPhase == .sessionRecovering,
              sessionController.resumeGeneration == generation,
              sessionController.isLayoutTrackingAllowed
        else { return }
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else {
            runSessionRecoveryReconciliation(generation: generation, reason: reason)
            return
        }
        axOperations.readFocusedWindow(
            pid: pid,
            priority: .interactive,
            coalescingKey: "session-recovery-fresh-focus"
        ) { [weak self] result in
            guard let self,
                  self.appPhase == .sessionRecovering,
                  self.sessionController.resumeGeneration == generation,
                  self.sessionController.isLayoutTrackingAllowed
            else { return }
            if result.disposition == .completed,
               let snapshot = result.value,
               NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
            {
                self.lastKnownFocusedElements[pid] = snapshot.handle.element
            }
            self.runSessionRecoveryReconciliation(generation: generation, reason: reason)
        }
    }

    func runSessionRecoveryReconciliation(generation: UInt64, reason: String) {
        guard appPhase == .sessionRecovering,
              sessionController.resumeGeneration == generation,
              sessionController.isLayoutTrackingAllowed
        else { return }
        rescanWindows(adoptFocused: true) { [weak self] completed in
            guard let self,
                  self.appPhase == .sessionRecovering,
                  self.sessionController.resumeGeneration == generation,
                  self.sessionController.isLayoutTrackingAllowed
            else { return }
            guard completed else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                    self?.refreshFocusedIdentityForSessionRecovery(
                        generation: generation,
                        reason: reason
                    )
                }
                return
            }
            self.finalizeSessionRecovery(generation: generation, reason: reason)
        }
    }

    func finalizeSessionRecovery(generation: UInt64, reason: String) {
        guard appPhase == .sessionRecovering,
              sessionController.resumeGeneration == generation,
              sessionController.isLayoutTrackingAllowed
        else { return }

        let commands = pendingSessionRecoveryCommands
        pendingSessionRecoveryCommands.removeAll()
        let launchedWhileUnavailable = pendingSessionRecoveryLaunchedPIDs
        pendingSessionRecoveryLaunchedPIDs.removeAll()
        pendingCoordinatorReconciliation = nil
        reconciliationDrainGeneration &+= 1
        reconciliationDrainScheduled = false
        lastActivatedApplicationPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        appPhase = .running

        for pid in launchedWhileUnavailable {
            guard let app = NSRunningApplication(processIdentifier: pid) else { continue }
            beginAppLaunchSettling(for: app, reason: "session-recovery")
        }
        scheduleReconciliationTimer()
        syncActiveRescanTimer()
        for command in commands { submit(command) }
        drainPendingCoordinatorWorkIfPossible()
        debugLog("layout tracking resumed reason=\(reason) generation=\(generation)")
    }
}
