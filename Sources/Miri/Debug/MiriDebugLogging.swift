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
            if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber,
               size.int64Value > 8 * 1_024 * 1_024
            {
                try? FileManager.default.removeItem(at: url)
            }
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

    func logRawAXWindowIfNeeded(
        _ snapshot: AXWindowReadSnapshot,
        app: NSRunningApplication,
        source: String
    ) {
        guard debugLogging else { return }
        let frameDescription = snapshot.frame.map(String.init(describing:)) ?? "nil"
        let signature = "raw|\(source)|\(app.bundleIdentifier ?? "nil")|\(snapshot.title)|\(frameDescription)|\(snapshot.handle.windowID.map(String.init) ?? "nil")|\(snapshot.minimized.map(String.init) ?? "nil")|\(snapshot.fullscreen.map(String.init) ?? "nil")"
        guard debugLoggedWindowSignatures.insert(signature).inserted else { return }
        let manageable = isManageableWindow(snapshot)
        let known = isKnownWindow(snapshot.handle.element)
        let transientTitle = isChromiumTransientTitle(snapshot.title)
        let cgInfo = snapshot.handle.windowID.flatMap { cgWindowDebugInfo(windowID: $0) } ?? "cg=nil"
        debugLog(
            "raw ax window source=\(source) app='\(app.localizedName ?? "pid \(snapshot.handle.pid)")' bundle='\(app.bundleIdentifier ?? "nil")' pid=\(snapshot.handle.pid) title='\(snapshot.title)' id=\(snapshot.handle.windowID.map(String.init) ?? "nil") role=\(snapshot.role ?? "nil") subrole=\(snapshot.subrole ?? "nil") frame=\(frameDescription) minimized=\(snapshot.minimized.map(String.init) ?? "nil") fullscreen=\(snapshot.fullscreen.map(String.init) ?? "nil") manageable=\(manageable) known=\(known) chromiumTransientTitle=\(transientTitle) \(cgInfo)"
        )
    }

    func logTransientPopupIfNeeded(
        _ window: ManagedWindow,
        app: NSRunningApplication,
        frame: CGRect?
    ) {
        guard debugLogging else { return }
        let frameDescription = frame.map { String(describing: $0) } ?? "nil"
        let signature = "transient|\(window.bundleID ?? "nil")|\(window.title)|\(frameDescription)|\(window.windowID.map(String.init) ?? "nil")"
        guard !debugLoggedWindowSignatures.contains(signature) else { return }
        debugLoggedWindowSignatures.insert(signature)
        debugLog("transient popup ignored app='\(window.appName)' bundle='\(window.bundleID ?? "nil")' pid=\(window.pid) title='\(window.title)' id=\(window.windowID.map(String.init) ?? "nil") frame=\(frameDescription)")
    }

    func logIgnoredPictureInPictureIfNeeded(
        _ window: ManagedWindow,
        app: NSRunningApplication,
        frame: CGRect?
    ) {
        guard debugLogging else { return }
        let frameDescription = frame.map { String(describing: $0) } ?? "nil"
        let signature = "pip|\(window.bundleID ?? "nil")|\(window.title)|\(window.windowID.map(String.init) ?? "nil")"
        guard !debugLoggedWindowSignatures.contains(signature) else { return }
        debugLoggedWindowSignatures.insert(signature)
        debugLog("picture-in-picture ignored app='\(window.appName)' bundle='\(window.bundleID ?? "nil")' pid=\(window.pid) title='\(window.title)' id=\(window.windowID.map(String.init) ?? "nil") frame=\(frameDescription)")
    }

    func cgWindowDebugInfo(windowID: UInt32) -> String? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(windowID)) as? [[String: Any]],
              let info = list.first
        else { return nil }
        let layer = info[kCGWindowLayer as String] ?? "nil"
        let onscreen = info[kCGWindowIsOnscreen as String] ?? "nil"
        let owner = info[kCGWindowOwnerName as String] ?? "nil"
        let name = info[kCGWindowName as String] ?? "nil"
        let bounds = info[kCGWindowBounds as String] ?? "nil"
        return "cg(layer=\(layer) onscreen=\(onscreen) owner='\(owner)' name='\(name)' bounds=\(bounds))"
    }

}
