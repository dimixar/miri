import CoreGraphics
import Foundation

enum WindowBehavior: String, Codable {
    case tile
    case float
    case ignore
}

enum FocusAlignment: String, Codable {
    case left
    case center
    case smart
}

enum NewWindowPosition: String, Codable {
    case beforeActive = "before_active"
    case afterActive = "after_active"
    case end
}

enum AnimationCurve: String, Codable {
    case smooth
    case snappy
    case linear
}

enum AnimationStrategy: String, Codable {
    case snapshot
    case off

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        switch value {
        case "off":
            self = .off
        case "snapshot", "smooth_ax", "snappy":
            self = .snapshot
        default:
            self = .snapshot
        }
    }
}

enum WorkspaceBarOverflowStyle: String, Codable {
    case plusCount = "plus_count"
    case dotsCount = "dots_count"
    case chevron
    case none
}

enum WorkspaceBarActiveStyle: String, Codable {
    case braces
    case filledPointer = "filled_pointer"
    case filledDot = "filled_dot"
    case squareBrackets = "square_brackets"
    case angleBrackets = "angle_brackets"
    case outline
    case filledOutline = "filled_outline"

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        switch value {
        case "braces":
            self = .braces
        case "filled_pointer":
            self = .filledPointer
        case "filled_dot":
            self = .filledDot
        case "square_brackets":
            self = .squareBrackets
        case "angle_brackets":
            self = .angleBrackets
        case "outline":
            self = .outline
        case "filled_outline":
            self = .filledOutline
        case "bold", "underline":
            self = .braces
        default:
            self = .braces
        }
    }
}

enum WorkspaceBarCenterStyle: String, Codable {
    case delimiter
    case border
    case filledBorder = "filled_border"
}

enum WidthResizeMode: String, Codable {
    case `default`
    case intelligent
}

enum KeyboardShortcutBackend: String, Codable {
    case eventTap = "event_tap"
    case registeredHotKeys = "registered_hot_keys"
}

struct LoadedMiriConfig {
    var config: MiriConfig
    var sourceURL: URL?
    var sourceModificationDate: Date?
}

struct MiriConfig: Codable {
    var defaultWidthRatio: CGFloat
    var presetWidthRatios: [CGFloat]?
    var animationDurationMS: Int?
    var keyboardAnimationMS: Int?
    var moveColumnAnimationMS: Int?
    var widthAnimationMS: Int?
    var animationCurve: AnimationCurve?
    var animationStrategy: AnimationStrategy?
    var snapshotAnimationSpeed: Int?
    var animationFPS: Int?
    var animationPixelThreshold: CGFloat?
    var workspaceAutoBackAndForth: Bool?
    var centerFocusedColumn: Bool?
    var focusAlignment: FocusAlignment?
    var newWindowPosition: NewWindowPosition?
    var innerGap: CGFloat?
    var outerGap: CGFloat?
    var parkedSliverWidth: CGFloat?
    var keyboardShortcutBackend: KeyboardShortcutBackend?
    var axCreatedPlaceholderProbeCooldownMS: Int?
    var excludedKeybindings: [String]?
    var keybindings: [String: [String]]?
    var windowReconciliationIntervalMS: Int?
    var likelyFullscreenTransitionGraceMS: Int?
    var fullscreenSpaceChangeGuardMS: Int?
    var logicalSpaceAutosaveIntervalMinutes: Int?
    var restoreOnExit: Bool?
    var persistLayout: Bool?
    var statePath: String?
    var debugLogging: Bool?
    var widthResizeMode: WidthResizeMode?
    var workspaceBarHighlightColor: String?
    var workspaceBarVisibleIconCount: Int?
    var workspaceBarOverflowStyle: WorkspaceBarOverflowStyle?
    var workspaceBarShowFullscreen: Bool?
    var workspaceBarActiveStyle: WorkspaceBarActiveStyle?
    var workspaceBarCenterStyle: WorkspaceBarCenterStyle?
    var workspaceBarDelimiterColor: String?
    var workspaceBarCenterBorderOutset: Int?
    var workspaceBarCenterBorderThickness: Int?
    var rules: [WindowRule]

