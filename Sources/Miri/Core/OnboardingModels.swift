import CoreGraphics
import Foundation

enum OnboardingStep: String, Codable {
    case accessibility
    case layout
    case animation
    case ready
    case completed
}

struct OnboardingProgress: Codable, Equatable {
    var step: OnboardingStep
    var focusAlignment: FocusAlignment
    var outerGap: Double
    var animationsEnabled: Bool?

    static func fresh(config: MiriConfig) -> OnboardingProgress {
        OnboardingProgress(
            step: .accessibility,
            focusAlignment: config.focusAlignment ?? MiriConfig.fallback.focusAlignment ?? .default,
            outerGap: Double(config.outerGap ?? MiriConfig.fallback.outerGap ?? 0),
            animationsEnabled: nil
        )
    }
}

@MainActor
final class OnboardingStore {
    private(set) var progress: OnboardingProgress
    private let url: URL

    init(config: MiriConfig, hasExistingConfiguration: Bool) {
        url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Miri/onboarding.json")

        if CommandLine.arguments.contains("--onboarding") {
            progress = .fresh(config: config)
            persist()
        } else if let data = try? Data(contentsOf: url),
                  let saved = try? JSONDecoder().decode(OnboardingProgress.self, from: data)
        {
            progress = saved
        } else if hasExistingConfiguration {
            progress = OnboardingProgress(
                step: .completed,
                focusAlignment: config.focusAlignment ?? .default,
                outerGap: Double(config.outerGap ?? 0),
                animationsEnabled: config.animationStrategy != .off
            )
            persist()
        } else {
            progress = .fresh(config: config)
            persist()
        }
    }

    var isRequired: Bool {
        progress.step != .completed
    }

    func update(_ progress: OnboardingProgress) {
        self.progress = progress
        persist()
    }

    func complete(_ progress: OnboardingProgress) {
        var completed = progress
        completed.step = .completed
        self.progress = completed
        persist()
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(progress).write(to: url, options: [.atomic])
        } catch {
            fputs("miri: unable to save onboarding progress: \(error.localizedDescription)\n", stderr)
        }
    }
}
