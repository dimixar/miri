import AppKit
import ApplicationServices
import Foundation

extension Miri {
    @MainActor func showOnboardingImplementation() {
        if let onboardingWindowController {
            onboardingWindowController.updatePermissions(permissionController.status)
            onboardingWindowController.showWindow(nil)
            onboardingWindowController.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let controller = OnboardingWindowController(
            progress: onboardingStore.progress,
            permissions: permissionController.status,
            permissionProvider: { [weak self] in
                self?.permissionController.status
                    ?? MiriPermissionStatus(accessibility: .missing, screenRecording: .missing)
            },
            progressSink: { [weak self] progress in
                self?.onboardingStore.update(progress)
            },
            actionSink: { [weak self] action in
                self?.enqueue(.ui(action))
            }
        )
        onboardingWindowController = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor func completeOnboardingImplementation(_ progress: OnboardingProgress) {
        guard AXIsProcessTrusted() else {
            onboardingWindowController?.presentError(
                "Accessibility access is no longer available. Return to the first step and grant it again."
            )
            return
        }
        if progress.animationsEnabled == true,
           permissionController.status.screenRecording != .granted
        {
            onboardingWindowController?.presentError(
                "Screen Recording access must be active after a restart before snapshot animations can be enabled."
            )
            return
        }

        var config = configStore.documentConfig
        config.focusAlignment = progress.focusAlignment
        config.outerGap = CGFloat(progress.outerGap)
        config.animationStrategy = progress.animationsEnabled == true ? .snapshot : .off

        switch configStore.save(config) {
        case .saved(let destination):
            onboardingStore.complete(progress)
            permissionController.acknowledgeAccessibilityForCurrentRun()
            onboardingWindowController?.close()
            onboardingWindowController = nil
            enqueue(.config(.saved(destination: destination)))
            startRuntime()
        case .failed(let reason):
            onboardingWindowController?.presentError(reason)
        }
    }
}
