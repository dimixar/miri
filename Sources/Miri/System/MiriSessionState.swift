import AppKit
import CoreGraphics
import Foundation
import IOKit

extension Miri {
    var isSessionAvailable: Bool {
        sessionController.isAvailable
    }

    var isLayoutTrackingAllowed: Bool {
        sessionController.isLayoutTrackingAllowed
    }

    var isScreenLocked: Bool {
        get { sessionController.isScreenLocked }
        set { sessionController.isScreenLocked = newValue }
    }

    var isWorkspaceSessionActive: Bool {
        get { sessionController.isWorkspaceSessionActive }
        set { sessionController.isWorkspaceSessionActive = newValue }
    }

    var isSystemSleeping: Bool {
        get { sessionController.isSystemSleeping }
        set { sessionController.isSystemSleeping = newValue }
    }

    var isAwaitingSessionRecoveryInteraction: Bool {
        get { sessionController.isAwaitingRecoveryInteraction }
        set { sessionController.isAwaitingRecoveryInteraction = newValue }
    }

    var isSessionRecoveryResumeScheduled: Bool {
        get { sessionController.isRecoveryResumeScheduled }
        set { sessionController.isRecoveryResumeScheduled = newValue }
    }

    var sessionResumeGeneration: UInt64 {
        get { sessionController.resumeGeneration }
        set { sessionController.resumeGeneration = newValue }
    }

    func observeSessionState() {
        let locked = currentConsoleLockState()
        if locked == nil {
            debugLog("session state initial lock state unavailable; assuming unlocked")
        }

        let workspaceActive: Bool?
        if let session = CGSessionCopyCurrentDictionary() as? [String: Any],
           let onConsole = session[kCGSessionOnConsoleKey as String] as? Bool
        {
            workspaceActive = onConsole
        } else {
            workspaceActive = nil
            debugLog("session state initial console ownership unavailable; assuming active")
        }
        sessionController.start(initialLocked: locked, initialWorkspaceActive: workspaceActive)

        logSessionState(
            "session monitor locked=\(isScreenLocked) active=\(isWorkspaceSessionActive) sleeping=\(isSystemSleeping) awaitingInteraction=\(isAwaitingSessionRecoveryInteraction) tracking=\(isLayoutTrackingAllowed)"
        )
    }

    func updateSessionStateImplementation(
        screenLocked: Bool? = nil,
        workspaceActive: Bool? = nil,
        systemSleeping: Bool? = nil,
        reason: String
    ) {
        let transition = sessionController.apply(
            screenLocked: screenLocked,
            workspaceActive: workspaceActive,
            systemSleeping: systemSleeping
        )
        guard transition.changed else { return }

        if transition.wasAvailable, !transition.isAvailable {
            pauseLayoutTrackingForSession()
        } else if !transition.wasAvailable, transition.isAvailable {
            awaitManagedInteractionForSessionRecovery(reason: reason)
        }

        logSessionState(
            "session state reason=\(reason) locked=\(isScreenLocked) active=\(isWorkspaceSessionActive) sleeping=\(isSystemSleeping) available=\(transition.isAvailable) awaitingInteraction=\(isAwaitingSessionRecoveryInteraction) tracking=\(isLayoutTrackingAllowed)"
        )
    }

    private func pauseLayoutTrackingForSession() {
        sessionResumeGeneration &+= 1
        isAwaitingSessionRecoveryInteraction = true
        isSessionRecoveryResumeScheduled = false
        pendingSessionRecoveryCommands.removeAll()
        pendingSessionRecoveryLaunchedPIDs.removeAll()
        windowManagement.observation.configurePeriodicTimer(enabled: false, interval: windowReconciliationInterval)
        windowManagement.observation.configureActiveRescanTimer(pids: [])
        cancelAppLaunchSettlingForUnavailableSession()
        manualResizeController.cancel()
        pendingFocusCommands.removeAll()
        pendingCoordinatorReconciliation = nil
        windowManagement.observation.cancelCreationReconciliations()
        layoutController.cancel(reason: "session-unavailable")
        syncSessionRecoveryInputTracking()
        debugLog("layout tracking paused for unavailable session")
    }

    private func awaitManagedInteractionForSessionRecovery(reason: String) {
        guard isAwaitingSessionRecoveryInteraction else {
            return
        }
        isSessionRecoveryResumeScheduled = false
        refreshSessionRecoveryInputTracking()
        debugLog("layout tracking awaiting managed-window interaction reason=\(reason) generation=\(sessionResumeGeneration)")
    }

    private func logSessionState(_ message: String) {
        print("miri: \(message)")
        NSLog("miri: %@", message)
        debugLog(message)
    }

    func currentConsoleLockState() -> Bool? {
        SessionController.currentConsoleLockState()
    }

    func currentConsoleSessionIsActive() -> Bool? {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return nil
        }
        return session[kCGSessionOnConsoleKey as String] as? Bool
    }
}
