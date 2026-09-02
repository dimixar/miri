import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Foundation

private let inputHotKeySignature = OSType(
    (UInt32(UInt8(ascii: "M")) << 24)
        | (UInt32(UInt8(ascii: "I")) << 16)
        | (UInt32(UInt8(ascii: "R")) << 8)
        | UInt32(UInt8(ascii: "I"))
)

@MainActor
final class InputController {
    private let emit: (AppEvent) -> Void
    private let isAwaitingSessionRecovery: () -> Bool
    private let handleRecoveryKey: (CGEvent?, Command?) -> Bool
    private let shouldSuppressCommand: () -> Bool

    private var eventTap: CFMachPort?
    private var eventTapSource: CFRunLoopSource?
    private var carbonHotKeys: [EventHotKeyRef] = []
    private var carbonEventHandler: EventHandlerRef?
    private var carbonCommandByID: [UInt32: Command] = [:]
    private var commandByKeybinding: [String: Command] = [:]
    private var excludedKeybindingSet = Set<String>()
    private var focusedWindowInputMonitor: Any?

    init(
        emit: @escaping (AppEvent) -> Void,
        isAwaitingSessionRecovery: @escaping () -> Bool,
        handleRecoveryKey: @escaping (CGEvent?, Command?) -> Bool,
        shouldSuppressCommand: @escaping () -> Bool
    ) {
        self.emit = emit
        self.isAwaitingSessionRecovery = isAwaitingSessionRecovery
        self.handleRecoveryKey = handleRecoveryKey
        self.shouldSuppressCommand = shouldSuppressCommand
    }

    var commandCount: Int { commandByKeybinding.count }

    func configure(_ config: MiriConfig) {
        commandByKeybinding = KeybindingResolver.makeCommandByKeybinding(config: config)
        excludedKeybindingSet = Set((config.excludedKeybindings ?? MiriConfig.fallback.excludedKeybindings ?? [])
            .compactMap(KeybindingResolver.normalizedKeybinding(_:)))
    }

    func install(backend: KeyboardShortcutBackend) {
        switch backend {
        case .eventTap:
            uninstallCarbonHotKeys()
            installEventTap()
        case .registeredHotKeys:
            uninstallEventTap()
            installCarbonHotKeys()
        }
    }

