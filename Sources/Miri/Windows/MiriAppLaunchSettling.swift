import AppKit
import Foundation

extension Miri {
    private var appLaunchSettlingDuration: TimeInterval { 30 }
    private var appLaunchSettlingInterval: TimeInterval { 1 }
    private var appLaunchMissingWindowGrace: TimeInterval { 0.75 }

    func beginAppLaunchSettling(for app: NSRunningApplication, reason: String) {
        let pid = app.processIdentifier
        guard pid != 0,
              pid != ProcessInfo.processInfo.processIdentifier,
              app.activationPolicy == .regular,
              appLaunchObservedPIDs.insert(pid).inserted
        else {
            return
        }

        let deadline = CFAbsoluteTimeGetCurrent() + appLaunchSettlingDuration
        appLaunchSettlingDeadlines[pid] = deadline
        startObservingApp(pid: pid)
        syncAppLaunchSettlingTimer()
        debugLog(
            "app launch settling started reason=\(reason) app='\(app.localizedName ?? "pid \(pid)")' bundle='\(app.bundleIdentifier ?? "nil")' pid=\(pid) duration=\(Int(appLaunchSettlingDuration))s"
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.performAppLaunchSettlingReconciliation(pid: pid, reason: "initial")
        }
    }

    func finishAppLaunchSettling(pid: pid_t, reason: String, allowFutureLaunch: Bool = false) {
        let wasSettling = appLaunchSettlingDeadlines.removeValue(forKey: pid) != nil
        appLaunchMissingWindowSince.removeValue(forKey: pid)
        if allowFutureLaunch {
            appLaunchObservedPIDs.remove(pid)
        }
        if wasSettling {
            debugLog("app launch settling finished reason=\(reason) pid=\(pid)")
        }
        syncAppLaunchSettlingTimer()
    }

    func cancelAppLaunchSettlingForUnavailableSession() {
        guard !appLaunchSettlingDeadlines.isEmpty else {
            return
        }
        let pids = appLaunchSettlingDeadlines.keys.sorted()
        appLaunchSettlingDeadlines.removeAll()
        appLaunchMissingWindowSince.removeAll()
        appLaunchSettlingTimer?.invalidate()
        appLaunchSettlingTimer = nil
        debugLog("app launch settling cancelled reason=session-unavailable pids=\(pids)")
    }

    func syncAppLaunchSettlingTimer() {
        let shouldRun = isLayoutTrackingAllowed && !appLaunchSettlingDeadlines.isEmpty
        if shouldRun, appLaunchSettlingTimer == nil {
            appLaunchSettlingTimer = Timer.scheduledTimer(
                withTimeInterval: appLaunchSettlingInterval,
                repeats: true
            ) { [weak self] _ in
                self?.handleAppLaunchSettlingTick()
            }
            debugLog("app launch settling timer started")
        } else if !shouldRun, appLaunchSettlingTimer != nil {
            appLaunchSettlingTimer?.invalidate()
            appLaunchSettlingTimer = nil
            debugLog("app launch settling timer stopped")
        }
    }

    private func handleAppLaunchSettlingTick() {
        guard isLayoutTrackingAllowed else {
            syncAppLaunchSettlingTimer()
            return
        }

        let now = CFAbsoluteTimeGetCurrent()
        for (pid, deadline) in Array(appLaunchSettlingDeadlines) {
            guard now < deadline else {
                finishAppLaunchSettling(pid: pid, reason: "deadline")
                continue
            }
            performAppLaunchSettlingReconciliation(pid: pid, reason: "timer")
        }
    }

    private func performAppLaunchSettlingReconciliation(pid: pid_t, reason: String) {
        guard let deadline = appLaunchSettlingDeadlines[pid],
              CFAbsoluteTimeGetCurrent() < deadline
        else {
            return
        }
        guard let app = NSRunningApplication(processIdentifier: pid),
              app.activationPolicy == .regular
        else {
            finishAppLaunchSettling(
                pid: pid,
                reason: "process-unavailable",
                allowFutureLaunch: true
            )
            return
        }
        guard isLayoutTrackingAllowed else {
            return
        }

        let adoptFocused = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
        if axReconciliationShouldDefer {
            deferAXReconciliation(
                pid: pid,
                adoptFocused: adoptFocused,
                reason: "app-launch-settling:\(reason)"
            )
        } else {
            debugLog("app launch settling reconciliation reason=\(reason) pid=\(pid)")
            reconcileWindows(for: app, adoptFocused: adoptFocused)
        }
    }

    func noteAppLaunchSettlingWindowObserved(_ window: ManagedWindow) {
        guard appLaunchSettlingDeadlines[window.pid] != nil,
              let existing = allWindows().first(where: {
                  $0.pid == window.pid && sameWindow($0.element, window.element)
              })
        else {
            return
        }
        appLaunchMissingWindowSince[window.pid]?.removeValue(forKey: ObjectIdentifier(existing))
        if appLaunchMissingWindowSince[window.pid]?.isEmpty == true {
            appLaunchMissingWindowSince.removeValue(forKey: window.pid)
        }
    }

    func shouldDeferMissingWindowRemovalDuringAppLaunchSettling(
        _ window: ManagedWindow,
        reason: String
    ) -> Bool {
        let pid = window.pid
        let now = CFAbsoluteTimeGetCurrent()
        guard let deadline = appLaunchSettlingDeadlines[pid], now < deadline else {
            appLaunchMissingWindowSince[pid]?.removeValue(forKey: ObjectIdentifier(window))
            return false
        }

        let id = ObjectIdentifier(window)
        if let missingSince = appLaunchMissingWindowSince[pid]?[id] {
            if now - missingSince >= appLaunchMissingWindowGrace {
                appLaunchMissingWindowSince[pid]?.removeValue(forKey: id)
                return false
            }
        } else {
            appLaunchMissingWindowSince[pid, default: [:]][id] = now
        }

        debugLog(
            "preserving launch-settling window reason=\(reason) app='\(window.appName)' bundle='\(window.bundleID ?? "nil")' pid=\(pid) title='\(window.title)'"
        )
        return true
    }
}
