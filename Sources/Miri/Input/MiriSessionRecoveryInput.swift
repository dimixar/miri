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
        if isAwaitingSessionRecoveryInteraction {
            installSessionRecoveryEventTap()
        } else {
            uninstallSessionRecoveryEventTap()
        }
    }

    func refreshSessionRecoveryInputTracking() {
        uninstallSessionRecoveryEventTap()
        syncSessionRecoveryInputTracking()
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: true)
        }
    }

    func installSessionRecoveryEventTap() {
        guard sessionRecoveryEventTap == nil else {
            return
        }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: sessionRecoveryInputEventMask,
            callback: sessionRecoveryEventTapCallback,
            userInfo: refcon
        ), let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            debugLog("session recovery input tracking unavailable")
            return
        }

        sessionRecoveryEventTap = tap
        sessionRecoveryEventTapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        debugLog("session recovery input tracking enabled")
    }

    func uninstallSessionRecoveryEventTap() {
        if let sessionRecoveryEventTap {
            CGEvent.tapEnable(tap: sessionRecoveryEventTap, enable: false)
            CFMachPortInvalidate(sessionRecoveryEventTap)
        }
        if let sessionRecoveryEventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), sessionRecoveryEventTapSource, .commonModes)
        }
        sessionRecoveryEventTap = nil
        sessionRecoveryEventTapSource = nil
    }

    func handleSessionRecoveryEventTapDisabled() {
        enqueue(.input(.sessionRecoveryEventTapDisabled))
    }

    func handleSessionRecoveryEventTapDisabledImplementation() {
        guard let sessionRecoveryEventTap else {
            return
        }
        CGEvent.tapEnable(tap: sessionRecoveryEventTap, enable: true)
    }

    func handleSessionRecoveryInput(_ event: CGEvent, type: CGEventType) {
        guard isAwaitingSessionRecoveryInteraction else {
            return
        }
        if type == .keyDown {
            guard sessionRecoveryInputTargetsManagedWindow(event, type: type) else {
                return
            }
            requestSessionRecovery(reason: "managed-key-down")
        } else {
            handlePointerEvent(event, type: type)
        }
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
        guard isAwaitingSessionRecoveryInteraction,
              isSessionAvailable,
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
        guard !isSessionRecoveryResumeScheduled else {
            return
        }

        isSessionRecoveryResumeScheduled = true
        let generation = sessionResumeGeneration
        debugLog("session recovery requested reason=\(reason) generation=\(generation)")
        DispatchQueue.main.async { [weak self] in
            self?.enqueue(.session(.recoveryReady(generation: generation, reason: reason)))
        }
    }

    func completeSessionRecoveryImplementation(generation: UInt64, reason: String) {
        guard sessionResumeGeneration == generation,
              sessionRecoverySessionIsEligible
        else {
            isSessionRecoveryResumeScheduled = false
            return
        }
        guard !transientSystemWindowIsActive(forceRefresh: true) else {
            isSessionRecoveryResumeScheduled = false
            debugLog("session recovery deferred reason=transient-system-window")
            return
        }

        let commands = pendingSessionRecoveryCommands
        pendingSessionRecoveryCommands.removeAll()
        let launchedWhileUnavailable = pendingSessionRecoveryLaunchedPIDs
        pendingSessionRecoveryLaunchedPIDs.removeAll()
        isSessionRecoveryResumeScheduled = false
        isAwaitingSessionRecoveryInteraction = false
        uninstallSessionRecoveryEventTap()

        lastActivatedApplicationPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        rescanWindows(adoptFocused: true)
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

private func sessionRecoveryEventTapCallback(
    _ proxy: CGEventTapProxy,
    _ type: CGEventType,
    _ event: CGEvent,
    _ refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else {
        return Unmanaged.passUnretained(event)
    }
    let app = Unmanaged<Miri>.fromOpaque(refcon).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        app.handleSessionRecoveryEventTapDisabled()
    } else {
        app.handleSessionRecoveryInput(event, type: type)
    }
    return Unmanaged.passUnretained(event)
}
