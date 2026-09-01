import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

/// Accessibility calls are synchronous IPC into the target application. The
/// system default can block Miri's main run loop for several seconds when an
/// application is hung, so every AX element created by this process inherits a
/// short, bounded timeout instead.
let miriAXMessagingTimeout: Float = 0.25
let miriAXFailureRetryDelay: TimeInterval = 1.0

@discardableResult
func configureAXMessagingTimeout() -> AXError {
    AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), miriAXMessagingTimeout)
}

@discardableResult
func setAXFrame(_ frame: CGRect, for element: AXUIElement) -> AXError {
    let initialSizeError = setAXSize(frame.size, for: element)
    guard initialSizeError != .cannotComplete else { return initialSizeError }

    let positionError = setAXPosition(frame.origin, for: element)
    guard positionError != .cannotComplete else { return positionError }

    let finalSizeError = setAXSize(frame.size, for: element)
    guard finalSizeError == .success else { return finalSizeError }
    return positionError
}

@MainActor
@discardableResult
func setAXFrame(
    _ frame: CGRect,
    for window: ManagedWindow,
    disableEnhancedUserInterface: Bool = true
) -> AXError {
    guard disableEnhancedUserInterface else {
        return setAXFrame(frame, for: window.element)
    }

    return withDisabledEnhancedUserInterface(for: window.pid) {
        setAXFrame(frame, for: window.element)
    }
}

@discardableResult
func setAXSize(_ size: CGSize, for element: AXUIElement) -> AXError {
    var size = CGSize(width: size.width, height: size.height)
    guard let sizeValue = AXValueCreate(.cgSize, &size) else {
        return .failure
    }
    return AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue)
}

@discardableResult
func setAXPosition(_ origin: CGPoint, for element: AXUIElement) -> AXError {
    var origin = origin
    guard let positionValue = AXValueCreate(.cgPoint, &origin) else {
        return .failure
    }
    return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, positionValue)
}

func withDisabledEnhancedUserInterface(for pid: pid_t, _ body: () -> AXError) -> AXError {
    let app = AXUIElementCreateApplication(pid)
    let attribute = "AXEnhancedUserInterface" as CFString
    var rawValue: CFTypeRef?
    let readError = AXUIElementCopyAttributeValue(app, attribute, &rawValue)
    guard readError != .cannotComplete else { return readError }
    let wasEnabled = readError == .success && (rawValue as? Bool == true)

    if wasEnabled {
        let disableError = AXUIElementSetAttributeValue(app, attribute, kCFBooleanFalse)
        guard disableError != .cannotComplete else { return disableError }
    }

    let bodyError = body()
    if wasEnabled {
        let restoreError = AXUIElementSetAttributeValue(app, attribute, kCFBooleanTrue)
        if bodyError == .success, restoreError != .success {
            return restoreError
        }
    }
    return bodyError
}

func currentExecutableURL() -> URL? {
    var size: UInt32 = 0
    _ = _NSGetExecutablePath(nil, &size)

    let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: Int(size))
    defer {
        buffer.deallocate()
    }

    guard _NSGetExecutablePath(buffer, &size) == 0 else {
        return nil
    }

    return URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath()
}
