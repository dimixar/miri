import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

func setAXFrame(_ frame: CGRect, for element: AXUIElement) {
    setAXSize(frame.size, for: element)
    setAXPosition(frame.origin, for: element)
    setAXSize(frame.size, for: element)
}

func setAXFrame(_ frame: CGRect, for window: ManagedWindow, disableEnhancedUserInterface: Bool = true) {
    guard disableEnhancedUserInterface else {
        setAXFrame(frame, for: window.element)
        return
    }

    withDisabledEnhancedUserInterface(for: window.pid) {
        setAXFrame(frame, for: window.element)
    }
}

func setAXSize(_ size: CGSize, for element: AXUIElement) {
    var size = CGSize(width: size.width, height: size.height)
    if let sizeValue = AXValueCreate(.cgSize, &size) {
        AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeValue)
    }
}

func setAXPosition(_ origin: CGPoint, for element: AXUIElement) {
    var origin = origin
    if let positionValue = AXValueCreate(.cgPoint, &origin) {
        AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, positionValue)
    }
}

func withDisabledEnhancedUserInterface(for pid: pid_t, _ body: () -> Void) {
    let app = AXUIElementCreateApplication(pid)
    let attribute = "AXEnhancedUserInterface" as CFString
    var rawValue: CFTypeRef?
    let wasReadable = AXUIElementCopyAttributeValue(app, attribute, &rawValue) == .success
    let wasEnabled = wasReadable && (rawValue as? Bool == true)

    if wasEnabled {
        AXUIElementSetAttributeValue(app, attribute, kCFBooleanFalse)
    }
    body()
    if wasEnabled {
        AXUIElementSetAttributeValue(app, attribute, kCFBooleanTrue)
    }
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
