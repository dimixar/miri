import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

final class Miri: NSObject, @unchecked Sendable {
    private var loadedConfig = MiriConfig.loadWithMetadata()
    var config: MiriConfig {
        loadedConfig.config
    }
    var workspaces: [Workspace] = [Workspace()]
    var floatingWindows: [ManagedWindow] = []
    var activeWorkspace: Int = 0
    weak var previousWorkspace: Workspace?
    private var observers: [pid_t: AXObserver] = [:]
    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private var commandByKeybinding: [String: Command] = [:]
    private var minimizedWindowStates: [PersistentWindowIdentity: PersistentWindowState] = [:]
    private var fullscreenWindowStates: [PersistentWindowIdentity: FullscreenWindowState] = [:]
    private var appliedFrames: [ObjectIdentifier: CGRect] = [:]
    private var appliedVisibility: [ObjectIdentifier: Bool] = [:]
    private var suppressFocusedWindowNotificationsUntil: CFAbsoluteTime = 0
    var snapshotWriteTimer: DispatchSourceTimer?
    @MainActor private var settingsWindowController: SettingsWindowController?
    private var excludedKeybindingSet = Set<String>()
    private var rescanTimer: Timer?
    var debugLoggedWindowSignatures = Set<String>()
    var isApplyingLayout = false
    var animationTimer: DispatchSourceTimer?
    var hoverFocusTimer: DispatchSourceTimer?
    var hoverFocusTarget: ObjectIdentifier?
    var hoverFocusRequiresRearm = false
    var hoverFocusSuppressedUntil: CFAbsoluteTime = 0
    var transientWindowActive = false
    var transientWindowStateCheckedAt: CFAbsoluteTime = 0
    var trackpadNavigation: ThreeFingerTrackpadNavigation?
    var trackpadCameraY: CGFloat?
    var trackpadCameraVelocity = CGPoint.zero
    var trackpadPendingCameraDelta = CGSize.zero
    var trackpadLatestCameraVelocity = CGPoint.zero
    var trackpadRenderTimer: DispatchSourceTimer?
    var trackpadMomentumTimer: DispatchSourceTimer?
    var trackpadMomentumLastFrameAt: CFAbsoluteTime = 0
    private var manualResizeEndTimer: DispatchSourceTimer?
    var manualResizeElement: AXUIElement?
    private var manualResizeSuppressedUntil: CFAbsoluteTime = 0
    var presentationFrames: [ObjectIdentifier: CGRect] = [:]
    lazy var persistentLayoutSnapshot = readPersistentLayoutSnapshot()
    var needsPersistentLayoutRestore = true
    private var signalSources: [DispatchSourceSignal] = []
    private let restoreStateURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("miri-\(ProcessInfo.processInfo.processIdentifier).restore.json")
    private var cleanupWatcher: Process?

    func start() {
        guard requestAccessibilityPermission() else {
            fputs("miri: Accessibility permission is required. Enable it for this binary or Terminal, then run again.\n", stderr)
            exit(1)
        }

        observeWorkspace()
        installTerminationHandlers()
        if restoreOnExit {
            startCleanupWatcher()
        }
        configureInput()
        installEventTap()
        installTrackpadNavigation()
        rescanWindows(adoptFocused: true)
        scheduleRescanTimer()

        print("miri: running")
        print("miri: loaded \(commandByKeybinding.count) keybindings")
        if trackpadNavigationEnabled {
            if trackpadNavigation != nil {
                print("miri: three-finger trackpad swipe navigates columns/workspaces")
            } else {
                print("miri: three-finger trackpad navigation unavailable; private MultitouchSupport backend did not start")
            }
        }
        print("miri: Cmd-Tab is passed through and adopted after macOS focuses a window")
        if hideMethod == .skyLightAlpha && !SkyLight.shared.canSetAlpha {
            print("miri: SkyLight alpha support unavailable; parked windows will remain as edge slivers")
        }
    }

    func currentConfigForStatusBar() -> MiriConfig {
        config
    }

    func currentWorkspaceBarStatus() -> MiriWorkspaceBarStatus {
        guard workspaces.indices.contains(activeWorkspace) else {
            return MiriWorkspaceBarStatus(workspace: activeWorkspace + 1, focusedIndex: nil, windows: [], occupiedWorkspaces: [])
        }

        let workspace = workspaces[activeWorkspace]
        return MiriWorkspaceBarStatus(
            workspace: activeWorkspace + 1,
            focusedIndex: workspace.columns.isEmpty ? nil : workspace.activeColumn,
            windows: workspace.columns.map(workspaceBarWindow),
            occupiedWorkspaces: occupiedWorkspaceSummaries()
        )
    }

    private func occupiedWorkspaceSummaries() -> [MiriWorkspaceSummary] {
        workspaces.enumerated().compactMap { index, workspace in
            guard !workspace.columns.isEmpty else { return nil }
            let focusedIndex = min(max(workspace.activeColumn, 0), workspace.columns.count - 1)
            let focusedWindow = workspaceBarWindow(workspace.columns[focusedIndex])
            let appNames = Array(NSOrderedSet(array: workspace.columns.map(\.appName))) as? [String] ?? workspace.columns.map(\.appName)
            return MiriWorkspaceSummary(
                workspace: index + 1,
                isActive: index == activeWorkspace,
                lastFocusedWindow: focusedWindow,
                appNames: appNames
            )
        }
    }

    private func workspaceBarWindow(_ window: ManagedWindow) -> MiriWorkspaceBarWindow {
        MiriWorkspaceBarWindow(bundleID: window.bundleID, appName: window.appName, title: window.title)
    }

    func currentStatus() -> MiriStatus {
        let nonEmptyWorkspaceCount = max(1, workspaces.filter { !$0.columns.isEmpty }.count)
        guard let window = activeWindow() else {
            return MiriStatus(
                workspace: activeWorkspace + 1,
                workspaceCount: nonEmptyWorkspaceCount,
                focusedWindow: "None",
                widthPercent: nil
            )
        }

        let title = window.title.isEmpty ? window.appName : "\(window.appName) — \(window.title)"
        return MiriStatus(
            workspace: activeWorkspace + 1,
            workspaceCount: nonEmptyWorkspaceCount,
            focusedWindow: title,
            widthPercent: Int((widthRatio(for: window) * 100).rounded())
        )
    }

