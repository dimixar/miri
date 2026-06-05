import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

extension Miri {
    var axReconciliationShouldDefer: Bool {
        isApplyingLayout
            || animationTimer != nil
            || snapshotAnimationSession != nil
            || snapshotAnimationPreparing
            || pendingSnapshotDeferredLayout
    }

    func deferAXReconciliation(
        pid: pid_t,
        adoptFocused: Bool,
        needsFullRescan: Bool = false,
        reason: String
    ) {
        if pid != 0 {
            pendingAXReconciliationPIDs.insert(pid)
        } else {
            pendingAXReconciliationNeedsFullRescan = true
        }
        pendingAXReconciliationAdoptFocused = pendingAXReconciliationAdoptFocused || adoptFocused
        pendingAXReconciliationNeedsFullRescan = pendingAXReconciliationNeedsFullRescan || needsFullRescan
        debugLog(
            "ax reconciliation deferred reason=\(reason) pid=\(pid) pids=\(pendingAXReconciliationPIDs.count) fullRescan=\(pendingAXReconciliationNeedsFullRescan)"
        )
        schedulePendingAXReconciliationDrain()
    }

    func schedulePendingAXReconciliationDrain() {
        guard !pendingAXReconciliationDrainScheduled else {
            return
        }
        pendingAXReconciliationDrainScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.drainPendingAXReconciliationIfReady()
        }
    }

    func drainPendingAXReconciliationIfReady() {
        guard !axReconciliationShouldDefer else {
            pendingAXReconciliationDrainScheduled = false
            schedulePendingAXReconciliationDrain()
            return
        }

        pendingAXReconciliationDrainScheduled = false
        guard pendingAXReconciliationNeedsFullRescan || !pendingAXReconciliationPIDs.isEmpty else {
            pendingAXReconciliationAdoptFocused = false
            return
        }

        let pids = pendingAXReconciliationPIDs
        let adoptFocused = pendingAXReconciliationAdoptFocused
        let needsFullRescan = pendingAXReconciliationNeedsFullRescan
        pendingAXReconciliationPIDs.removeAll()
        pendingAXReconciliationAdoptFocused = false
        pendingAXReconciliationNeedsFullRescan = false

        debugLog(
            "ax reconciliation draining pids=\(pids.count) fullRescan=\(needsFullRescan) adoptFocused=\(adoptFocused)"
        )
        if needsFullRescan {
            rescanWindows(adoptFocused: adoptFocused)
            return
        }

        for pid in pids {
            reconcileWindows(forPID: pid, adoptFocused: adoptFocused)
        }
    }

    func scheduleAXCreationReconciliation(pid: pid_t, adoptFocused: Bool, reason: String) {
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
        axCreationSettleGeneration &+= 1
        let generation = axCreationSettleGeneration
        pendingAXCreationSettleGenerations[pid] = generation
        let delays: [TimeInterval] = originalWindowCount == 0
            ? [0.12, 0.45, 1.0, 2.5, 5.0, 10.0, 20.0, 35.0]
            : [0.12, 0.45, 1.0, 2.5]
        debugLog("ax creation reconciliation scheduled reason=\(reason) pid=\(pid) knownWindows=\(originalWindowCount) attempts=\(delays.count)")

        for (index, delay) in delays.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self,
                      self.pendingAXCreationSettleGenerations[pid] == generation
                else {
                    return
                }

                if self.axReconciliationShouldDefer {
                    self.debugLog("ax creation reconciliation attempt deferred reason=\(reason) pid=\(pid) attempt=\(index + 1)/\(delays.count)")
                    self.deferAXReconciliation(pid: pid, adoptFocused: adoptFocused, reason: "\(reason):settle")
                } else {
                    self.debugLog("ax creation reconciliation attempt reason=\(reason) pid=\(pid) attempt=\(index + 1)/\(delays.count)")
                    self.reconcileWindows(forPID: pid, adoptFocused: adoptFocused)
                    let currentWindowCount = self.allWindows().filter { $0.pid == pid }.count
                    if currentWindowCount > originalWindowCount {
                        self.debugLog("ax creation reconciliation completed reason=\(reason) pid=\(pid) windows=\(currentWindowCount)")
                        self.pendingAXCreationSettleGenerations.removeValue(forKey: pid)
                        return
                    }
                }

                if index == delays.indices.last {
                    self.pendingAXCreationSettleGenerations.removeValue(forKey: pid)
                }
            }
        }
    }

    @discardableResult
    func adoptFocusedWindow(pid: pid_t?, applyLayout: Bool = true) -> Bool {
        guard let pid else {
            return false
        }
        if fullscreenSpaceChangeGuardIsActive() {
            debugLog("suppressing focus adoption during fullscreen space guard")
            return false
        }
        if let fullscreenState = focusedRememberedFullscreenWindowState() {
            enforceRememberedFullscreenWorkspaceIfNeeded(fullscreenState)
            debugLog("suppressing focus adoption while focused on remembered fullscreen app='\(fullscreenState.appName)' bundle='\(fullscreenState.bundleID ?? "nil")'")
            return false
        }

        let appElement = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &value)
        guard error == .success, let focused = value else {
            return false
        }

        let focusedElement = focused as! AXUIElement
        if floatingWindows.contains(where: { sameWindow($0.element, focusedElement) }) {
            if applyLayout {
                projectLayout(focusActiveWindow: false)
            }
            return true
        }

        if let loc = location(of: focusedElement) {
            if CFAbsoluteTimeGetCurrent() < keyboardFocusAuthorityUntil,
               let active = activeWindow(),
               !sameWindow(active.element, focusedElement)
            {
                return false
            }
            let workspace = workspaces[loc.workspace]
            let changedFocus = activeWorkspace != loc.workspace || workspace.activeColumn != loc.column
            setActiveWorkspace(loc.workspace)
            workspace.activeColumn = loc.column
            if changedFocus {
                revealActiveColumnIfNeeded(in: workspace, viewport: currentViewport())
            }
            if applyLayout {
                projectLayout(focusActiveWindow: false)
            }
            return true
        }

        return false
    }

    func startObservingApp(pid: pid_t) {
        guard observers[pid] == nil else {
            return
        }

        let appElement = AXUIElementCreateApplication(pid)
        var observer: AXObserver?
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard AXObserverCreate(pid, axObserverCallback, &observer) == .success, let observer else {
            return
        }

        let notifications = [
            kAXCreatedNotification,
            kAXFocusedWindowChangedNotification,
            kAXUIElementDestroyedNotification,
            kAXWindowMovedNotification,
            kAXWindowResizedNotification,
            kAXWindowMiniaturizedNotification,
            kAXWindowDeminiaturizedNotification,
            kAXApplicationHiddenNotification,
            kAXApplicationShownNotification,
        ]

        for notification in notifications {
            AXObserverAddNotification(observer, appElement, notification as CFString, refcon)
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        observers[pid] = observer
    }

    fileprivate func handleAXNotification(_ name: String, element: AXUIElement) {
        logAXNotification(name, element: element)
        noteFullscreenSpaceHelperIfNeeded(element)
        if transientSystemWindowIsActive(forceRefresh: true) {
            return
        }

        switch name {
        case kAXFocusedWindowChangedNotification:
            var pid: pid_t = 0
            AXUIElementGetPid(element, &pid)
            if !isKnownWindow(element), isManageableWindow(element) {
                scheduleAXCreationReconciliation(pid: pid, adoptFocused: true, reason: name)
            }
            guard !isApplyingLayout,
                  snapshotAnimationSession == nil,
                  !snapshotAnimationPreparing,
                  animationTimer == nil,
                  CFAbsoluteTimeGetCurrent() >= suppressFocusedWindowNotificationsUntil
            else {
                return
            }
            adoptFocusedWindow(pid: pid)
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
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                    self?.reconcileWindows(forPID: pid, adoptFocused: true)
                }
            }
        case kAXCreatedNotification,
             kAXWindowMiniaturizedNotification,
             kAXWindowDeminiaturizedNotification,
             kAXApplicationHiddenNotification,
             kAXApplicationShownNotification:
            var pid: pid_t = 0
            AXUIElementGetPid(element, &pid)
            if name == kAXCreatedNotification {
                guard shouldScheduleAXCreatedReconciliation(for: element, pid: pid) else {
                    return
                }
                scheduleAXCreationReconciliation(pid: pid, adoptFocused: true, reason: name)
                return
            }
            guard !axReconciliationShouldDefer else {
                guard isKnownWindow(element) || isManageableWindow(element) else {
                    debugLog("ax notification ignored during snapshot reason=\(name) pid=\(pid) manageable=false known=false")
                    return
                }
                deferAXReconciliation(pid: pid, adoptFocused: true, reason: name)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                self?.reconcileWindows(forPID: pid, adoptFocused: true)
            }
        case kAXWindowResizedNotification:
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
            if handleFullscreenTransitionIfNeeded(element) {
                return
            }
            guard tiledWindow(for: element) != nil else {
                restoreFloatingVisibility()
                return
            }
            guard !manualResizeNotificationsSuppressed else {
                return
            }

            if manualResizeElement != nil {
                guard isManualResizeElement(element) else {
                    return
                }
                beginOrContinueManualResize(for: element)
            } else if !isApplyingLayout {
                beginOrContinueManualResize(for: element)
            }
        case kAXWindowMovedNotification:
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
            if handleFullscreenTransitionIfNeeded(element) {
                return
            }
            if manualResizeNotificationsSuppressed, tiledWindow(for: element) != nil {
                return
            }

            if manualResizeElement != nil {
                guard isManualResizeElement(element) else {
                    return
                }
                beginOrContinueManualResize(for: element)
            } else if !isApplyingLayout {
                guard let window = tiledWindow(for: element) else {
                    restoreFloatingVisibility()
                    return
                }
                if frameWidthDiffersFromLayout(for: element) {
                    beginOrContinueManualResize(for: element)
                    return
                }
                if let frame = axFrame(element) {
                    presentationFrames[ObjectIdentifier(window)] = frame
                }
                projectLayout(focusActiveWindow: false)
            }
        default:
            break
        }
    }
}
private func axObserverCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else {
        return
    }

    let app = Unmanaged<Miri>.fromOpaque(refcon).takeUnretainedValue()
    app.handleAXNotification(notification as String, element: element)
}