    static let fallback = MiriConfig(
        defaultWidthRatio: 0.8,
        presetWidthRatios: [0.5, 0.67, 0.8, 1.0],
        animationDurationMS: 240,
        keyboardAnimationMS: 240,
        moveColumnAnimationMS: 240,
        widthAnimationMS: 280,
        animationCurve: .smooth,
        animationStrategy: .snapshot,
        snapshotAnimationSpeed: 50,
        animationFPS: 60,
        animationPixelThreshold: 0.5,
        workspaceAutoBackAndForth: true,
        centerFocusedColumn: true,
        focusAlignment: .smart,
        newWindowPosition: .afterActive,
        innerGap: 0,
        outerGap: 0,
        parkedSliverWidth: 1,
        keyboardShortcutBackend: .eventTap,
        axCreatedPlaceholderProbeCooldownMS: 1000,
        excludedKeybindings: ["lalt+shift+5"],
        keybindings: defaultKeybindings,
        windowReconciliationIntervalMS: 60000,
        likelyFullscreenTransitionGraceMS: 1500,
        fullscreenSpaceChangeGuardMS: 1500,
        logicalSpaceAutosaveIntervalMinutes: 30,
        restoreOnExit: true,
        persistLayout: true,
        statePath: nil,
        debugLogging: false,
        widthResizeMode: .default,
        workspaceBarHighlightColor: "#5FFF84",
        workspaceBarVisibleIconCount: 6,
        workspaceBarOverflowStyle: .chevron,
        workspaceBarShowFullscreen: true,
        workspaceBarActiveStyle: .outline,
        workspaceBarCenterStyle: .filledBorder,
        workspaceBarDelimiterColor: "#D7D4D8",
        workspaceBarCenterBorderOutset: 5,
        workspaceBarCenterBorderThickness: 1,
        rules: [
            WindowRule(bundleID: "com.apple.finder", behavior: .ignore),
        ]
    )

    static let defaultKeybindings: [String: [String]] = [
        "focus_workspace_1": ["lalt+1"],
        "focus_workspace_2": ["lalt+2"],
        "focus_workspace_3": ["lalt+3"],
        "focus_workspace_4": ["lalt+4"],
        "focus_workspace_5": ["lalt+5"],
        "focus_workspace_6": ["lalt+6"],
        "focus_workspace_7": ["lalt+7"],
        "focus_workspace_8": ["lalt+8"],
        "focus_workspace_9": ["lalt+9"],
        "focus_previous_workspace": ["lalt+0"],
        "workspace_down": ["lalt+j"],
        "workspace_up": ["lalt+k"],
        "column_left": ["lalt+h"],
        "column_right": ["lalt+l"],
        "column_first": ["lalt+[", "lalt+home"],
        "column_last": ["lalt+]", "lalt+end"],
        "move_column_to_workspace_1": ["lalt+shift+1"],
        "move_column_to_workspace_2": ["lalt+shift+2"],
        "move_column_to_workspace_3": ["lalt+shift+3"],
        "move_column_to_workspace_4": ["lalt+shift+4"],
        "move_column_to_workspace_5": ["lalt+shift+5"],
        "move_column_to_workspace_6": ["lalt+shift+6"],
        "move_column_to_workspace_7": ["lalt+shift+7"],
        "move_column_to_workspace_8": ["lalt+shift+8"],
        "move_column_to_workspace_9": ["lalt+shift+9"],
        "move_column_down": ["lalt+shift+j"],
        "move_column_up": ["lalt+shift+k"],
        "move_column_left": ["lalt+shift+h"],
        "move_column_right": ["lalt+shift+l"],
        "move_column_to_first": ["lalt+shift+[", "lalt+shift+home"],
        "move_column_to_last": ["lalt+shift+]", "lalt+shift+end"],
        "cycle_width_preset_backward": ["lalt+ctrl+h"],
        "cycle_width_preset_forward": ["lalt+ctrl+l"],
        "nudge_width_narrower": ["lalt+ctrl+-"],
        "nudge_width_wider": ["lalt+ctrl+="],
        "cycle_all_width_presets_backward": ["lalt+ctrl+shift+h"],
        "cycle_all_width_presets_forward": ["lalt+ctrl+shift+l"],
        "nudge_all_widths_narrower": ["lalt+ctrl+shift+-"],
        "nudge_all_widths_wider": ["lalt+ctrl+shift+="],
    ]

    static func load() -> MiriConfig {
        loadWithMetadata().config
    }