    func installFocusedWindowMonitor() {
        guard focusedWindowInputMonitor == nil else { return }
        focusedWindowInputMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]
        ) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch event.type {
                case .leftMouseDown, .rightMouseDown, .otherMouseDown:
                    self.emit(.input(.focusedWindowProbeRequested(reason: "mouse-down")))
                case .keyDown:
                    let switchesWindow = event.modifierFlags.contains(.command)
                        && (event.keyCode == UInt16(kVK_ANSI_Grave) || event.keyCode == UInt16(kVK_Tab))
                    if switchesWindow {
                        self.emit(.input(.focusedWindowProbeRequested(reason: "command-window-switch")))
                    }
                default:
                    break
                }
            }
        }
    }

    func uninstallFocusedWindowMonitor() {
        guard let focusedWindowInputMonitor else { return }
        NSEvent.removeMonitor(focusedWindowInputMonitor)
        self.focusedWindowInputMonitor = nil
    }

    func reenableEventTap() {
        guard let eventTap else { return }
        CGEvent.tapEnable(tap: eventTap, enable: true)
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

    func uninstallCarbonHotKeys() {
        for hotKey in carbonHotKeys { UnregisterEventHotKey(hotKey) }
        carbonHotKeys.removeAll()
        carbonCommandByID.removeAll()
        if let carbonEventHandler {
            RemoveEventHandler(carbonEventHandler)
            self.carbonEventHandler = nil
        }
    }

    func reenableEventTap(after type: CGEventType) -> Bool {
        guard eventTap != nil else { return false }
        reenableEventTap()
        return true
    }

    fileprivate func handleKeyEvent(_ event: CGEvent) -> Bool {
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

        if isAwaitingSessionRecovery() {
            return handleRecoveryKey(event, command)
        }
        DispatchQueue.main.async { [weak self] in
            self?.emit(.input(.userInteraction))
        }
        guard let command else { return false }
        guard !shouldSuppressCommand() else { return false }
        DispatchQueue.main.async { [weak self] in
            self?.emit(.input(.command(command, animateWorkspace: false)))
        }
        return true
    }

    fileprivate func handleCarbonHotKey(id: UInt32) -> OSStatus {
        guard let command = carbonCommandByID[id] else {
            return OSStatus(eventNotHandledErr)
        }
        if isAwaitingSessionRecovery() {
            return handleRecoveryKeyForCarbon(command) ? noErr : OSStatus(eventNotHandledErr)
        }
        let suppressed = shouldSuppressCommand()
        DispatchQueue.main.async { [weak self] in
            if !suppressed {
                self?.emit(.input(.command(command, animateWorkspace: false)))
            }
            // Even a suppressed registered hot key must refresh cached
            // transient-window state so a closed dialog cannot lock out Miri.
            self?.emit(.input(.userInteraction))
        }
        return noErr
    }

    private func handleRecoveryKeyForCarbon(_ command: Command) -> Bool {
        handleRecoveryKey(nil, command)
    }

    private func installEventTap() {
        guard eventTap == nil else { return }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: inputEventTapCallback,
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

    private func installCarbonHotKeys() {
        uninstallCarbonHotKeys()
        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(
            GetApplicationEventTarget(), inputCarbonHotKeyHandler, 1, &eventSpec, refcon, &carbonEventHandler
        )
        guard status == noErr else {
            fputs("miri: unable to install registered shortcut handler (\(status)); falling back to event tap\n", stderr)
            installEventTap()
            return
        }

        var nextID: UInt32 = 1
        for binding in commandByKeybinding.keys.sorted() {
            guard !excludedKeybindingSet.contains(binding),
                  let command = commandByKeybinding[binding],
                  let hotKey = KeybindingResolver.carbonHotKey(forNormalizedKeybinding: binding)
            else { continue }
            if hotKey.usesSideSpecificOption {
                fputs("miri: registered shortcuts treat '\(binding)' as generic Option; left/right Option cannot be distinguished by this backend\n", stderr)
            }
            if hotKey.usesUnsupportedFn {
                fputs("miri: skipping '\(binding)'; registered shortcuts do not support fn/globe bindings\n", stderr)
                continue
            }
            let hotKeyID = EventHotKeyID(signature: inputHotKeySignature, id: nextID)
            var hotKeyRef: EventHotKeyRef?
            let registration = RegisterEventHotKey(
                UInt32(hotKey.keyCode), UInt32(hotKey.modifiers), hotKeyID,
                GetApplicationEventTarget(), 0, &hotKeyRef
            )
            guard registration == noErr, let hotKeyRef else {
                fputs("miri: unable to register shortcut '\(binding)' with registered shortcut backend (\(registration))\n", stderr)
                continue
            }
            carbonHotKeys.append(hotKeyRef)
            carbonCommandByID[nextID] = command
            nextID += 1
        }
        print("miri: registered \(carbonHotKeys.count) shortcuts with macOS")
    }
}

private func inputEventTapCallback(
    _ proxy: CGEventTapProxy,
    _ type: CGEventType,
    _ event: CGEvent,
    _ refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let controller = Unmanaged<InputController>.fromOpaque(refcon).takeUnretainedValue()
    let payload = MainRunLoopCallbackValue(value: event)
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        MainActor.assumeIsolated {
            controller.emitEventTapDisabled(type)
        }
        return Unmanaged.passUnretained(event)
    }
    guard type == .keyDown else { return Unmanaged.passUnretained(event) }
    let consumed = MainActor.assumeIsolated {
        controller.handleKeyEvent(payload.value)
    }
    return consumed ? nil : Unmanaged.passUnretained(event)
}

fileprivate extension InputController {
    func emitEventTapDisabled(_ type: CGEventType) {
        emit(.input(.eventTapDisabled(type)))
    }
}

private func inputCarbonHotKeyHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
        nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
    )
    guard status == noErr, hotKeyID.signature == inputHotKeySignature else {
        return OSStatus(eventNotHandledErr)
    }
    let controller = Unmanaged<InputController>.fromOpaque(userData).takeUnretainedValue()
    return MainActor.assumeIsolated {
        controller.handleCarbonHotKey(id: hotKeyID.id)
    }
}
