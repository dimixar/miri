import Foundation

enum ConfigInitialLoadResult {
    case loaded(source: URL)
    case fallback(reasons: [String])
}

enum ConfigReloadResult {
    case unchanged
    case reloaded(source: URL)
    case failed(reason: String)
}

enum ConfigSaveResult {
    case saved(destination: URL)
    case failed(reason: String)
}

/// Owns the config document and its file metadata. Runtime consumers receive a
/// fully resolved config; settings edit the last successfully decoded document.
/// Unknown root and rule keys are rejected so a settings save can never silently
/// discard configuration that this version of Miri does not understand.
@MainActor
final class ConfigStore {
    private(set) var documentConfig: MiriConfig
    private(set) var effectiveConfig: MiriConfig
    private(set) var sourceURL: URL?
    private(set) var sourceModificationDate: Date?
    private var observedSourceModificationDate: Date?
    private var observedCandidateURL: URL?
    private(set) var initialLoadResult: ConfigInitialLoadResult

    init() {
        let result = Self.loadFirstAvailable()
        switch result {
        case .success(let loaded):
            documentConfig = loaded.config
            effectiveConfig = loaded.config.resolved()
            sourceURL = loaded.sourceURL
            sourceModificationDate = loaded.sourceModificationDate
            observedSourceModificationDate = loaded.sourceModificationDate
            observedCandidateURL = loaded.sourceURL
            initialLoadResult = loaded.sourceURL.map(ConfigInitialLoadResult.loaded(source:))
                ?? .fallback(reasons: [])
        case .failure(let reasons):
            documentConfig = .fallback
            effectiveConfig = .fallback
            let failedCandidate = MiriConfig.configCandidates().first {
                FileManager.default.fileExists(atPath: $0.path)
            }
            sourceURL = failedCandidate
            sourceModificationDate = nil
            observedSourceModificationDate = nil
            observedCandidateURL = failedCandidate
            observedSourceModificationDate = observedCandidateURL.flatMap(MiriConfig.modificationDate(for:))
            initialLoadResult = .fallback(reasons: reasons)
        }
    }

    var destinationURL: URL {
        sourceURL ?? Self.defaultUserConfigURL
    }

    func sourceHasChanged() -> Bool {
        guard let sourceURL else {
            let candidate = MiriConfig.configCandidates().first {
                FileManager.default.fileExists(atPath: $0.path)
            }
            guard candidate == observedCandidateURL else { return true }
            return candidate.flatMap(MiriConfig.modificationDate(for:)) != observedSourceModificationDate
        }
        return MiriConfig.modificationDate(for: sourceURL) != observedSourceModificationDate
    }

    func reloadCurrentSource(force: Bool = false) -> ConfigReloadResult {
        guard force || sourceHasChanged() else {
            return .unchanged
        }

        let target = sourceURL ?? MiriConfig.configCandidates().first {
            FileManager.default.fileExists(atPath: $0.path)
        }
        guard let target else {
            return .failed(reason: "No config file exists at any supported location.")
        }

        do {
            let config = try Self.readDocument(at: target)
            adopt(config, source: target)
            return .reloaded(source: target)
        } catch {
            observedSourceModificationDate = MiriConfig.modificationDate(for: target)
            observedCandidateURL = target
            return .failed(reason: "\(target.path): \(error.localizedDescription)")
        }
    }

    func save(_ config: MiriConfig) -> ConfigSaveResult {
        let destination = destinationURL
        do {
            let normalized = MiriConfig.normalize(config)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(normalized)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: destination, options: [.atomic])
            adopt(normalized, source: destination)
            return .saved(destination: destination)
        } catch {
            return .failed(reason: error.localizedDescription)
        }
    }

    private func adopt(_ config: MiriConfig, source: URL) {
        documentConfig = config
        effectiveConfig = config.resolved()
        sourceURL = source
        sourceModificationDate = MiriConfig.modificationDate(for: source)
        observedSourceModificationDate = sourceModificationDate
        observedCandidateURL = source
    }

    private enum InitialReadResult {
        case success(LoadedMiriConfig)
        case failure([String])
    }

    private static func loadFirstAvailable() -> InitialReadResult {
        var reasons: [String] = []
        for url in MiriConfig.configCandidates() {
            guard FileManager.default.fileExists(atPath: url.path) else {
                continue
            }
            do {
                let config = try readDocument(at: url)
                print("miri: loaded config \(url.path)")
                return .success(LoadedMiriConfig(
                    config: config,
                    sourceURL: url,
                    sourceModificationDate: MiriConfig.modificationDate(for: url)
                ))
            } catch {
                let reason = "\(url.path): \(error.localizedDescription)"
                reasons.append(reason)
                fputs("miri: failed to parse config \(reason)\n", stderr)
                return .failure(reasons)
            }
        }
        return .failure(reasons)
    }

    private static func readDocument(at url: URL) throws -> MiriConfig {
        let data = try Data(contentsOf: url)
        try rejectUnknownKeys(in: data)
        let config = MiriConfig.normalize(try JSONDecoder().decode(MiriConfig.self, from: data))
        MiriConfig.migrateLegacyFocusAlignmentIfNeeded(config, originalData: data, at: url, logErrors: true)
        return config
    }

    private static func rejectUnknownKeys(in data: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConfigStoreError.rootMustBeObject
        }
        let rootKeys = Set(MiriConfig.CodingKeys.allCases.map(\.rawValue)).union(["center_focused_column"])
        let unknownRootKeys = Set(root.keys).subtracting(rootKeys).sorted()
        guard unknownRootKeys.isEmpty else {
            throw ConfigStoreError.unknownKeys(scope: "config", keys: unknownRootKeys)
        }
        if let rules = root["rules"] as? [[String: Any]] {
            let ruleKeys = Set(WindowRule.CodingKeys.allCases.map(\.rawValue))
            for (index, rule) in rules.enumerated() {
                let unknownRuleKeys = Set(rule.keys).subtracting(ruleKeys).sorted()
                guard unknownRuleKeys.isEmpty else {
                    throw ConfigStoreError.unknownKeys(scope: "rules[\(index)]", keys: unknownRuleKeys)
                }
            }
        }
    }

    private static let defaultUserConfigURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/miri/config.json")
}

