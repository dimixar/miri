import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

struct AXElementHandle: @unchecked Sendable {
    let element: AXUIElement
    let pid: pid_t
    let windowID: UInt32?

    var operationKey: String {
        if let windowID { return "window:\(windowID)" }
        return "element:\(CFHash(element))"
    }
}

struct AXWindowReadSnapshot: @unchecked Sendable {
    let handle: AXElementHandle
    let role: String?
    let subrole: String?
    let title: String
    let minimized: Bool?
    let fullscreen: Bool?
    let frame: CGRect?
    let positionSettable: Bool
    let sizeSettable: Bool
}

struct AXApplicationReadSnapshot: @unchecked Sendable {
    let pid: pid_t
    let windows: [AXWindowReadSnapshot]
    let supplementalWindows: [AXWindowReadSnapshot]
    let containsApplicationRoot: Bool
    let enumerationComplete: Bool
}

struct AXObserverRegistration: @unchecked Sendable {
    let observer: AXObserver
    let notificationErrors: [(name: String, error: AXError)]
}

private struct AXElementList: @unchecked Sendable {
    let elements: [AXUIElement]
}

private struct AXApplicationReadChunk: @unchecked Sendable {
    let snapshots: [AXWindowReadSnapshot]
    let containsApplicationRoot: Bool
}

private struct AXApplicationReadCursorKey: Hashable {
    let pid: pid_t
    let operationKey: String
}

@MainActor
private final class AXApplicationReadPipeline {
    let pid: pid_t
    let key: String
    let deadline: CFAbsoluteTime
    let startedAt: CFAbsoluteTime
    let supplementalHandles: [AXElementHandle]
    var completions: [(AXOperationResult<AXApplicationReadSnapshot>) -> Void]
    var elements: [AXUIElement] = []
    var nextElementIndex = 0
    var completedElementCount = 0
    var startElementOffset = 0
    var snapshots: [AXWindowReadSnapshot] = []
    var containsApplicationRoot = false
    var supplementalQueue: [AXElementHandle] = []
    var supplementalSnapshots: [AXWindowReadSnapshot] = []
    var supplementalPrepared = false
    var supplementalCompleted = false
    var finished = false

    init(
        pid: pid_t,
        key: String,
        supplementalHandles: [AXElementHandle],
        completion: @escaping (AXOperationResult<AXApplicationReadSnapshot>) -> Void
    ) {
        self.pid = pid
        self.key = key
        self.supplementalHandles = supplementalHandles
        completions = [completion]
        startedAt = CFAbsoluteTimeGetCurrent()
        deadline = startedAt + miriAXApplicationReadBudget
    }

    func addCompletion(
        _ completion: @escaping (AXOperationResult<AXApplicationReadSnapshot>) -> Void
    ) {
        guard !finished else { return }
        completions.append(completion)
    }

    func finish(_ result: AXOperationResult<AXApplicationReadSnapshot>) {
        guard !finished else { return }
        finished = true
        let callbacks = completions
        completions.removeAll()
        for callback in callbacks { callback(result) }
    }
}

private struct AXObserverCallbackHandle: @unchecked Sendable {
    let callback: AXObserverCallback
}

private let miriAXWindowReadBudget: TimeInterval = 0.75
private let miriAXApplicationReadBudget: TimeInterval = 2.0
private let miriAXObserverRegistrationBudget: TimeInterval = 0.75

enum AXOperationPriority: Int, Sendable {
    case background
    case normal
    case interactive
}

enum AXOperationDisposition: Sendable, Equatable {
    case completed
    case failed
    case circuitOpen
    case superseded
}

struct AXOperationResult<Value: Sendable>: Sendable {
    let value: Value?
    let error: AXError
    let disposition: AXOperationDisposition
    let queueWait: TimeInterval
    let elapsed: TimeInterval
    let budgetExhausted: Bool
    let retryAfter: TimeInterval?
}

struct AXTerminationRestoreRequest: @unchecked Sendable {
    let handle: AXElementHandle
    let frame: CGRect
}

struct AXTerminationRestoreSummary: Sendable {
    let requestedPIDs: Set<pid_t>
    let restoredPIDs: Set<pid_t>
    let failedPIDs: Set<pid_t>
    let timedOut: Bool

    var succeeded: Bool {
        !timedOut && failedPIDs.isEmpty && restoredPIDs == requestedPIDs
    }
}

struct AXCallback<Value: Sendable>: @unchecked Sendable {
    let body: @MainActor (AXOperationResult<Value>) -> Void

    func call(_ result: AXOperationResult<Value>) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                body(result)
            }
        }
    }
}

struct AXJob: @unchecked Sendable {
    let key: String
    let generation: UInt64
    let priority: AXOperationPriority
    let run: @Sendable () -> Void
    let cancel: @Sendable () -> Void
}

final class AXProcessLane: @unchecked Sendable {
    let pid: pid_t
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var interactiveJobs: [AXJob] = []
    private var normalJobs: [AXJob] = []
    private var backgroundJobs: [AXJob] = []
    private var latestGenerations: [String: UInt64] = [:]
    private var draining = false
    private var consecutiveTimeouts = 0
    private var circuitOpenUntil: CFAbsoluteTime = 0

    init(pid: pid_t) {
        self.pid = pid
        queue = DispatchQueue(label: "miri.ax.pid.\(pid)", qos: .userInitiated)
    }

