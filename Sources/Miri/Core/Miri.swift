import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Darwin
import Foundation

final class Miri: NSObject, NSApplicationDelegate, @unchecked Sendable {
    var loadedConfig = MiriConfig.loadWithMetadata()
    var config: MiriConfig {
        loadedConfig.config
    }
    var workspaces: [Workspace] = [Workspace()]
    var floatingWindows: [ManagedWindow] = []
    var activeWorkspace: Int = 0
    weak var previousWorkspace: Workspace?
    var logicalSpaceContexts: [LogicalSpaceContext] = [LogicalSpaceContext(id: 0)]
    var activeLogicalSpaceContextID: Int = 0
    var nextLogicalSpaceContextID: Int = 1
    var pendingLogicalSpaceSwitch = false
    var spaceBufferedWindows: [UInt32: BufferedSpaceWindow] = [:]
    var observers: [pid_t: AXObserver] = [:]
    var eventTap: CFMachPort?
    var eventTapSource: CFRunLoopSource?
    var carbonHotKeys: [EventHotKeyRef] = []
    var carbonEventHandler: EventHandlerRef?
    var carbonCommandByID: [UInt32: Command] = [:]
    var commandByKeybinding: [String: Command] = [:]
    var minimizedWindowStates: [PersistentWindowIdentity: PersistentWindowState] = [:]
    var fullscreenWindowStates: [PersistentWindowIdentity: FullscreenWindowState] = [:]
    var pendingFullscreenTransitionSince: [ObjectIdentifier: CFAbsoluteTime] = [:]
    var fullscreenTransitionGuardUntil: CFAbsoluteTime = 0
    var fullscreenSpaceChangeGuardUntil: CFAbsoluteTime = 0
    var fullscreenSpaceChangeGuardStartedGeneration: UInt64 = 0
    var fullscreenSpaceChangeGuardWorkspace: Int?
    var spaceChangeGeneration: UInt64 = 0
    var appliedFrames: [ObjectIdentifier: CGRect] = [:]
    var appliedVisibility: [ObjectIdentifier: Bool] = [:]
    var hiddenWorkspaceWindowIDs = Set<ObjectIdentifier>()
    var suppressFocusedWindowNotificationsUntil: CFAbsoluteTime = 0
    var snapshotWriteTimer: DispatchSourceTimer?
    var logicalSpaceSnapshotTimer: DispatchSourceTimer?
    @MainActor var settingsWindowController: SettingsWindowController?
    var excludedKeybindingSet = Set<String>()
    var reconciliationTimer: Timer?
    var debugLoggedWindowSignatures = Set<String>()
    var isApplyingLayout = false
    var animationTimer: AnimationTimer?
    var snapshotAnimationSession: SnapshotAnimationSession?
    var snapshotOverlayWindow: SnapshotOverlayWindow?
    var snapshotHiddenWindows: [ManagedWindow] = []
    var snapshotAnimationPreparing = false
    var pendingSnapshotDeferredLayout = false
    var pendingSnapshotDeferredFocusActiveWindow = false
    var pendingSnapshotDeferredLayoutLockDelay: TimeInterval = 0.08
    var pendingAXReconciliationPIDs = Set<pid_t>()
    var pendingAXReconciliationAdoptFocused = false
    var pendingAXReconciliationNeedsFullRescan = false
    var pendingAXReconciliationDrainScheduled = false
    var pendingAXCreationSettleGenerations: [pid_t: UInt64] = [:]
    var axCreationSettleGeneration: UInt64 = 0
    var transientWindowActive = false
    var floatingRaiseGeneration: UInt64 = 0
    var focusRequestGeneration: UInt64 = 0
    var pendingFocusCommands: [Command] = []
    var keyboardFocusAuthorityUntil: CFAbsoluteTime = 0
    var layoutRequestGeneration: UInt64 = 0
    let floatingWindowLevel = Int32(CGWindowLevelForKey(.floatingWindow))
    var transientWindowStateCheckedAt: CFAbsoluteTime = 0
    var manualResizeEndTimer: DispatchSourceTimer?
    var manualResizeElement: AXUIElement?
    var manualResizeSuppressedUntil: CFAbsoluteTime = 0
    var lastHorizontalFocusDirection: Int = 1
    var lastIntelligentResizeWindowID: ObjectIdentifier?
    var lastIntelligentGrowDirection: IntelligentResizeDirection?
    var presentationFrames: [ObjectIdentifier: CGRect] = [:]
    lazy var persistentLayoutSnapshot = readPersistentLayoutSnapshot()
    var needsPersistentLayoutRestore = true
    lazy var persistentLogicalSpaceSnapshot = readPersistentLogicalSpaceSnapshot()
    var needsPersistentLogicalSpaceRestore = true
    var pendingPersistentLogicalSpaceContexts: [PersistentLogicalSpaceContext] = []
    var signalSources: [DispatchSourceSignal] = []
    let restoreStateURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("miri-\(ProcessInfo.processInfo.processIdentifier).restore.json")
    var cleanupWatcher: Process?

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
        installInputBackend()
        rescanWindows(adoptFocused: true)
        scheduleReconciliationTimer()
        schedulePeriodicLogicalSpaceSnapshotWrite()

        print("miri: running")
        print("miri: loaded \(commandByKeybinding.count) keybindings")
        print("miri: Cmd-Tab is passed through and adopted after macOS focuses a window")
    }

    func applicationWillTerminate(_ notification: Notification) {
        snapshotWriteTimer?.cancel()
        logicalSpaceSnapshotTimer?.cancel()
        uninstallEventTap()
        uninstallCarbonHotKeys()
        writePersistentLayoutSnapshot()
        writePersistentLogicalSpaceSnapshot()
        if restoreOnExit {
            restoreManagedWindowsForExit()
        }
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
        center.addObserver(
            self,
            selector: #selector(activeSpaceChanged(_:)),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )
    }

    private func installTerminationHandlers() {
        for sig in [SIGINT, SIGTERM, SIGHUP, SIGQUIT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                self?.snapshotWriteTimer?.cancel()
                self?.logicalSpaceSnapshotTimer?.cancel()
                self?.writePersistentLayoutSnapshot()
                self?.writePersistentLogicalSpaceSnapshot()
                if self?.restoreOnExit == true {
                    self?.restoreManagedWindowsForExit()
                }
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    func startCleanupWatcher() {
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


}
