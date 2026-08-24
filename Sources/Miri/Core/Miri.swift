import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Darwin
import Foundation

final class Miri: NSObject, NSApplicationDelegate, @unchecked Sendable {
    var appPhase: AppPhase = .starting
    var nextCoordinatorSequence: UInt64 = 0
    var coordinatorEventQueue: [SequencedAppEvent] = []
    var isHandlingCoordinatorEvent = false
    var activeCoordinatorSequence: EventSequence?
    var pendingCoordinatorReconciliation: ReconciliationIntent?
    var reconciliationDrainScheduled = false
    var reconciliationDrainGeneration: UInt64 = 0
    var terminationPrepared = false
    let configStore = ConfigStore()
    var config: MiriConfig {
        configStore.effectiveConfig
    }
    var workspaces: [Workspace] = [Workspace()]
    var floatingWindows: [ManagedWindow] = []
    var activeWorkspace: Int = 0
    weak var previousWorkspace: Workspace?
    weak var emptyWorkspaceFocusAuthority: Workspace?
    var logicalSpaceContexts: [LogicalSpaceContext] = [LogicalSpaceContext(id: 0)]
    var activeLogicalSpaceContextID: Int = 0
    var nextLogicalSpaceContextID: Int = 1
    var pendingLogicalSpaceSwitch = false
    var spaceBufferedWindows: [UInt32: BufferedSpaceWindow] = [:]
    var observers: [pid_t: AXObserver] = [:]
    var focusedWindowProbeGeneration: UInt64 = 0
    var minimizedWindowStates: [PersistentWindowIdentity: PersistentWindowState] = [:]
    var fullscreenWindowStates: [PersistentWindowIdentity: FullscreenWindowState] = [:]
    var pendingFullscreenTransitionSince: [ObjectIdentifier: CFAbsoluteTime] = [:]
    var fullscreenTransitionGuardUntil: CFAbsoluteTime = 0
    var fullscreenSpaceChangeGuardUntil: CFAbsoluteTime = 0
    var fullscreenSpaceChangeGuardStartedGeneration: UInt64 = 0
    var fullscreenSpaceChangeGuardWorkspace: Int?
    var spaceChangeGeneration: UInt64 = 0
    var suppressFocusedWindowNotificationsUntil: CFAbsoluteTime = 0
    @MainActor var settingsWindowController: SettingsWindowController?
    var reconciliationTimer: Timer?
    var activeRescanTimer: Timer?
    var appLaunchSettlingTimer: Timer?
    var appLaunchSettlingDeadlines: [pid_t: CFAbsoluteTime] = [:]
    var appLaunchObservedPIDs = Set<pid_t>()
    var appLaunchMissingWindowSince: [pid_t: [ObjectIdentifier: CFAbsoluteTime]] = [:]
    var pendingSessionRecoveryCommands: [Command] = []
    var pendingSessionRecoveryLaunchedPIDs = Set<pid_t>()
    var debugLoggedWindowSignatures = Set<String>()
    var pendingAXCreationSettleGenerations: [pid_t: UInt64] = [:]
    var axCreationSettleGeneration: UInt64 = 0
    var lastAXCreatedPlaceholderProbeAt: [pid_t: CFAbsoluteTime] = [:]
    var transientWindowActive = false
    var lastActivatedApplicationPID: pid_t?
    var pendingFocusCommands: [Command] = []
    var keyboardFocusAuthorityUntil: CFAbsoluteTime = 0
    let floatingWindowLevel = Int32(CGWindowLevelForKey(.floatingWindow))
    var transientWindowStateCheckedAt: CFAbsoluteTime = 0
    var lastHorizontalFocusDirection: Int = 1
    var lastIntelligentResizeWindowID: ObjectIdentifier?
    var lastIntelligentGrowDirection: IntelligentResizeDirection?
    var persistentLayoutSnapshot: PersistentLayoutSnapshot? { persistenceController.layoutSnapshot }
    var needsPersistentLayoutRestore: Bool {
        get { persistenceController.needsLayoutRestore }
        set { persistenceController.needsLayoutRestore = newValue }
    }
    var persistentLogicalSpaceSnapshot: PersistentLogicalSpaceSnapshot? { persistenceController.logicalSpaceSnapshot }
    var needsPersistentLogicalSpaceRestore: Bool {
        get { persistenceController.needsLogicalSpaceRestore }
        set { persistenceController.needsLogicalSpaceRestore = newValue }
    }
    var pendingPersistentLogicalSpaceContexts: [PersistentLogicalSpaceContext] {
        get { persistenceController.pendingLogicalSpaceContexts }
        set { persistenceController.pendingLogicalSpaceContexts = newValue }
    }
    var signalSources: [DispatchSourceSignal] = []

    lazy var persistenceController = PersistenceController(
        configuration: PersistenceConfiguration(config: config)
    ) { [weak self] event in
        self?.enqueue(.persistence(event))
    }

    lazy var layoutController = LayoutController(owner: self) { [weak self] event in
        self?.enqueue(.layout(event))
    }

    lazy var manualResizeController = ManualResizeController(
        sameWindow: { [weak self] lhs, rhs in self?.sameWindow(lhs, rhs) ?? false },
        emitEnded: { [weak self] element in self?.enqueue(.timer(.manualResizeEnded(element: element))) }
    )

    lazy var sessionController = SessionController { [weak self] event in
        self?.enqueue(event)
    }

    lazy var inputController = InputController(
        emit: { [weak self] event in self?.enqueue(event) },
        isAwaitingSessionRecovery: { [weak self] in
            self?.isAwaitingSessionRecoveryInteraction ?? false
        },
        handleRecoveryKey: { [weak self] event, command in
            self?.handleSessionRecoveryKeyEvent(event, command: command) ?? false
        },
        shouldSuppressCommand: { [weak self] in
            self?.transientSystemWindowIsActive() ?? true
        }
    )

    func start() {
        guard requestAccessibilityPermission() else {
            fputs("miri: Accessibility permission is required. Enable it for this binary or Terminal, then run again.\n", stderr)
            exit(1)
        }

        reconcileWorkspaceCapacity()
        observeWorkspace()
        observeSessionState()
        installTerminationHandlers()
        persistenceController.start()
        configureInput()
        installInputBackend()
        installFocusedWindowInputMonitor()
        syncSessionRecoveryInputTracking()
        lastActivatedApplicationPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        appPhase = isLayoutTrackingAllowed ? .running : .sessionUnavailable
        if isLayoutTrackingAllowed {
            requestReconciliation(
                .all(adoptFocused: true, source: .startup, reason: "startup")
            )
        } else {
            print("miri: layout tracking paused because the user session is unavailable")
        }
        scheduleReconciliationTimer()
        syncActiveRescanTimer()

        print("miri: running")
        print("miri: loaded \(inputController.commandCount) keybindings")
        print("miri: Cmd-Tab is passed through and adopted after macOS focuses a window")
    }

    func applicationWillTerminate(_ notification: Notification) {
        enqueue(.terminate(reason: "NSApplicationWillTerminate"))
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
                self?.enqueue(.terminate(reason: "signal-\(sig)"))
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

}