    func enqueue(_ job: AXJob) {
        lock.lock()
        latestGenerations[job.key] = job.generation
        let supersededJobs = removeQueuedJobs(matching: job.key)
        switch job.priority {
        case .interactive: interactiveJobs.append(job)
        case .normal: normalJobs.append(job)
        case .background: backgroundJobs.append(job)
        }
        let shouldStart = !draining
        if shouldStart { draining = true }
        lock.unlock()

        // Complete removed jobs outside the lane lock. Their callbacks are
        // delivered on the main actor and must remain exactly-once.
        for superseded in supersededJobs { superseded.cancel() }
        if shouldStart {
            queue.async { [weak self] in self?.drain() }
        }
    }

    func isCircuitOpen(now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) -> Bool {
        lock.withLock { circuitOpenUntil > now }
    }

    func removeAll(resetHealth: Bool = false) {
        let cancelledJobs = lock.withLock { () -> [AXJob] in
            let jobs = interactiveJobs + normalJobs + backgroundJobs
            interactiveJobs.removeAll()
            normalJobs.removeAll()
            backgroundJobs.removeAll()
            latestGenerations.removeAll()
            if resetHealth {
                consecutiveTimeouts = 0
                circuitOpenUntil = 0
            }
            return jobs
        }
        for job in cancelledJobs { job.cancel() }
    }

    func resetHealth() {
        lock.withLock {
            consecutiveTimeouts = 0
            circuitOpenUntil = 0
        }
    }

    func notifyWhenQuiescent(_ completion: @escaping @Sendable () -> Void) {
        queue.async(execute: completion)
    }

    func shouldExecute(key: String, generation: UInt64) -> Bool {
        lock.withLock { latestGenerations[key] == generation }
    }

    func circuitDelay(now: CFAbsoluteTime) -> TimeInterval? {
        lock.withLock {
            guard circuitOpenUntil > now else { return nil }
            return circuitOpenUntil - now
        }
    }

    func record(error: AXError, now: CFAbsoluteTime) -> TimeInterval? {
        lock.withLock {
            if error == .cannotComplete {
                consecutiveTimeouts += 1
                let delay = min(pow(2.0, Double(max(0, consecutiveTimeouts - 1))), 8.0)
                circuitOpenUntil = max(circuitOpenUntil, now + delay)
                return delay
            }
            if error == .success {
                consecutiveTimeouts = 0
                circuitOpenUntil = 0
            }
            return nil
        }
    }

    private func drain() {
        while let job = nextJob() {
            job.run()
        }
        lock.lock()
        draining = false
        let shouldRestart = !(interactiveJobs.isEmpty && normalJobs.isEmpty && backgroundJobs.isEmpty)
        if shouldRestart { draining = true }
        lock.unlock()
        if shouldRestart {
            queue.async { [weak self] in self?.drain() }
        }
    }

    private func nextJob() -> AXJob? {
        lock.withLock {
            if !interactiveJobs.isEmpty { return interactiveJobs.removeFirst() }
            if !normalJobs.isEmpty { return normalJobs.removeFirst() }
            if !backgroundJobs.isEmpty { return backgroundJobs.removeFirst() }
            return nil
        }
    }

    /// Called only while `lock` is held.
    private func removeQueuedJobs(matching key: String) -> [AXJob] {
        var removed: [AXJob] = []
        removed.append(contentsOf: interactiveJobs.extractAll { $0.key == key })
        removed.append(contentsOf: normalJobs.extractAll { $0.key == key })
        removed.append(contentsOf: backgroundJobs.extractAll { $0.key == key })
        return removed
    }
}

final class AXOperationExecutor: @unchecked Sendable {
    private let lock = NSLock()
    private var lanes: [pid_t: AXProcessLane] = [:]

    func isCircuitOpen(pid: pid_t) -> Bool {
        lane(for: pid).isCircuitOpen()
    }

    func remove(pid: pid_t) {
        let lane = lock.withLock { lanes.removeValue(forKey: pid) }
        lane?.removeAll()
    }

    func quiesceAllAndResetHealth(completion: @escaping @Sendable () -> Void) {
        let activeLanes = lock.withLock { Array(lanes.values) }
        guard !activeLanes.isEmpty else {
            completion()
            return
        }
        let group = DispatchGroup()
        for lane in activeLanes {
            // A running operation can still report `.cannotComplete` after the
            // queue is cleared. Reset health only after that operation and its
            // lane drain have finished, otherwise it can reopen the circuit
            // immediately before recovery or final restoration.
            lane.removeAll()
            group.enter()
            lane.notifyWhenQuiescent { group.leave() }
        }
        group.notify(queue: .global(qos: .userInitiated)) {
            for lane in activeLanes { lane.resetHealth() }
            completion()
        }
    }

    func resetHealth(pid: pid_t) {
        lane(for: pid).resetHealth()
    }

    func resetAllHealth() {
        let activeLanes = lock.withLock { Array(lanes.values) }
        for lane in activeLanes { lane.resetHealth() }
    }