    func openConfigFromMenu() {
        if let url = loadedConfig.sourceURL {
            NSWorkspace.shared.open(url)
            return
        }

        let fallbackURL = URL(fileURLWithPath: NSString(string: "~/.config/miri/config.json").expandingTildeInPath)
        NSWorkspace.shared.open(fallbackURL)
    }

    func reloadFromMenu() {
        loadedConfig.sourceModificationDate = nil
        _ = reloadConfigIfNeeded()
    }

    func rescanFromMenu() {
        rescanWindows(adoptFocused: true)
    }

    @MainActor func showSettingsFromMenu() {
        let apps = availableRuleApps()
        if let settingsWindowController {
            settingsWindowController.refresh(config: config, availableApps: apps)
            settingsWindowController.showWindow(nil)
            settingsWindowController.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let controller = SettingsWindowController(miri: self, config: config, availableApps: apps)
        settingsWindowController = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor func saveConfigFromSettings(_ updatedConfig: MiriConfig) {
        let url = loadedConfig.sourceURL ?? URL(fileURLWithPath: NSString(string: "~/.config/miri/config.json").expandingTildeInPath)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(updatedConfig)
            try data.write(to: url, options: [.atomic])
            loadedConfig.sourceModificationDate = nil
            _ = reloadConfigIfNeeded()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not save Miri config"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    private func availableRuleApps() -> [RuleAppInfo] {
        let windowApps = (tiledWindows() + floatingWindows).compactMap { window -> RuleAppInfo? in
            guard let bundleID = window.bundleID, !bundleID.isEmpty else {
                return nil
            }
            return RuleAppInfo(bundleID: bundleID, appName: window.appName)
        }

        let fallbackRunningApps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> RuleAppInfo? in
                guard let bundleID = app.bundleIdentifier, !bundleID.isEmpty else {
                    return nil
                }
                return RuleAppInfo(bundleID: bundleID, appName: app.localizedName ?? bundleID)
            }

        let apps = windowApps.isEmpty ? fallbackRunningApps : windowApps
        var seen = Set<String>()
        return apps.filter { seen.insert($0.bundleID).inserted }.sorted { $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending }
    }

    @MainActor func quitFromMenu() {
        snapshotWriteTimer?.cancel()
        writePersistentLayoutSnapshot()
        if restoreOnExit {
            restoreManagedWindowsForExit()
        }
        NSApp.terminate(nil)
    }

    private func scheduleRescanTimer() {
        rescanTimer?.invalidate()
        rescanTimer = Timer.scheduledTimer(withTimeInterval: rescanInterval, repeats: true) { [weak self] _ in
            self?.handlePeriodicTick()
        }
    }

    private func handlePeriodicTick() {
        guard !reloadConfigIfNeeded() else {
            return
        }
        let wasTransient = transientWindowActive
        guard !transientSystemWindowIsActive(forceRefresh: true) else {
            cancelHoverFocus()
            clearTrackpadCamera()
            return
        }
        rescanWindows(adoptFocused: wasTransient)
    }

    @discardableResult
    func reloadConfigIfNeeded() -> Bool {
        let previousSourceURL = loadedConfig.sourceURL
        let previousModificationDate = loadedConfig.sourceModificationDate

        if let previousSourceURL {
            let currentModificationDate = MiriConfig.modificationDate(for: previousSourceURL)
            guard currentModificationDate != previousModificationDate else {
                return false
            }

            loadedConfig.sourceModificationDate = currentModificationDate
        }

        let previousRescanInterval = rescanInterval
        let previousRestoreOnExit = restoreOnExit
        let previousTrackpadSettings = trackpadNavigationSettings
        let reloaded = MiriConfig.loadWithMetadata(logLoaded: false)

        guard reloaded.sourceURL != nil else {
            if previousSourceURL != nil {
                fputs("miri: config reload skipped; keeping previous config\n", stderr)
            }
            return false
        }

        loadedConfig = reloaded
        configureInput()

        if trackpadNavigationSettings != previousTrackpadSettings {
            restartTrackpadNavigation()
        }
        if rescanInterval != previousRescanInterval {
            scheduleRescanTimer()
        }
        updateCleanupWatcher(previousRestoreOnExit: previousRestoreOnExit)

        let sourcePath = loadedConfig.sourceURL?.path ?? "fallback"
        print("miri: reloaded config \(sourcePath), \(commandByKeybinding.count) keybindings")
        rescanWindows(adoptFocused: false)
        projectLayout(focusActiveWindow: false)
        return true
    }

    private func requestAccessibilityPermission() -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    private func observeWorkspace() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            self,
            selector: #selector(applicationActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(applicationLaunched(_:)),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )
        center.addObserver(
            self,
            selector: #selector(applicationTerminated(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )
    }

    private func installTerminationHandlers() {
        for sig in [SIGINT, SIGTERM, SIGHUP, SIGQUIT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                self?.snapshotWriteTimer?.cancel()
                self?.writePersistentLayoutSnapshot()
                if self?.restoreOnExit == true {
                    self?.restoreManagedWindowsForExit()
                }
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    private func startCleanupWatcher() {
        guard let executableURL = currentExecutableURL() else {
            return
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = [
            "--cleanup-watch",
            "\(ProcessInfo.processInfo.processIdentifier)",
            restoreStateURL.path,
        ]

        if let null = FileHandle(forWritingAtPath: "/dev/null") {
            process.standardOutput = null
            process.standardError = null
        }

        do {
            try process.run()
            cleanupWatcher = process
        } catch {
            fputs("miri: failed to start cleanup watcher: \(error)\n", stderr)
        }
    }

    private func installEventTap() {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.mouseMoved.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: eventTapCallback,
            userInfo: refcon
        ) else {
            fputs("miri: unable to create event tap. Check Accessibility/Input Monitoring permissions.\n", stderr)
            exit(1)
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            fputs("miri: unable to create event tap run loop source.\n", stderr)
            exit(1)
        }

        eventTap = tap
        eventTapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func installTrackpadNavigation() {
        guard trackpadNavigationEnabled else {
            return
        }

        let navigation = ThreeFingerTrackpadNavigation(
            fingers: trackpadNavigationFingers,
            invertX: trackpadNavigationInvertX,
            invertY: trackpadNavigationInvertY
        ) { [weak self] event in
            DispatchQueue.main.async { [weak self] in
                self?.handleTrackpadNavigationEvent(event)
            }
        }

        guard navigation.start() else { return }

        trackpadNavigation = navigation
    }

    func restartTrackpadNavigation() {
        trackpadNavigation?.stop()
        trackpadNavigation = nil
        clearTrackpadCamera()
        installTrackpadNavigation()
    }

    private func updateCleanupWatcher(previousRestoreOnExit: Bool) {
        guard restoreOnExit != previousRestoreOnExit else {
            return
        }

        if restoreOnExit {
            startCleanupWatcher()
        } else {
            cleanupWatcher?.terminate()
            cleanupWatcher = nil
            try? FileManager.default.removeItem(at: restoreStateURL)
        }
    }

    private func configureInput() {
        commandByKeybinding = KeybindingResolver.makeCommandByKeybinding(config: config)
        excludedKeybindingSet = Set((config.excludedKeybindings ?? MiriConfig.fallback.excludedKeybindings ?? [])
            .compactMap(KeybindingResolver.normalizedKeybinding(_:)))
    }

    fileprivate func handleEventTapDisabled(_ type: CGEventType) {
        guard let eventTap else {
            debugLog("event tap disabled by \(type), but tap is nil")
            return
        }
        CGEvent.tapEnable(tap: eventTap, enable: true)
        debugLog("event tap re-enabled after \(type)")
    }

    fileprivate func handleKeyEvent(_ event: CGEvent) -> Bool {
        guard !transientSystemWindowIsActive() else {
            return false
        }

        let modifiers = event.flags

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let keyText = KeybindingResolver.keyboardText(from: event)
        guard !KeybindingResolver.isExcludedKeybinding(
            modifiers: modifiers,
            keyCode: keyCode,
            keyText: keyText,
            excludedKeybindingSet: excludedKeybindingSet
        ) else {
            return false
        }

        guard let command = KeybindingResolver.commandForKeyEvent(
            modifiers: modifiers,
            keyCode: keyCode,
            keyText: keyText,
            commandByKeybinding: commandByKeybinding
        ) else {
            return false
        }

        DispatchQueue.main.async { [weak self] in
            self?.perform(command)
        }
        return true
    }

    @objc private func applicationActivated(_ notification: Notification) {
        guard !isApplyingLayout else {
            return
        }
        guard !transientSystemWindowIsActive(forceRefresh: true) else {
            cancelHoverFocus()
            clearTrackpadCamera()
            return
        }
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            self?.rescanWindows(adoptFocused: false)
            self?.adoptFocusedWindow(pid: app.processIdentifier)
        }
        adoptFocusedWindow(pid: app.processIdentifier)
    }

    @objc private func applicationLaunched(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.rescanWindows(adoptFocused: true)
        }
    }

    @objc private func applicationTerminated(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.rescanWindows(adoptFocused: false)
            self?.projectLayout(focusActiveWindow: false)
        }
    }

    func rescanWindows(adoptFocused: Bool) {
        guard !transientSystemWindowIsActive() else {
            cancelHoverFocus()
            clearTrackpadCamera()
            return
        }

        let discovered = discoverWindows()
        var changed = false

        for window in allWindows() {
            if !discovered.contains(where: { sameWindow($0.element, window.element) }) {
                let runningApp = NSRunningApplication(processIdentifier: window.pid)
                let temporarilyHidden = isHiddenOrMinimizedWindow(window.element)
                    || runningApp?.isHidden == true
                let likelyFullscreenTransition = !temporarilyHidden
                    && runningApp != nil
                    && behavior(for: window) != .ignore

                if isFullscreenWindow(window.element) || likelyFullscreenTransition {
                    rememberFullscreenWindowState(window)
                    removeWindow(window, preferRightFocus: true)
                    changed = true
                    continue
                }
                if behavior(for: window) == .ignore {
                    setWindowAlpha(1, for: window.windowID)
                }
                if temporarilyHidden {
                    rememberMinimizedWindowState(window)
                }
                removeWindow(window, preferRightFocus: temporarilyHidden)
                changed = true
            }
        }

        restoreExitedFullscreenWindows(discovered: discovered)

        for found in discovered {
            if let existing = allWindows().first(where: { sameWindow($0.element, found.element) }) {
                existing.title = found.title
                existing.appName = found.appName
                existing.bundleID = found.bundleID

                let shouldFloat = behavior(for: existing) == .float
                let isFloating = floatingWindows.contains(where: { $0 === existing })
                if shouldFloat != isFloating {
                    removeWindow(existing)
                    if shouldFloat {
                        insertFloatingWindow(existing, applyLayout: false)
                    } else {
                        insertNewWindow(existing, applyLayout: false, focusNewWindow: false)
                    }
                    changed = true
                }
            } else {
                if behavior(for: found) == .float {
                    insertFloatingWindow(found, applyLayout: false)
                } else {
                    restoreMinimizedWindowStateIfAvailable(for: found)
                    insertRestoredWindowNearFocused(found, applyLayout: false)
                }
                changed = true
            }
        }

        let restoredPersistentLayout = applyPersistentLayoutSnapshotIfNeeded()
        ensureTrailingEmptyWorkspace()

        if adoptFocused {
            let adoptedFocusedWindow = adoptFocusedWindow(
                pid: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                applyLayout: false
            )
            let restoredPersistentFocus = adoptedFocusedWindow ? false : restorePersistentFocusedWindow()
            projectLayout(
                focusActiveWindow: restoredPersistentFocus,
                layoutLockDelay: restoredPersistentLayout ? 0.4 : 0.08
            )
        } else if changed || restoredPersistentLayout {
            projectLayout(focusActiveWindow: false, layoutLockDelay: restoredPersistentLayout ? 0.4 : 0.08)
        }
    }

    private func discoverWindows() -> [ManagedWindow] {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        var windows: [ManagedWindow] = []

        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular, !app.isHidden else {
                continue
            }
            let pid = app.processIdentifier
            guard pid != currentPID else {
                continue
            }

            startObservingApp(pid: pid)

            let appElement = AXUIElementCreateApplication(pid)
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value)
            guard error == .success, let axWindows = value as? [AXUIElement] else {
                continue
            }

            for element in axWindows {
                if debugLogging, isChromiumBrowser(app) {
                    logRawAXWindowIfNeeded(element, app: app, source: "scan")
                }
                guard !isUnknownSubroleWindow(element),
                      !isHiddenOrMinimizedWindow(element),
                      !isFullscreenWindow(element),
                      isManageableWindow(element) || isKnownWindow(element) || isRememberedFullscreenWindow(element)
                else {
                    continue
                }
                let title = axString(element, kAXTitleAttribute) ?? ""
                let appName = app.localizedName ?? "pid \(pid)"
                let windowID = SkyLight.shared.windowID(for: element)
                let window = ManagedWindow(
                    element: element,
                    pid: pid,
                    windowID: windowID,
                    bundleID: app.bundleIdentifier,
                    appName: appName,
                    title: title
                )
                if !isKnownWindow(element), isLikelyTransientPopup(window, app: app) {
                    logTransientPopupIfNeeded(window, app: app)
                    setWindowAlpha(1, for: window.windowID)
                    continue
                }
                if !isKnownWindow(element), isPictureInPictureWindow(window) {
                    logIgnoredPictureInPictureIfNeeded(window, app: app)
                    setWindowAlpha(1, for: window.windowID)
                    continue
                }
                logDiscoveredWindowIfNeeded(window, app: app)
                guard behavior(for: window) != .ignore else {
                    setWindowAlpha(1, for: window.windowID)
                    continue
                }
                windows.append(window)
            }
        }

