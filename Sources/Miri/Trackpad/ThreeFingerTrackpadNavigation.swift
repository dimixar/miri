import CoreGraphics
import Darwin
import Foundation

private typealias MTDeviceRef = UnsafeMutableRawPointer

private struct MTPoint {
    var x: Float
    var y: Float
}

private struct MTVector {
    var position: MTPoint
    var velocity: MTPoint
}

private struct MTTouch {
    var frame: Int32
    var timestamp: Double
    var identifier: Int32
    var state: Int32
    var unknown1: Int32
    var unknown2: Int32
    var normalized: MTVector
    var size: Float
    var unknown3: Int32
    var angle: Float
    var majorAxis: Float
    var minorAxis: Float
    var unknown4: MTVector
    var unknown5_0: Int32
    var unknown5_1: Int32
    var unknown6: Float
}

private typealias MTContactCallbackFunction = @convention(c) (
    MTDeviceRef?,
    UnsafeMutableRawPointer?,
    Int32,
    Double,
    Int32
) -> Int32

private let miriTrackpadContactCallback: MTContactCallbackFunction = { _, touches, count, _, _ in
    ThreeFingerTrackpadNavigation.handleContacts(touches: touches, count: Int(count))
    return 0
}

private final class MultitouchSupport {
    typealias CreateList = @convention(c) () -> Unmanaged<CFArray>?
    typealias RegisterContactFrameCallback = @convention(c) (MTDeviceRef?, MTContactCallbackFunction) -> Void
    typealias DeviceStart = @convention(c) (MTDeviceRef?, Int32) -> Void

    let handle: UnsafeMutableRawPointer
    let createList: CreateList
    let registerContactFrameCallback: RegisterContactFrameCallback
    let deviceStart: DeviceStart

    init?() {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport",
            RTLD_LAZY
        ) else {
            return nil
        }

        guard let createListSymbol = dlsym(handle, "MTDeviceCreateList"),
              let registerSymbol = dlsym(handle, "MTRegisterContactFrameCallback"),
              let startSymbol = dlsym(handle, "MTDeviceStart")
        else {
            dlclose(handle)
            return nil
        }

        self.handle = handle
        createList = unsafeBitCast(createListSymbol, to: CreateList.self)
        registerContactFrameCallback = unsafeBitCast(registerSymbol, to: RegisterContactFrameCallback.self)
        deviceStart = unsafeBitCast(startSymbol, to: DeviceStart.self)
    }

    deinit {
        dlclose(handle)
    }
}

final class ThreeFingerTrackpadNavigation: @unchecked Sendable {
    private struct GestureState {
        var active = false
        var lastCentroid = CGPoint.zero
        var lastTimestamp: CFAbsoluteTime = 0
        var velocity = CGPoint.zero
    }

    private let fingers: Int
    private let invertX: Bool
    private let invertY: Bool
    private let onEvent: (TrackpadNavigationEvent) -> Void
    private let lock = NSLock()
    private var state = GestureState()
    private var framework: MultitouchSupport?
    private var deviceList: CFArray?
    private var devices: [MTDeviceRef] = []

    nonisolated(unsafe) private static weak var active: ThreeFingerTrackpadNavigation?

    init(
        fingers: Int,
        invertX: Bool,
        invertY: Bool,
        onEvent: @escaping (TrackpadNavigationEvent) -> Void
    ) {
        self.fingers = fingers
        self.invertX = invertX
        self.invertY = invertY
        self.onEvent = onEvent
    }

    func start() -> Bool {
        guard let framework = MultitouchSupport(),
              let unmanagedDeviceList = framework.createList()
        else {
            return false
        }

        let deviceList = unmanagedDeviceList.takeRetainedValue()
        let count = CFArrayGetCount(deviceList)
        guard count > 0 else {
            return false
        }

        var devices: [MTDeviceRef] = []
        for index in 0..<count {
            guard let rawDevice = CFArrayGetValueAtIndex(deviceList, index) else {
                continue
            }

            let device = UnsafeMutableRawPointer(mutating: rawDevice)
            framework.registerContactFrameCallback(device, miriTrackpadContactCallback)
            framework.deviceStart(device, 0)
            devices.append(device)
        }

        guard !devices.isEmpty else {
            return false
        }

        self.framework = framework
        self.deviceList = deviceList
        self.devices = devices
        Self.active = self
        return true
    }

    func stop() {
        lock.lock()
        resetGesture()
        lock.unlock()

        if Self.active === self {
            Self.active = nil
        }
        devices.removeAll()
        deviceList = nil
        framework = nil
    }

    fileprivate static func handleContacts(touches: UnsafeMutableRawPointer?, count: Int) {
        active?.handleContacts(touches: touches, count: count)
    }

    private func handleContacts(touches: UnsafeMutableRawPointer?, count: Int) {
        let event: TrackpadNavigationEvent?

        lock.lock()
        if count != fingers || touches == nil {
            event = endGesture()
        } else {
            event = updateGesture(touches: touches!.assumingMemoryBound(to: MTTouch.self), count: count)
        }
        lock.unlock()

        if let event {
            onEvent(event)
        }
    }

    private func updateGesture(touches: UnsafeMutablePointer<MTTouch>, count: Int) -> TrackpadNavigationEvent? {
        let centroid = centroid(of: touches, count: count)
        let now = CFAbsoluteTimeGetCurrent()
        guard state.active else {
            state.active = true
            state.lastCentroid = centroid
            state.lastTimestamp = now
            state.velocity = .zero
            return .began
        }

        var deltaX = centroid.x - state.lastCentroid.x
        var deltaY = centroid.y - state.lastCentroid.y
        if invertX {
            deltaX *= -1
        }
        if invertY {
            deltaY *= -1
        }

        let elapsed = max(now - state.lastTimestamp, 1.0 / 120.0)
        state.lastCentroid = centroid
        state.lastTimestamp = now
        guard abs(deltaX) > 0.00005 || abs(deltaY) > 0.00005 else {
            return nil
        }

        let instantVelocity = CGPoint(x: deltaX / elapsed, y: deltaY / elapsed)
        state.velocity = CGPoint(
            x: state.velocity.x * 0.65 + instantVelocity.x * 0.35,
            y: state.velocity.y * 0.65 + instantVelocity.y * 0.35
        )

        return .changed(delta: CGPoint(x: deltaX, y: deltaY), velocity: state.velocity)
    }

    private func centroid(of touches: UnsafeMutablePointer<MTTouch>, count: Int) -> CGPoint {
        var x: CGFloat = 0
        var y: CGFloat = 0

        for index in 0..<count {
            let touch = touches[index]
            x += CGFloat(touch.normalized.position.x)
            y += CGFloat(touch.normalized.position.y)
        }

        return CGPoint(x: x / CGFloat(count), y: y / CGFloat(count))
    }

    private func endGesture() -> TrackpadNavigationEvent? {
        guard state.active else {
            return nil
        }

        let velocity = state.velocity
        resetGesture()
        return .ended(velocity: velocity)
    }

    private func resetGesture() {
        state.active = false
        state.lastCentroid = .zero
        state.lastTimestamp = 0
        state.velocity = .zero
    }
}
