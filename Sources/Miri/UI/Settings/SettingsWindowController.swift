import AppKit
import QuartzCore
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let store: SettingsStore

    init(
        config: MiriConfig,
        availableApps: [RuleAppInfo],
        permissions: MiriPermissionStatus,
        actionSink: @escaping (UIAction) -> Void
    ) {
        store = SettingsStore(
            config: config,
            availableApps: availableApps,
            permissions: permissions,
            actionSink: actionSink
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 940, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Miri Settings"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(
            width: MiriTheme.Size.settingsMinimumWidth,
            height: MiriTheme.Size.settingsMinimumHeight
        )
        window.center()

        super.init(window: window)
        window.delegate = self
        window.setFrameAutosaveName("MiriSettingsWindow")
        let hostingView = NSHostingView(
            rootView: SettingsRootView(
                store: store,
                requestClose: { [weak window] in window?.performClose(nil) }
            )
        )
        hostingView.sizingOptions = []
        window.contentView = hostingView
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        let wasVisible = window?.isVisible == true
        super.showWindow(sender)
        guard !wasVisible, let window else { return }
        window.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = MiriTheme.Motion.windowPresentation
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
        }
    }

    func refresh(
        config: MiriConfig,
        availableApps: [RuleAppInfo],
        permissions: MiriPermissionStatus
    ) {
        store.refresh(
            config: config,
            availableApps: availableApps,
            permissions: permissions
        )
    }

    func updatePermissions(_ permissions: MiriPermissionStatus) {
        store.updatePermissions(permissions)
    }

    func presentSaveSuccess(closeOnSuccess: Bool) {
        store.presentSaveSuccess()
        if closeOnSuccess {
            close()
        }
    }

    func presentSaveFailure(reason: String) {
        store.presentSaveFailure(reason: reason)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard store.isDirty else { return true }

        let alert = NSAlert()
        alert.messageText = "Discard unsaved changes?"
        alert.informativeText = "Your changes have not been applied to Miri."
        alert.addButton(withTitle: "Discard Changes")
        alert.addButton(withTitle: "Keep Editing")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
