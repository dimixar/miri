import AppKit
import ApplicationServices
import Darwin
import Foundation

/// Owns the operating-system observation handles and delayed discovery work.
/// It reports facts and reconciliation intents; it never mutates the logical
/// workspace graph or starts layout.
@MainActor
final class WindowObservationController: NSObject {
    typealias EventSink = (AppEvent) -> Void

    private let emit: EventSink
    private let axOperations: AXOperationController
    private var workspaceObserverTokens: [NSObjectProtocol] = []
    private var axObservers: [pid_t: AXObserver] = [:]
    private var pendingAXObserverPIDs = Set<pid_t>()
    private var observerRegistrationGenerations: [pid_t: UInt64] = [:]
    private var nextObserverRegistrationGeneration: UInt64 = 0
    private var stateGenerations: [pid_t: UInt64] = [:]
    private var nextStateGeneration: UInt64 = 0
    private(set) var globalStateGeneration: UInt64 = 0
    private var stopped = false
    private var periodicTimer: Timer?
    private var activeRescanTimer: Timer?
    private var activeRescanPIDs = Set<pid_t>()
    private var launchSettlingTimer: Timer?

    private var focusedWindowProbeGeneration: UInt64 = 0
    private(set) var launchSettlingDeadlines: [pid_t: CFAbsoluteTime] = [:]
    private var launchObservedPIDs = Set<pid_t>()
    private var launchMissingWindowSince: [pid_t: [ObjectIdentifier: CFAbsoluteTime]] = [:]
    private var pendingCreationSettleGenerations: [pid_t: UInt64] = [:]
    private var creationSettleGeneration: UInt64 = 0
    private var lastPlaceholderProbeAt: [pid_t: CFAbsoluteTime] = [:]
    private(set) var transientWindowActive = false
    private var transientWindowStateCheckedAt: CFAbsoluteTime = 0

    init(axOperations: AXOperationController, emit: @escaping EventSink) {
        self.axOperations = axOperations
        self.emit = emit
    }

    deinit {
        MainActor.assumeIsolated { stop() }
    }