    func submit<Value: Sendable>(
        pid: pid_t,
        key: String,
        generation: UInt64,
        priority: AXOperationPriority,
        operationBudget: TimeInterval? = nil,
        recordsSuccess: Bool = true,
        operation: @escaping @Sendable () -> (Value?, AXError),
        completion: AXCallback<Value>
    ) {
        let lane = lane(for: pid)
        let submittedAt = CFAbsoluteTimeGetCurrent()
        let cancelledResult = AXOperationResult<Value>(
            value: nil,
            error: .success,
            disposition: .superseded,
            queueWait: 0,
            elapsed: 0,
            budgetExhausted: false,
            retryAfter: nil
        )
        let job = AXJob(key: key, generation: generation, priority: priority) { [weak lane] in
            guard let lane else {
                completion.call(cancelledResult)
                return
            }
            guard lane.shouldExecute(key: key, generation: generation) else {
                completion.call(AXOperationResult(
                    value: nil,
                    error: .success,
                    disposition: .superseded,
                    queueWait: CFAbsoluteTimeGetCurrent() - submittedAt,
                    elapsed: 0,
                    budgetExhausted: false,
                    retryAfter: nil
                ))
                return
            }
            let now = CFAbsoluteTimeGetCurrent()
            if let retryAfter = lane.circuitDelay(now: now) {
                completion.call(AXOperationResult(
                    value: nil,
                    error: .cannotComplete,
                    disposition: .circuitOpen,
                    queueWait: now - submittedAt,
                    elapsed: 0,
                    budgetExhausted: false,
                    retryAfter: retryAfter
                ))
                return
            }

            let startedAt = CFAbsoluteTimeGetCurrent()
            let (value, error) = operation()
            let elapsed = CFAbsoluteTimeGetCurrent() - startedAt
            let retryAfter = error == .success && !recordsSuccess
                ? nil
                : lane.record(error: error, now: CFAbsoluteTimeGetCurrent())
            let stillLatest = lane.shouldExecute(key: key, generation: generation)
            completion.call(AXOperationResult(
                value: stillLatest ? value : nil,
                error: error,
                disposition: stillLatest
                    ? (error == .success ? .completed : .failed)
                    : .superseded,
                queueWait: startedAt - submittedAt,
                elapsed: elapsed,
                budgetExhausted: operationBudget.map { elapsed >= $0 * 0.9 && error == .cannotComplete } ?? false,
                retryAfter: retryAfter
            ))
        } cancel: {
            completion.call(cancelledResult)
        }
        lane.enqueue(job)
    }

    private func lane(for pid: pid_t) -> AXProcessLane {
        lock.withLock {
            if let lane = lanes[pid] { return lane }
            let lane = AXProcessLane(pid: pid)
            lanes[pid] = lane
            return lane
        }
    }
}

@MainActor
final class AXTerminationRestoreSession {
    let requestedPIDs: Set<pid_t>
    let completion: (AXTerminationRestoreSummary) -> Void
    var pendingPIDs: Set<pid_t>
    var restoredPIDs = Set<pid_t>()
    var failedPIDs = Set<pid_t>()
    var finished = false

    init(requestedPIDs: Set<pid_t>, completion: @escaping (AXTerminationRestoreSummary) -> Void) {
        self.requestedPIDs = requestedPIDs
        self.pendingPIDs = requestedPIDs
        self.completion = completion
    }

    func record(pid: pid_t, succeeded: Bool) {
        guard !finished, pendingPIDs.remove(pid) != nil else { return }
        if succeeded {
            restoredPIDs.insert(pid)
        } else {
            failedPIDs.insert(pid)
        }
    }

    func finish(timedOut: Bool) {
        guard !finished else { return }
        finished = true
        if timedOut { failedPIDs.formUnion(pendingPIDs) }
        completion(AXTerminationRestoreSummary(
            requestedPIDs: requestedPIDs,
            restoredPIDs: restoredPIDs,
            failedPIDs: failedPIDs,
            timedOut: timedOut
        ))
    }
}

@MainActor
final class AXOperationController {
    typealias Logger = (String) -> Void

    private let executor = AXOperationExecutor()
    private let log: Logger
    private var nextGeneration: UInt64 = 0
    private var terminationAdmissionClosed = false
    private var terminationRestoreSession: AXTerminationRestoreSession?
    private var applicationReadOffsets: [AXApplicationReadCursorKey: Int] = [:]
    private var activeApplicationReads: [AXApplicationReadCursorKey: AXApplicationReadPipeline] = [:]

    init(log: @escaping Logger) {
        self.log = log
    }

    func isCircuitOpen(pid: pid_t) -> Bool {
        executor.isCircuitOpen(pid: pid)
    }

    func remove(pid: pid_t) {
        applicationReadOffsets = applicationReadOffsets.filter { $0.key.pid != pid }
        let reads = activeApplicationReads.values.filter { $0.pid == pid }
        for read in reads where !read.finished {
            finishApplicationPipeline(read, result: AXOperationResult(
                value: nil,
                error: .success,
                disposition: .superseded,
                queueWait: 0,
                elapsed: CFAbsoluteTimeGetCurrent() - read.startedAt,
                budgetExhausted: false,
                retryAfter: nil
            ))
        }
        executor.remove(pid: pid)
    }

