import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

extension Miri {
    func debugLog(_ message: String) {
        guard debugLogging else {
            return
        }
        let line = "miri: \(message)"
        print(line)
        appendDebugLog(line)
    }

    var debugLogURL: URL {
        let configHome = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
            .map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        return configHome.appendingPathComponent("miri/debug.log")
    }

    func appendDebugLog(_ line: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let text = "\(timestamp) \(line)\n"
        let url = debugLogURL
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: url.path), let data = text.data(using: .utf8) {
                let handle = try FileHandle(forWritingTo: url)
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
            } else {
                try text.write(to: url, atomically: true, encoding: .utf8)
            }
        } catch {
            print("miri: failed to write debug log: \(error)")
        }
    }

    func logTransientPopupIfNeeded(_ window: ManagedWindow, app: NSRunningApplication) {
        guard debugLogging else { return }
        let frameDescription = axFrame(window.element).map { String(describing: $0) } ?? "nil"
        let signature = "transient|\(window.bundleID ?? "nil")|\(window.title)|\(frameDescription)|\(window.windowID.map(String.init) ?? "nil")"
        guard !debugLoggedWindowSignatures.contains(signature) else { return }
        debugLoggedWindowSignatures.insert(signature)
        debugLog("transient popup ignored app='\(window.appName)' bundle='\(window.bundleID ?? "nil")' pid=\(window.pid) title='\(window.title)' id=\(window.windowID.map(String.init) ?? "nil") frame=\(frameDescription)")
    }

    func logIgnoredPictureInPictureIfNeeded(_ window: ManagedWindow, app: NSRunningApplication) {
        guard debugLogging else { return }
        let frameDescription = axFrame(window.element).map { String(describing: $0) } ?? "nil"
        let signature = "pip|\(window.bundleID ?? "nil")|\(window.title)|\(window.windowID.map(String.init) ?? "nil")"
        guard !debugLoggedWindowSignatures.contains(signature) else { return }
        debugLoggedWindowSignatures.insert(signature)
        debugLog("picture-in-picture ignored app='\(window.appName)' bundle='\(window.bundleID ?? "nil")' pid=\(window.pid) title='\(window.title)' id=\(window.windowID.map(String.init) ?? "nil") frame=\(frameDescription)")
    }

    func logRawAXWindowIfNeeded(_ element: AXUIElement, app: NSRunningApplication, source: String) {
        guard debugLogging else { return }
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        let title = axString(element, kAXTitleAttribute) ?? ""
        let frameDescription = axFrame(element).map { String(describing: $0) } ?? "nil"
        let windowID = SkyLight.shared.windowID(for: element)
        let signature = "raw|\(source)|\(app.bundleIdentifier ?? "nil")|\(title)|\(frameDescription)|\(windowID.map(String.init) ?? "nil")"
        guard !debugLoggedWindowSignatures.contains(signature) else { return }
        debugLoggedWindowSignatures.insert(signature)

        let role = axString(element, kAXRoleAttribute) ?? "nil"
        let subrole = axString(element, kAXSubroleAttribute) ?? "nil"
        let minimized = axBool(element, kAXMinimizedAttribute).map(String.init) ?? "nil"
        let fullscreen = axBool(element, "AXFullScreen").map(String.init) ?? "nil"
        let manageable = isManageableWindow(element)
        let known = isKnownWindow(element)
        let transientTitle = isChromiumTransientTitle(title)
        let cgInfo = windowID.flatMap { cgWindowDebugInfo(windowID: $0) } ?? "cg=nil"

        debugLog("raw ax window source=\(source) app='\(app.localizedName ?? "pid \(pid)")' bundle='\(app.bundleIdentifier ?? "nil")' pid=\(pid) title='\(title)' id=\(windowID.map(String.init) ?? "nil") role=\(role) subrole=\(subrole) frame=\(frameDescription) minimized=\(minimized) fullscreen=\(fullscreen) manageable=\(manageable) known=\(known) chromiumTransientTitle=\(transientTitle) \(cgInfo)")
    }

    func logAXNotification(_ name: String, element: AXUIElement) {
        guard debugLogging else { return }
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        guard let app = NSRunningApplication(processIdentifier: pid), isChromiumBrowser(app) else { return }
        logRawAXWindowIfNeeded(element, app: app, source: "notification:\(name)")
    }

    func logDiscoveredWindowIfNeeded(_ window: ManagedWindow, app: NSRunningApplication) {
        guard debugLogging else { return }
        let frameDescription = axFrame(window.element).map { String(describing: $0) } ?? "nil"
        let signature = "\(window.bundleID ?? "nil")|\(window.title)|\(frameDescription)|\(window.windowID.map(String.init) ?? "nil")"
        guard !debugLoggedWindowSignatures.contains(signature) else { return }
        debugLoggedWindowSignatures.insert(signature)

        let role = axString(window.element, kAXRoleAttribute) ?? "nil"
        let subrole = axString(window.element, kAXSubroleAttribute) ?? "nil"
        let modal = axBool(window.element, "AXModal").map(String.init) ?? "nil"
        let minimized = axBool(window.element, kAXMinimizedAttribute).map(String.init) ?? "nil"
        let fullscreen = axBool(window.element, "AXFullScreen").map(String.init) ?? "nil"
        let positionSettable = isAXAttributeSettable(window.element, kAXPositionAttribute)
        let sizeSettable = isAXAttributeSettable(window.element, kAXSizeAttribute)
        let hasClose = axAttributeExists(window.element, kAXCloseButtonAttribute)
        let hasMinimize = axAttributeExists(window.element, kAXMinimizeButtonAttribute)
        let hasZoom = axAttributeExists(window.element, kAXZoomButtonAttribute)
        let cgInfo = window.windowID.flatMap { cgWindowDebugInfo(windowID: $0) } ?? "cg=nil"

        debugLog("window discovered app='\(window.appName)' bundle='\(window.bundleID ?? "nil")' pid=\(window.pid) title='\(window.title)' id=\(window.windowID.map(String.init) ?? "nil") role=\(role) subrole=\(subrole) frame=\(frameDescription) minimized=\(minimized) fullscreen=\(fullscreen) modal=\(modal) posSettable=\(positionSettable) sizeSettable=\(sizeSettable) buttons(close/min/zoom)=\(hasClose)/\(hasMinimize)/\(hasZoom) activationPolicy=\(app.activationPolicy.rawValue) \(cgInfo)")
    }

    func cgWindowDebugInfo(windowID: UInt32) -> String? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(windowID)) as? [[String: Any]],
              let info = list.first
        else { return nil }
        let layer = info[kCGWindowLayer as String] ?? "nil"
        let alpha = info[kCGWindowAlpha as String] ?? "nil"
        let onscreen = info[kCGWindowIsOnscreen as String] ?? "nil"
        let owner = info[kCGWindowOwnerName as String] ?? "nil"
        let name = info[kCGWindowName as String] ?? "nil"
        let bounds = info[kCGWindowBounds as String] ?? "nil"
        return "cg(layer=\(layer) alpha=\(alpha) onscreen=\(onscreen) owner='\(owner)' name='\(name)' bounds=\(bounds))"
    }

}
