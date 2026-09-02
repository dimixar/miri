import AppKit
import CoreGraphics
import Foundation
import IOKit

extension Miri {
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
            "session monitor locked=\(sessionController.isScreenLocked) active=\(sessionController.isWorkspaceSessionActive) sleeping=\(sessionController.isSystemSleeping) awaitingInteraction=\(sessionController.isAwaitingRecoveryInteraction) tracking=\(sessionController.isLayoutTrackingAllowed)"
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
            "session state reason=\(reason) locked=\(sessionController.isScreenLocked) active=\(sessionController.isWorkspaceSessionActive) sleeping=\(sessionController.isSystemSleeping) available=\(transition.isAvailable) awaitingInteraction=\(sessionController.isAwaitingRecoveryInteraction) tracking=\(sessionController.isLayoutTrackingAllowed)"
        )
    }

    private func pauseLayoutTrackingForSession() {
        sessionController.pauseForUnavailableSession()
        pendingSessionRecoveryCommands.removeAll()
        pendingSessionRecoveryLaunchedPIDs.removeAll()
        windowManagement.observation.configurePeriodicTimer(enabled: false, interval: windowReconciliationInterval)
        windowManagement.observation.configureActiveRescanTimer(pids: [])
        cancelAppLaunchSettlingForUnavailableSession()
        manualResizeController.cancel()
        pendingFocusCommands.removeAll()
        pendingCoordinatorReconciliation = nil
        reconciliationDrainGeneration &+= 1
        reconciliationDrainScheduled = false
        fullWindowScanGeneration &+= 1
        focusStateGeneration &+= 1
        activeRescanInputGeneration &+= 1
        lastKnownFocusedElements.removeAll()
        sessionRecoveryFocusedValidationPID = nil
        sessionRecoveryFocusedValidationGeneration = nil
        let validationWaiters = sessionRecoveryFocusedValidationWaiters
        sessionRecoveryFocusedValidationWaiters.removeAll()
        for waiter in validationWaiters { waiter(nil) }
        windowManagement.observation.invalidateAsyncStateForSessionTransition()
        cancelTransientSystemWindowRefreshForSessionTransition()

        let layoutPauseGeneration = layoutController.beginUnavailableSessionPause()
        sessionPauseQuiescenceGeneration &+= 1
        let quiescenceGeneration = sessionPauseQuiescenceGeneration
        sessionPauseQuiescenceInFlight = true
        let staleWaiters = sessionPauseQuiescenceWaiters
        sessionPauseQuiescenceWaiters.removeAll()
        for waiter in staleWaiters { waiter() }
        axOperations.quiesceForUnavailableSession { [weak self] in
            guard let self,
                  self.sessionPauseQuiescenceGeneration == quiescenceGeneration
            else { return }
            self.windowManagement.observation.completeAXQuiescenceForSessionTransition()
            self.layoutController.completeUnavailableSessionPause(
                generation: layoutPauseGeneration
            )
            self.sessionPauseQuiescenceInFlight = false
            let waiters = self.sessionPauseQuiescenceWaiters
            self.sessionPauseQuiescenceWaiters.removeAll()
            for waiter in waiters { waiter() }
            self.debugLog("session AX operations quiesced generation=\(quiescenceGeneration)")
        }
        syncSessionRecoveryInputTracking()
        debugLog("layout tracking paused for unavailable session")
    }

    private func awaitManagedInteractionForSessionRecovery(reason: String) {
        guard sessionController.isAwaitingRecoveryInteraction else {
            return
        }
        fullWindowScanGeneration &+= 1
        focusStateGeneration &+= 1
        lastKnownFocusedElements.removeAll()
        windowManagement.observation.invalidateAsyncStateForSessionTransition()
        axOperations.resetHealthForSessionRecovery()
        sessionController.prepareRecoveryInteraction()
        refreshSessionRecoveryInputTracking()
        debugLog("layout tracking awaiting managed-window interaction reason=\(reason) generation=\(sessionController.resumeGeneration)")
    }

    func afterSessionAXQuiescence(_ completion: @escaping () -> Void) {
        if sessionPauseQuiescenceInFlight {
            sessionPauseQuiescenceWaiters.append(completion)
        } else {
            completion()
        }
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