    func quiesceForUnavailableSession(completion: @escaping @MainActor () -> Void) {
        cancelActiveApplicationReads()
        executor.quiesceAllAndResetHealth {
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion() }
            }
        }
    }

    func resetHealthForSessionRecovery() {
        guard !terminationAdmissionClosed else { return }
        executor.resetAllHealth()
    }

    /// Permanently closes normal AX admission, drains already-running work,
    /// then performs one independent final frame-restoration batch per PID.
    /// The global deadline also bounds a lane that fails to return despite the
    /// process-wide AX messaging timeout.
    func restoreFramesForTermination(
        _ requests: [AXTerminationRestoreRequest],
        timeout: TimeInterval = 3.0,
        completion: @escaping @MainActor (AXTerminationRestoreSummary) -> Void
    ) {
        guard terminationRestoreSession == nil else {
            let session = terminationRestoreSession!
            completion(AXTerminationRestoreSummary(
                requestedPIDs: session.requestedPIDs,
                restoredPIDs: session.restoredPIDs,
                failedPIDs: session.failedPIDs.union(session.pendingPIDs),
                timedOut: true
            ))
            return
        }

        terminationAdmissionClosed = true
        cancelActiveApplicationReads()
        let grouped = Dictionary(grouping: requests, by: { $0.handle.pid })
        let requestedPIDs = Set(grouped.keys)
        let session = AXTerminationRestoreSession(
            requestedPIDs: requestedPIDs,
            completion: completion
        )
        terminationRestoreSession = session
        let deadline = CFAbsoluteTimeGetCurrent() + max(0.25, timeout)

        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.25, timeout)) { [weak self, weak session] in
            guard let self, let session, self.terminationRestoreSession === session else { return }
            self.log("ax termination restoration deadline exceeded pending=\(session.pendingPIDs.sorted())")
            session.finish(timedOut: true)
            self.terminationRestoreSession = nil
        }

        executor.quiesceAllAndResetHealth { [weak self, weak session] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let session, self.terminationRestoreSession === session else { return }
                    guard !grouped.isEmpty else {
                        session.finish(timedOut: false)
                        self.terminationRestoreSession = nil
                        return
                    }
                    for (pid, pidRequests) in grouped {
                        self.submitTerminationRestoreBatch(
                            pid: pid,
                            requests: pidRequests,
                            deadline: deadline,
                            session: session
                        )
                    }
                }
            }
        }
    }

    func setFrame(
        _ frame: CGRect,
        handle: AXElementHandle,
        disableEnhancedUserInterface: Bool,
        priority: AXOperationPriority = .interactive,
        completion: @escaping @MainActor (AXOperationResult<CGRect>) -> Void
    ) {
        submit(
            pid: handle.pid,
            key: "set-frame:\(handle.operationKey)",
            priority: priority,
            operationName: "set-frame",
            callCountEstimate: disableEnhancedUserInterface ? 6 : 3,
            operation: {
                let error: AXError
                if disableEnhancedUserInterface {
                    error = withDisabledEnhancedUserInterface(for: handle.pid) {
                        setAXFrame(frame, for: handle.element)
                    }
                } else {
                    error = setAXFrame(frame, for: handle.element)
                }
                return (error == .success ? frame : nil, error)
            },
            completion: completion
        )
    }

    func recoverTransientWindow(
        handle: AXElementHandle,
        centeredOrigin: CGPoint?,
        completion: @escaping @MainActor (AXOperationResult<Bool>) -> Void = { _ in }
    ) {
        submit(
            pid: handle.pid,
            key: "transient-recovery:\(handle.operationKey)",
            priority: .normal,
            operationName: "transient-recovery",
            callCountEstimate: centeredOrigin == nil ? 1 : 2,
            operation: {
                if let centeredOrigin {
                    let positionError = setAXPosition(centeredOrigin, for: handle.element)
                    guard positionError != .cannotComplete else { return (nil, positionError) }
                }
                let raiseError = AXUIElementPerformAction(handle.element, kAXRaiseAction as CFString)
                return (raiseError == .success, raiseError)
            },
            completion: completion
        )
    }

    func focus(
        handle: AXElementHandle,
        completion: @escaping @MainActor (AXOperationResult<Bool>) -> Void = { _ in }
    ) {
        submit(
            pid: handle.pid,
            key: "focus",
            priority: .interactive,
            operationName: "focus",
            callCountEstimate: 2,
            operation: {
                let raiseError = AXUIElementPerformAction(handle.element, kAXRaiseAction as CFString)
                guard raiseError != .cannotComplete else { return (nil, raiseError) }
                let focusError = AXUIElementSetAttributeValue(
                    handle.element,
                    kAXFocusedAttribute as CFString,
                    kCFBooleanTrue
                )
                return (focusError == .success, focusError)
            },
            completion: completion
        )
    }

    func registerObserver(
        pid: pid_t,
        notifications: [String],
        callback: @escaping AXObserverCallback,
        refcon: UnsafeMutableRawPointer,
        completion: @escaping @MainActor (AXOperationResult<AXObserverRegistration>) -> Void
    ) {
        let callbackHandle = AXObserverCallbackHandle(callback: callback)
        let refconBits = UInt(bitPattern: refcon)
        submit(
            pid: pid,
            key: "observer-registration",
            priority: .background,
            operationName: "observer-registration",
            operationBudget: miriAXObserverRegistrationBudget,
            callCountEstimate: notifications.count + 1,
            operation: {
                let deadline = CFAbsoluteTimeGetCurrent() + miriAXObserverRegistrationBudget
                var observer: AXObserver?
                let createError = AXObserverCreate(pid, callbackHandle.callback, &observer)
                guard createError == .success, let observer else { return (nil, createError) }
                let appElement = AXUIElementCreateApplication(pid)
                let restoredRefcon = UnsafeMutableRawPointer(bitPattern: refconBits)
                var errors: [(name: String, error: AXError)] = []
                for notification in notifications {
                    guard CFAbsoluteTimeGetCurrent() < deadline else {
                        return (nil, .cannotComplete)
                    }
                    let error = AXObserverAddNotification(
                        observer,
                        appElement,
                        notification as CFString,
                        restoredRefcon
                    )
                    if error == .cannotComplete { return (nil, error) }
                    if error != .success, error != .notificationAlreadyRegistered {
                        errors.append((notification, error))
                    }
                }
                guard CFAbsoluteTimeGetCurrent() < deadline else {
                    return (nil, .cannotComplete)
                }
                return (AXObserverRegistration(observer: observer, notificationErrors: errors), .success)
            },
            completion: completion
        )
    }

    func readWindow(
        handle: AXElementHandle,
        priority: AXOperationPriority = .normal,
        completion: @escaping @MainActor (AXOperationResult<AXWindowReadSnapshot>) -> Void
    ) {
        submit(
            pid: handle.pid,
            key: "read-window:\(handle.operationKey)",
            priority: priority,
            operationName: "read-window",
            operationBudget: miriAXWindowReadBudget,
            callCountEstimate: 9,
            operation: {
                readWindowSnapshot(
                    element: handle.element,
                    pid: handle.pid,
                    knownWindowID: handle.windowID,
                    resolveWindowID: false,
                    deadline: CFAbsoluteTimeGetCurrent() + miriAXWindowReadBudget
                )
            },
            completion: completion
        )
    }

    func readFocusedWindow(
        pid: pid_t,
        priority: AXOperationPriority = .interactive,
        coalescingKey: String = "focused-window",
        completion: @escaping @MainActor (AXOperationResult<AXWindowReadSnapshot>) -> Void
    ) {
        submit(
            pid: pid,
            key: coalescingKey,
            priority: priority,
            operationName: "focused-window",
            operationBudget: miriAXWindowReadBudget,
            callCountEstimate: 10,
            operation: {
                let deadline = CFAbsoluteTimeGetCurrent() + miriAXWindowReadBudget
                let app = AXUIElementCreateApplication(pid)
                var value: CFTypeRef?
                let error = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value)
                guard error == .success, let element = value as! AXUIElement? else {
                    return (nil, error)
                }
                return readWindowSnapshot(
                    element: element,
                    pid: pid,
                    knownWindowID: nil,
                    resolveWindowID: false,
                    deadline: deadline
                )
            },
            completion: completion
        )
    }

    func readApplication(
        pid: pid_t,
        priority: AXOperationPriority,
        supplementalHandles: [AXElementHandle] = [],
        coalescingKey: String = "application-windows",
        joinExisting: Bool = false,
        completion: @escaping @MainActor (AXOperationResult<AXApplicationReadSnapshot>) -> Void
    ) {
        let cursorKey = AXApplicationReadCursorKey(pid: pid, operationKey: coalescingKey)
        if coalescingKey.hasPrefix("targeted-reconciliation:") {
            applicationReadOffsets = applicationReadOffsets.filter {
                $0.key.pid != pid || $0.key == cursorKey
            }
        }
        if let active = activeApplicationReads[cursorKey], !active.finished {
            if joinExisting {
                active.addCompletion(completion)
                return
            }
            // Finish the old owner on the main actor before the replacement is
            // submitted. Otherwise a previously delivered chunk callback can
            // enqueue more old work after the newer generation and supersede it.
            finishApplicationPipeline(active, result: AXOperationResult(
                value: nil,
                error: .success,
                disposition: .superseded,
                queueWait: 0,
                elapsed: CFAbsoluteTimeGetCurrent() - active.startedAt,
                budgetExhausted: false,
                retryAfter: nil
            ))
        }
        let pipeline = AXApplicationReadPipeline(
            pid: pid,
            key: coalescingKey,
            supplementalHandles: supplementalHandles,
            completion: completion
        )
        activeApplicationReads[cursorKey] = pipeline
        let deadline = pipeline.deadline
        submit(
            pid: pid,
            key: coalescingKey,
            priority: priority,
            operationName: "application-windows",
            operationBudget: miriAXApplicationReadBudget,
            recordsSuccess: false,
            callCountEstimate: 1,
            operation: { () -> (AXElementList?, AXError) in
                guard CFAbsoluteTimeGetCurrent() < deadline else {
                    return (nil, .cannotComplete)
                }
                let app = AXUIElementCreateApplication(pid)
                var value: CFTypeRef?
                let error = AXUIElementCopyAttributeValue(
                    app,
                    kAXWindowsAttribute as CFString,
                    &value
                )
                guard error == .success, let elements = value as? [AXUIElement] else {
                    return (nil, error)
                }
                return (AXElementList(elements: elements), .success)
            }
        ) { [weak self, pipeline] result in
            guard let self, !pipeline.finished else { return }
            guard result.disposition == .completed, let list = result.value else {
                self.finishApplicationPipelineFailure(pipeline, from: result)
                return
            }
            if list.elements.isEmpty {
                pipeline.elements = []
            } else {
                let offset = self.applicationReadOffsets[cursorKey, default: 0]
                    % list.elements.count
                pipeline.startElementOffset = offset
                pipeline.elements = Array(list.elements[offset...])
                    + Array(list.elements[..<offset])
            }
            self.continueApplicationPipeline(pipeline, priority: priority)
        }
    }

    private func continueApplicationPipeline(
        _ pipeline: AXApplicationReadPipeline,
        priority: AXOperationPriority
    ) {
        guard !pipeline.finished else { return }
        guard CFAbsoluteTimeGetCurrent() < pipeline.deadline else {
            finishApplicationPipelineBudgetExceeded(pipeline)
            return
        }

        if pipeline.nextElementIndex < pipeline.elements.count {
            // One window per lane turn preserves partial progress and gives
            // interactive work a scheduling point between expensive snapshots.
            let end = min(pipeline.nextElementIndex + 1, pipeline.elements.count)
            let chunk = AXElementList(
                elements: Array(pipeline.elements[pipeline.nextElementIndex..<end])
            )
            pipeline.nextElementIndex = end
            let pid = pipeline.pid
            let deadline = min(
                pipeline.deadline,
                CFAbsoluteTimeGetCurrent() + miriAXWindowReadBudget
            )
            submit(
                pid: pipeline.pid,
                key: pipeline.key,
                priority: priority,
                operationName: "application-window-chunk",
                operationBudget: miriAXWindowReadBudget,
                recordsSuccess: false,
                callCountEstimate: chunk.elements.count * 10,
                operation: { () -> (AXApplicationReadChunk?, AXError) in
                    var snapshots: [AXWindowReadSnapshot] = []
                    var containsApplicationRoot = false
                    for element in chunk.elements {
                        let (snapshot, error) = readWindowSnapshot(
                            element: element,
                            pid: pid,
                            knownWindowID: nil,
                            resolveWindowID: true,
                            deadline: deadline
                        )
                        guard error == .success, let snapshot else { return (nil, error) }
                        containsApplicationRoot = containsApplicationRoot
                            || snapshot.role == kAXApplicationRole
                        snapshots.append(snapshot)
                    }
                    return (AXApplicationReadChunk(
                        snapshots: snapshots,
                        containsApplicationRoot: containsApplicationRoot
                    ), .success)
                }
            ) { [weak self, pipeline] result in
                guard let self, !pipeline.finished else { return }
                guard result.disposition == .completed, let chunk = result.value else {
                    self.finishApplicationPipelineFailure(pipeline, from: result)
                    return
                }
                pipeline.snapshots.append(contentsOf: chunk.snapshots)
                pipeline.completedElementCount += chunk.snapshots.count
                pipeline.containsApplicationRoot = pipeline.containsApplicationRoot
                    || chunk.containsApplicationRoot
                self.continueApplicationPipeline(pipeline, priority: priority)
            }
            return
        }

        if !pipeline.supplementalPrepared {
            pipeline.supplementalPrepared = true
            let enumeratedIDs = Set(pipeline.snapshots.compactMap { $0.handle.windowID })
            pipeline.supplementalQueue = pipeline.supplementalHandles.filter { handle in
                if let windowID = handle.windowID, enumeratedIDs.contains(windowID) {
                    return false
                }
                return !pipeline.snapshots.contains {
                    CFEqual($0.handle.element, handle.element)
                }
            }
        }

        guard !pipeline.supplementalQueue.isEmpty else {
            pipeline.supplementalCompleted = true
            executor.resetHealth(pid: pipeline.pid)
            applicationReadOffsets.removeValue(forKey: AXApplicationReadCursorKey(
                pid: pipeline.pid,
                operationKey: pipeline.key
            ))
            finishApplicationPipeline(pipeline, result: AXOperationResult(
                value: AXApplicationReadSnapshot(
                    pid: pipeline.pid,
                    windows: pipeline.snapshots,
                    supplementalWindows: pipeline.supplementalSnapshots,
                    containsApplicationRoot: pipeline.containsApplicationRoot,
                    enumerationComplete: true
                ),
                error: .success,
                disposition: .completed,
                queueWait: 0,
                elapsed: CFAbsoluteTimeGetCurrent() - pipeline.startedAt,
                budgetExhausted: false,
                retryAfter: nil
            ))
            return
        }

        let count = min(3, pipeline.supplementalQueue.count)
        let handles = Array(pipeline.supplementalQueue.prefix(count))
        pipeline.supplementalQueue.removeFirst(count)
        let pid = pipeline.pid
        let deadline = min(
            pipeline.deadline,
            CFAbsoluteTimeGetCurrent() + miriAXWindowReadBudget
        )
        submit(
            pid: pipeline.pid,
            key: pipeline.key,
            priority: priority,
            operationName: "application-supplemental-chunk",
            operationBudget: miriAXWindowReadBudget,
            recordsSuccess: false,
            callCountEstimate: handles.count * 9,
            operation: { () -> (AXApplicationReadChunk?, AXError) in
                var snapshots: [AXWindowReadSnapshot] = []
                for handle in handles {
                    let (snapshot, error) = readWindowSnapshot(
                        element: handle.element,
                        pid: pid,
                        knownWindowID: handle.windowID,
                        resolveWindowID: false,
                        deadline: deadline
                    )
                    if error == .cannotComplete { return (nil, error) }
                    if let snapshot { snapshots.append(snapshot) }
                }
                return (AXApplicationReadChunk(
                    snapshots: snapshots,
                    containsApplicationRoot: false
                ), .success)
            }
        ) { [weak self, pipeline] result in
            guard let self, !pipeline.finished else { return }
            guard result.disposition == .completed, let chunk = result.value else {
                self.finishApplicationPipelineFailure(pipeline, from: result)
                return
            }
            pipeline.supplementalSnapshots.append(contentsOf: chunk.snapshots)
            self.continueApplicationPipeline(pipeline, priority: priority)
        }
    }

    private func finishApplicationPipelineFailure<Value: Sendable>(
        _ pipeline: AXApplicationReadPipeline,
        from result: AXOperationResult<Value>
    ) {
        if result.disposition != .superseded,
           !pipeline.elements.isEmpty,
           (result.error == .cannotComplete || result.disposition == .circuitOpen)
        {
            finishApplicationPipelinePartial(pipeline, retryAfter: result.retryAfter)
            return
        }
        finishApplicationPipeline(pipeline, result: AXOperationResult(
            value: nil,
            error: result.error,
            disposition: result.disposition,
            queueWait: result.queueWait,
            elapsed: CFAbsoluteTimeGetCurrent() - pipeline.startedAt,
            budgetExhausted: result.budgetExhausted,
            retryAfter: result.retryAfter
        ))
    }

    private func finishApplicationPipelineBudgetExceeded(_ pipeline: AXApplicationReadPipeline) {
        finishApplicationPipelinePartial(pipeline, retryAfter: miriAXFailureRetryDelay)
    }

    private func finishApplicationPipelinePartial(
        _ pipeline: AXApplicationReadPipeline,
        retryAfter: TimeInterval?
    ) {
        let enumerationComplete = pipeline.completedElementCount >= pipeline.elements.count
            && pipeline.supplementalCompleted
        let cursorKey = AXApplicationReadCursorKey(
            pid: pipeline.pid,
            operationKey: pipeline.key
        )
        if enumerationComplete {
            applicationReadOffsets.removeValue(forKey: cursorKey)
        } else {
            applicationReadOffsets[cursorKey] = pipeline.elements.isEmpty
                ? 0
                : (pipeline.startElementOffset + pipeline.nextElementIndex)
                    % pipeline.elements.count
        }
        log(
            "ax application pipeline partial pid=\(pipeline.pid) processed=\(pipeline.nextElementIndex)/\(pipeline.elements.count) elapsed=\(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - pipeline.startedAt))s"
        )
        finishApplicationPipeline(pipeline, result: AXOperationResult(
            value: AXApplicationReadSnapshot(
                pid: pipeline.pid,
                windows: pipeline.snapshots,
                supplementalWindows: pipeline.supplementalSnapshots,
                containsApplicationRoot: pipeline.containsApplicationRoot,
                enumerationComplete: enumerationComplete
            ),
            error: .success,
            disposition: .completed,
            queueWait: 0,
            elapsed: CFAbsoluteTimeGetCurrent() - pipeline.startedAt,
            budgetExhausted: true,
            retryAfter: retryAfter
        ))
    }

    private func cancelActiveApplicationReads() {
        let reads = Array(activeApplicationReads.values)
        for read in reads where !read.finished {
            finishApplicationPipeline(read, result: AXOperationResult(
                value: nil,
                error: .success,
                disposition: .superseded,
                queueWait: 0,
                elapsed: CFAbsoluteTimeGetCurrent() - read.startedAt,
                budgetExhausted: false,
                retryAfter: nil
            ))
        }
    }

    private func finishApplicationPipeline(
        _ pipeline: AXApplicationReadPipeline,
        result: AXOperationResult<AXApplicationReadSnapshot>
    ) {
        let key = AXApplicationReadCursorKey(pid: pipeline.pid, operationKey: pipeline.key)
        if activeApplicationReads[key] === pipeline {
            activeApplicationReads.removeValue(forKey: key)
        }
        pipeline.finish(result)
    }

    private func submitTerminationRestoreBatch(
        pid: pid_t,
        requests: [AXTerminationRestoreRequest],
        deadline: CFAbsoluteTime,
        session: AXTerminationRestoreSession
    ) {
        nextGeneration &+= 1
        let generation = nextGeneration
        executor.submit(
            pid: pid,
            key: "termination-restore",
            generation: generation,
            priority: .interactive,
            operation: {
                let error = withDisabledEnhancedUserInterface(for: pid) {
                    var finalError = AXError.success
                    for request in requests {
                        guard CFAbsoluteTimeGetCurrent() < deadline else {
                            return .cannotComplete
                        }
                        let error = setAXFrame(request.frame, for: request.handle.element)
                        if error == .cannotComplete { return error }
                        if error != .success { finalError = error }
                    }
                    return finalError
                }
                return (error == .success ? true : nil, error)
            },
            completion: AXCallback { [weak self, weak session] result in
                guard let self, let session, self.terminationRestoreSession === session else { return }
                let succeeded = result.disposition == .completed && result.value == true
                session.record(pid: pid, succeeded: succeeded)
                self.log(
                    "ax termination restoration pid=\(pid) disposition=\(String(describing: result.disposition)) error=\(result.error.rawValue) queueWait=\(String(format: "%.3f", result.queueWait))s elapsed=\(String(format: "%.3f", result.elapsed))s callCountEstimate=\(requests.count * 3 + 3)"
                )
                guard session.pendingPIDs.isEmpty else { return }
                session.finish(timedOut: false)
                self.terminationRestoreSession = nil
            }
        )
    }

    private func submit<Value: Sendable>(
        pid: pid_t,
        key: String,
        priority: AXOperationPriority,
        operationName: String,
        operationBudget: TimeInterval? = nil,
        recordsSuccess: Bool = true,
        callCountEstimate: Int = 1,
        operation: @escaping @Sendable () -> (Value?, AXError),
        completion: @escaping @MainActor (AXOperationResult<Value>) -> Void
    ) {
        guard !terminationAdmissionClosed else {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    completion(AXOperationResult(
                        value: nil,
                        error: .success,
                        disposition: .superseded,
                        queueWait: 0,
                        elapsed: 0,
                        budgetExhausted: false,
                        retryAfter: nil
                    ))
                }
            }
            return
        }
        nextGeneration &+= 1
        let generation = nextGeneration
        executor.submit(
            pid: pid,
            key: key,
            generation: generation,
            priority: priority,
            operationBudget: operationBudget,
            recordsSuccess: recordsSuccess,
            operation: operation,
            completion: AXCallback { [weak self] result in
                if result.disposition == .failed || result.disposition == .circuitOpen || result.elapsed >= 0.05 {
                    self?.log(
                        "ax operation=\(operationName) pid=\(pid) disposition=\(String(describing: result.disposition)) error=\(result.error.rawValue) queueWait=\(String(format: "%.3f", result.queueWait))s elapsed=\(String(format: "%.3f", result.elapsed))s budgetExhausted=\(result.budgetExhausted) callCountEstimate=\(callCountEstimate) retryAfter=\(result.retryAfter.map { String(format: "%.2f", $0) } ?? "none")"
                    )
                }
                completion(result)
            }
        )
    }
}

