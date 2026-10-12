import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Foundation

struct MousePointerEvent {
    enum Kind { case down, dragged, up }
    let kind: Kind
    let location: CGPoint
    let windowID: UInt32?
}

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
    private var pointerTap: CFMachPort?
    private var pointerTapSource: CFRunLoopSource?
    private var carbonHotKeys: [EventHotKeyRef] = []
    private var carbonEventHandler: EventHandlerRef?
    private var carbonCommandByID: [UInt32: Command] = [:]
    private var carbonKeyCodeByID: [UInt32: Int64] = [:]
    private var pressedCarbonIDs = Set<UInt32>()
    private var swallowedKeys = Set<Int64>()
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
        emit(.input(.shortcutReleased))
        commandByKeybinding = KeybindingResolver.makeCommandByKeybinding(config: config)
        excludedKeybindingSet = Set((config.excludedKeybindings ?? MiriConfig.fallback.excludedKeybindings ?? [])
            .compactMap(KeybindingResolver.normalizedKeybinding(_:)))
    }

    func install(backend: KeyboardShortcutBackend) {
        emit(.input(.shortcutReleased))
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
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown, .keyUp, .flagsChanged]
        ) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch event.type {
                case .leftMouseDown, .rightMouseDown, .otherMouseDown:
                    self.emit(.input(.shortcutReleased))
                    self.emit(.input(.focusedWindowProbeRequested(reason: "mouse-down")))
                case .keyUp:
                    self.pressedCarbonIDs = self.pressedCarbonIDs.filter {
                        self.carbonKeyCodeByID[$0] != Int64(event.keyCode)
                    }
                    self.emit(.input(.shortcutReleased))
                case .flagsChanged:
                    self.emit(.input(.shortcutReleased))
                case .keyDown:
                    if KeybindingResolver.commandForKeyEvent(
                        modifiers: event.cgEvent?.flags ?? [], keyCode: Int64(event.keyCode),
                        keyText: event.charactersIgnoringModifiers ?? "", commandByKeybinding: self.commandByKeybinding
                    ) == nil {
                        self.emit(.input(.shortcutReleased))
                    }
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

    func installPointerMonitor() {
        guard pointerTap == nil else { return }
        let mask = [CGEventType.leftMouseDown, .leftMouseDragged, .leftMouseUp].reduce(CGEventMask(0)) {
            $0 | CGEventMask(1 << $1.rawValue)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: mask, callback: pointerEventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ), let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            fputs("miri: unable to observe mouse gestures. Check Input Monitoring permissions.\n", stderr)
            return
        }
        pointerTap = tap
        pointerTapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func reenablePointerMonitor() {
        if let pointerTap { CGEvent.tapEnable(tap: pointerTap, enable: true) }
    }

    func uninstallPointerMonitor() {
        if let pointerTap {
            CGEvent.tapEnable(tap: pointerTap, enable: false)
            CFMachPortInvalidate(pointerTap)
        }
        if let pointerTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), pointerTapSource, .commonModes)
        }
        pointerTap = nil
        pointerTapSource = nil
    }

    fileprivate func handlePointerEvent(_ event: CGEvent, type: CGEventType) {
        let kind: MousePointerEvent.Kind
        switch type {
        case .leftMouseDown: kind = .down
        case .leftMouseDragged: kind = .dragged
        case .leftMouseUp: kind = .up
        default: return
        }
        let handlingID = event.getIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent)
        let pointedID = event.getIntegerValueField(.mouseEventWindowUnderMousePointer)
        let rawID = handlingID > 0 ? handlingID : pointedID
        let windowID = rawID > 0 && rawID <= Int64(UInt32.max) ? UInt32(rawID) : nil
        emit(.input(.pointer(MousePointerEvent(kind: kind, location: event.location, windowID: windowID))))
    }

    fileprivate func pointerMonitorDisabled() {
        emit(.input(.pointerTapDisabled))
    }

    func reenableEventTap() {
        guard let eventTap else { return }
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }

    func uninstallEventTap() {
        emit(.input(.shortcutReleased))
        swallowedKeys.removeAll()
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
        emit(.input(.shortcutReleased))
        pressedCarbonIDs.removeAll()
        carbonKeyCodeByID.removeAll()
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

    func handleKeyEvent(_ event: CGEvent) -> Bool {
        if event.type == .keyUp {
            emit(.input(.shortcutReleased))
            return swallowedKeys.remove(event.getIntegerValueField(.keyboardEventKeycode)) != nil
        }
        if event.type == .flagsChanged {
            emit(.input(.shortcutReleased))
            return false
        }
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
            emit(.input(.shortcutReleased))
            let consumed = handleRecoveryKey(event, command)
            if consumed { swallowedKeys.insert(keyCode) }
            return consumed
        }
        DispatchQueue.main.async { [weak self] in
            self?.emit(.input(.userInteraction))
        }
        guard let command, !shouldSuppressCommand() else {
            emit(.input(.shortcutReleased))
            return swallowedKeys.contains(keyCode)
        }
        swallowedKeys.insert(keyCode)
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        DispatchQueue.main.async { [weak self] in
            self?.emit(.input(.shortcut(command, keyCode: keyCode, modifiers: modifiers, isRepeat: isRepeat)))
        }
        return true
    }

    func handleCarbonHotKey(id: UInt32, released: Bool) -> OSStatus {
        if released {
            // Carbon can report release when a modifier is lifted while the
            // physical letter key is still down. Do not turn a modifier re-press
            // into a fresh boundary hold; the global key-up route clears it.
            if let keyCode = carbonKeyCodeByID[id],
               !CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(keyCode)) {
                pressedCarbonIDs.remove(id)
            }
            emit(.input(.shortcutReleased))
            return noErr
        }
        guard let command = carbonCommandByID[id] else {
            return OSStatus(eventNotHandledErr)
        }
        if isAwaitingSessionRecovery() {
            emit(.input(.shortcutReleased))
            return handleRecoveryKeyForCarbon(command) ? noErr : OSStatus(eventNotHandledErr)
        }
        let suppressed = shouldSuppressCommand()
        let isRepeat = !pressedCarbonIDs.insert(id).inserted
        let keyCode = carbonKeyCodeByID[id] ?? -1
        let modifiers = CGEventSource.flagsState(.combinedSessionState)
        if suppressed { emit(.input(.shortcutReleased)) }
        DispatchQueue.main.async { [weak self] in
            if !suppressed {
                self?.emit(.input(.shortcut(command, keyCode: keyCode, modifiers: modifiers, isRepeat: isRepeat)))
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
        let mask = [CGEventType.keyDown, .keyUp, .flagsChanged].reduce(CGEventMask(0)) {
            $0 | CGEventMask(1 << $1.rawValue)
        }
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
        var eventSpecs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(
            GetApplicationEventTarget(), inputCarbonHotKeyHandler, 2, &eventSpecs, refcon, &carbonEventHandler
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
            carbonKeyCodeByID[nextID] = hotKey.keyCode
            nextID += 1
        }
        print("miri: registered \(carbonHotKeys.count) shortcuts with macOS")
    }
}

private func pointerEventTapCallback(
    _ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent,
    _ refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let controller = Unmanaged<InputController>.fromOpaque(refcon).takeUnretainedValue()
    let payload = MainRunLoopCallbackValue(value: event)
    MainActor.assumeIsolated {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            controller.pointerMonitorDisabled()
        } else {
            controller.handlePointerEvent(payload.value, type: type)
        }
    }
    return Unmanaged.passUnretained(event)
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
    guard type == .keyDown || type == .keyUp || type == .flagsChanged else { return Unmanaged.passUnretained(event) }
    let consumed = MainActor.assumeIsolated {
        controller.handleKeyEvent(payload.value)
    }
    return consumed ? nil : Unmanaged.passUnretained(event)
}

fileprivate extension InputController {
    func emitEventTapDisabled(_ type: CGEventType) {
        emit(.input(.shortcutReleased))
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
    let released = GetEventKind(event) == UInt32(kEventHotKeyReleased)
    return MainActor.assumeIsolated {
        controller.handleCarbonHotKey(id: hotKeyID.id, released: released)
    }
}
