import AppKit
import ApplicationServices
import CoreGraphics

@MainActor
private final class TransientWindowRefreshAccumulator {
    var remaining: Int
    var windows: [AXWindowReadSnapshot] = []
    var finished = false

    init(remaining: Int) {
        self.remaining = remaining
    }
}

extension Miri {
    func transientSystemWindowIsActive(forceRefresh: Bool = false) -> Bool {
        if forceRefresh { refreshTransientSystemWindowState() }
        return windowManagement.observation.transientWindowActive
    }

    func refreshTransientSystemWindowState(
        allowDuringSessionRecovery: Bool = false,
        completion: (() -> Void)? = nil
    ) {
        let refreshAllowed = sessionController.isLayoutTrackingAllowed
            || (allowDuringSessionRecovery && sessionRecoverySessionIsEligible)
        guard refreshAllowed else {
            completion?()
            return
        }
        if transientWindowRefreshInFlight {
            transientWindowRefreshPending = true
            transientWindowRefreshPendingAllowsSessionRecovery =
                transientWindowRefreshPendingAllowsSessionRecovery
                || allowDuringSessionRecovery
            if let completion {
                pendingTransientWindowRefreshCompletions.append(completion)
            }
            return
        }
        if let completion {
            transientWindowRefreshCompletions.append(completion)
        }
        transientWindowRefreshInFlight = true
        transientWindowRefreshPending = false
        transientWindowRefreshPendingAllowsSessionRecovery = false
        transientWindowRefreshGeneration &+= 1
        let generation = transientWindowRefreshGeneration
        let apps = transientCheckApplications
        let expectedPIDs = Set(apps.map(\.processIdentifier))
        let expectedFrontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let accumulator = TransientWindowRefreshAccumulator(remaining: apps.count)
        guard !apps.isEmpty else {
            _ = windowManagement.observation.recordTransientState(
                false,
                checkedAt: CFAbsoluteTimeGetCurrent()
            )
            finishTransientSystemWindowRefresh()
            return
        }

        // AX's configured messaging timeout is the first line of defense, but
        // activation and session recovery must not depend on every target call
        // honoring it. Preserve the last admitted guard state and release all
        // waiters after a bounded outer deadline.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self, weak accumulator] in
            guard let self, let accumulator,
                  generation == self.transientWindowRefreshGeneration,
                  self.transientWindowRefreshInFlight,
                  !accumulator.finished
            else { return }
            accumulator.finished = true
            self.debugLog("transient refresh deadline exceeded pending=\(accumulator.remaining)")
            self.finishTransientSystemWindowRefresh()
        }

