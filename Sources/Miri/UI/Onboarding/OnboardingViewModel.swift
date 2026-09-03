import Combine
import Foundation

@MainActor
final class OnboardingViewModel: ObservableObject {
    @Published var progress: OnboardingProgress {
        didSet {
            if progress != oldValue {
                progressSink(progress)
            }
        }
    }
    @Published private(set) var permissions: MiriPermissionStatus

    private let progressSink: (OnboardingProgress) -> Void
    private let actionSink: (UIAction) -> Void

    init(
        progress: OnboardingProgress,
        permissions: MiriPermissionStatus,
        progressSink: @escaping (OnboardingProgress) -> Void,
        actionSink: @escaping (UIAction) -> Void
    ) {
        self.progress = progress
        self.permissions = permissions
        self.progressSink = progressSink
        self.actionSink = actionSink
    }

    var stepIndex: Int {
        switch progress.step {
        case .accessibility: return 0
        case .layout: return 1
        case .animation: return 2
        case .ready, .completed: return 3
        }
    }

    var title: String {
        switch progress.step {
        case .accessibility: return "Welcome to Miri"
        case .layout: return "Make it feel like yours"
        case .animation: return "Smooth or instant?"
        case .ready: return "You’re ready"
        case .completed: return "Miri"
        }
    }

    var subtitle: String {
        switch progress.step {
        case .accessibility:
            return "First, allow Miri to arrange your windows. You stay in control of when tiling begins."
        case .layout:
            return "Choose how the focused column sits on screen, then set a comfortable outer margin."
        case .animation:
            return "Choose snapshot transitions for fluid movement, or keep every layout change immediate."
        case .ready:
            return "Miri will now discover your windows and begin managing your desktop."
        case .completed:
            return ""
        }
    }

    var canGoBack: Bool {
        progress.step != .accessibility && progress.step != .completed
    }

    var canGoNext: Bool {
        switch progress.step {
        case .accessibility:
            return permissions.accessibility != .missing
        case .layout, .ready:
            return true
        case .animation:
            guard let enabled = progress.animationsEnabled else { return false }
            return !enabled || permissions.screenRecording == .granted
        case .completed:
            return false
        }
    }

    var nextTitle: String {
        progress.step == .ready ? "Start using Miri" : "Next"
    }

    func updatePermissions(_ permissions: MiriPermissionStatus) {
        self.permissions = permissions
    }

    func requestAccessibility() {
        actionSink(.requestAccessibilityPermission)
    }

    func requestScreenRecording() {
        progressSink(progress)
        actionSink(.requestScreenRecordingPermission)
    }

    func restartForScreenRecording() {
        progressSink(progress)
        actionSink(.restart)
    }

    func goBack() {
        switch progress.step {
        case .layout: progress.step = .accessibility
        case .animation: progress.step = .layout
        case .ready: progress.step = .animation
        case .accessibility, .completed: return
        }
    }

    func goNext() {
        guard canGoNext else { return }
        switch progress.step {
        case .accessibility: progress.step = .layout
        case .layout: progress.step = .animation
        case .animation: progress.step = .ready
        case .ready: actionSink(.completeOnboarding(progress))
        case .completed: break
        }
    }
}
