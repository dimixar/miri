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
}

struct AXObserverRegistration: @unchecked Sendable {
    let observer: AXObserver
    let notificationErrors: [(name: String, error: AXError)]
}

private struct AXObserverCallbackHandle: @unchecked Sendable {
    let callback: AXObserverCallback
}

enum AXOperationPriority: Int, Sendable {
    case background
    case normal
    case interactive
}

enum AXOperationDisposition: Sendable {
    case completed
    case failed
    case circuitOpen
    case superseded
}

struct AXOperationResult<Value: Sendable>: Sendable {
    let value: Value?
    let error: AXError
    let disposition: AXOperationDisposition
    let elapsed: TimeInterval
    let retryAfter: TimeInterval?
}

private struct AXCallback<Value: Sendable>: @unchecked Sendable {
    let body: @MainActor (AXOperationResult<Value>) -> Void

    func call(_ result: AXOperationResult<Value>) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                body(result)
            }
        }
    }
}

private struct AXJob: @unchecked Sendable {
    let key: String
    let generation: UInt64
    let priority: AXOperationPriority
    let run: @Sendable () -> Void
    let cancel: @Sendable () -> Void
}

private final class AXProcessLane: @unchecked Sendable {
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
        switch job.priority {
        case .interactive: interactiveJobs.append(job)
        case .normal: normalJobs.append(job)
        case .background: backgroundJobs.append(job)
        }
        let shouldStart = !draining
        if shouldStart { draining = true }
        lock.unlock()

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
}

