import AppKit
import ApplicationServices
import CoreGraphics

extension Miri {
    func transientSystemWindowIsActive(forceRefresh: Bool = false) -> Bool {
        let now = CFAbsoluteTimeGetCurrent()
        if !forceRefresh, now - transientWindowStateCheckedAt < 0.25 {
            return transientWindowActive
        }

        transientWindowStateCheckedAt = now
        let activeTransientWindows = transientSystemWindows()
        recoverTransientSystemWindows(activeTransientWindows)
        transientWindowActive = !activeTransientWindows.isEmpty
        return transientWindowActive
    }

    func transientSystemWindows() -> [TransientSystemWindow] {
        transientCheckApplications.compactMap { app in
            guard let window = focusedWindow(for: app),
                  isTransientSystemWindow(window, app: app)
            else {
                return nil
            }
            return TransientSystemWindow(element: window)
        }
    }

    @discardableResult
    func recoverTransientSystemWindows(_ windows: [TransientSystemWindow]) -> Bool {
        guard !windows.isEmpty else {
            return false
        }

        let viewport = currentViewport()
        var moved = false
        for transient in windows {
            setWindowAlpha(1, for: SkyLight.shared.windowID(for: transient.element))
            if let frame = axFrame(transient.element), transientFrameNeedsRecovery(frame, viewport: viewport) {
                setAXPosition(centeredOrigin(for: frame, in: viewport), for: transient.element)
                moved = true
            }
            AXUIElementPerformAction(transient.element, kAXRaiseAction as CFString)
        }
        return moved
    }

    func transientFrameNeedsRecovery(_ frame: CGRect, viewport: CGRect) -> Bool {
        !frame.intersects(viewport)
            || frame.midX < viewport.minX
            || frame.midX > viewport.maxX
            || frame.midY < viewport.minY
            || frame.midY > viewport.maxY
    }

    func centeredOrigin(for frame: CGRect, in viewport: CGRect) -> CGPoint {
        CGPoint(
            x: viewport.midX - frame.width / 2,
            y: viewport.midY - frame.height / 2
        )
    }

    var transientCheckApplications: [NSRunningApplication] {
        var apps: [NSRunningApplication] = []
        if let frontmostApplication = NSWorkspace.shared.frontmostApplication {
            apps.append(frontmostApplication)
        }
        for app in NSWorkspace.shared.runningApplications where app.isActive {
            if !apps.contains(where: { $0.processIdentifier == app.processIdentifier }) {
                apps.append(app)
            }
        }
        for panelService in openAndSavePanelServices(matchingAnyHostIn: apps) {
            if !apps.contains(where: { $0.processIdentifier == panelService.processIdentifier }) {
                apps.append(panelService)
            }
        }
        return apps
    }

    func openAndSavePanelServices(matchingAnyHostIn hosts: [NSRunningApplication]) -> [NSRunningApplication] {
        let hostNames = hosts.compactMap(\.localizedName)
        guard !hostNames.isEmpty else {
            return []
        }

        return NSWorkspace.shared.runningApplications.filter { app in
            guard isOpenAndSavePanelService(app),
                  let name = app.localizedName
            else {
                return false
            }
            return hostNames.contains { name.contains("(\($0))") }
        }
    }

    func isOpenAndSavePanelService(_ app: NSRunningApplication) -> Bool {
        app.bundleIdentifier == "com.apple.appkit.xpc.openAndSavePanelService"
    }

    func focusedWindow(for app: NSRunningApplication) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value
        else {
            return nil
        }
        return (value as! AXUIElement)
    }

    func isTransientSystemWindow(_ element: AXUIElement, app: NSRunningApplication) -> Bool {
        let role = axString(element, kAXRoleAttribute)
        let subrole = axString(element, kAXSubroleAttribute)
        if role == kAXSheetRole || role == "AXSheet" || role == "AXDialog" {
            return true
        }
        if subrole == "AXSystemDialog" || subrole == "AXDialog" {
            return true
        }
        if isUnknownSubroleTransientOverlay(element) {
            return true
        }
        if isChromiumTransientElement(element, app: app) {
            return true
        }
        return isOpenAndSavePanelService(app)
    }

    func isUnknownSubroleTransientOverlay(_ element: AXUIElement) -> Bool {
        guard axString(element, kAXRoleAttribute) == kAXWindowRole,
              axString(element, kAXSubroleAttribute) == "AXUnknown"
        else {
            return false
        }

        let title = axString(element, kAXTitleAttribute)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty && !isManageableWindow(element)
    }

    func isChromiumTransientElement(_ element: AXUIElement, app: NSRunningApplication) -> Bool {
        guard isChromiumBrowser(app),
              axString(element, kAXRoleAttribute) == kAXWindowRole,
              isChromiumTransientSubrole(axString(element, kAXSubroleAttribute)),
              isChromiumTransientTitle(axString(element, kAXTitleAttribute) ?? ""),
              let frame = axFrame(element)
        else {
            return false
        }
        return frame.width <= 620 && frame.height <= 620
    }

    func isLikelyTransientPopup(_ window: ManagedWindow, app: NSRunningApplication) -> Bool {
        // Chromium exposes toolbar bubbles (media controls, profiles, permissions,
        // extension popovers, etc.) as small, often untitled AXWindows. PiP is also
        // app-managed/always-on-top, so don't tile it either.
        guard isChromiumBrowser(app), isChromiumTransientTitle(window.title) else {
            return false
        }
        guard let frame = axFrame(window.element) else {
            return false
        }
        return frame.width <= 620 && frame.height <= 620
    }

    func isChromiumTransientTitle(_ title: String) -> Bool {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalizedTitle.isEmpty
            || normalizedTitle == "global media controls"
            || isPictureInPictureTitle(title)
    }

    func isChromiumTransientSubrole(_ subrole: String?) -> Bool {
        subrole == nil || subrole == kAXStandardWindowSubrole || subrole == "AXUnknown"
    }

    func isPictureInPictureWindow(_ window: ManagedWindow) -> Bool {
        isPictureInPictureTitle(window.title)
    }

    func isPictureInPictureTitle(_ title: String) -> Bool {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalizedTitle == "picture in picture"
            || normalizedTitle == "picture-in-picture"
            || normalizedTitle == "pip"
    }

    func isChromiumBrowser(_ app: NSRunningApplication) -> Bool {
        guard let bundleID = app.bundleIdentifier else {
            return false
        }
        return bundleID == "com.google.Chrome"
            || bundleID == "com.google.Chrome.beta"
            || bundleID == "com.google.Chrome.dev"
            || bundleID == "com.google.Chrome.canary"
            || bundleID == "com.microsoft.edgemac"
            || bundleID == "com.brave.Browser"
            || bundleID == "com.vivaldi.Vivaldi"
            || bundleID == "com.operasoftware.Opera"
            || bundleID == "net.imput.helium"
            || bundleID.hasPrefix("org.chromium.")
    }

    func setWindowAlpha(_ alpha: Float, for windowID: UInt32?) {
        guard hideMethod == .skyLightAlpha else {
            return
        }
        SkyLight.shared.setAlpha(alpha, for: windowID)
    }

}
