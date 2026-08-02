import AppKit
import CoreGraphics
import Foundation
import IOKit

extension Miri {
    var isLayoutTrackingAllowed: Bool {
        isWorkspaceSessionActive && !isScreenLocked
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

        logSessionState(
            "session monitor locked=\(isScreenLocked) active=\(isWorkspaceSessionActive) tracking=\(isLayoutTrackingAllowed)"
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

    private func updateSessionState(
        screenLocked: Bool? = nil,
        workspaceActive: Bool? = nil,
        reason: String
    ) {
        let wasAllowed = isLayoutTrackingAllowed
        let previousLocked = isScreenLocked
        let previousActive = isWorkspaceSessionActive

        if let screenLocked {
            isScreenLocked = screenLocked
        }
        if let workspaceActive {
            isWorkspaceSessionActive = workspaceActive
        }

        let isAllowed = isLayoutTrackingAllowed
        guard previousLocked != isScreenLocked
                || previousActive != isWorkspaceSessionActive
                || wasAllowed != isAllowed
        else {
            return
        }

        logSessionState(
            "session state reason=\(reason) locked=\(isScreenLocked) active=\(isWorkspaceSessionActive) tracking=\(isAllowed)"
        )

        if wasAllowed, !isAllowed {
            pauseLayoutTrackingForSession()
        } else if !wasAllowed, isAllowed {
            resumeLayoutTrackingForSession(reason: reason)
        }
    }

    private func pauseLayoutTrackingForSession() {
        sessionResumeGeneration &+= 1
        reconciliationTimer?.invalidate()
        reconciliationTimer = nil
        activeRescanTimer?.invalidate()
        activeRescanTimer = nil
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
        debugLog("layout tracking paused for unavailable session")
    }

    private func resumeLayoutTrackingForSession(reason: String) {
        sessionResumeGeneration &+= 1
        let generation = sessionResumeGeneration
        debugLog("layout tracking resume scheduled reason=\(reason) generation=\(generation)")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self,
                  self.isLayoutTrackingAllowed,
                  self.sessionResumeGeneration == generation
            else {
                return
            }

            self.lastActivatedApplicationPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            self.rescanWindows(adoptFocused: true)
            self.scheduleReconciliationTimer()
            self.syncActiveRescanTimer()
            self.debugLog("layout tracking resumed generation=\(generation)")
        }
    }

    private func logSessionState(_ message: String) {
        print("miri: \(message)")
        NSLog("miri: %@", message)
        debugLog(message)
    }

    private func currentConsoleLockState() -> Bool? {
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
}
