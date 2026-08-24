import AppKit
import ApplicationServices
import Darwin
import Foundation

/// Owns the operating-system observation handles and delayed discovery work.
/// It reports facts and reconciliation intents; it never mutates the logical
/// workspace graph or starts layout.
final class WindowObservationController: NSObject, @unchecked Sendable {
    typealias EventSink = (AppEvent) -> Void

    private let emit: EventSink
    private var workspaceObserverTokens: [NSObjectProtocol] = []
    private var axObservers: [pid_t: AXObserver] = [:]
    private var periodicTimer: Timer?
    private var activeRescanTimer: Timer?
    private var activeRescanPIDs = Set<pid_t>()
    private var launchSettlingTimer: Timer?

    private(set) var focusedWindowProbeGeneration: UInt64 = 0
    private(set) var launchSettlingDeadlines: [pid_t: CFAbsoluteTime] = [:]
    private var launchObservedPIDs = Set<pid_t>()
    private var launchMissingWindowSince: [pid_t: [ObjectIdentifier: CFAbsoluteTime]] = [:]
    private var pendingCreationSettleGenerations: [pid_t: UInt64] = [:]
    private var creationSettleGeneration: UInt64 = 0
    private var lastPlaceholderProbeAt: [pid_t: CFAbsoluteTime] = [:]
    private(set) var transientWindowActive = false
    private var transientWindowStateCheckedAt: CFAbsoluteTime = 0

    init(emit: @escaping EventSink) {
        self.emit = emit
    }

    deinit {
        stop()
    }

