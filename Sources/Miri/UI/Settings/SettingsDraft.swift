import CoreGraphics
import Foundation

/// A normalized, fully typed representation of every configuration value editable
/// in Settings. Optional config values are resolved once when the editing session
/// begins instead of throughout the view hierarchy.
struct SettingsDraft: Equatable {
    var restoreOnExit: Bool
    var persistLayout: Bool

    var defaultWidthRatio: CGFloat
    var presetWidthRatios: [CGFloat]
    var widthResizeMode: WidthResizeMode
    var focusAlignment: FocusAlignment
    var newWindowPosition: NewWindowPosition
    var minimumWorkspaceCount: Int
    var workspaceAutoBackAndForth: Bool
    var innerGap: CGFloat
    var outerGap: CGFloat
    var parkedSliverWidth: CGFloat

    var animationStrategy: AnimationStrategy
    var snapshotAnimationSpeed: Int
    var animationFPS: Int
    var animationPixelThreshold: CGFloat

    var workspaceBarShowFullscreen: Bool
    var workspaceBarVisibleIconCount: Int
    var workspaceBarOverflowStyle: WorkspaceBarOverflowStyle
    var workspaceBarActiveStyle: WorkspaceBarActiveStyle
    var workspaceBarCenterStyle: WorkspaceBarCenterStyle
    var workspaceBarUseCustomColors: Bool
    var workspaceBarHighlightColor: String
    var workspaceBarDelimiterColor: String
    var workspaceBarCenterBorderOutset: Int
    var workspaceBarCenterBorderThickness: Int

    var keyboardShortcutBackend: KeyboardShortcutBackend
    var excludedKeybindings: [String]
    var keybindings: [String: [String]]

    var windowReconciliationIntervalMS: Int
    var axCreatedPlaceholderProbeCooldownMS: Int
    var likelyFullscreenTransitionGraceMS: Int
    var fullscreenSpaceChangeGuardMS: Int
    var logicalSpaceAutosaveIntervalMinutes: Int
    var activeRescanEnabled: Bool
    var activeRescanBundleIDs: [String]
    var debugLogging: Bool

    var rules: [WindowRule]

    init(config: MiriConfig) {
        let fallback = MiriConfig.fallback

        restoreOnExit = config.restoreOnExit ?? fallback.restoreOnExit ?? true
        persistLayout = config.persistLayout ?? fallback.persistLayout ?? true

        defaultWidthRatio = config.defaultWidthRatio
        presetWidthRatios = config.presetWidthRatios ?? fallback.presetWidthRatios ?? []
        widthResizeMode = config.widthResizeMode ?? fallback.widthResizeMode ?? .default
        focusAlignment = config.focusAlignment ?? fallback.focusAlignment ?? .default
        newWindowPosition = config.newWindowPosition ?? fallback.newWindowPosition ?? .afterActive
        minimumWorkspaceCount = config.minimumWorkspaceCount ?? fallback.minimumWorkspaceCount ?? 1
        workspaceAutoBackAndForth = config.workspaceAutoBackAndForth ?? fallback.workspaceAutoBackAndForth ?? false
        innerGap = config.innerGap ?? fallback.innerGap ?? 0
        outerGap = config.outerGap ?? fallback.outerGap ?? 0
        parkedSliverWidth = config.parkedSliverWidth ?? fallback.parkedSliverWidth ?? 1

        animationStrategy = config.animationStrategy ?? fallback.animationStrategy ?? .snapshot
        snapshotAnimationSpeed = config.snapshotAnimationSpeed ?? fallback.snapshotAnimationSpeed ?? 50
        animationFPS = config.animationFPS ?? fallback.animationFPS ?? 60
        animationPixelThreshold = config.animationPixelThreshold ?? fallback.animationPixelThreshold ?? 0.5

        workspaceBarShowFullscreen = config.workspaceBarShowFullscreen ?? fallback.workspaceBarShowFullscreen ?? true
        workspaceBarVisibleIconCount = config.workspaceBarVisibleIconCount ?? fallback.workspaceBarVisibleIconCount ?? 6
        workspaceBarOverflowStyle = config.workspaceBarOverflowStyle ?? fallback.workspaceBarOverflowStyle ?? .chevron
        workspaceBarActiveStyle = config.workspaceBarActiveStyle ?? fallback.workspaceBarActiveStyle ?? .outline
        workspaceBarCenterStyle = config.workspaceBarCenterStyle ?? fallback.workspaceBarCenterStyle ?? .filledBorder
        workspaceBarUseCustomColors = config.workspaceBarUseCustomColors ?? fallback.workspaceBarUseCustomColors ?? false
        workspaceBarHighlightColor = config.workspaceBarHighlightColor ?? fallback.workspaceBarHighlightColor ?? "#5FFF84"
        workspaceBarDelimiterColor = config.workspaceBarDelimiterColor ?? fallback.workspaceBarDelimiterColor ?? "#D7D4D8"
        workspaceBarCenterBorderOutset = config.workspaceBarCenterBorderOutset ?? fallback.workspaceBarCenterBorderOutset ?? 5
        workspaceBarCenterBorderThickness = config.workspaceBarCenterBorderThickness ?? fallback.workspaceBarCenterBorderThickness ?? 1

        keyboardShortcutBackend = config.keyboardShortcutBackend ?? fallback.keyboardShortcutBackend ?? .eventTap
        excludedKeybindings = config.excludedKeybindings ?? fallback.excludedKeybindings ?? []
        keybindings = config.keybindings ?? MiriConfig.defaultKeybindings

        windowReconciliationIntervalMS = config.windowReconciliationIntervalMS ?? fallback.windowReconciliationIntervalMS ?? 60_000
        axCreatedPlaceholderProbeCooldownMS = config.axCreatedPlaceholderProbeCooldownMS ?? fallback.axCreatedPlaceholderProbeCooldownMS ?? 1_000
        likelyFullscreenTransitionGraceMS = config.likelyFullscreenTransitionGraceMS ?? fallback.likelyFullscreenTransitionGraceMS ?? 1_500
        fullscreenSpaceChangeGuardMS = config.fullscreenSpaceChangeGuardMS ?? fallback.fullscreenSpaceChangeGuardMS ?? 1_500
        logicalSpaceAutosaveIntervalMinutes = config.logicalSpaceAutosaveIntervalMinutes ?? fallback.logicalSpaceAutosaveIntervalMinutes ?? 30
        activeRescanEnabled = config.activeRescanEnabled ?? fallback.activeRescanEnabled ?? true
        activeRescanBundleIDs = config.activeRescanBundleIDs ?? fallback.activeRescanBundleIDs ?? []
        debugLogging = config.debugLogging ?? fallback.debugLogging ?? false

        rules = config.rules
    }

