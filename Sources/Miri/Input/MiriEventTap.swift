import CoreGraphics
import Foundation

extension Miri {
    var keyboardShortcutBackend: KeyboardShortcutBackend {
        config.keyboardShortcutBackend ?? MiriConfig.fallback.keyboardShortcutBackend ?? .eventTap
    }

    func configureInput() {
        inputController.configure(config)
    }

    func installInputBackend() {
        inputController.install(backend: keyboardShortcutBackend)
    }

    func uninstallEventTap() {
        inputController.uninstallEventTap()
    }

    func uninstallCarbonHotKeys() {
        inputController.uninstallCarbonHotKeys()
    }

    func handleEventTapDisabledImplementation(_ type: CGEventType) {
        if inputController.reenableEventTap(after: type) {
            debugLog("event tap re-enabled after \(type)")
        } else {
            debugLog("event tap disabled by \(type), but tap is nil")
        }
    }

}