    func startWorkspaceObservation() {
        guard workspaceObserverTokens.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        workspaceObserverTokens = [
            center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                self?.emit(.workspace(.applicationActivated(app)))
            },
            center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                self?.emit(.workspace(.applicationLaunched(app)))
            },
            center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                self?.emit(.workspace(.applicationTerminated(app)))
            },
            center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                self?.emit(.workspace(.activeSpaceChanged))
            },
        ]
    }

    func observeApplication(pid: pid_t, log: (String) -> Void) {
        guard axObservers[pid] == nil else { return }
        let appElement = AXUIElementCreateApplication(pid)
        var observer: AXObserver?
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard AXObserverCreate(pid, windowObservationAXCallback, &observer) == .success,
              let observer
        else { return }

        let notifications = [
            kAXCreatedNotification,
            kAXFocusedWindowChangedNotification,
            kAXMainWindowChangedNotification,
            kAXUIElementDestroyedNotification,
            kAXWindowMovedNotification,
            kAXWindowResizedNotification,
            kAXWindowMiniaturizedNotification,
            kAXWindowDeminiaturizedNotification,
            kAXApplicationHiddenNotification,
            kAXApplicationShownNotification,
        ]
        for notification in notifications {
            let error = AXObserverAddNotification(observer, appElement, notification as CFString, refcon)
            if error != .success, error != .notificationAlreadyRegistered {
                log("ax observer registration failed pid=\(pid) notification=\(notification) error=\(error.rawValue)")
            }
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        axObservers[pid] = observer
    }

    func removeApplication(pid: pid_t) {
        axObservers.removeValue(forKey: pid)
        pendingCreationSettleGenerations.removeValue(forKey: pid)
        lastPlaceholderProbeAt.removeValue(forKey: pid)
    }

    func scheduleFocusedWindowProbe(reason: String, delay: TimeInterval = 0.08) {
        focusedWindowProbeGeneration &+= 1
        let generation = focusedWindowProbeGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.emit(.input(.focusedWindowProbeDue(reason: reason, generation: generation)))
        }
    }

    func scheduleApplicationActivationSettled(_ app: NSRunningApplication, delay: TimeInterval = 0.08) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.emit(.workspace(.applicationActivationSettled(app)))
        }
    }

    func scheduleReconciliation(_ intent: ReconciliationIntent, delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.emit(.windows(.reconciliationRequested(intent)))
        }
    }

    func focusedWindowProbeIsCurrent(_ generation: UInt64) -> Bool {
        generation == focusedWindowProbeGeneration
    }

    func placeholderProbeIsRateLimited(pid: pid_t, cooldown: TimeInterval) -> (limited: Bool, elapsed: TimeInterval?) {
        guard cooldown > 0 else { return (false, nil) }
        let now = CFAbsoluteTimeGetCurrent()
        if let last = lastPlaceholderProbeAt[pid], now - last < cooldown {
            return (true, now - last)
        }
        lastPlaceholderProbeAt[pid] = now
        return (false, nil)
    }

    func scheduleCreationReconciliation(
        pid: pid_t,
        adoptFocused: Bool,
        sourceReason: String,
        delays: [TimeInterval]
    ) {
        creationSettleGeneration &+= 1
        let generation = creationSettleGeneration
        pendingCreationSettleGenerations[pid] = generation
        for (index, delay) in delays.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.pendingCreationSettleGenerations[pid] == generation else { return }
                self.emit(.windows(.reconciliationRequested(.application(
                    pid: pid,
                    adoptFocused: adoptFocused,
                    source: .delayedProbe,
                    reason: "\(sourceReason):settle-\(index + 1)"
                ))))
                if index == delays.indices.last {
                    self.pendingCreationSettleGenerations.removeValue(forKey: pid)
                }
            }
        }
    }

    func cancelCreationReconciliations() {
        pendingCreationSettleGenerations.removeAll()
    }

    @discardableResult
    func beginLaunchSettling(pid: pid_t, deadline: CFAbsoluteTime) -> Bool {
        guard launchObservedPIDs.insert(pid).inserted else { return false }
        launchSettlingDeadlines[pid] = deadline
        return true
    }

    func scheduleInitialLaunchProbe(pid: pid_t, delay: TimeInterval = 0.12) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.launchSettlingDeadlines[pid] != nil else { return }
            self.emit(.windows(.reconciliationRequested(.application(
                pid: pid,
                adoptFocused: true,
                source: .launchSettling,
                reason: "initial"
            ))))
        }
    }

    @discardableResult
    func finishLaunchSettling(pid: pid_t, allowFutureLaunch: Bool) -> Bool {
        let existed = launchSettlingDeadlines.removeValue(forKey: pid) != nil
        launchMissingWindowSince.removeValue(forKey: pid)
        if allowFutureLaunch { launchObservedPIDs.remove(pid) }
        return existed
    }

    func cancelLaunchSettling() -> [pid_t] {
        let pids = launchSettlingDeadlines.keys.sorted()
        launchSettlingDeadlines.removeAll()
        launchMissingWindowSince.removeAll()
        configureLaunchSettlingTimer(enabled: false, interval: 1)
        return pids
    }

    func launchDeadline(for pid: pid_t) -> CFAbsoluteTime? {
        launchSettlingDeadlines[pid]
    }

    func noteLaunchWindowObserved(pid: pid_t, identity: ObjectIdentifier) {
        guard launchSettlingDeadlines[pid] != nil else { return }
        launchMissingWindowSince[pid]?.removeValue(forKey: identity)
        if launchMissingWindowSince[pid]?.isEmpty == true {
            launchMissingWindowSince.removeValue(forKey: pid)
        }
    }

    func shouldDeferLaunchMissingWindow(
        pid: pid_t,
        identity: ObjectIdentifier,
        now: CFAbsoluteTime,
        grace: TimeInterval
    ) -> Bool {
        guard let deadline = launchSettlingDeadlines[pid], now < deadline else {
            launchMissingWindowSince[pid]?.removeValue(forKey: identity)
            return false
        }
        if let missingSince = launchMissingWindowSince[pid]?[identity] {
            if now - missingSince >= grace {
                launchMissingWindowSince[pid]?.removeValue(forKey: identity)
                return false
            }
        } else {
            launchMissingWindowSince[pid, default: [:]][identity] = now
        }
        return true
    }

    func configurePeriodicTimer(enabled: Bool, interval: TimeInterval) {
        periodicTimer?.invalidate()
        periodicTimer = nil
        guard enabled else { return }
        periodicTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.emit(.windows(.reconciliationRequested(.all(
                adoptFocused: false,
                source: .periodicTimer,
                reason: "periodic-timer"
            ))))
        }
    }

    func configureActiveRescanTimer(pids: Set<pid_t>, interval: TimeInterval = 1) {
        activeRescanPIDs = pids
        if !pids.isEmpty, activeRescanTimer == nil {
            activeRescanTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                guard let self, !self.activeRescanPIDs.isEmpty else { return }
                self.emit(.windows(.reconciliationRequested(ReconciliationIntent(
                    id: nil,
                    scope: .applications(self.activeRescanPIDs),
                    adoptFocused: true,
                    source: .activeRescan,
                    reason: "timer"
                ))))
            }
        } else if pids.isEmpty {
            activeRescanTimer?.invalidate()
            activeRescanTimer = nil
        }
    }

    func configureLaunchSettlingTimer(enabled: Bool, interval: TimeInterval) {
        if enabled, launchSettlingTimer == nil {
            launchSettlingTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                guard let self else { return }
                let now = CFAbsoluteTimeGetCurrent()
                let expiredPIDs = self.launchSettlingDeadlines.compactMap { pid, deadline in
                    deadline <= now ? pid : nil
                }
                for pid in expiredPIDs {
                    self.launchMissingWindowSince.removeValue(forKey: pid)
                }
                self.launchSettlingDeadlines = self.launchSettlingDeadlines.filter { $0.value > now }
                let pids = Set(self.launchSettlingDeadlines.keys)
                guard !pids.isEmpty else {
                    self.configureLaunchSettlingTimer(enabled: false, interval: interval)
                    return
                }
                self.emit(.windows(.reconciliationRequested(ReconciliationIntent(
                    id: nil,
                    scope: .applications(pids),
                    adoptFocused: true,
                    source: .launchSettling,
                    reason: "timer"
                ))))
            }
        } else if !enabled {
            launchSettlingTimer?.invalidate()
            launchSettlingTimer = nil
        }
    }

    func cachedTransientState(now: CFAbsoluteTime, forceRefresh: Bool) -> Bool? {
        guard !forceRefresh, now - transientWindowStateCheckedAt < 0.25 else { return nil }
        return transientWindowActive
    }

    @discardableResult
    func recordTransientState(_ active: Bool, checkedAt: CFAbsoluteTime) -> Bool {
        let changed = transientWindowActive != active
        transientWindowStateCheckedAt = checkedAt
        transientWindowActive = active
        return changed
    }

    func stop() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObserverTokens.forEach(center.removeObserver)
        workspaceObserverTokens.removeAll()
        axObservers.removeAll()
        periodicTimer?.invalidate()
        activeRescanTimer?.invalidate()
        launchSettlingTimer?.invalidate()
        periodicTimer = nil
        activeRescanTimer = nil
        launchSettlingTimer = nil
        activeRescanPIDs.removeAll()
        pendingCreationSettleGenerations.removeAll()
    }
}

private func windowObservationAXCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let monitor = Unmanaged<WindowObservationController>.fromOpaque(refcon).takeUnretainedValue()
    monitor.emitAXNotification(name: notification as String, element: element)
}

private extension WindowObservationController {
    func emitAXNotification(name: String, element: AXUIElement) {
        emit(.windows(.accessibilityNotification(name: name, element: element)))
    }
}