    /// Applies only values represented by Settings to the original document.
    /// Fields not exposed in the UI remain untouched.
    func applying(to source: MiriConfig) -> MiriConfig {
        var config = source

        config.restoreOnExit = restoreOnExit
        config.persistLayout = persistLayout

        config.defaultWidthRatio = defaultWidthRatio
        config.presetWidthRatios = presetWidthRatios
        config.widthResizeMode = widthResizeMode
        config.focusAlignment = focusAlignment
        config.newWindowPosition = newWindowPosition
        config.minimumWorkspaceCount = minimumWorkspaceCount
        config.workspaceAutoBackAndForth = workspaceAutoBackAndForth
        config.innerGap = innerGap
        config.outerGap = outerGap
        config.parkedSliverWidth = parkedSliverWidth

        config.animationStrategy = animationStrategy
        config.snapshotAnimationSpeed = snapshotAnimationSpeed
        config.animationFPS = animationFPS
        config.animationPixelThreshold = animationPixelThreshold

        config.workspaceBarShowFullscreen = workspaceBarShowFullscreen
        config.workspaceBarVisibleIconCount = workspaceBarVisibleIconCount
        config.workspaceBarOverflowStyle = workspaceBarOverflowStyle
        config.workspaceBarActiveStyle = workspaceBarActiveStyle
        config.workspaceBarCenterStyle = workspaceBarCenterStyle
        config.workspaceBarUseCustomColors = workspaceBarUseCustomColors
        config.workspaceBarHighlightColor = workspaceBarHighlightColor
        config.workspaceBarDelimiterColor = workspaceBarDelimiterColor
        config.workspaceBarCenterBorderOutset = workspaceBarCenterBorderOutset
        config.workspaceBarCenterBorderThickness = workspaceBarCenterBorderThickness

        config.keyboardShortcutBackend = keyboardShortcutBackend
        config.excludedKeybindings = excludedKeybindings
        config.keybindings = keybindings

        config.windowReconciliationIntervalMS = windowReconciliationIntervalMS
        config.axCreatedPlaceholderProbeCooldownMS = axCreatedPlaceholderProbeCooldownMS
        config.likelyFullscreenTransitionGraceMS = likelyFullscreenTransitionGraceMS
        config.fullscreenSpaceChangeGuardMS = fullscreenSpaceChangeGuardMS
        config.logicalSpaceAutosaveIntervalMinutes = logicalSpaceAutosaveIntervalMinutes
        config.activeRescanEnabled = activeRescanEnabled
        config.activeRescanBundleIDs = MiriConfig.normalizeBundleIDs(activeRescanBundleIDs)
        config.debugLogging = debugLogging

        config.rules = rules
        return MiriConfig.normalize(config)
    }

    func validationMessage() -> String? {
        let finiteValues: [(String, CGFloat)] = [
            ("Default width", defaultWidthRatio),
            ("Inner gap", innerGap),
            ("Outer gap", outerGap),
            ("Parked sliver", parkedSliverWidth),
            ("Animation pixel threshold", animationPixelThreshold),
        ]
        if let invalid = finiteValues.first(where: { !$0.1.isFinite }) {
            return "\(invalid.0) must be a number."
        }
        if presetWidthRatios.contains(where: { !$0.isFinite }) {
            return "Every width preset must be a number separated by commas."
        }

        var seenBindings: [String: String] = [:]
        for command in keybindings.keys.sorted() {
            for binding in keybindings[command] ?? [] {
                let normalized = binding.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard !normalized.isEmpty else { continue }
                if let previous = seenBindings[normalized] {
                    return "Keybinding '\(binding)' is assigned to both '\(previous)' and '\(command)'."
                }
                seenBindings[normalized] = command
            }
        }
        return nil
    }
}