private final class AXOperationExecutor: @unchecked Sendable {
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
            lane.removeAll(resetHealth: true)
            group.enter()
            lane.notifyWhenQuiescent { group.leave() }
        }
        group.notify(queue: .global(qos: .userInitiated), execute: completion)
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
        operation: @escaping @Sendable () -> (Value?, AXError),
        completion: AXCallback<Value>
    ) {
        let lane = lane(for: pid)
        let cancelledResult = AXOperationResult<Value>(
            value: nil,
            error: .success,
            disposition: .superseded,
            elapsed: 0,
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
                    elapsed: 0,
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
                    elapsed: 0,
                    retryAfter: retryAfter
                ))
                return
            }

            let startedAt = CFAbsoluteTimeGetCurrent()
            let (value, error) = operation()
            let elapsed = CFAbsoluteTimeGetCurrent() - startedAt
            let retryAfter = lane.record(error: error, now: CFAbsoluteTimeGetCurrent())
            let stillLatest = lane.shouldExecute(key: key, generation: generation)
            completion.call(AXOperationResult(
                value: stillLatest ? value : nil,
                error: error,
                disposition: stillLatest
                    ? (error == .success ? .completed : .failed)
                    : .superseded,
                elapsed: elapsed,
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
final class AXOperationController {
    typealias Logger = (String) -> Void

    private let executor = AXOperationExecutor()
    private let log: Logger
    private var nextGeneration: UInt64 = 0

    init(log: @escaping Logger) {
        self.log = log
    }

    func isCircuitOpen(pid: pid_t) -> Bool {
        executor.isCircuitOpen(pid: pid)
    }

    func remove(pid: pid_t) {
        executor.remove(pid: pid)
    }

    func quiesceForUnavailableSession(completion: @escaping @MainActor () -> Void) {
        executor.quiesceAllAndResetHealth {
            DispatchQueue.main.async {
                MainActor.assumeIsolated { completion() }
            }
        }
    }

    func resetHealthForSessionRecovery() {
        executor.resetAllHealth()
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
            operation: {
                var observer: AXObserver?
                let createError = AXObserverCreate(pid, callbackHandle.callback, &observer)
                guard createError == .success, let observer else { return (nil, createError) }
                let appElement = AXUIElementCreateApplication(pid)
                let restoredRefcon = UnsafeMutableRawPointer(bitPattern: refconBits)
                var errors: [(name: String, error: AXError)] = []
                for notification in notifications {
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
            operation: { readWindowSnapshot(element: handle.element, pid: handle.pid) },
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
            operation: {
                let app = AXUIElementCreateApplication(pid)
                var value: CFTypeRef?
                let error = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value)
                guard error == .success, let element = value as! AXUIElement? else {
                    return (nil, error)
                }
                return readWindowSnapshot(element: element, pid: pid)
            },
            completion: completion
        )
    }

    func readApplication(
        pid: pid_t,
        priority: AXOperationPriority,
        supplementalHandles: [AXElementHandle] = [],
        coalescingKey: String = "application-windows",
        completion: @escaping @MainActor (AXOperationResult<AXApplicationReadSnapshot>) -> Void
    ) {
        submit(
            pid: pid,
            key: coalescingKey,
            priority: priority,
            operationName: "application-windows",
            operation: {
                let app = AXUIElementCreateApplication(pid)
                var value: CFTypeRef?
                let windowsError = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
                guard windowsError == .success, let elements = value as? [AXUIElement] else {
                    return (nil, windowsError)
                }

                var snapshots: [AXWindowReadSnapshot] = []
                var containsApplicationRoot = false
                for element in elements {
                    let (snapshot, error) = readWindowSnapshot(element: element, pid: pid)
                    guard error == .success, let snapshot else { return (nil, error) }
                    containsApplicationRoot = containsApplicationRoot || snapshot.role == kAXApplicationRole
                    snapshots.append(snapshot)
                }

                var supplementalSnapshots: [AXWindowReadSnapshot] = []
                let enumeratedIDs = Set(snapshots.compactMap { $0.handle.windowID })
                for handle in supplementalHandles {
                    if let windowID = handle.windowID, enumeratedIDs.contains(windowID) { continue }
                    if snapshots.contains(where: { CFEqual($0.handle.element, handle.element) }) { continue }
                    let (snapshot, error) = readWindowSnapshot(element: handle.element, pid: pid)
                    if error == .cannotComplete { return (nil, error) }
                    if let snapshot { supplementalSnapshots.append(snapshot) }
                }

                return (AXApplicationReadSnapshot(
                    pid: pid,
                    windows: snapshots,
                    supplementalWindows: supplementalSnapshots,
                    containsApplicationRoot: containsApplicationRoot
                ), .success)
            },
            completion: completion
        )
    }

    private func submit<Value: Sendable>(
        pid: pid_t,
        key: String,
        priority: AXOperationPriority,
        operationName: String,
        operation: @escaping @Sendable () -> (Value?, AXError),
        completion: @escaping @MainActor (AXOperationResult<Value>) -> Void
    ) {
        nextGeneration &+= 1
        let generation = nextGeneration
        executor.submit(
            pid: pid,
            key: key,
            generation: generation,
            priority: priority,
            operation: operation,
            completion: AXCallback { [weak self] result in
                if result.disposition == .failed || result.disposition == .circuitOpen || result.elapsed >= 0.05 {
                    self?.log(
                        "ax operation=\(operationName) pid=\(pid) disposition=\(String(describing: result.disposition)) error=\(result.error.rawValue) elapsed=\(String(format: "%.3f", result.elapsed))s retryAfter=\(result.retryAfter.map { String(format: "%.2f", $0) } ?? "none")"
                    )
                }
                completion(result)
            }
        )
    }
}

private func readWindowSnapshot(element: AXUIElement, pid: pid_t) -> (AXWindowReadSnapshot?, AXError) {
    func value(_ attribute: String) -> (CFTypeRef?, AXError) {
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

    var positionSettable = DarwinBoolean(false)
    var sizeSettable = DarwinBoolean(false)
    let positionSettableError = AXUIElementIsAttributeSettable(
        element,
        kAXPositionAttribute as CFString,
        &positionSettable
    )
    guard positionSettableError != .cannotComplete else { return (nil, positionSettableError) }
    let sizeSettableError = AXUIElementIsAttributeSettable(
        element,
        kAXSizeAttribute as CFString,
        &sizeSettable
    )
    guard sizeSettableError != .cannotComplete else { return (nil, sizeSettableError) }

    let handle = AXElementHandle(
        element: element,
        pid: pid,
        windowID: SkyLight.shared.windowID(for: element)
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

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