    static func loadWithMetadata(logLoaded: Bool = true, logErrors: Bool = true) -> LoadedMiriConfig {
        let candidates = configCandidates()
        let decoder = JSONDecoder()

        for url in candidates {
            guard let data = try? Data(contentsOf: url) else {
                continue
            }

            do {
                let config = normalize(try decoder.decode(MiriConfig.self, from: data))
                if logLoaded {
                    print("miri: loaded config \(url.path)")
                }
                return LoadedMiriConfig(
                    config: config,
                    sourceURL: url,
                    sourceModificationDate: modificationDate(for: url)
                )
            } catch {
                if logErrors {
                    fputs("miri: failed to parse config \(url.path): \(error)\n", stderr)
                }
            }
        }

        return LoadedMiriConfig(config: .fallback, sourceURL: nil, sourceModificationDate: nil)
    }

    static func modificationDate(for url: URL) -> Date? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return nil
        }
        return attributes[.modificationDate] as? Date
    }

    private static func normalize(_ loadedConfig: MiriConfig) -> MiriConfig {
        var config = loadedConfig
        config.defaultWidthRatio = config.defaultWidthRatio.clampedWidthRatio
        config.presetWidthRatios = normalizeWidthPresets(config.presetWidthRatios)
        config.animationDurationMS = config.animationDurationMS.map { min(max($0, 0), 500) }
        config.keyboardAnimationMS = config.keyboardAnimationMS.map { min(max($0, 0), 500) }
        config.moveColumnAnimationMS = config.moveColumnAnimationMS.map { min(max($0, 0), 500) }
        config.widthAnimationMS = config.widthAnimationMS.map { min(max($0, 0), 500) }
        config.snapshotAnimationSpeed = config.snapshotAnimationSpeed.map { min(max($0, 1), 100) }
        config.animationFPS = config.animationFPS.map { min(max($0, 1), 120) }
        config.animationPixelThreshold = config.animationPixelThreshold.map { min(max($0, 0), 32) }
        config.innerGap = config.innerGap.map { min(max($0, 0), 96) }
        config.outerGap = config.outerGap.map { min(max($0, 0), 96) }
        config.parkedSliverWidth = config.parkedSliverWidth.map { min(max($0, 0), 32) }
        config.windowReconciliationIntervalMS = config.windowReconciliationIntervalMS.map { min(max($0, 5000), 300000) }
        config.likelyFullscreenTransitionGraceMS = config.likelyFullscreenTransitionGraceMS.map { min(max($0, 100), 2000) }
        config.fullscreenSpaceChangeGuardMS = config.fullscreenSpaceChangeGuardMS.map { min(max($0, 100), 3000) }
        config.logicalSpaceAutosaveIntervalMinutes = config.logicalSpaceAutosaveIntervalMinutes.map { min(max($0, 1), 60) }
        config.workspaceBarVisibleIconCount = config.workspaceBarVisibleIconCount.map { min(max($0, 1), 6) }
        config.workspaceBarCenterBorderOutset = config.workspaceBarCenterBorderOutset.map { min(max($0, 0), 5) }
        config.workspaceBarCenterBorderThickness = config.workspaceBarCenterBorderThickness.map { min(max($0, 1), 3) }
        config.rules = config.rules.map { rule in
            var rule = rule
            rule.widthRatio = rule.widthRatio.map(\.clampedWidthRatio)
            rule.workspace = rule.workspace.map { min(max($0, 1), 99) }
            return rule
        }
        return config
    }

    private static func normalizeWidthPresets(_ presets: [CGFloat]?) -> [CGFloat]? {
        guard let presets else {
            return nil
        }

        let sorted = presets
            .filter(\.isFinite)
            .map(\.clampedManualWidthRatio)
            .sorted()
        var unique: [CGFloat] = []
        for preset in sorted where unique.last.map({ abs($0 - preset) >= 0.005 }) ?? true {
            unique.append(preset)
        }
        return unique.isEmpty ? nil : unique
    }

    private static func configCandidates() -> [URL] {
        var urls: [URL] = []

        if let path = ProcessInfo.processInfo.environment["MIRI_CONFIG"], !path.isEmpty {
            urls.append(URL(fileURLWithPath: NSString(string: path).expandingTildeInPath))
        }

        urls.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("miri.config.json"))

        let xdgConfig = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
            .map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        urls.append(xdgConfig.appendingPathComponent("miri/config.json"))

        return urls
    }

    private enum CodingKeys: String, CodingKey {
        case defaultWidthRatio = "default_width_ratio"
        case presetWidthRatios = "preset_width_ratios"
        case animationDurationMS = "animation_duration_ms"
        case keyboardAnimationMS = "keyboard_animation_ms"
        case moveColumnAnimationMS = "move_column_animation_ms"
        case widthAnimationMS = "width_animation_ms"
        case animationCurve = "animation_curve"
        case animationStrategy = "animation_strategy"
        case snapshotAnimationSpeed = "snapshot_animation_speed"
        case animationFPS = "animation_fps"
        case animationPixelThreshold = "animation_pixel_threshold"
        case workspaceAutoBackAndForth = "workspace_auto_back_and_forth"
        case centerFocusedColumn = "center_focused_column"
        case focusAlignment = "focus_alignment"
        case newWindowPosition = "new_window_position"
        case innerGap = "inner_gap"
        case outerGap = "outer_gap"
        case parkedSliverWidth = "parked_sliver_width"
        case keyboardShortcutBackend = "keyboard_shortcut_backend"
        case axCreatedPlaceholderProbeCooldownMS = "ax_created_placeholder_probe_cooldown_ms"
        case excludedKeybindings = "excluded_keybindings"
        case keybindings
        case windowReconciliationIntervalMS = "window_reconciliation_interval_ms"
        case likelyFullscreenTransitionGraceMS = "likely_fullscreen_transition_grace_ms"
        case fullscreenSpaceChangeGuardMS = "fullscreen_space_change_guard_ms"
        case logicalSpaceAutosaveIntervalMinutes = "logical_space_autosave_interval_minutes"
        case restoreOnExit = "restore_on_exit"
        case persistLayout = "persist_layout"
        case statePath = "state_path"
        case debugLogging = "debug_logging"
        case widthResizeMode = "width_resize_mode"
        case workspaceBarHighlightColor = "workspace_bar_highlight_color"
        case workspaceBarVisibleIconCount = "workspace_bar_visible_icon_count"
        case workspaceBarOverflowStyle = "workspace_bar_overflow_style"
        case workspaceBarShowFullscreen = "workspace_bar_show_fullscreen"
        case workspaceBarActiveStyle = "workspace_bar_active_style"
        case workspaceBarCenterStyle = "workspace_bar_center_style"
        case workspaceBarDelimiterColor = "workspace_bar_delimiter_color"
        case workspaceBarCenterBorderOutset = "workspace_bar_center_border_outset"
        case workspaceBarCenterBorderThickness = "workspace_bar_center_border_thickness"
        case rules
    }
}

