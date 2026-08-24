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
    lazy var windowManagement = WindowManagement { [weak self] event in
        self?.enqueue(event)
    }
    var workspaces: [Workspace] { windowManagement.workspaces }
    var floatingWindows: [ManagedWindow] { windowManagement.floatingWindows }
    var activeWorkspace: Int { windowManagement.activeWorkspace }
    var previousWorkspace: Workspace? { windowManagement.previousWorkspace }
    var emptyWorkspaceFocusAuthority: Workspace? { windowManagement.emptyWorkspaceFocusAuthority }
    var logicalSpaceContexts: [LogicalSpaceContext] { windowManagement.logicalSpaceContexts }
    var activeLogicalSpaceContextID: Int { windowManagement.activeLogicalSpaceContextID }
    var nextLogicalSpaceContextID: Int { windowManagement.nextLogicalSpaceContextID }
    var pendingLogicalSpaceSwitch: Bool { windowManagement.pendingLogicalSpaceSwitch }
    var spaceBufferedWindows: [UInt32: BufferedSpaceWindow] { windowManagement.spaceBufferedWindows }
    var minimizedWindowStates: [PersistentWindowIdentity: PersistentWindowState] { windowManagement.minimizedWindowStates }
    var fullscreenWindowStates: [PersistentWindowIdentity: FullscreenWindowState] { windowManagement.fullscreenWindowStates }
    var pendingFullscreenTransitionSince: [ObjectIdentifier: CFAbsoluteTime] { windowManagement.pendingFullscreenTransitionSince }
    var fullscreenTransitionGuardUntil: CFAbsoluteTime = 0
    var fullscreenSpaceChangeGuardUntil: CFAbsoluteTime = 0
    var fullscreenSpaceChangeGuardStartedGeneration: UInt64 = 0
    var fullscreenSpaceChangeGuardWorkspace: Int? { windowManagement.fullscreenSpaceChangeGuardWorkspace }
    var spaceChangeGeneration: UInt64 = 0
    var suppressFocusedWindowNotificationsUntil: CFAbsoluteTime = 0
    @MainActor var settingsWindowController: SettingsWindowController?
    var pendingSessionRecoveryCommands: [Command] = []
    var pendingSessionRecoveryLaunchedPIDs = Set<pid_t>()
    var debugLoggedWindowSignatures = Set<String>()
    var lastActivatedApplicationPID: pid_t?
    var pendingFocusCommands: [Command] = []
    var keyboardFocusAuthorityUntil: CFAbsoluteTime = 0
    let floatingWindowLevel = Int32(CGWindowLevelForKey(.floatingWindow))
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
        windowManagement.observation.startWorkspaceObservation()
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
