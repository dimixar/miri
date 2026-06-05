import Carbon.HIToolbox
import Foundation

private let miriHotKeySignature = OSType(
    (UInt32(UInt8(ascii: "M")) << 24)
        | (UInt32(UInt8(ascii: "I")) << 16)
        | (UInt32(UInt8(ascii: "R")) << 8)
        | UInt32(UInt8(ascii: "I"))
)

extension Miri {
    func installCarbonHotKeys() {
        uninstallCarbonHotKeys()

        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            carbonHotKeyHandler,
            1,
            &eventSpec,
            refcon,
            &carbonEventHandler
        )
        guard handlerStatus == noErr else {
            fputs("miri: unable to install registered shortcut handler (\(handlerStatus)); falling back to event tap\n", stderr)
            installEventTap()
            return
        }

        var nextID: UInt32 = 1
        for binding in commandByKeybinding.keys.sorted() {
            guard !excludedKeybindingSet.contains(binding),
                  let command = commandByKeybinding[binding],
                  let hotKey = KeybindingResolver.carbonHotKey(forNormalizedKeybinding: binding)
            else {
                continue
            }

            if hotKey.usesSideSpecificOption {
                fputs("miri: registered shortcuts treat '\(binding)' as generic Option; left/right Option cannot be distinguished by this backend\n", stderr)
            }
            if hotKey.usesUnsupportedFn {
                fputs("miri: skipping '\(binding)'; registered shortcuts do not support fn/globe bindings\n", stderr)
                continue
            }

            let hotKeyID = EventHotKeyID(signature: miriHotKeySignature, id: nextID)
            var hotKeyRef: EventHotKeyRef?
            let status = RegisterEventHotKey(
                UInt32(hotKey.keyCode),
                UInt32(hotKey.modifiers),
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &hotKeyRef
            )

            guard status == noErr, let hotKeyRef else {
                fputs("miri: unable to register shortcut '\(binding)' with registered shortcut backend (\(status))\n", stderr)
                continue
            }

            carbonHotKeys.append(hotKeyRef)
            carbonCommandByID[nextID] = command
            nextID += 1
        }

        print("miri: registered \(carbonHotKeys.count) shortcuts with macOS")
    }

    func uninstallCarbonHotKeys() {
        for hotKey in carbonHotKeys {
            UnregisterEventHotKey(hotKey)
        }
        carbonHotKeys.removeAll()
        carbonCommandByID.removeAll()

        if let carbonEventHandler {
            RemoveEventHandler(carbonEventHandler)
            self.carbonEventHandler = nil
        }
    }

    func handleCarbonHotKey(id: UInt32) -> OSStatus {
        guard let command = carbonCommandByID[id] else {
            return OSStatus(eventNotHandledErr)
        }

        guard !transientSystemWindowIsActive() else {
            return noErr
        }

        DispatchQueue.main.async { [weak self] in
            self?.scheduleActiveRescanForUserInput()
            self?.submit(command)
        }
        return noErr
    }
}

private func carbonHotKeyHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event,
          let userData
    else {
        return OSStatus(eventNotHandledErr)
    }

    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr, hotKeyID.signature == miriHotKeySignature else {
        return OSStatus(eventNotHandledErr)
    }

    let app = Unmanaged<Miri>.fromOpaque(userData).takeUnretainedValue()
    return app.handleCarbonHotKey(id: hotKeyID.id)
}
