import AppKit
import QuartzCore
import SwiftUI

@MainActor
final class OnboardingWindowController: NSWindowController {
    private let model: OnboardingViewModel
    private let permissionProvider: () -> MiriPermissionStatus
    private var permissionTimer: Timer?

    init(
        progress: OnboardingProgress,
        permissions: MiriPermissionStatus,
        permissionProvider: @escaping () -> MiriPermissionStatus,
        progressSink: @escaping (OnboardingProgress) -> Void,
        actionSink: @escaping (UIAction) -> Void
    ) {
        model = OnboardingViewModel(
            progress: progress,
            permissions: permissions,
            progressSink: progressSink,
            actionSink: actionSink
        )
        self.permissionProvider = permissionProvider

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 620),
            styleMask: [.titled, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to Miri"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(
            width: MiriTheme.Size.onboardingMinimumWidth,
            height: MiriTheme.Size.onboardingMinimumHeight
        )
        window.center()

        super.init(window: window)
        let hostingView = NSHostingView(rootView: OnboardingRootView(model: model))
        hostingView.sizingOptions = []
        window.contentView = hostingView
        window.setContentSize(NSSize(width: 820, height: 620))
        window.center()
        startPermissionChecks()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func close() {
        permissionTimer?.invalidate()
        permissionTimer = nil
        super.close()
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        guard let window else { return }
        window.center()
        window.alphaValue = 0
        let finalFrame = window.frame
        window.setFrame(finalFrame.insetBy(dx: 14, dy: 10), display: false)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.35
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
            window.animator().setFrame(finalFrame, display: true)
        }
    }

    func updatePermissions(_ permissions: MiriPermissionStatus) {
        model.updatePermissions(permissions)
    }

    func presentError(_ message: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Could not finish setup"
        alert.informativeText = message
        alert.beginSheetModal(for: window)
    }

    private func startPermissionChecks() {
        permissionTimer = Timer.scheduledTimer(
            timeInterval: 0.5,
            target: self,
            selector: #selector(checkPermissions),
            userInfo: nil,
            repeats: true
        )
    }

    @objc private func checkPermissions() {
        model.updatePermissions(permissionProvider())
    }
}
