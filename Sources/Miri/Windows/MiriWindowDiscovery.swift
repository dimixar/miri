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
            cancelHoverFocus()
            clearTrackpadCamera()
            return
        }
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            self?.rescanWindows(adoptFocused: false)
            self?.adoptFocusedWindow(pid: app.processIdentifier)
        }
        adoptFocusedWindow(pid: app.processIdentifier)
    }

    @objc func applicationLaunched(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.rescanWindows(adoptFocused: true)
        }
    }

    @objc func applicationTerminated(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.rescanWindows(adoptFocused: false)
            self?.projectLayout(focusActiveWindow: false)
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

    func rescanWindows(adoptFocused: Bool) {
        guard !transientSystemWindowIsActive() else {
            cancelHoverFocus()
            clearTrackpadCamera()
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
            if let existing = allWindows().first(where: { sameWindow($0.element, found.element) }) {
                pendingFullscreenTransitionSince.removeValue(forKey: ObjectIdentifier(existing))
                _ = consumeBufferedWindowIfNeeded(existing)
                existing.title = found.title
                existing.appName = found.appName
                existing.bundleID = found.bundleID

                let shouldFloat = behavior(for: existing) == .float
                let isFloating = floatingWindows.contains(where: { $0 === existing })
                if shouldFloat != isFloating {
                    removeWindow(existing)
                    if shouldFloat {
                        insertFloatingWindow(existing, applyLayout: false)
                    } else {
                        insertNewWindow(existing, applyLayout: false, focusNewWindow: false)
                    }
                    changed = true
                }
            } else {
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
                changed = true
            }
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
        let currentPID = ProcessInfo.processInfo.processIdentifier
        var windows: [ManagedWindow] = []

        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular, !app.isHidden else {
                continue
            }
            let pid = app.processIdentifier
            guard pid != currentPID else {
                continue
            }

            startObservingApp(pid: pid)

            let appElement = AXUIElementCreateApplication(pid)
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value)
            guard error == .success, let axWindows = value as? [AXUIElement] else {
                continue
            }

            for element in axWindows {
                logRawAXWindowIfNeeded(element, app: app, source: "scan")
                noteFullscreenSpaceHelperIfNeeded(element)
                guard !isUnknownSubroleWindow(element),
                      !isHiddenOrMinimizedWindow(element),
                      !isFullscreenWindow(element),
                      isManageableWindow(element) || isKnownWindow(element) || isRememberedFullscreenWindow(element)
                else {
                    continue
                }
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
                    continue
                }
                if !isKnownWindow(element), isPictureInPictureWindow(window) {
                    logIgnoredPictureInPictureIfNeeded(window, app: app)
                    continue
                }
                logDiscoveredWindowIfNeeded(window, app: app)
                guard behavior(for: window) != .ignore else {
                    continue
                }
                windows.append(window)
            }
        }

        return windows
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