private enum ConfigStoreError: LocalizedError {
    case rootMustBeObject
    case unknownKeys(scope: String, keys: [String])

    var errorDescription: String? {
        switch self {
        case .rootMustBeObject:
            return "The config root must be a JSON object."
        case .unknownKeys(let scope, let keys):
            return "Unknown keys in \(scope): \(keys.joined(separator: ", "))."
        }
    }
}

extension MiriConfig {
    func resolved(with fallback: MiriConfig = .fallback) -> MiriConfig {
        var value = self
        value.presetWidthRatios = presetWidthRatios ?? fallback.presetWidthRatios
        value.animationDurationMS = animationDurationMS ?? fallback.animationDurationMS
        value.keyboardAnimationMS = keyboardAnimationMS ?? fallback.keyboardAnimationMS
        value.moveColumnAnimationMS = moveColumnAnimationMS ?? fallback.moveColumnAnimationMS
        value.widthAnimationMS = widthAnimationMS ?? fallback.widthAnimationMS
        value.animationCurve = animationCurve ?? fallback.animationCurve
        value.animationStrategy = animationStrategy ?? fallback.animationStrategy
        value.snapshotAnimationSpeed = snapshotAnimationSpeed ?? fallback.snapshotAnimationSpeed
        value.animationFPS = animationFPS ?? fallback.animationFPS
        value.animationPixelThreshold = animationPixelThreshold ?? fallback.animationPixelThreshold
        value.workspaceAutoBackAndForth = workspaceAutoBackAndForth ?? fallback.workspaceAutoBackAndForth
        value.minimumWorkspaceCount = minimumWorkspaceCount ?? fallback.minimumWorkspaceCount
        value.focusAlignment = focusAlignment ?? fallback.focusAlignment
        value.newWindowPosition = newWindowPosition ?? fallback.newWindowPosition
        value.innerGap = innerGap ?? fallback.innerGap
        value.outerGap = outerGap ?? fallback.outerGap
        value.parkedSliverWidth = parkedSliverWidth ?? fallback.parkedSliverWidth
        value.keyboardShortcutBackend = keyboardShortcutBackend ?? fallback.keyboardShortcutBackend
        value.axCreatedPlaceholderProbeCooldownMS = axCreatedPlaceholderProbeCooldownMS ?? fallback.axCreatedPlaceholderProbeCooldownMS
        value.activeRescanEnabled = activeRescanEnabled ?? fallback.activeRescanEnabled
        value.activeRescanBundleIDs = activeRescanBundleIDs ?? fallback.activeRescanBundleIDs
        value.excludedKeybindings = excludedKeybindings ?? fallback.excludedKeybindings
        value.keybindings = keybindings ?? fallback.keybindings
        value.windowReconciliationIntervalMS = windowReconciliationIntervalMS ?? fallback.windowReconciliationIntervalMS
        value.likelyFullscreenTransitionGraceMS = likelyFullscreenTransitionGraceMS ?? fallback.likelyFullscreenTransitionGraceMS
        value.fullscreenSpaceChangeGuardMS = fullscreenSpaceChangeGuardMS ?? fallback.fullscreenSpaceChangeGuardMS
        value.logicalSpaceAutosaveIntervalMinutes = logicalSpaceAutosaveIntervalMinutes ?? fallback.logicalSpaceAutosaveIntervalMinutes
        value.restoreOnExit = restoreOnExit ?? fallback.restoreOnExit
        value.persistLayout = persistLayout ?? fallback.persistLayout
        value.statePath = statePath ?? fallback.statePath
        value.debugLogging = debugLogging ?? fallback.debugLogging
        value.widthResizeMode = widthResizeMode ?? fallback.widthResizeMode
        value.workspaceBarUseCustomColors = workspaceBarUseCustomColors ?? fallback.workspaceBarUseCustomColors
        value.workspaceBarHighlightColor = workspaceBarHighlightColor ?? fallback.workspaceBarHighlightColor
        value.workspaceBarVisibleIconCount = workspaceBarVisibleIconCount ?? fallback.workspaceBarVisibleIconCount
        value.workspaceBarOverflowStyle = workspaceBarOverflowStyle ?? fallback.workspaceBarOverflowStyle
        value.workspaceBarShowFullscreen = workspaceBarShowFullscreen ?? fallback.workspaceBarShowFullscreen
        value.workspaceBarActiveStyle = workspaceBarActiveStyle ?? fallback.workspaceBarActiveStyle
        value.workspaceBarCenterStyle = workspaceBarCenterStyle ?? fallback.workspaceBarCenterStyle
        value.workspaceBarDelimiterColor = workspaceBarDelimiterColor ?? fallback.workspaceBarDelimiterColor
        value.workspaceBarCenterBorderOutset = workspaceBarCenterBorderOutset ?? fallback.workspaceBarCenterBorderOutset
        value.workspaceBarCenterBorderThickness = workspaceBarCenterBorderThickness ?? fallback.workspaceBarCenterBorderThickness
        return MiriConfig.normalize(value)
    }
}
