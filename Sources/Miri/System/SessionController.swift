import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import IOKit

@MainActor
final class SessionController {
    private let emit: (AppEvent) -> Void
    private var observerTokens: [NSObjectProtocol] = []
    private var recoveryEventTap: CFMachPort?
    private var recoveryEventTapSource: CFRunLoopSource?

    private(set) var isScreenLocked = false
    private(set) var isWorkspaceSessionActive = true
    private(set) var isSystemSleeping = false
    private(set) var isAwaitingRecoveryInteraction = false
    private(set) var isRecoveryResumeScheduled = false
    private(set) var resumeGeneration: UInt64 = 0

    init(emit: @escaping (AppEvent) -> Void) {
        self.emit = emit
    }

    var isAvailable: Bool {
        isWorkspaceSessionActive && !isScreenLocked && !isSystemSleeping
    }

    var isLayoutTrackingAllowed: Bool {
        isAvailable && !isAwaitingRecoveryInteraction
    }

    func start(initialLocked: Bool?, initialWorkspaceActive: Bool?) {
        if let initialLocked { isScreenLocked = initialLocked }
        if let initialWorkspaceActive { isWorkspaceSessionActive = initialWorkspaceActive }
        guard observerTokens.isEmpty else { return }

        let distributed = DistributedNotificationCenter.default()
        observerTokens.append(distributed.addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] notification in
            let reason = notification.name.rawValue
            MainActor.assumeIsolated {
                self?.emitState(screenLocked: true, reason: reason)
            }
        })
        observerTokens.append(distributed.addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak self] notification in
            let reason = notification.name.rawValue
            MainActor.assumeIsolated {
                self?.emitState(screenLocked: false, reason: reason)
            }
        })

        let workspace = NSWorkspace.shared.notificationCenter
        observerTokens.append(workspace.addObserver(
            forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let reason = notification.name.rawValue
            MainActor.assumeIsolated {
                self?.emitState(
                    screenLocked: SessionController.currentConsoleLockState(),
                    workspaceActive: true,
                    reason: reason
                )
            }
        })
        observerTokens.append(workspace.addObserver(
            forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let reason = notification.name.rawValue
            MainActor.assumeIsolated {
                self?.emitState(workspaceActive: false, reason: reason)
            }
        })
        observerTokens.append(workspace.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let reason = notification.name.rawValue
            MainActor.assumeIsolated {
                self?.emitState(systemSleeping: true, reason: reason)
            }
        })
        observerTokens.append(workspace.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let reason = notification.name.rawValue
            MainActor.assumeIsolated {
                self?.emitState(
                    screenLocked: SessionController.currentConsoleLockState(),
                    systemSleeping: false,
                    reason: reason
                )
            }
        })
        if !isAvailable { isAwaitingRecoveryInteraction = true }
    }

    func apply(
        screenLocked: Bool?,
        workspaceActive: Bool?,
        systemSleeping: Bool?
    ) -> (wasAvailable: Bool, isAvailable: Bool, changed: Bool) {
        let wasAvailable = isAvailable
        let previous = (isScreenLocked, isWorkspaceSessionActive, isSystemSleeping)
        if let screenLocked { isScreenLocked = screenLocked }
        if let workspaceActive { isWorkspaceSessionActive = workspaceActive }
        if let systemSleeping { isSystemSleeping = systemSleeping }
        let changed = previous.0 != isScreenLocked
            || previous.1 != isWorkspaceSessionActive
            || previous.2 != isSystemSleeping
            || wasAvailable != isAvailable
        return (wasAvailable, isAvailable, changed)
    }

    func pauseForUnavailableSession() {
        resumeGeneration &+= 1
        isAwaitingRecoveryInteraction = true
        isRecoveryResumeScheduled = false
    }

    func prepareRecoveryInteraction() {
        isRecoveryResumeScheduled = false
    }

    func scheduleRecoveryIfNeeded() -> UInt64? {
        guard !isRecoveryResumeScheduled else { return nil }
        isRecoveryResumeScheduled = true
        return resumeGeneration
    }

    func cancelScheduledRecovery() {
        isRecoveryResumeScheduled = false
    }

    func completeRecovery(generation: UInt64) -> Bool {
        guard resumeGeneration == generation else {
            isRecoveryResumeScheduled = false
            return false
        }
        isRecoveryResumeScheduled = false
        isAwaitingRecoveryInteraction = false
        return true
    }

    func stop() {
        let distributed = DistributedNotificationCenter.default()
        let workspace = NSWorkspace.shared.notificationCenter
        for token in observerTokens {
            distributed.removeObserver(token)
            workspace.removeObserver(token)
        }
        observerTokens.removeAll()
        uninstallRecoveryInput()
    }

    func installRecoveryInput(mask: CGEventMask) {
        guard recoveryEventTap == nil else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: sessionControllerRecoveryEventTapCallback,
            userInfo: refcon
        ), let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            return
        }
        recoveryEventTap = tap
        recoveryEventTapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func uninstallRecoveryInput() {
        if let recoveryEventTap {
            CGEvent.tapEnable(tap: recoveryEventTap, enable: false)
            CFMachPortInvalidate(recoveryEventTap)
        }
        if let recoveryEventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), recoveryEventTapSource, .commonModes)
        }
        recoveryEventTap = nil
        recoveryEventTapSource = nil
    }

    func reenableRecoveryInput() {
        guard let recoveryEventTap else { return }
        CGEvent.tapEnable(tap: recoveryEventTap, enable: true)
    }

    private func emitState(
        screenLocked: Bool? = nil,
        workspaceActive: Bool? = nil,
        systemSleeping: Bool? = nil,
        reason: String
    ) {
        emit(.session(.stateChanged(
            screenLocked: screenLocked,
            workspaceActive: workspaceActive,
            systemSleeping: systemSleeping,
            reason: reason
        )))
    }

    fileprivate func handleRecoveryInput(_ event: CGEvent, type: CGEventType) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            emit(.input(.sessionRecoveryEventTapDisabled))
        } else {
            emit(.input(.sessionRecoveryCandidate(event: event, type: type)))
        }
    }

    nonisolated static func currentConsoleLockState() -> Bool? {
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard root != 0 else { return nil }
        defer { IOObjectRelease(root) }
        guard let value = IORegistryEntryCreateCFProperty(
            root, "IOConsoleLocked" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() else {
            return nil
        }
        return value as? Bool
    }
}

private func sessionControllerRecoveryEventTapCallback(
    _ proxy: CGEventTapProxy,
    _ type: CGEventType,
    _ event: CGEvent,
    _ refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let controller = Unmanaged<SessionController>.fromOpaque(refcon).takeUnretainedValue()
    let payload = MainRunLoopCallbackValue(value: event)
    MainActor.assumeIsolated {
        controller.handleRecoveryInput(payload.value, type: type)
    }
    return Unmanaged.passUnretained(event)
}
