import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Darwin
import Foundation

@MainActor
final class Miri: NSObject, NSApplicationDelegate {
    var appPhase: AppPhase = .starting
    var nextCoordinatorSequence: UInt64 = 0
    var coordinatorEventQueue: [SequencedAppEvent] = []
    var isHandlingCoordinatorEvent = false
    var activeCoordinatorSequence: EventSequence?
    var pendingCoordinatorReconciliation: ReconciliationIntent?
    var reconciliationDrainScheduled = false
    var reconciliationDrainGeneration: UInt64 = 0
    var fullWindowScanGeneration: UInt64 = 0
    var terminationPrepared = false
    let configStore = ConfigStore()
    lazy var axOperations = AXOperationController { [weak self] message in
        self?.debugLog(message)
    }
    lazy var windowManagement = WindowManagement(axOperations: axOperations) { [weak self] event in
        self?.enqueue(event)
    }
    var fullscreenTransitionGuardUntil: CFAbsoluteTime = 0
    var fullscreenSpaceChangeGuardUntil: CFAbsoluteTime = 0
    var fullscreenSpaceChangeGuardStartedGeneration: UInt64 = 0
    var spaceChangeGeneration: UInt64 = 0
    var suppressFocusedWindowNotificationsUntil: CFAbsoluteTime = 0
    @MainActor var settingsWindowController: SettingsWindowController?
    var pendingSessionRecoveryCommands: [Command] = []
    var pendingSessionRecoveryLaunchedPIDs = Set<pid_t>()
    var sessionPauseQuiescenceGeneration: UInt64 = 0
    var sessionPauseQuiescenceInFlight = false
    var sessionPauseQuiescenceWaiters: [() -> Void] = []
    var sessionRecoveryFocusedValidationPID: pid_t?
    var sessionRecoveryFocusedValidationGeneration: UInt64?
    var sessionRecoveryFocusedValidationWaiters: [(((pid: pid_t, windowID: UInt32?))?) -> Void] = []
    var debugLoggedWindowSignatures = Set<String>()
    var lastActivatedApplicationPID: pid_t?
    var pendingFocusCommands: [Command] = []
    var keyboardFocusAuthorityUntil: CFAbsoluteTime = 0
    let floatingWindowLevel = Int32(CGWindowLevelForKey(.floatingWindow))
    var lastHorizontalFocusDirection: Int = 1
    var lastIntelligentResizeWindowID: ObjectIdentifier?
    var lastIntelligentGrowDirection: IntelligentResizeDirection?
    var activeRescanInputGeneration: UInt64 = 0
    var transientWindowRefreshGeneration: UInt64 = 0
    var transientWindowRefreshInFlight = false
    var transientWindowRefreshPending = false
    var transientWindowRefreshPendingAllowsSessionRecovery = false
    var transientWindowRefreshCompletions: [() -> Void] = []
    var pendingTransientWindowRefreshCompletions: [() -> Void] = []
    var focusStateGeneration: UInt64 = 0
    var lastKnownFocusedElements: [pid_t: AXUIElement] = [:]
    var signalSources: [DispatchSourceSignal] = []

    lazy var persistenceController = PersistenceController(
        configuration: PersistenceConfiguration(config: configStore.effectiveConfig)
    ) { [weak self] event in
        self?.enqueue(.persistence(event))
    }

    lazy var layoutController = LayoutController(
        dependencies: makeLayoutControllerDependencies(),
        axOperations: axOperations
    ) { [weak self] event in
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
            self?.sessionController.isAwaitingRecoveryInteraction ?? false
        },
        handleRecoveryKey: { [weak self] event, command in
            self?.handleSessionRecoveryKeyEvent(event, command: command) ?? false
        },
        shouldSuppressCommand: { [weak self] in
            // Hot-key callbacks must remain constant-time. AX-backed transient
            // detection refreshes asynchronously elsewhere; input consumes only
            // the last admitted environment-guard state.
            self?.windowManagement.observation.transientWindowActive ?? true
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
        if sessionController.isLayoutTrackingAllowed {
            refreshTransientSystemWindowState()
        }
        installTerminationHandlers()
        persistenceController.start()
        inputController.configure(configStore.effectiveConfig)
        inputController.install(backend: keyboardShortcutBackend)
        inputController.installFocusedWindowMonitor()
        syncSessionRecoveryInputTracking()
        lastActivatedApplicationPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        appPhase = sessionController.isLayoutTrackingAllowed ? .running : .sessionUnavailable
        if sessionController.isLayoutTrackingAllowed {
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

    private func makeLayoutControllerDependencies() -> LayoutControllerDependencies {
        LayoutControllerDependencies(
            modelSnapshot: { [unowned self] in windowManagement.snapshot() },
            settings: { [unowned self] in
                LayoutControllerSettings(
                    focusAlignment: focusAlignment,
                    innerGap: innerGap,
                    parkedSliverWidth: parkedSliverWidth,
                    animationStrategy: animationStrategy,
                    debugLogging: debugLogging,
                    snapshotAnimationSpeed: snapshotAnimationSpeed,
                    animationFPS: animationFPS,
                    animationPixelThreshold: animationPixelThreshold,
                    floatingWindowLevel: floatingWindowLevel
                )
            },
            activeWindow: { [unowned self] in activeWindow() },
            widthRatio: { [unowned self] in widthRatio(for: $0) },
            renderedOutsets: { [unowned self] in renderedOutsets(for: $0) },
            screenContaining: { [unowned self] in screenContaining($0) },
            suppressManualResize: { [unowned self] in manualResizeController.suppress(for: $0) },
            isLayoutTrackingAllowed: { [unowned self] in sessionController.isLayoutTrackingAllowed },
            currentViewport: { [unowned self] in currentViewport() },
            parkedSliverPoints: { [unowned self] in parkedSliverPoints(for: $0) },
            location: { [unowned self] in location(of: $0) },
            tiledWindows: { [unowned self] in tiledWindows() },
            debugLog: { [unowned self] in debugLog($0) },
            stripMetrics: { [unowned self] in stripMetrics(for: $0, viewport: $1) },
            maxHorizontalCameraOffset: { [unowned self] in maxHorizontalCameraOffset(for: $0, viewport: $1) },
            visualFrame: { [unowned self] in visualFrame($0, viewport: $1) },
            deferReconciliation: { [unowned self] in
                deferAXReconciliation(pid: $0, adoptFocused: $1, reason: $2)
            },
            setFocusedNotificationSuppressionUntil: { [unowned self] in
                suppressFocusedWindowNotificationsUntil = $0
            },
            notePhysicalFocusTarget: { [unowned self] window in
                lastKnownFocusedElements[window.pid] = window.element
            },
            workspaceProjection: { [unowned self] in windowManagement.workspaceProjection(at: $0) }
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