        for app in apps {
            let pid = app.processIdentifier
            axOperations.readFocusedWindow(
                pid: pid,
                priority: .background,
                coalescingKey: "transient-focused-window"
            ) { [weak self, weak app] result in
                guard let self,
                      generation == self.transientWindowRefreshGeneration,
                      !accumulator.finished
                else { return }
                if result.disposition == .completed,
                   let snapshot = result.value,
                   let liveApp = app ?? NSRunningApplication(processIdentifier: pid),
                   self.isTransientSystemWindow(snapshot, app: liveApp)
                {
                    accumulator.windows.append(snapshot)
                }
                accumulator.remaining -= 1
                guard accumulator.remaining == 0 else { return }
                accumulator.finished = true

                let currentPIDs = Set(self.transientCheckApplications.map(\.processIdentifier))
                let currentFrontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
                guard currentPIDs == expectedPIDs,
                      currentFrontmostPID == expectedFrontmostPID else {
                    self.transientWindowRefreshPending = true
                    self.transientWindowRefreshPendingAllowsSessionRecovery =
                        self.transientWindowRefreshPendingAllowsSessionRecovery
                        || allowDuringSessionRecovery
                    self.pendingTransientWindowRefreshCompletions.append(
                        contentsOf: self.transientWindowRefreshCompletions
                    )
                    self.transientWindowRefreshCompletions.removeAll()
                    self.debugLog("transient refresh discarded reason=active-app-set-changed")
                    self.finishTransientSystemWindowRefresh()
                    return
                }

                let viewport = self.currentViewport()
                var recoveryRequested = false
                for snapshot in accumulator.windows {
                    let origin = snapshot.frame.flatMap { frame -> CGPoint? in
                        guard self.transientFrameNeedsRecovery(frame, viewport: viewport) else { return nil }
                        recoveryRequested = true
                        return self.centeredOrigin(for: frame, in: viewport)
                    }
                    self.axOperations.recoverTransientWindow(
                        handle: snapshot.handle,
                        centeredOrigin: origin
                    )
                }
                let active = !accumulator.windows.isEmpty
                let changed = self.windowManagement.observation.recordTransientState(
                    active,
                    checkedAt: CFAbsoluteTimeGetCurrent()
                )
                if changed || recoveryRequested {
                    self.enqueue(.windows(.environmentGuardEvaluated(
                        blocked: active,
                        recovered: recoveryRequested
                    )))
                }
                self.finishTransientSystemWindowRefresh()
            }
        }
    }

    func cancelTransientSystemWindowRefreshForSessionTransition() {
        transientWindowRefreshGeneration &+= 1
        transientWindowRefreshInFlight = false
        transientWindowRefreshPending = false
        transientWindowRefreshPendingAllowsSessionRecovery = false
        let completions = transientWindowRefreshCompletions
            + pendingTransientWindowRefreshCompletions
        transientWindowRefreshCompletions.removeAll()
        pendingTransientWindowRefreshCompletions.removeAll()
        for completion in completions { completion() }
    }

    func finishTransientSystemWindowRefresh() {
        transientWindowRefreshInFlight = false
        let completions = transientWindowRefreshCompletions
        transientWindowRefreshCompletions.removeAll()
        for completion in completions { completion() }

        guard transientWindowRefreshPending else { return }
        transientWindowRefreshPending = false
        let allowDuringSessionRecovery = transientWindowRefreshPendingAllowsSessionRecovery
        transientWindowRefreshPendingAllowsSessionRecovery = false
        transientWindowRefreshCompletions = pendingTransientWindowRefreshCompletions
        pendingTransientWindowRefreshCompletions.removeAll()
        refreshTransientSystemWindowState(
            allowDuringSessionRecovery: allowDuringSessionRecovery
        )
    }

    func isTransientSystemWindow(
        _ snapshot: AXWindowReadSnapshot,
        app: NSRunningApplication
    ) -> Bool {
        if snapshot.role == kAXSheetRole || snapshot.role == "AXSheet" || snapshot.role == "AXDialog" {
            return true
        }
        if snapshot.subrole == "AXSystemDialog" || snapshot.subrole == "AXDialog" {
            return true
        }
        if snapshot.role == kAXWindowRole,
           snapshot.subrole == "AXUnknown",
           snapshot.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !isManageableWindow(snapshot)
        {
            return true
        }
        if isChromiumBrowser(app),
           snapshot.role == kAXWindowRole,
           isChromiumTransientSubrole(snapshot.subrole),
           isChromiumTransientTitle(snapshot.title),
           let frame = snapshot.frame,
           frame.width <= 620,
           frame.height <= 620
        {
            return true
        }
        return isOpenAndSavePanelService(app)
    }

    func transientFrameNeedsRecovery(_ frame: CGRect, viewport: CGRect) -> Bool {
        !frame.intersects(viewport)
            || frame.midX < viewport.minX
            || frame.midX > viewport.maxX
            || frame.midY < viewport.minY
            || frame.midY > viewport.maxY
    }

    func centeredOrigin(for frame: CGRect, in viewport: CGRect) -> CGPoint {
        CGPoint(
            x: viewport.midX - frame.width / 2,
            y: viewport.midY - frame.height / 2
        )
    }

    var transientCheckApplications: [NSRunningApplication] {
        var apps: [NSRunningApplication] = []
        if let frontmostApplication = NSWorkspace.shared.frontmostApplication {
            apps.append(frontmostApplication)
        }
        for app in NSWorkspace.shared.runningApplications where app.isActive {
            if !apps.contains(where: { $0.processIdentifier == app.processIdentifier }) {
                apps.append(app)
            }
        }
        for panelService in openAndSavePanelServices(matchingAnyHostIn: apps) {
            if !apps.contains(where: { $0.processIdentifier == panelService.processIdentifier }) {
                apps.append(panelService)
            }
        }
        return apps
    }

    func openAndSavePanelServices(matchingAnyHostIn hosts: [NSRunningApplication]) -> [NSRunningApplication] {
        let hostNames = hosts.compactMap(\.localizedName)
        guard !hostNames.isEmpty else {
            return []
        }

        return NSWorkspace.shared.runningApplications.filter { app in
            guard isOpenAndSavePanelService(app),
                  let name = app.localizedName
            else {
                return false
            }
            return hostNames.contains { name.contains("(\($0))") }
        }
    }

    func isOpenAndSavePanelService(_ app: NSRunningApplication) -> Bool {
        app.bundleIdentifier == "com.apple.appkit.xpc.openAndSavePanelService"
    }

    func isLikelyTransientPopup(
        _ window: ManagedWindow,
        app: NSRunningApplication,
        frame: CGRect?
    ) -> Bool {
        // Chromium exposes toolbar bubbles (media controls, profiles, permissions,
        // extension popovers, etc.) as small, often untitled AXWindows. PiP is also
        // app-managed/always-on-top, so don't tile it either.
        guard isChromiumBrowser(app),
              isChromiumTransientTitle(window.title),
              let frame
        else {
            return false
        }
        return frame.width <= 620 && frame.height <= 620
    }

    func isChromiumTransientTitle(_ title: String) -> Bool {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalizedTitle.isEmpty
            || normalizedTitle == "global media controls"
            || isPictureInPictureTitle(title)
    }

    func isChromiumTransientSubrole(_ subrole: String?) -> Bool {
        subrole == nil || subrole == kAXStandardWindowSubrole || subrole == "AXUnknown"
    }

    func isPictureInPictureWindow(_ window: ManagedWindow) -> Bool {
        isPictureInPictureTitle(window.title)
    }

    func isPictureInPictureTitle(_ title: String) -> Bool {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalizedTitle == "picture in picture"
            || normalizedTitle == "picture-in-picture"
            || normalizedTitle == "pip"
    }

    func isChromiumBrowser(_ app: NSRunningApplication) -> Bool {
        guard let bundleID = app.bundleIdentifier else {
            return false
        }
        return bundleID == "com.google.Chrome"
            || bundleID == "com.google.Chrome.beta"
            || bundleID == "com.google.Chrome.dev"
            || bundleID == "com.google.Chrome.canary"
            || bundleID == "com.microsoft.edgemac"
            || bundleID == "com.brave.Browser"
            || bundleID == "com.vivaldi.Vivaldi"
            || bundleID == "com.operasoftware.Opera"
            || bundleID == "net.imput.helium"
            || bundleID.hasPrefix("org.chromium.")
    }

}
