import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

extension Miri {
    func requestSessionRecoveryForFullscreenTransitionIfNeeded(
        notification: String,
        element: AXUIElement
    ) {
        guard notification == kAXWindowMovedNotification
                || notification == kAXWindowResizedNotification
                || notification == kAXFocusedWindowChangedNotification,
              sessionRecoverySessionIsEligible,
              let isFullscreen = axBool(element, "AXFullScreen")
        else {
            return
        }

        let enteredFullscreen = isFullscreen && isKnownWindow(element)
        let exitedFullscreen = !isFullscreen && isRememberedFullscreenWindow(element)
        guard enteredFullscreen || exitedFullscreen else {
            return
        }

        let direction = enteredFullscreen ? "entered" : "exited"
        requestSessionRecovery(reason: "tracked-window-fullscreen-\(direction):\(notification)")
    }

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
        guard sessionController.isAwaitingRecoveryInteraction else {
            return
        }
        if type == .keyDown {
            guard sessionRecoveryInputTargetsManagedWindow(event, type: type) else {
                return
            }
            requestSessionRecovery(reason: "managed-key-down")
        } else {
            guard sessionRecoveryInputTargetsManagedWindow(event, type: type) else {
                return
            }
            requestSessionRecovery(reason: "managed-pointer-event-\(type.rawValue)")
        }
    }

    func handleSessionRecoveryKeyEvent(_ event: CGEvent?, command: Command?) -> Bool {
        guard sessionController.isAwaitingRecoveryInteraction else {
            return false
        }
        if let event {
            guard sessionRecoveryInputTargetsManagedWindow(event, type: .keyDown) else {
                return false
            }
        } else {
            guard sessionRecoveryFocusedLayoutTarget() != nil else {
                return false
            }
        }
        requestSessionRecovery(reason: "managed-key-down", command: command)
        return command != nil
    }

    func sessionRecoveryInputTargetsManagedWindow(
        _ event: CGEvent,
        type: CGEventType
    ) -> Bool {
        guard sessionRecoverySessionIsEligible else {
            return false
        }

        if type == .keyDown {
            let targetPID = pid_t(event.getIntegerValueField(.eventTargetUnixProcessID))
            guard let target = sessionRecoveryFocusedLayoutTarget() else {
                return false
            }
            return targetPID <= 0 || targetPID == target.pid
        }

        let handlingWindowID = event.getIntegerValueField(
            .mouseEventWindowUnderMousePointerThatCanHandleThisEvent
        )
        let pointedWindowID = event.getIntegerValueField(.mouseEventWindowUnderMousePointer)
        let candidateIDs = [handlingWindowID, pointedWindowID]
            .filter { $0 > 0 && $0 <= Int64(UInt32.max) }
            .map(UInt32.init)

        if candidateIDs.isEmpty {
            guard let hitWindowID = sessionRecoveryFrontmostWindowID(at: event.location) else {
                return false
            }
            return allWindows().contains { $0.windowID == hitWindowID }
                || sessionRecoveryLayoutTarget(windowID: hitWindowID)
        }

        if allWindows().contains(where: { window in
            guard let windowID = window.windowID,
                  candidateIDs.contains(windowID)
            else {
                return false
            }
            return cgWindowIsOnScreen(windowID)
        }) {
            return true
        }

        return candidateIDs.contains { sessionRecoveryLayoutTarget(windowID: $0) }
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

    func sessionRecoveryFocusedLayoutTarget() -> (pid: pid_t, windowID: UInt32?)? {
        guard sessionRecoverySessionIsEligible,
              let app = NSWorkspace.shared.frontmostApplication,
              app.activationPolicy == .regular
        else {
            return nil
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &value
        ) == .success,
            let value
        else {
            return nil
        }

        let focusedElement = value as! AXUIElement
        let focusedWindowID = SkyLight.shared.windowID(for: focusedElement)
        if let known = allWindows().first(where: { window in
            guard window.pid == app.processIdentifier else {
                return false
            }
            if sameWindow(window.element, focusedElement) {
                return window.windowID.map(cgWindowIsOnScreen) ?? true
            }
            guard let focusedWindowID, window.windowID == focusedWindowID else {
                return false
            }
            return cgWindowIsOnScreen(focusedWindowID)
        }) {
            return (known.pid, known.windowID)
        }

        guard sessionRecoveryPIDIsLayoutRelevant(app.processIdentifier),
              isManageableWindow(focusedElement)
        else {
            return nil
        }
        if let focusedWindowID, !cgWindowIsOnScreen(focusedWindowID) {
            return nil
        }
        return (app.processIdentifier, focusedWindowID)
    }

    func sessionRecoveryLayoutTarget(windowID: UInt32) -> Bool {
        guard cgWindowIsOnScreen(windowID),
              let ownerPID = cgWindowOwnerPID(windowID: windowID),
              sessionRecoveryPIDIsLayoutRelevant(ownerPID),
              let app = NSRunningApplication(processIdentifier: ownerPID),
              app.activationPolicy == .regular
        else {
            return false
        }

        let appElement = AXUIElementCreateApplication(ownerPID)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXWindowsAttribute as CFString,
            &value
        ) == .success,
            let windows = value as? [AXUIElement]
        else {
            return false
        }
        return windows.contains { element in
            SkyLight.shared.windowID(for: element) == windowID && isManageableWindow(element)
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
            return
        }
        guard !transientSystemWindowIsActive(forceRefresh: true) else {
            sessionController.cancelScheduledRecovery()
            debugLog("session recovery deferred reason=transient-system-window")
            return
        }

        let commands = pendingSessionRecoveryCommands
        pendingSessionRecoveryCommands.removeAll()
        let launchedWhileUnavailable = pendingSessionRecoveryLaunchedPIDs
        pendingSessionRecoveryLaunchedPIDs.removeAll()
        guard sessionController.completeRecovery(generation: generation) else { return }
        uninstallSessionRecoveryEventTap()

        lastActivatedApplicationPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        requestReconciliation(
            .all(adoptFocused: true, source: .sessionRecovery, reason: "session-recovery-complete")
        )
        for pid in launchedWhileUnavailable {
            guard let app = NSRunningApplication(processIdentifier: pid) else {
                continue
            }
            beginAppLaunchSettling(for: app, reason: "session-recovery")
        }
        scheduleReconciliationTimer()
        syncActiveRescanTimer()
        for command in commands {
            submit(command)
        }
        debugLog("layout tracking resumed reason=\(reason) generation=\(generation)")
    }
}
