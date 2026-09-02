import CoreGraphics
import Foundation

extension Miri {
    var keyboardShortcutBackend: KeyboardShortcutBackend {
        configStore.effectiveConfig.keyboardShortcutBackend ?? MiriConfig.fallback.keyboardShortcutBackend ?? .eventTap
    }

    var animationStrategy: AnimationStrategy {
        let configured = configStore.effectiveConfig.animationStrategy
            ?? MiriConfig.fallback.animationStrategy
            ?? .snapshot
        guard configured == .snapshot else { return configured }
        return permissionController.status.screenRecording == .granted ? .snapshot : .off
    }

    var snapshotAnimationSpeed: Int {
        configStore.effectiveConfig.snapshotAnimationSpeed ?? MiriConfig.fallback.snapshotAnimationSpeed ?? 50
    }

    var animationFPS: Int {
        configStore.effectiveConfig.animationFPS ?? MiriConfig.fallback.animationFPS ?? 30
    }

    var animationPixelThreshold: CGFloat {
        configStore.effectiveConfig.animationPixelThreshold ?? MiriConfig.fallback.animationPixelThreshold ?? 2
    }

    var workspaceAutoBackAndForth: Bool {
        configStore.effectiveConfig.workspaceAutoBackAndForth ?? MiriConfig.fallback.workspaceAutoBackAndForth ?? false
    }

    var minimumWorkspaceCount: Int {
        min(max(configStore.effectiveConfig.minimumWorkspaceCount ?? MiriConfig.fallback.minimumWorkspaceCount ?? 1, 1), 9)
    }

    var focusAlignment: FocusAlignment {
        configStore.effectiveConfig.focusAlignment ?? MiriConfig.fallback.focusAlignment ?? .default
    }

    var newWindowPosition: NewWindowPosition {
        configStore.effectiveConfig.newWindowPosition ?? MiriConfig.fallback.newWindowPosition ?? .afterActive
    }

    var innerGap: CGFloat {
        configStore.effectiveConfig.innerGap ?? MiriConfig.fallback.innerGap ?? 0
    }

    var outerGap: CGFloat {
        configStore.effectiveConfig.outerGap ?? MiriConfig.fallback.outerGap ?? 0
    }

    var parkedSliverWidth: CGFloat {
        configStore.effectiveConfig.parkedSliverWidth ?? MiriConfig.fallback.parkedSliverWidth ?? 1
    }

    var widthPresetRatios: [CGFloat] {
        configStore.effectiveConfig.presetWidthRatios ?? MiriConfig.fallback.presetWidthRatios ?? [0.5, 0.67, 0.8, 1.0]
    }

    var windowReconciliationInterval: TimeInterval {
        TimeInterval(configStore.effectiveConfig.windowReconciliationIntervalMS ?? MiriConfig.fallback.windowReconciliationIntervalMS ?? 60000) / 1000
    }

    var axCreatedPlaceholderProbeCooldown: TimeInterval {
        let milliseconds = configStore.effectiveConfig.axCreatedPlaceholderProbeCooldownMS
            ?? MiriConfig.fallback.axCreatedPlaceholderProbeCooldownMS
            ?? 1000
        return TimeInterval(max(0, milliseconds)) / 1000
    }

    var activeRescanEnabled: Bool {
        configStore.effectiveConfig.activeRescanEnabled ?? MiriConfig.fallback.activeRescanEnabled ?? false
    }

    var activeRescanBundleIDs: Set<String> {
        Set(configStore.effectiveConfig.activeRescanBundleIDs ?? MiriConfig.fallback.activeRescanBundleIDs ?? [])
    }

    var fullscreenTransitionGrace: TimeInterval {
        TimeInterval(configStore.effectiveConfig.likelyFullscreenTransitionGraceMS ?? MiriConfig.fallback.likelyFullscreenTransitionGraceMS ?? 1500) / 1000
    }

    var fullscreenSpaceChangeGuardDuration: TimeInterval {
        TimeInterval(configStore.effectiveConfig.fullscreenSpaceChangeGuardMS ?? MiriConfig.fallback.fullscreenSpaceChangeGuardMS ?? 1500) / 1000
    }

    var logicalSpaceAutosaveInterval: TimeInterval {
        TimeInterval(logicalSpaceAutosaveIntervalMinutes * 60)
    }

    var logicalSpaceAutosaveIntervalMinutes: Int {
        configStore.effectiveConfig.logicalSpaceAutosaveIntervalMinutes ?? MiriConfig.fallback.logicalSpaceAutosaveIntervalMinutes ?? 30
    }

    var restoreOnExit: Bool {
        configStore.effectiveConfig.restoreOnExit ?? MiriConfig.fallback.restoreOnExit ?? true
    }

    var debugLogging: Bool {
        configStore.effectiveConfig.debugLogging ?? MiriConfig.fallback.debugLogging ?? false
    }

    var widthResizeMode: WidthResizeMode {
        configStore.effectiveConfig.widthResizeMode ?? MiriConfig.fallback.widthResizeMode ?? .default
    }
}