        return windows
    }

    private func isHiddenOrMinimizedWindow(_ element: AXUIElement) -> Bool {
        axBool(element, kAXMinimizedAttribute) == true
    }

    private func isFullscreenWindow(_ element: AXUIElement) -> Bool {
        axBool(element, "AXFullScreen") == true
    }

    private func isRememberedFullscreenWindow(_ element: AXUIElement) -> Bool {
        fullscreenWindowStates.values.contains { sameWindow($0.element, element) }
    }

    private func isLikelyFullscreenFrame(_ element: AXUIElement) -> Bool {
        guard let frame = axFrame(element) else {
            return false
        }

        for screen in NSScreen.screens {
            let screenFrame = screen.frame
            let widthMatches = abs(frame.width - screenFrame.width) <= 4
            let heightMatches = abs(frame.height - screenFrame.height) <= 4
            let originMatches = abs(frame.minX - screenFrame.minX) <= 4 && abs(frame.minY - screenFrame.minY) <= 4
            if widthMatches && heightMatches && originMatches {
                return true
            }
        }

        let viewport = currentViewport()
        return frame.width >= viewport.width * 1.2 || frame.height >= viewport.height * 1.2
    }

    func isManageableWindow(_ element: AXUIElement) -> Bool {
        guard axString(element, kAXRoleAttribute) == kAXWindowRole else {
            return false
        }

        let subrole = axString(element, kAXSubroleAttribute)
        if let subrole, subrole != kAXStandardWindowSubrole {
            return false
        }

        if subrole == "AXUnknown" {
            return false
        }

        if axBool(element, kAXMinimizedAttribute) == true {
            return false
        }

        guard let frame = axFrame(element), frame.width >= 120, frame.height >= 80 else {
            return false
        }

        var positionSettable = DarwinBoolean(false)
        var sizeSettable = DarwinBoolean(false)
        let positionError = AXUIElementIsAttributeSettable(element, kAXPositionAttribute as CFString, &positionSettable)
        let sizeError = AXUIElementIsAttributeSettable(element, kAXSizeAttribute as CFString, &sizeSettable)
        return positionError == .success && sizeError == .success && positionSettable.boolValue && sizeSettable.boolValue
    }

    private func isUnknownSubroleWindow(_ element: AXUIElement) -> Bool {
        axString(element, kAXSubroleAttribute) == "AXUnknown"
    }

    func isKnownWindow(_ element: AXUIElement) -> Bool {
        allWindows().contains { sameWindow($0.element, element) }
    }

    private func insertNewWindow(_ window: ManagedWindow, applyLayout: Bool = true, focusNewWindow: Bool = true) {
        let workspace = targetWorkspace(for: window)
        workspace.clampFocus()

        let insertionIndex = newWindowInsertionIndex(in: workspace, for: window)
        insertWindow(window, in: workspace, at: insertionIndex, applyLayout: applyLayout, focusNewWindow: focusNewWindow)
    }

    private func insertRestoredWindowNearFocused(_ window: ManagedWindow, applyLayout: Bool = true) {
        let workspace = activeWorkspaceObject() ?? targetWorkspace(for: window)
        workspace.clampFocus()
        let insertionIndex = workspace.columns.isEmpty ? 0 : min(workspace.activeColumn + 1, workspace.columns.count)
        insertWindow(window, in: workspace, at: insertionIndex, applyLayout: applyLayout, focusNewWindow: false)
    }

    private func insertWindow(
        _ window: ManagedWindow,
        in workspace: Workspace,
        at insertionIndex: Int,
        applyLayout: Bool,
        focusNewWindow: Bool
    ) {
        let index = min(max(insertionIndex, 0), workspace.columns.count)
        workspace.columns.insert(window, at: index)
        if focusNewWindow {
            workspace.activeColumn = index
        } else if workspace.columns.count > 1, workspace.activeColumn >= index {
            workspace.activeColumn += 1
        }
        workspace.scrollOffset = nil
        if focusNewWindow, let workspaceIndex = workspaces.firstIndex(where: { $0 === workspace }) {
            setActiveWorkspace(workspaceIndex, rememberPrevious: false)
        }
        ensureTrailingEmptyWorkspace()
        if applyLayout {
            projectLayout(focusActiveWindow: focusNewWindow)
        }
    }

    private func targetWorkspace(for window: ManagedWindow) -> Workspace {
        if let oneBased = rule(for: window)?.workspace {
            let index = max(0, oneBased - 1)
            ensureWorkspaceExists(index)
            return workspaces[index]
        }

        return activeWorkspaceObject() ?? workspaces[0]
    }

    private func ensureWorkspaceExists(_ index: Int) {
        while workspaces.count <= index {
            workspaces.append(Workspace())
        }
    }

    private func newWindowInsertionIndex(in workspace: Workspace, for window: ManagedWindow) -> Int {
        guard !workspace.columns.isEmpty else {
            return 0
        }

        switch rule(for: window)?.openPosition ?? newWindowPosition {
        case .beforeActive:
            return min(max(workspace.activeColumn, 0), workspace.columns.count)
        case .afterActive:
            return min(max(workspace.activeColumn + 1, 0), workspace.columns.count)
        case .end:
            return workspace.columns.count
        }
    }

    private func insertFloatingWindow(_ window: ManagedWindow, applyLayout: Bool = true) {
        if !floatingWindows.contains(where: { $0 === window }) {
            floatingWindows.append(window)
        }
        if applyLayout {
            projectLayout(focusActiveWindow: false)
        }
    }

    private func removeWindow(_ window: ManagedWindow, preferRightFocus: Bool = false) {
        let id = ObjectIdentifier(window)
        appliedFrames.removeValue(forKey: id)
        appliedVisibility.removeValue(forKey: id)
        if let index = floatingWindows.firstIndex(where: { $0 === window }) {
            floatingWindows.remove(at: index)
            return
        }

        for workspace in workspaces {
            if let index = workspace.columns.firstIndex(where: { $0 === window }) {
                let wasActive = workspace.activeColumn == index
                workspace.columns.remove(at: index)
                if wasActive && preferRightFocus {
                    workspace.activeColumn = min(index, max(0, workspace.columns.count - 1))
                } else if workspace.activeColumn >= index {
                    workspace.activeColumn = max(0, workspace.activeColumn - 1)
                }
                workspace.scrollOffset = nil
                workspace.clampFocus()
                break
            }
        }
        ensureTrailingEmptyWorkspace()
    }

    private func rememberFullscreenWindowState(_ window: ManagedWindow) {
        guard let location = tiledWindowLocation(for: window.element) else {
            return
        }
        let workspace = location.workspace
        let leftWindow = location.columnIndex > 0 ? workspace.columns[location.columnIndex - 1] : nil
        let rightWindow = location.columnIndex + 1 < workspace.columns.count ? workspace.columns[location.columnIndex + 1] : nil
        let left = leftWindow.map(persistentIdentity(for:))
        let right = rightWindow.map(persistentIdentity(for:))
        let identity = persistentIdentity(for: window)
        fullscreenWindowStates[identity] = FullscreenWindowState(
            identity: identity,
            element: window.element,
            pid: window.pid,
            windowID: window.windowID,
            bundleID: window.bundleID,
            appName: window.appName,
            title: window.title,
            workspace: location.workspaceIndex,
            column: location.columnIndex,
            leftNeighborID: leftWindow.map(ObjectIdentifier.init),
            rightNeighborID: rightWindow.map(ObjectIdentifier.init),
            leftNeighbor: left,
            rightNeighbor: right,
            widthRatio: widthRatio(for: window),
            wasActive: activeWorkspace == location.workspaceIndex && workspace.activeColumn == location.columnIndex
        )
    }

    private func restoreExitedFullscreenWindows(discovered: [ManagedWindow]) {
        for found in discovered {
            guard let match = fullscreenWindowStates.first(where: { sameWindow($0.value.element, found.element) || persistentIdentity(for: found) == $0.key }) else {
                continue
            }
            fullscreenWindowStates.removeValue(forKey: match.key)
            found.manualWidthRatio = match.value.widthRatio
            insertRestoredFullscreenWindow(found, state: match.value)
        }
    }

    private func insertRestoredFullscreenWindow(_ window: ManagedWindow, state: FullscreenWindowState) {
        while workspaces.count <= state.workspace {
            workspaces.append(Workspace())
        }
        let workspace = workspaces[min(max(state.workspace, 0), workspaces.count - 1)]
        let index = restoredFullscreenInsertionIndex(in: workspace, state: state)
        insertWindow(window, in: workspace, at: index, applyLayout: false, focusNewWindow: state.wasActive)
    }

    private func restoredFullscreenInsertionIndex(in workspace: Workspace, state: FullscreenWindowState) -> Int {
        let leftIndex = neighborIndex(id: state.leftNeighborID, identity: state.leftNeighbor, in: workspace)
        let rightIndex = neighborIndex(id: state.rightNeighborID, identity: state.rightNeighbor, in: workspace)
        if let leftIndex, let rightIndex, leftIndex < rightIndex {
            return rightIndex
        }
        if let leftIndex {
            return min(leftIndex + 1, workspace.columns.count)
        }
        if let rightIndex, state.leftNeighbor == nil {
            return rightIndex
        }
        if let rightIndex, rightIndex > 0 {
            return rightIndex
        }
        return workspace.columns.count
    }

    private func neighborIndex(id: ObjectIdentifier?, identity: PersistentWindowIdentity?, in workspace: Workspace) -> Int? {
        if let id,
           let index = workspace.columns.firstIndex(where: { ObjectIdentifier($0) == id }) {
            return index
        }
        guard let identity else {
            return nil
        }
        if let exact = workspace.columns.firstIndex(where: { persistentIdentity(for: $0) == identity }) {
            return exact
        }
        if let bundleID = identity.bundleID,
           let bundle = workspace.columns.firstIndex(where: { $0.bundleID == bundleID }) {
            return bundle
        }
        return workspace.columns.firstIndex { $0.appName.caseInsensitiveCompare(identity.appName) == .orderedSame }
    }

    private func rememberMinimizedWindowState(_ window: ManagedWindow) {
        guard let location = tiledWindowLocation(for: window.element) else {
            return
        }
        minimizedWindowStates[persistentIdentity(for: window)] = PersistentWindowState(
            identity: persistentIdentity(for: window),
            workspace: location.workspaceIndex,
            column: location.columnIndex,
            manualWidthRatio: widthRatio(for: window)
        )
    }

    private func restoreMinimizedWindowStateIfAvailable(for window: ManagedWindow) {
        let identity = persistentIdentity(for: window)
        guard let state = minimizedWindowStates.removeValue(forKey: identity) else {
            return
        }
        window.manualWidthRatio = state.manualWidthRatio
    }

    func ensureTrailingEmptyWorkspace() {
        if workspaces.isEmpty {
            workspaces = [Workspace()]
            activeWorkspace = 0
            previousWorkspace = nil
            return
        }

        if !workspaces.last!.isEmpty {
            workspaces.append(Workspace())
        }

        if workspaces.count > 1 {
            var index = workspaces.count - 2
            while index >= 0 {
                if index != activeWorkspace && workspaces[index].isEmpty {
                    workspaces.remove(at: index)
                    if activeWorkspace > index {
                        activeWorkspace -= 1
                    }
                }
                if index == 0 {
                    break
                }
                index -= 1
            }
        }

        activeWorkspace = min(max(activeWorkspace, 0), workspaces.count - 1)
        for workspace in workspaces {
            workspace.clampFocus()
        }
    }

    func projectLayout(
        focusActiveWindow: Bool,
        animated: Bool = false,
        from previousState: LayoutState? = nil,
        animationDuration: TimeInterval? = nil,
        layoutLockDelay: TimeInterval = 0.08,
        animatedWindowIDs: Set<ObjectIdentifier>? = nil,
        resizingWindowID: ObjectIdentifier? = nil
    ) {
        let viewport = currentViewport()

        let targetState = captureLayoutState()
        debugLog("layout workspace=\(targetState.activeWorkspace + 1) tiled=\(tiledWindows().count) floating=\(floatingWindows.count) animated=\(animated)")
        let duration = animationDuration ?? self.animationDuration
        suppressManualResizeNotifications(for: (animated ? duration : 0) + max(layoutLockDelay, 0.25))
        if animated, duration > 0, let previousState {
            animateLayout(
                from: previousState,
                to: targetState,
                viewport: viewport,
                focusActiveWindow: focusActiveWindow,
                duration: duration,
                animatedWindowIDs: animatedWindowIDs,
                resizingWindowID: resizingWindowID
            )
            return
        }

        stopAnimation(clearPresentation: true)
        isApplyingLayout = true
        let layout = layoutItems(viewport: viewport, state: targetState, parkHidden: true)
        applyLayout(layout, focusActiveWindow: focusActiveWindow)
        restoreFloatingVisibility()
        releaseLayoutLock(after: layoutLockDelay)
    }

    func layoutItems(viewport: CGRect, state: LayoutState, parkHidden: Bool) -> [LayoutItem] {
        let stateActiveWorkspace = min(max(state.activeWorkspace, 0), max(workspaces.count - 1, 0))
        let cameraY = state.cameraY ?? CGFloat(stateActiveWorkspace) * viewport.height
        let cameraWorkspace = trackpadCameraWorkspaceIndex(cameraY: cameraY, viewport: viewport)
        var layout: [LayoutItem] = []

        for (workspaceIndex, workspace) in workspaces.enumerated() {
            let activeColumn = activeColumn(in: workspace, workspaceIndex: workspaceIndex, state: state)
            let scrollOffset = scrollOffset(in: workspace, workspaceIndex: workspaceIndex, state: state)
            let strip = stripFrames(
                for: workspace,
                viewport: viewport,
                activeColumn: activeColumn,
                scrollOffset: scrollOffset
            )
            let rowOffset = CGFloat(workspaceIndex) * viewport.height - cameraY

            for (columnIndex, window) in workspace.columns.enumerated() {
                let frame: CGRect
                var projected = strip[columnIndex]
                projected.origin.y += rowOffset
                projected = visualFrame(projected, viewport: viewport)

                let visible = projected.intersects(viewport)
                if visible || !parkHidden {
                    frame = projected
                } else if workspaceIndex == cameraWorkspace {
                    frame = parkedFrame(for: window, viewport: viewport, beforeActive: columnIndex < activeColumn)
                } else {
                    frame = parkedFrame(
                        for: window,
                        viewport: viewport,
                        beforeActive: CGFloat(workspaceIndex) * viewport.height < cameraY
                    )
                }

                layout.append(LayoutItem(window: window, frame: frame, visible: visible))
            }
        }

        return layout
    }

    func activeColumn(in workspace: Workspace, workspaceIndex: Int, state: LayoutState) -> Int {
        let activeColumn = state.activeColumns.indices.contains(workspaceIndex)
            ? state.activeColumns[workspaceIndex]
            : workspace.activeColumn

        guard !workspace.columns.isEmpty else {
            return 0
        }

        return min(max(activeColumn, 0), workspace.columns.count - 1)
    }

    private func scrollOffset(in workspace: Workspace, workspaceIndex: Int, state: LayoutState) -> CGFloat? {
        if state.scrollOffsets.indices.contains(workspaceIndex) {
            return state.scrollOffsets[workspaceIndex]
        }
        return workspace.scrollOffset
    }

    func trackpadCameraWorkspaceIndex(cameraY: CGFloat, viewport: CGRect) -> Int {
        guard viewport.height > 0, !workspaces.isEmpty else {
            return 0
        }

        return min(max(Int(round(cameraY / viewport.height)), 0), workspaces.count - 1)
    }

    func applyLayout(_ layout: [LayoutItem], focusActiveWindow: Bool) {
        if focusActiveWindow, let activeWindow = self.activeWindow() {
            let inactiveVisible = layout.filter { $0.visible && $0.window !== activeWindow }
            for item in inactiveVisible {
                applyLayoutItem(item)
            }

            if let activeItem = layout.first(where: { $0.window === activeWindow }) {
                applyLayoutItem(activeItem, forceFrame: true)
            }
        } else {
            for item in layout where item.visible {
                applyLayoutItem(item)
            }
        }

        for item in layout where !item.visible {
            applyLayoutItem(item)
        }

        if focusActiveWindow, let activeWindow = self.activeWindow() {
            focus(activeWindow)
        }
    }

    private func applyLayoutItem(_ item: LayoutItem, forceFrame: Bool = false) {
        let id = ObjectIdentifier(item.window)
        let wasVisible = appliedVisibility[id]
        let previousFrame = appliedFrames[id]
        let shouldApplyFrame = forceFrame
            || item.visible
            || wasVisible != false
            || previousFrame.map { frameDelta(from: $0, to: item.frame) >= animationPixelThreshold } ?? true

        if shouldApplyFrame {
            setAXFrame(item.frame, for: item.window.element)
            appliedFrames[id] = item.frame
        }

        if wasVisible != item.visible {
            setWindowAlpha(item.visible ? 1 : 0, for: item.window.windowID)
            appliedVisibility[id] = item.visible
        }
    }

    func restoreFloatingVisibility() {
        for window in floatingWindows {
            setWindowAlpha(1, for: window.windowID)
        }
    }

    func focus(_ window: ManagedWindow) {
        setWindowAlpha(1, for: window.windowID)
        suppressFocusedWindowNotificationsUntil = CFAbsoluteTimeGetCurrent() + 0.2
        if let app = NSRunningApplication(processIdentifier: window.pid) {
            app.activate(options: [.activateIgnoringOtherApps])
        }
        AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    }

    private func restoreManagedWindowsForExit() {
        guard restoreOnExit else {
            return
        }

        let viewport = currentViewport()
        for window in tiledWindows() {
            setWindowAlpha(1, for: window.windowID)
            setAXFrame(viewport, for: window.element)
        }
        restoreFloatingVisibility()
        try? FileManager.default.removeItem(at: restoreStateURL)
    }

    private func writeRestoreSnapshot(viewport: CGRect) {
        guard restoreOnExit else {
            try? FileManager.default.removeItem(at: restoreStateURL)
            return
        }

        let ids = Array(Set(tiledWindows().compactMap(\.windowID))).sorted()
        guard !ids.isEmpty else {
            try? FileManager.default.removeItem(at: restoreStateURL)
            return
        }

        let snapshot = RestoreSnapshot(windowIDs: ids, viewport: RectSnapshot(viewport))
        guard let data = try? JSONEncoder().encode(snapshot) else {
            return
        }

        try? data.write(to: restoreStateURL, options: [.atomic])
    }

    private func handleFullscreenTransitionIfNeeded(_ element: AXUIElement) -> Bool {
        if (isFullscreenWindow(element) || isLikelyFullscreenFrame(element)), let location = tiledWindowLocation(for: element) {
            rememberFullscreenWindowState(location.window)
            removeWindow(location.window, preferRightFocus: true)
            projectLayout(focusActiveWindow: location.workspace.columns.isEmpty ? false : true, layoutLockDelay: 0.02)
            schedulePersistentLayoutSnapshotWrite()
            return true
        }

        if !isFullscreenWindow(element), !isLikelyFullscreenFrame(element), isRememberedFullscreenWindow(element) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                self?.rescanWindows(adoptFocused: true)
            }
            return true
        }

        return false
    }

    private func removeDestroyedWindowImmediately(_ element: AXUIElement) -> Bool {
        if let location = tiledWindowLocation(for: element) {
            let wasActiveWorkspace = activeWorkspace == location.workspaceIndex
            let wasActiveWindow = wasActiveWorkspace && location.workspace.activeColumn == location.columnIndex
            removeWindow(location.window, preferRightFocus: true)
            if wasActiveWindow {
                projectLayout(focusActiveWindow: true, layoutLockDelay: 0.02)
            } else {
                projectLayout(focusActiveWindow: false, layoutLockDelay: 0.02)
            }
            return true
        }

        if let window = floatingWindows.first(where: { sameWindow($0.element, element) }) {
            removeWindow(window)
            projectLayout(focusActiveWindow: false, layoutLockDelay: 0.02)
            return true
        }

        return false
    }

    private func updateManualWidthRatio(for element: AXUIElement) -> Bool {
        guard !isFullscreenWindow(element),
              !isLikelyFullscreenFrame(element),
              let location = tiledWindowLocation(for: element),
              let frame = axFrame(element)
        else {
            return false
        }

        let viewport = currentViewport()
        guard viewport.width > 0 else {
            return false
        }

        let ratio = (frame.width / viewport.width).clampedManualWidthRatio
        let previousRatio = location.window.manualWidthRatio
        let oldScrollOffset = location.workspace.scrollOffset
        location.window.manualWidthRatio = ratio

        let metrics = stripMetrics(for: location.workspace, viewport: viewport)
        let virtualOrigin = metrics.origins[location.columnIndex]
        let newScrollOffset = virtualOrigin - (frame.minX - viewport.minX)

        location.workspace.scrollOffset = newScrollOffset
        setActiveWorkspace(location.workspaceIndex)
        location.workspace.activeColumn = location.columnIndex
        presentationFrames[ObjectIdentifier(location.window)] = frame

        if let previousRatio,
           abs(previousRatio - ratio) < 0.005,
           let oldScrollOffset,
           abs(oldScrollOffset - newScrollOffset) < 0.5
        {
            return false
        }

        return true
    }

    private func beginOrContinueManualResize(for element: AXUIElement) {
        cancelHoverFocus()
        guard !isFullscreenWindow(element), !isLikelyFullscreenFrame(element) else {
            _ = handleFullscreenTransitionIfNeeded(element)
            return
        }
        guard tiledWindow(for: element) != nil else {
            restoreFloatingVisibility()
            return
        }

        if let manualResizeElement, !sameWindow(manualResizeElement, element) {
            return
        }

        manualResizeElement = element
        manualResizeEndTimer?.cancel()
        stopAnimation(clearPresentation: false)

        if updateManualWidthRatio(for: element) {
            schedulePersistentLayoutSnapshotWrite()
            projectLayout(focusActiveWindow: false, layoutLockDelay: 0)
        }

        scheduleManualResizeEnd(for: element)
    }

    private var manualResizeNotificationsSuppressed: Bool {
        CFAbsoluteTimeGetCurrent() < manualResizeSuppressedUntil
    }

    private func suppressManualResizeNotifications(for duration: TimeInterval) {
        guard duration > 0 else {
            return
        }
        manualResizeSuppressedUntil = max(manualResizeSuppressedUntil, CFAbsoluteTimeGetCurrent() + duration)
    }

    private func scheduleManualResizeEnd(for element: AXUIElement) {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(140), leeway: .milliseconds(20))
        timer.setEventHandler { [weak self] in
            guard let self else {
                return
            }

            manualResizeEndTimer?.cancel()
            manualResizeEndTimer = nil

            if manualResizeElement.map({ sameWindow($0, element) }) == true {
                if updateManualWidthRatio(for: element) {
                    schedulePersistentLayoutSnapshotWrite()
                }
                projectLayout(focusActiveWindow: false, layoutLockDelay: 0.02)
                manualResizeElement = nil
            }
        }

        manualResizeEndTimer = timer
        timer.resume()
    }

    private func isManualResizeElement(_ element: AXUIElement) -> Bool {
        manualResizeElement.map { sameWindow($0, element) } ?? false
    }

    private func frameWidthDiffersFromLayout(for element: AXUIElement) -> Bool {
        guard let window = tiledWindow(for: element),
              let frame = axFrame(element)
        else {
            return false
        }

        let viewport = currentViewport()
        guard viewport.width > 0 else {
            return false
        }

        let frameRatio = (frame.width / viewport.width).clampedManualWidthRatio
        return abs(frameRatio - widthRatio(for: window)) >= 0.005
    }

    @discardableResult
    private func adoptFocusedWindow(pid: pid_t?, applyLayout: Bool = true) -> Bool {
        guard let pid else {
            return false
        }

        let appElement = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &value)
        guard error == .success, let focused = value else {
            return false
        }

        let focusedElement = focused as! AXUIElement
        if floatingWindows.contains(where: { sameWindow($0.element, focusedElement) }) {
            if applyLayout {
                projectLayout(focusActiveWindow: false)
            }
            return true
        }

        if let loc = location(of: focusedElement) {
            clearTrackpadCamera()
            let workspace = workspaces[loc.workspace]
            let changedFocus = activeWorkspace != loc.workspace || workspace.activeColumn != loc.column
            setActiveWorkspace(loc.workspace)
            workspace.activeColumn = loc.column
            if changedFocus {
                revealActiveColumnIfNeeded(in: workspace, viewport: currentViewport())
            }
            if applyLayout {
                projectLayout(focusActiveWindow: false)
            }
            return true
        }

        return false
    }

    private func startObservingApp(pid: pid_t) {
        guard observers[pid] == nil else {
            return
        }

        let appElement = AXUIElementCreateApplication(pid)
        var observer: AXObserver?
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard AXObserverCreate(pid, axObserverCallback, &observer) == .success, let observer else {
            return
        }

        let notifications = [
            kAXCreatedNotification,
            kAXFocusedWindowChangedNotification,
            kAXUIElementDestroyedNotification,
            kAXWindowMovedNotification,
            kAXWindowResizedNotification,
            kAXWindowMiniaturizedNotification,
            kAXWindowDeminiaturizedNotification,
            kAXApplicationHiddenNotification,
            kAXApplicationShownNotification,
        ]

        for notification in notifications {
            AXObserverAddNotification(observer, appElement, notification as CFString, refcon)
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        observers[pid] = observer
    }

    fileprivate func handleAXNotification(_ name: String, element: AXUIElement) {
        logAXNotification(name, element: element)
        if transientSystemWindowIsActive(forceRefresh: true) {
            cancelHoverFocus()
            clearTrackpadCamera()
            return
        }

        switch name {
        case kAXFocusedWindowChangedNotification:
            guard CFAbsoluteTimeGetCurrent() >= suppressFocusedWindowNotificationsUntil else {
                return
            }
            var pid: pid_t = 0
            AXUIElementGetPid(element, &pid)
            adoptFocusedWindow(pid: pid)
        case kAXUIElementDestroyedNotification:
            if removeDestroyedWindowImmediately(element) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                    self?.rescanWindows(adoptFocused: false)
                }
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                    self?.rescanWindows(adoptFocused: true)
                }
            }
        case kAXCreatedNotification,
             kAXWindowMiniaturizedNotification,
             kAXWindowDeminiaturizedNotification,
             kAXApplicationHiddenNotification,
             kAXApplicationShownNotification:
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                self?.rescanWindows(adoptFocused: true)
            }
        case kAXWindowResizedNotification:
            if handleFullscreenTransitionIfNeeded(element) {
                return
            }
            guard tiledWindow(for: element) != nil else {
                restoreFloatingVisibility()
                return
            }
            guard !manualResizeNotificationsSuppressed else {
                return
            }

            if manualResizeElement != nil {
                guard isManualResizeElement(element) else {
                    return
                }
                beginOrContinueManualResize(for: element)
            } else if !isApplyingLayout {
                beginOrContinueManualResize(for: element)
            }
        case kAXWindowMovedNotification:
            if handleFullscreenTransitionIfNeeded(element) {
                return
            }
            if manualResizeNotificationsSuppressed, tiledWindow(for: element) != nil {
                return
            }

            if manualResizeElement != nil {
                guard isManualResizeElement(element) else {
                    return
                }
                beginOrContinueManualResize(for: element)
            } else if !isApplyingLayout {
                guard let window = tiledWindow(for: element) else {
                    restoreFloatingVisibility()
                    return
                }
                if frameWidthDiffersFromLayout(for: element) {
                    beginOrContinueManualResize(for: element)
                    return
                }
                if let frame = axFrame(element) {
                    presentationFrames[ObjectIdentifier(window)] = frame
                }
                projectLayout(focusActiveWindow: false)
            }
        default:
            break
        }
    }

}

private func eventTapCallback(
    _ proxy: CGEventTapProxy,
    _ type: CGEventType,
    _ event: CGEvent,
    _ refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else {
        return Unmanaged.passUnretained(event)
    }

    let app = Unmanaged<Miri>.fromOpaque(refcon).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        app.handleEventTapDisabled(type)
        return Unmanaged.passUnretained(event)
    }

    guard type == .keyDown || type == .mouseMoved else {
        return Unmanaged.passUnretained(event)
    }

    if type == .mouseMoved {
        app.handleMouseMoved(event)
        return Unmanaged.passUnretained(event)
    }

    if app.handleKeyEvent(event) {
        return nil
    }
    return Unmanaged.passUnretained(event)
}

private func axObserverCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else {
        return
    }

    let app = Unmanaged<Miri>.fromOpaque(refcon).takeUnretainedValue()
    app.handleAXNotification(notification as String, element: element)
}