    func startWorkspaceObservation() {
        guard workspaceObserverTokens.isEmpty else { return }
        stopped = false
        let center = NSWorkspace.shared.notificationCenter
        workspaceObserverTokens = [
            center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                MainActor.assumeIsolated { self?.emit(.workspace(.applicationActivated(app))) }
            },
            center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                MainActor.assumeIsolated { self?.emit(.workspace(.applicationLaunched(app))) }
            },
            center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
                MainActor.assumeIsolated { self?.emit(.workspace(.applicationTerminated(app))) }
            },
            center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.emit(.workspace(.activeSpaceChanged)) }
            },
        ]
    }

    func observeApplication(pid: pid_t, log: @escaping (String) -> Void) {
        guard !stopped,
              axObservers[pid] == nil,
              pendingAXObserverPIDs.insert(pid).inserted
        else { return }
        nextObserverRegistrationGeneration &+= 1
        let registrationGeneration = nextObserverRegistrationGeneration
        observerRegistrationGenerations[pid] = registrationGeneration
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
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        axOperations.registerObserver(
            pid: pid,
            notifications: notifications,
            callback: windowObservationAXCallback,
            refcon: refcon
        ) { [weak self] result in
            guard let self,
                  !self.stopped,
                  self.observerRegistrationGenerations[pid] == registrationGeneration,
                  NSRunningApplication(processIdentifier: pid) != nil
            else { return }
            self.pendingAXObserverPIDs.remove(pid)
            guard result.disposition == .completed, let registration = result.value else {
                log("ax observer registration unavailable pid=\(pid) error=\(result.error.rawValue)")
                return
            }
            for failure in registration.notificationErrors {
                log("ax observer registration failed pid=\(pid) notification=\(failure.name) error=\(failure.error.rawValue)")
            }
            CFRunLoopAddSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(registration.observer),
                .commonModes
            )
            self.axObservers[pid] = registration.observer
        }
    }

    func removeApplication(pid: pid_t) {
        noteWindowStateChange(pid: pid)
        nextObserverRegistrationGeneration &+= 1
        observerRegistrationGenerations[pid] = nextObserverRegistrationGeneration
        axObservers.removeValue(forKey: pid)
        pendingAXObserverPIDs.remove(pid)
        axOperations.remove(pid: pid)
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

    func noteWindowStateChange(pid: pid_t) {
        nextStateGeneration &+= 1
        stateGenerations[pid] = nextStateGeneration
        globalStateGeneration &+= 1
    }

    func stateGeneration(for pid: pid_t) -> UInt64 {
        stateGenerations[pid] ?? 0
    }

    func noteGlobalStateChange() {
        globalStateGeneration &+= 1
    }

    func completeAXQuiescenceForSessionTransition() {
        let pendingPIDs = pendingAXObserverPIDs
        pendingAXObserverPIDs.removeAll()
        for pid in pendingPIDs {
            nextObserverRegistrationGeneration &+= 1
            observerRegistrationGenerations[pid] = nextObserverRegistrationGeneration
        }
    }

    func invalidateAsyncStateForSessionTransition() {
        nextStateGeneration &+= 1
        let generation = nextStateGeneration
        let pids = Set(stateGenerations.keys)
            .union(axObservers.keys)
            .union(pendingAXObserverPIDs)
        for pid in pids { stateGenerations[pid] = generation }
        globalStateGeneration &+= 1
        focusedWindowProbeGeneration &+= 1
        pendingCreationSettleGenerations.removeAll()
    }

    func configurePeriodicTimer(enabled: Bool, interval: TimeInterval) {
        periodicTimer?.invalidate()
        periodicTimer = nil
        guard enabled else { return }
        periodicTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.emit(.windows(.reconciliationRequested(.all(
                    adoptFocused: false,
                    source: .periodicTimer,
                    reason: "periodic-timer"
                ))))
            }
        }
    }

    func configureActiveRescanTimer(pids: Set<pid_t>, interval: TimeInterval = 1) {
        activeRescanPIDs = pids
        if !pids.isEmpty, activeRescanTimer == nil {
            activeRescanTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !self.activeRescanPIDs.isEmpty else { return }
                    self.emit(.windows(.reconciliationRequested(ReconciliationIntent(
                        id: nil,
                        scope: .applications(self.activeRescanPIDs),
                        adoptFocused: false,
                        source: .activeRescan,
                        reason: "timer"
                    ))))
                }
            }
        } else if pids.isEmpty {
            activeRescanTimer?.invalidate()
            activeRescanTimer = nil
        }
    }

    func configureLaunchSettlingTimer(enabled: Bool, interval: TimeInterval) {
        if enabled, launchSettlingTimer == nil {
            launchSettlingTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
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
        stopped = true
        let center = NSWorkspace.shared.notificationCenter
        workspaceObserverTokens.forEach(center.removeObserver)
        workspaceObserverTokens.removeAll()
        let observedPIDs = Set(axObservers.keys).union(pendingAXObserverPIDs)
        axObservers.removeAll()
        pendingAXObserverPIDs.removeAll()
        observerRegistrationGenerations.removeAll()
        for pid in observedPIDs { axOperations.remove(pid: pid) }
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

func windowObservationAXCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let monitor = Unmanaged<WindowObservationController>.fromOpaque(refcon).takeUnretainedValue()
    let name = notification as String
    let payload = MainRunLoopCallbackValue(value: element)
    MainActor.assumeIsolated {
        monitor.emitAXNotification(name: name, element: payload.value)
    }
}

private extension WindowObservationController {
    func emitAXNotification(name: String, element: AXUIElement) {
        emit(.windows(.accessibilityNotification(name: name, element: element)))
    }
}
