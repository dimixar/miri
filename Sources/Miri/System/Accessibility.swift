import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

func setAXFrame(_ frame: CGRect, for element: AXUIElement) {
    var origin = CGPoint(x: frame.minX, y: frame.minY)
    if let positionValue = AXValueCreate(.cgPoint, &origin) {
        AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, positionValue)
    }

    var size = CGSize(width: frame.width, height: frame.height)
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
