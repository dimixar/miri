import AppKit
import ApplicationServices
import Foundation

extension Miri {
    func widthRatio(for window: ManagedWindow) -> CGFloat {
        if let manualWidthRatio = window.manualWidthRatio {
            return manualWidthRatio.clampedManualWidthRatio
        }

        for rule in config.rules where rule.matches(window) {
            if let widthRatio = rule.widthRatio {
                return widthRatio.clampedWidthRatio
            }
        }
        return config.defaultWidthRatio.clampedWidthRatio
    }

    func behavior(for window: ManagedWindow) -> WindowBehavior {
        for rule in config.rules where rule.matches(window) {
            if let behavior = rule.behavior {
                return behavior
            }
        }
        return .tile
    }

    func configuredBehavior(for element: AXUIElement, pid: pid_t) -> WindowBehavior? {
        guard let app = NSRunningApplication(processIdentifier: pid) else {
            return nil
        }
        let candidate = ManagedWindow(
            element: element,
            pid: pid,
            windowID: SkyLight.shared.windowID(for: element),
            bundleID: app.bundleIdentifier,
            appName: app.localizedName ?? "pid \(pid)",
            title: axString(element, kAXTitleAttribute) ?? ""
        )
        return behavior(for: candidate)
    }

    func rule(for window: ManagedWindow) -> WindowRule? {
        config.rules.first { $0.matches(window) }
    }

    func activeWindow() -> ManagedWindow? {
        guard let workspace = activeWorkspaceObject(), !workspace.columns.isEmpty else {
            return nil
        }
        workspace.clampFocus()
        return workspace.columns[workspace.activeColumn]
    }

    func allWindows() -> [ManagedWindow] {
        workspaces.flatMap(\.columns) + floatingWindows
    }

    func tiledWindows() -> [ManagedWindow] {
        workspaces.flatMap(\.columns)
    }

}
