import AppKit
import ApplicationServices
import Foundation

extension Miri {
    func widthRatio(for window: ManagedWindow) -> CGFloat {
        if let manualWidthRatio = window.manualWidthRatio {
            return manualWidthRatio.clampedManualWidthRatio
        }

        for rule in configStore.effectiveConfig.rules where rule.matches(window) {
            if let widthRatio = rule.widthRatio {
                return widthRatio.clampedWidthRatio
            }
        }
        return configStore.effectiveConfig.defaultWidthRatio.clampedWidthRatio
    }

    func behavior(for window: ManagedWindow) -> WindowBehavior {
        for rule in configStore.effectiveConfig.rules where rule.matches(window) {
            if let behavior = rule.behavior {
                return behavior
            }
        }
        return .tile
    }

    func rule(for window: ManagedWindow) -> WindowRule? {
        configStore.effectiveConfig.rules.first { $0.matches(window) }
    }

    func activeWindow() -> ManagedWindow? {
        windowManagement.activeWindow()
    }

    func allWindows() -> [ManagedWindow] {
        windowManagement.allWindows()
    }

    func tiledWindows() -> [ManagedWindow] {
        windowManagement.tiledWindows()
    }

}
