import ApplicationServices
import Darwin
import Foundation

struct SkyLightWindowShadowParameters: Sendable {
    let standardDeviation: CGFloat
    let density: CGFloat
    let offsetX: CGFloat
    let offsetY: CGFloat
    let flags: UInt32
}

final class SkyLight: @unchecked Sendable {
    static let shared = SkyLight()

    private typealias SLSMainConnectionID = @convention(c) () -> Int32
    private typealias SLSMoveWindow = @convention(c) (Int32, UInt32, UnsafeMutablePointer<CGPoint>) -> Int32
    private typealias SLSGetWindowTransform = @convention(c) (Int32, UInt32, UnsafeMutablePointer<CGAffineTransform>) -> Int32
    private typealias SLSSetWindowTransform = @convention(c) (Int32, UInt32, CGAffineTransform) -> Int32
    private typealias SLSSetWindowLevel = @convention(c) (Int32, UInt32, Int32) -> Int32
    private typealias SLSTransactionCreate = @convention(c) (Int32) -> CFTypeRef?
    private typealias SLSTransactionCommit = @convention(c) (CFTypeRef, Int32) -> Void
    private typealias SLSTransactionMoveWindowWithGroup = @convention(c) (CFTypeRef, UInt32, CGPoint) -> Void
    private typealias SLSGetWindowShadowAndRimParameters = @convention(c) (
        Int32,
        UInt32,
        UnsafeMutablePointer<Float>,
        UnsafeMutablePointer<Float>,
        UnsafeMutablePointer<Int32>,
        UnsafeMutablePointer<Int32>,
        UnsafeMutablePointer<UInt32>
    ) -> Int32
    private typealias CFReleaseFunction = @convention(c) (CFTypeRef) -> Void
    private typealias AXUIElementGetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<UInt32>) -> Int32

    private let connectionID: Int32?
    private let moveWindow: SLSMoveWindow?
    private let getWindowTransform: SLSGetWindowTransform?
    private let setWindowTransform: SLSSetWindowTransform?
    private let setWindowLevel: SLSSetWindowLevel?
    private let transactionCreate: SLSTransactionCreate?
    private let transactionCommit: SLSTransactionCommit?
    private let transactionMoveWindowWithGroup: SLSTransactionMoveWindowWithGroup?
    private let getWindowShadowAndRimParameters: SLSGetWindowShadowAndRimParameters?
    private let cfRelease: CFReleaseFunction?
    private let axUIElementGetWindow: AXUIElementGetWindow?

    private init() {
        let skyLightHandle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
        let hiServicesHandle = dlopen(
            "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices",
            RTLD_LAZY
        )
        let coreFoundationHandle = dlopen(
            "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation",
            RTLD_LAZY
        )

        let mainConnection = skyLightHandle
            .flatMap { dlsym($0, "SLSMainConnectionID") }
            .map { unsafeBitCast($0, to: SLSMainConnectionID.self) }
        moveWindow = skyLightHandle
            .flatMap { dlsym($0, "SLSMoveWindow") }
            .map { unsafeBitCast($0, to: SLSMoveWindow.self) }
        getWindowTransform = skyLightHandle
            .flatMap { dlsym($0, "SLSGetWindowTransform") }
            .map { unsafeBitCast($0, to: SLSGetWindowTransform.self) }
        setWindowTransform = skyLightHandle
            .flatMap { dlsym($0, "SLSSetWindowTransform") }
            .map { unsafeBitCast($0, to: SLSSetWindowTransform.self) }
        setWindowLevel = skyLightHandle
            .flatMap { dlsym($0, "SLSSetWindowLevel") }
            .map { unsafeBitCast($0, to: SLSSetWindowLevel.self) }
        transactionCreate = skyLightHandle
            .flatMap { dlsym($0, "SLSTransactionCreate") }
            .map { unsafeBitCast($0, to: SLSTransactionCreate.self) }
        transactionCommit = skyLightHandle
            .flatMap { dlsym($0, "SLSTransactionCommit") }
            .map { unsafeBitCast($0, to: SLSTransactionCommit.self) }
        transactionMoveWindowWithGroup = skyLightHandle
            .flatMap { dlsym($0, "SLSTransactionMoveWindowWithGroup") }
            .map { unsafeBitCast($0, to: SLSTransactionMoveWindowWithGroup.self) }
        getWindowShadowAndRimParameters = skyLightHandle
            .flatMap { dlsym($0, "SLSGetWindowShadowAndRimParameters") }
            .map { unsafeBitCast($0, to: SLSGetWindowShadowAndRimParameters.self) }
        cfRelease = coreFoundationHandle
            .flatMap { dlsym($0, "CFRelease") }
            .map { unsafeBitCast($0, to: CFReleaseFunction.self) }
        axUIElementGetWindow = hiServicesHandle
            .flatMap { dlsym($0, "_AXUIElementGetWindow") }
            .map { unsafeBitCast($0, to: AXUIElementGetWindow.self) }
        connectionID = mainConnection?()
    }

    var canSetWindowLevel: Bool {
        connectionID != nil && setWindowLevel != nil
    }

    var canPositionWindows: Bool {
        connectionID != nil
            && (transactionMoveWindowWithGroup != nil || moveWindow != nil || setWindowTransform != nil)
    }

    func windowID(for element: AXUIElement) -> UInt32? {
        guard let axUIElementGetWindow else {
            return nil
        }

        var id: UInt32 = 0
        let error = axUIElementGetWindow(element, &id)
        return error == AXError.success.rawValue && id != 0 ? id : nil
    }

    @discardableResult
    func move(_ windowID: UInt32?, to origin: CGPoint) -> Bool {
        guard let connectionID, let moveWindow, let windowID else {
            return false
        }

        var origin = origin
        guard moveWindow(connectionID, windowID, &origin) == 0 else {
            return false
        }
        return windowOrigin(windowID).map { originsMatch($0, origin) } ?? false
    }

    @discardableResult
    func moveWithTransaction(_ windowID: UInt32?, to origin: CGPoint) -> Bool {
        guard let windowID, let transactionMoveWindowWithGroup else {
            return false
        }
        guard withTransaction({ transaction in
            transactionMoveWindowWithGroup(transaction, windowID, origin)
        }) else {
            return false
        }
        // Transaction creation and commit do not report whether WindowServer
        // accepted a cross-process move. Verify the observable result so a
        // silently ignored transaction can fall through to another mechanism.
        return windowOrigin(windowID).map { originsMatch($0, origin) } ?? false
    }

    func shadowParameters(for windowID: UInt32?) -> SkyLightWindowShadowParameters? {
        guard let connectionID, let windowID, let getWindowShadowAndRimParameters else {
            return nil
        }

        var standardDeviation: Float = 0
        var density: Float = 0
        var offsetX: Int32 = 0
        var offsetY: Int32 = 0
        var flags: UInt32 = 0
        guard getWindowShadowAndRimParameters(
            connectionID,
            windowID,
            &standardDeviation,
            &density,
            &offsetX,
            &offsetY,
            &flags
        ) == 0 else {
            return nil
        }

        return SkyLightWindowShadowParameters(
            standardDeviation: CGFloat(standardDeviation),
            density: CGFloat(density),
            offsetX: CGFloat(offsetX),
            offsetY: CGFloat(offsetY),
            flags: flags
        )
    }

    @discardableResult
    func transform(for windowID: UInt32?) -> CGAffineTransform? {
        guard let connectionID, let getWindowTransform, let windowID else {
            return nil
        }

        var transform = CGAffineTransform.identity
        return getWindowTransform(connectionID, windowID, &transform) == 0 ? transform : nil
    }

    @discardableResult
    func translate(_ windowID: UInt32?, from base: CGAffineTransform, by offset: CGPoint) -> Bool {
        guard let connectionID, let setWindowTransform, let windowID else {
            return false
        }

        var transform = base
        // SkyLight's window transform maps global coordinates into the
        // window's local coordinates, so a positive visual displacement uses
        // the opposite translation in the transform.
        transform.tx -= offset.x
        transform.ty -= offset.y
        return setWindowTransform(connectionID, windowID, transform) == 0
    }

    @discardableResult
    func setTransform(_ transform: CGAffineTransform, for windowID: UInt32?) -> Bool {
        guard let connectionID, let setWindowTransform, let windowID else {
            return false
        }

        return setWindowTransform(connectionID, windowID, transform) == 0
    }

    @discardableResult
    func setLevel(_ level: Int32, for windowID: UInt32?) -> Bool {
        guard let connectionID, let setWindowLevel, let windowID else {
            return false
        }
        return setWindowLevel(connectionID, windowID, level) == 0
    }

    private func withTransaction(_ body: (CFTypeRef) -> Void) -> Bool {
        guard let connectionID,
              let transactionCreate,
              let transactionCommit,
              let transaction = transactionCreate(connectionID)
        else {
            return false
        }

        body(transaction)
        transactionCommit(transaction, 0)
        cfRelease?(transaction)
        return true
    }

    private func windowOrigin(_ windowID: UInt32) -> CGPoint? {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionIncludingWindow],
            CGWindowID(windowID)
        ) as? [[String: Any]],
            let bounds = list.first?[kCGWindowBounds as String] as? NSDictionary
        else {
            return nil
        }

        var rect = CGRect.zero
        guard CGRectMakeWithDictionaryRepresentation(bounds as CFDictionary, &rect) else {
            return nil
        }
        return rect.origin
    }

    private func originsMatch(_ lhs: CGPoint, _ rhs: CGPoint) -> Bool {
        abs(lhs.x - rhs.x) <= 0.5 && abs(lhs.y - rhs.y) <= 0.5
    }
}
