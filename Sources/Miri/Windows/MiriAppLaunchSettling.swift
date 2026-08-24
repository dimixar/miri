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
              windowManagement.observation.beginLaunchSettling(
                pid: pid,
                deadline: CFAbsoluteTimeGetCurrent() + appLaunchSettlingDuration
              )
        else {
            return
        }

        startObservingApp(pid: pid)
        syncAppLaunchSettlingTimer()
        debugLog(
            "app launch settling started reason=\(reason) app='\(app.localizedName ?? "pid \(pid)")' bundle='\(app.bundleIdentifier ?? "nil")' pid=\(pid) duration=\(Int(appLaunchSettlingDuration))s"
        )

        windowManagement.observation.scheduleInitialLaunchProbe(pid: pid)
    }

    func finishAppLaunchSettling(pid: pid_t, reason: String, allowFutureLaunch: Bool = false) {
        let wasSettling = windowManagement.observation.finishLaunchSettling(
            pid: pid,
            allowFutureLaunch: allowFutureLaunch
        )
        if wasSettling {
            debugLog("app launch settling finished reason=\(reason) pid=\(pid)")
        }
        syncAppLaunchSettlingTimer()
    }

    func cancelAppLaunchSettlingForUnavailableSession() {
        let pids = windowManagement.observation.cancelLaunchSettling()
        guard !pids.isEmpty else { return }
        debugLog("app launch settling cancelled reason=session-unavailable pids=\(pids)")
    }

    func syncAppLaunchSettlingTimer() {
        let shouldRun = isLayoutTrackingAllowed
            && !windowManagement.observation.launchSettlingDeadlines.isEmpty
        windowManagement.observation.configureLaunchSettlingTimer(
            enabled: shouldRun,
            interval: appLaunchSettlingInterval
        )
    }

    func noteAppLaunchSettlingWindowObserved(_ window: ManagedWindow) {
        guard let existing = allWindows().first(where: {
                  $0.pid == window.pid && sameWindow($0.element, window.element)
              })
        else {
            return
        }
        windowManagement.observation.noteLaunchWindowObserved(
            pid: window.pid,
            identity: ObjectIdentifier(existing)
        )
    }

    func shouldDeferMissingWindowRemovalDuringAppLaunchSettling(
        _ window: ManagedWindow,
        reason: String
    ) -> Bool {
        let pid = window.pid
        let now = CFAbsoluteTimeGetCurrent()
        let shouldDefer = windowManagement.observation.shouldDeferLaunchMissingWindow(
            pid: pid,
            identity: ObjectIdentifier(window),
            now: now,
            grace: appLaunchMissingWindowGrace
        )
        guard shouldDefer else { return false }

        debugLog(
            "preserving launch-settling window reason=\(reason) app='\(window.appName)' bundle='\(window.bundleID ?? "nil")' pid=\(pid) title='\(window.title)'"
        )
        return true
    }
}
