import AppKit
import ApplicationServices
import Foundation

extension Miri {
    func widthRatio(for window: ManagedWindow) -> CGFloat {
        if let column = windowManagement.logicalSpaceContexts.flatMap(\.workspaces).flatMap(\.columns).first(where: { $0.windows.contains { $0 === window } }) {
            if let shared = column.widthRatio { return shared.clampedManualWidthRatio }
            return standaloneWidthRatio(for: column.windows.first ?? window)
        }
        return standaloneWidthRatio(for: window)
    }

    func standaloneWidthRatio(for window: ManagedWindow) -> CGFloat {
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
        if let manual = windowManagement.manualBehavior(for: window.element) {
            return manual
        }
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