private func readWindowSnapshot(
    element: AXUIElement,
    pid: pid_t,
    knownWindowID: UInt32?,
    resolveWindowID: Bool,
    deadline: CFAbsoluteTime
) -> (AXWindowReadSnapshot?, AXError) {
    func value(_ attribute: String) -> (CFTypeRef?, AXError) {
        guard CFAbsoluteTimeGetCurrent() < deadline else {
            return (nil, .cannotComplete)
        }
        var raw: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &raw)
        return (raw, error)
    }

    let (roleValue, roleError) = value(kAXRoleAttribute)
    guard roleError != .cannotComplete else { return (nil, roleError) }
    let role = roleValue as? String

    let (subroleValue, subroleError) = value(kAXSubroleAttribute)
    guard subroleError != .cannotComplete else { return (nil, subroleError) }
    let subrole = subroleValue as? String

    let (titleValue, titleError) = value(kAXTitleAttribute)
    guard titleError != .cannotComplete else { return (nil, titleError) }
    let title = titleValue as? String ?? ""

    let (minimizedValue, minimizedError) = value(kAXMinimizedAttribute)
    guard minimizedError != .cannotComplete else { return (nil, minimizedError) }

    let (fullscreenValue, fullscreenError) = value("AXFullScreen")
    guard fullscreenError != .cannotComplete else { return (nil, fullscreenError) }

    let (positionValue, positionError) = value(kAXPositionAttribute)
    guard positionError != .cannotComplete else { return (nil, positionError) }
    let (sizeValue, sizeError) = value(kAXSizeAttribute)
    guard sizeError != .cannotComplete else { return (nil, sizeError) }

    var frame: CGRect?
    if let positionValue, let sizeValue,
       CFGetTypeID(positionValue) == AXValueGetTypeID(),
       CFGetTypeID(sizeValue) == AXValueGetTypeID()
    {
        var point = CGPoint.zero
        var size = CGSize.zero
        if AXValueGetValue(positionValue as! AXValue, .cgPoint, &point),
           AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        {
            frame = CGRect(origin: point, size: size)
        }
    }

    guard CFAbsoluteTimeGetCurrent() < deadline else { return (nil, .cannotComplete) }
    var positionSettable = DarwinBoolean(false)
    var sizeSettable = DarwinBoolean(false)
    let positionSettableError = AXUIElementIsAttributeSettable(
        element,
        kAXPositionAttribute as CFString,
        &positionSettable
    )
    guard positionSettableError != .cannotComplete else { return (nil, positionSettableError) }
    guard CFAbsoluteTimeGetCurrent() < deadline else { return (nil, .cannotComplete) }
    let sizeSettableError = AXUIElementIsAttributeSettable(
        element,
        kAXSizeAttribute as CFString,
        &sizeSettable
    )
    guard sizeSettableError != .cannotComplete else { return (nil, sizeSettableError) }
    guard CFAbsoluteTimeGetCurrent() < deadline else { return (nil, .cannotComplete) }

    let resolvedWindowID = knownWindowID
        ?? (resolveWindowID ? SkyLight.shared.windowID(for: element) : nil)
    guard CFAbsoluteTimeGetCurrent() < deadline else { return (nil, .cannotComplete) }
    let handle = AXElementHandle(
        element: element,
        pid: pid,
        windowID: resolvedWindowID
    )
    return (AXWindowReadSnapshot(
        handle: handle,
        role: role,
        subrole: subrole,
        title: title,
        minimized: minimizedValue as? Bool,
        fullscreen: fullscreenValue as? Bool,
        frame: frame,
        positionSettable: positionSettableError == .success && positionSettable.boolValue,
        sizeSettable: sizeSettableError == .success && sizeSettable.boolValue
    ), .success)
}

private extension Array {
    mutating func extractAll(where shouldExtract: (Element) -> Bool) -> [Element] {
        var kept: [Element] = []
        var extracted: [Element] = []
        kept.reserveCapacity(count)
        for element in self {
            if shouldExtract(element) {
                extracted.append(element)
            } else {
                kept.append(element)
            }
        }
        self = kept
        return extracted
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
