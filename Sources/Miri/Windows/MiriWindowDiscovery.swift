import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

extension Miri {
    @objc func applicationActivated(_ notification: Notification) {
        guard !isApplyingLayout else {
            return
        }
        guard !transientSystemWindowIsActive(forceRefresh: true) else {
            return
        }
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            self?.reconcileWindows(for: app, adoptFocused: false)
            self?.adoptFocusedWindow(pid: app.processIdentifier)
        }
        adoptFocusedWindow(pid: app.processIdentifier)
    }

    @objc func applicationLaunched(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            return
        }
        startObservingApp(pid: app.processIdentifier)
        guard !axReconciliationShouldDefer else {
            deferAXReconciliation(pid: app.processIdentifier, adoptFocused: true, reason: "NSWorkspaceDidLaunch")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.reconcileWindows(for: app, adoptFocused: true)
        }
    }

    @objc func applicationTerminated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            return
        }
        guard !axReconciliationShouldDefer else {
            deferAXReconciliation(
                pid: app.processIdentifier,
                adoptFocused: true,
                needsFullRescan: true,
                reason: "NSWorkspaceDidTerminate"
            )
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.removeWindows(forPID: app.processIdentifier)
        }
    }

    @objc func activeSpaceChanged(_ notification: Notification) {
        if activeContextHasBufferedSourceWindows() {
            debugLog("skipping logical macOS space save during switch because active context has buffered source windows")
        } else {
            saveActiveLogicalSpaceContext()
        }
        pendingLogicalSpaceSwitch = true
        spaceChangeGeneration &+= 1
        debugLog("active macOS space changed generation=\(spaceChangeGeneration)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.rescanWindows(adoptFocused: true)
        }
    }

    func reconcileWindows(for element: AXUIElement, adoptFocused: Bool) {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success,
              pid != 0
        else { return }
        reconcileWindows(forPID: pid, adoptFocused: adoptFocused)
    }

    func reconcileWindows(forPID pid: pid_t, adoptFocused: Bool) {
        guard let app = NSRunningApplication(processIdentifier: pid) else {
            return
        }
        reconcileWindows(for: app, adoptFocused: adoptFocused)
    }

    func reconcileWindows(for app: NSRunningApplication, adoptFocused: Bool) {
        guard app.activationPolicy == .regular,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else {
            return
        }
        guard !transientSystemWindowIsActive() else {
            return
        }

        startObservingApp(pid: app.processIdentifier)
        guard let discovered = discoverWindows(for: app) else {
            removeVanishedWindows(
                forPID: app.processIdentifier,
                adoptFocused: adoptFocused,
                reason: "reconcile AXWindows unavailable"
            )
            return
        }
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
            guard !windowHasCGInfo(window) else {
                continue
            }

            let wasActiveWindow = activeWindow().map { $0 === window } == true
            debugLog(
                "removing vanished window reason=\(reason) app='\(window.appName)' bundle='\(window.bundleID ?? "nil")' pid=\(window.pid) title='\(window.title)' id=\(window.windowID.map(String.init) ?? "nil")"
            )
            removeWindow(window, preferRightFocus: true)
            changed = true
            removedActive = removedActive || wasActiveWindow
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

        for window in allWindows().filter({ $0.pid == pid }) {
            if discovered.contains(where: { sameWindow($0.element, window.element) }) {
                continue
            }

            let runningApp = NSRunningApplication(processIdentifier: window.pid)
            let temporarilyHidden = isHiddenOrMinimizedWindow(window.element)
                || runningApp?.isHidden == true
            let windowID = ObjectIdentifier(window)
            let now = CFAbsoluteTimeGetCurrent()

            if isFullscreenWindow(window.element) {
                pendingFullscreenTransitionSince.removeValue(forKey: windowID)
                fullscreenTransitionGuardUntil = max(fullscreenTransitionGuardUntil, now + fullscreenTransitionGrace)
                rememberFullscreenWindowState(window)
                removeWindow(window, preferRightFocus: true)
                changed = true
                continue
            }

            if let pendingSince = pendingFullscreenTransitionSince[windowID], now - pendingSince < fullscreenTransitionGrace {
                debugLog("preserving pending fullscreen transition app='\(window.appName)' bundle='\(window.bundleID ?? "nil")' title='\(window.title)'")
                continue
            }
            pendingFullscreenTransitionSince.removeValue(forKey: windowID)

            if bufferWindowInUnknownSpaceIfNeeded(window) {
                changed = true
                shouldSaveLogicalSpaceContext = false
                continue
            }
            if temporarilyHidden {
                rememberMinimizedWindowState(window)
            }
            removeWindow(window, preferRightFocus: temporarilyHidden)
            changed = true
        }

        restoreExitedFullscreenWindows(discovered: discovered)

        for found in discovered {
            changed = upsertDiscoveredWindow(found) || changed
        }

        ensureTrailingEmptyWorkspace()
        if adoptFocused {
            _ = adoptFocusedWindow(
                pid: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                applyLayout: false
            )
            projectLayout(focusActiveWindow: false, layoutLockDelay: layoutLockDelay)
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
            pendingFullscreenTransitionSince.removeValue(forKey: ObjectIdentifier(existing))
            _ = consumeBufferedWindowIfNeeded(existing)
            let metadataChanged = existing.title != found.title
                || existing.appName != found.appName
                || existing.bundleID != found.bundleID
            existing.title = found.title
            existing.appName = found.appName
            existing.bundleID = found.bundleID

            let shouldFloat = behavior(for: existing) == .float
            let isFloating = floatingWindows.contains(where: { $0 === existing })
            guard shouldFloat != isFloating else {
                return metadataChanged
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

    func removeWindows(forPID pid: pid_t) {
        var changed = false
        for window in allWindows().filter({ $0.pid == pid }) {
            removeWindow(window, preferRightFocus: true)
            changed = true
        }
        let previousFullscreenCount = fullscreenWindowStates.count
        fullscreenWindowStates = fullscreenWindowStates.filter { $0.value.pid != pid }
        changed = changed || fullscreenWindowStates.count != previousFullscreenCount
        observers.removeValue(forKey: pid)
        if changed {
            projectLayout(focusActiveWindow: false, layoutLockDelay: 0.08)
            saveActiveLogicalSpaceContext()
        }
    }

    func rescanWindows(adoptFocused: Bool) {
        guard !transientSystemWindowIsActive() else {
            return
        }

        let discovered = discoverWindows()
        let restoredPersistentLogicalSpace = restorePersistentLogicalSpaceContextsIfNeeded(discovered: discovered)
        if let fullscreenState = focusedRememberedFullscreenWindowState() {
            enforceRememberedFullscreenWorkspaceIfNeeded(fullscreenState)
            debugLog("skipping rescan mutations while focused on remembered fullscreen app='\(fullscreenState.appName)' bundle='\(fullscreenState.bundleID ?? "nil")' workspace=\(fullscreenState.workspace + 1)")
            return
        }
        if likelyFullscreenExitSettle(discovered: discovered) {
            debugLog("freezing logical macOS space during fullscreen settle visible=0 known=\(currentLogicalSpaceSignature().count)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.rescanWindows(adoptFocused: true)
            }
            return
        }

        let switchedLogicalSpace = handlePendingLogicalSpaceSwitch(discovered: discovered)
        var changed = switchedLogicalSpace || restoredPersistentLogicalSpace
        var shouldSaveLogicalSpaceContext = true

        if likelyBulkTransientDisappearance(discovered: discovered) {
            debugLog("freezing logical macOS space during bulk transient disappearance visible=\(discoveredSignature(discovered).count) known=\(currentLogicalSpaceSignature().count)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.rescanWindows(adoptFocused: true)
            }
            return
        }

        for window in allWindows() {
            if !discovered.contains(where: { sameWindow($0.element, window.element) }) {
                let runningApp = NSRunningApplication(processIdentifier: window.pid)
                let temporarilyHidden = isHiddenOrMinimizedWindow(window.element)
                    || runningApp?.isHidden == true
                let windowID = ObjectIdentifier(window)
                let now = CFAbsoluteTimeGetCurrent()

                if isFullscreenWindow(window.element) {
                    pendingFullscreenTransitionSince.removeValue(forKey: windowID)
                    fullscreenTransitionGuardUntil = max(fullscreenTransitionGuardUntil, now + fullscreenTransitionGrace)
                    rememberFullscreenWindowState(window)
                    removeWindow(window, preferRightFocus: true)
                    changed = true
                    continue
                }

                if let pendingSince = pendingFullscreenTransitionSince[windowID], now - pendingSince < fullscreenTransitionGrace {
                    debugLog("preserving pending fullscreen transition app='\(window.appName)' bundle='\(window.bundleID ?? "nil")' title='\(window.title)'")
                    continue
                }
                pendingFullscreenTransitionSince.removeValue(forKey: windowID)

                if runningApp != nil,
                   !temporarilyHidden,
                   behavior(for: window) != .ignore,
                   now < fullscreenTransitionGuardUntil
                {
                    debugLog("preserving window during fullscreen transition app='\(window.appName)' bundle='\(window.bundleID ?? "nil")' title='\(window.title)'")
                    continue
                }
                if bufferWindowInUnknownSpaceIfNeeded(window) {
                    changed = true
                    shouldSaveLogicalSpaceContext = false
                    continue
                }
                if temporarilyHidden {
                    rememberMinimizedWindowState(window)
                }
                removeWindow(window, preferRightFocus: temporarilyHidden)
                changed = true
            }
        }

        restoreExitedFullscreenWindows(discovered: discovered)

        for found in discovered {
            changed = upsertDiscoveredWindow(found) || changed
        }

        let restoredPersistentLayout = applyPersistentLayoutSnapshotIfNeeded()
        ensureTrailingEmptyWorkspace()

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

    func discoverWindows() -> [ManagedWindow] {
        var windows: [ManagedWindow] = []

        for app in NSWorkspace.shared.runningApplications {
            if let appWindows = discoverWindows(for: app) {
                windows.append(contentsOf: appWindows)
            }
        }

        return windows
    }

    func discoverWindows(for app: NSRunningApplication) -> [ManagedWindow]? {
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

        var windows: [ManagedWindow] = []
        for element in axWindows {
            if let window = managedWindow(from: element, app: app, source: "scan") {
                windows.append(window)
            }
        }

        return windows
    }

    func managedWindow(from element: AXUIElement, app: NSRunningApplication, source: String) -> ManagedWindow? {
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
        return window
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

    func isUnknownSubroleWindow(_ element: AXUIElement) -> Bool {
        axString(element, kAXSubroleAttribute) == "AXUnknown"
    }

    func isKnownWindow(_ element: AXUIElement) -> Bool {
        allWindows().contains { sameWindow($0.element, element) }
    }

}
