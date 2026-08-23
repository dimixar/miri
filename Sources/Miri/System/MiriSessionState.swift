import AppKit
import CoreGraphics
import Foundation
import IOKit

extension Miri {
    var isSessionAvailable: Bool {
        isWorkspaceSessionActive && !isScreenLocked && !isSystemSleeping
    }

    var isLayoutTrackingAllowed: Bool {
        isSessionAvailable && !isAwaitingSessionRecoveryInteraction
    }

    func observeSessionState() {
        if let locked = currentConsoleLockState() {
            isScreenLocked = locked
        } else {
            debugLog("session state initial lock state unavailable; assuming unlocked")
        }

        if let session = CGSessionCopyCurrentDictionary() as? [String: Any],
           let onConsole = session[kCGSessionOnConsoleKey as String] as? Bool
        {
            isWorkspaceSessionActive = onConsole
        } else {
            debugLog("session state initial console ownership unavailable; assuming active")
        }

        let distributedCenter = DistributedNotificationCenter.default()
        distributedCenter.addObserver(
            self,
            selector: #selector(screenDidLock(_:)),
            name: Notification.Name("com.apple.screenIsLocked"),
            object: nil
        )
        distributedCenter.addObserver(
            self,
            selector: #selector(screenDidUnlock(_:)),
            name: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil
        )

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceCenter.addObserver(
            self,
            selector: #selector(workspaceSessionDidBecomeActive(_:)),
            name: NSWorkspace.sessionDidBecomeActiveNotification,
            object: nil
        )
        workspaceCenter.addObserver(
            self,
            selector: #selector(workspaceSessionDidResignActive(_:)),
            name: NSWorkspace.sessionDidResignActiveNotification,
            object: nil
        )
        workspaceCenter.addObserver(
            self,
            selector: #selector(workspaceWillSleep(_:)),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        workspaceCenter.addObserver(
            self,
            selector: #selector(workspaceDidWake(_:)),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        if !isSessionAvailable {
            isAwaitingSessionRecoveryInteraction = true
        }

        logSessionState(
            "session monitor locked=\(isScreenLocked) active=\(isWorkspaceSessionActive) sleeping=\(isSystemSleeping) awaitingInteraction=\(isAwaitingSessionRecoveryInteraction) tracking=\(isLayoutTrackingAllowed)"
        )
    }

    @objc private func screenDidLock(_ notification: Notification) {
        updateSessionState(screenLocked: true, reason: notification.name.rawValue)
    }

    @objc private func screenDidUnlock(_ notification: Notification) {
        updateSessionState(screenLocked: false, reason: notification.name.rawValue)
    }

    @objc private func workspaceSessionDidBecomeActive(_ notification: Notification) {
        updateSessionState(
            screenLocked: currentConsoleLockState(),
            workspaceActive: true,
            reason: notification.name.rawValue
        )
    }

    @objc private func workspaceSessionDidResignActive(_ notification: Notification) {
        updateSessionState(workspaceActive: false, reason: notification.name.rawValue)
    }

    @objc private func workspaceWillSleep(_ notification: Notification) {
        updateSessionState(systemSleeping: true, reason: notification.name.rawValue)
    }

    @objc private func workspaceDidWake(_ notification: Notification) {
        updateSessionState(
            screenLocked: currentConsoleLockState(),
            systemSleeping: false,
            reason: notification.name.rawValue
        )
    }

    private func updateSessionState(
        screenLocked: Bool? = nil,
        workspaceActive: Bool? = nil,
        systemSleeping: Bool? = nil,
        reason: String
    ) {
        let wasAvailable = isSessionAvailable
        let previousLocked = isScreenLocked
        let previousActive = isWorkspaceSessionActive
        let previousSleeping = isSystemSleeping

        if let screenLocked {
            isScreenLocked = screenLocked
        }
        if let workspaceActive {
            isWorkspaceSessionActive = workspaceActive
        }
        if let systemSleeping {
            isSystemSleeping = systemSleeping
        }

        let isAvailable = isSessionAvailable
        guard previousLocked != isScreenLocked
                || previousActive != isWorkspaceSessionActive
                || previousSleeping != isSystemSleeping
                || wasAvailable != isAvailable
        else {
            return
        }

        if wasAvailable, !isAvailable {
            pauseLayoutTrackingForSession()
        } else if !wasAvailable, isAvailable {
            awaitManagedInteractionForSessionRecovery(reason: reason)
        }

        logSessionState(
            "session state reason=\(reason) locked=\(isScreenLocked) active=\(isWorkspaceSessionActive) sleeping=\(isSystemSleeping) available=\(isAvailable) awaitingInteraction=\(isAwaitingSessionRecoveryInteraction) tracking=\(isLayoutTrackingAllowed)"
        )
    }

    private func pauseLayoutTrackingForSession() {
        sessionResumeGeneration &+= 1
        isAwaitingSessionRecoveryInteraction = true
        isSessionRecoveryResumeScheduled = false
        pendingSessionRecoveryCommands.removeAll()
        pendingSessionRecoveryLaunchedPIDs.removeAll()
        reconciliationTimer?.invalidate()
        reconciliationTimer = nil
        activeRescanTimer?.invalidate()
        activeRescanTimer = nil
        cancelAppLaunchSettlingForUnavailableSession()
        manualResizeEndTimer?.cancel()
        manualResizeEndTimer = nil
        manualResizeElement = nil
        pendingFocusCommands.removeAll()
        pendingAXReconciliationPIDs.removeAll()
        pendingAXReconciliationAdoptFocused = false
        pendingAXReconciliationNeedsFullRescan = false
        pendingAXCreationSettleGenerations.removeAll()
        pendingSnapshotDeferredLayout = false
        stopAnimation(clearPresentation: true)
        isApplyingLayout = false
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
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard root != 0 else {
            return nil
        }
        defer { IOObjectRelease(root) }

        guard let value = IORegistryEntryCreateCFProperty(
            root,
            "IOConsoleLocked" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue()
        else {
            return nil
        }
        return value as? Bool
    }

    func currentConsoleSessionIsActive() -> Bool? {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return nil
        }
        return session[kCGSessionOnConsoleKey as String] as? Bool
    }
}
