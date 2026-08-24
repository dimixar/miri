import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Foundation

extension Miri {
    var keyboardShortcutBackend: KeyboardShortcutBackend {
        config.keyboardShortcutBackend ?? MiriConfig.fallback.keyboardShortcutBackend ?? .eventTap
    }

    func installInputBackend() {
        switch keyboardShortcutBackend {
        case .eventTap:
            uninstallCarbonHotKeys()
            installEventTap()
        case .registeredHotKeys:
            uninstallEventTap()
            installCarbonHotKeys()
        }
    }

    func installEventTap() {
        guard eventTap == nil else {
            return
        }

        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
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

    func uninstallEventTap() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        if let eventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), eventTapSource, .commonModes)
        }
        eventTap = nil
        eventTapSource = nil
    }

    func updateCleanupWatcher(previousRestoreOnExit: Bool) {
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

    func configureInput() {
        commandByKeybinding = KeybindingResolver.makeCommandByKeybinding(config: config)
        excludedKeybindingSet = Set((config.excludedKeybindings ?? MiriConfig.fallback.excludedKeybindings ?? [])
            .compactMap(KeybindingResolver.normalizedKeybinding(_:)))
    }

    func handleEventTapDisabled(_ type: CGEventType) {
        enqueue(.input(.eventTapDisabled(type)))
    }

    func handleEventTapDisabledImplementation(_ type: CGEventType) {
        guard let eventTap else {
            debugLog("event tap disabled by \(type), but tap is nil")
            return
        }
        CGEvent.tapEnable(tap: eventTap, enable: true)
        debugLog("event tap re-enabled after \(type)")
    }

    func handleKeyEvent(_ event: CGEvent) -> Bool {
        let modifiers = event.flags
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let keyText = KeybindingResolver.keyboardText(from: event)
        let isExcluded = KeybindingResolver.isExcludedKeybinding(
            modifiers: modifiers,
            keyCode: keyCode,
            keyText: keyText,
            excludedKeybindingSet: excludedKeybindingSet
        )
        let command = isExcluded ? nil : KeybindingResolver.commandForKeyEvent(
            modifiers: modifiers,
            keyCode: keyCode,
            keyText: keyText,
            commandByKeybinding: commandByKeybinding
        )

        if isAwaitingSessionRecoveryInteraction {
            guard sessionRecoveryInputTargetsManagedWindow(
                event,
                type: .keyDown
            ) else {
                return false
            }
            requestSessionRecovery(reason: "managed-key-down", command: command)
            return command != nil
        }

        DispatchQueue.main.async { [weak self] in
            self?.enqueue(.input(.userInteraction))
        }
        guard let command else {
            return false
        }

        guard !transientSystemWindowIsActive() else {
            return false
        }

        DispatchQueue.main.async { [weak self] in
            self?.enqueue(.input(.command(command, animateWorkspace: false)))
        }
        return true
    }

    func handlePointerEvent(_ event: CGEvent, type: CGEventType) {
        guard isAwaitingSessionRecoveryInteraction,
              sessionRecoveryInputTargetsManagedWindow(event, type: type)
        else {
            return
        }
        requestSessionRecovery(reason: "managed-pointer-event-\(type.rawValue)")
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

    guard type == .keyDown else {
        return Unmanaged.passUnretained(event)
    }

    if app.handleKeyEvent(event) {
        return nil
    }
    return Unmanaged.passUnretained(event)
}