struct WindowRule: Codable {
    var bundleID: String?
    var appName: String?
    var titleContains: String?
    var titleExactMatch: Bool?
    var behavior: WindowBehavior?
    var widthRatio: CGFloat?
    var workspace: Int?
    var openPosition: NewWindowPosition?

    init(
        bundleID: String? = nil,
        appName: String? = nil,
        titleContains: String? = nil,
        titleExactMatch: Bool? = nil,
        behavior: WindowBehavior? = nil,
        widthRatio: CGFloat? = nil,
        workspace: Int? = nil,
        openPosition: NewWindowPosition? = nil
    ) {
        self.bundleID = bundleID
        self.appName = appName
        self.titleContains = titleContains
        self.titleExactMatch = titleExactMatch
        self.behavior = behavior
        self.widthRatio = widthRatio
        self.workspace = workspace
        self.openPosition = openPosition
    }

    func matches(_ window: ManagedWindow) -> Bool {
        if let bundleID, window.bundleID != bundleID {
            return false
        }
        if let appName, window.appName != appName {
            return false
        }
        if let titleContains {
            if titleExactMatch == true {
                if window.title.compare(titleContains, options: [.caseInsensitive, .diacriticInsensitive]) != .orderedSame {
                    return false
                }
            } else if window.title.range(of: titleContains, options: [.caseInsensitive, .diacriticInsensitive]) == nil {
                return false
            }
        }
        return bundleID != nil || appName != nil || titleContains != nil
    }

    private enum CodingKeys: String, CodingKey {
        case bundleID = "bundle_id"
        case appName = "app_name"
        case titleContains = "title_contains"
        case titleExactMatch = "title_exact_match"
        case behavior
        case widthRatio = "width_ratio"
        case workspace
        case openPosition = "open_position"
    }
}

extension CGFloat {
    var clampedWidthRatio: CGFloat {
        Swift.min(Swift.max(self, 0.2), 2.0)
    }

    var clampedManualWidthRatio: CGFloat {
        Swift.min(Swift.max(self, 0.05), 2.0)
    }
}
