import Combine
import Foundation

@MainActor
final class SettingsStore: ObservableObject {
    enum Feedback: Equatable {
        case none
        case saving
        case saved
        case error(String)
    }

    @Published var draft: SettingsDraft {
        didSet {
            if draft != oldValue, feedback != .saving {
                feedback = .none
            }
        }
    }
    @Published private(set) var permissions: MiriPermissionStatus
    @Published private(set) var availableApps: [RuleAppInfo]
    @Published private(set) var feedback: Feedback = .none

    private(set) var sourceConfig: MiriConfig
    private(set) var originalDraft: SettingsDraft
    private let actionSink: (UIAction) -> Void

    init(
        config: MiriConfig,
        availableApps: [RuleAppInfo],
        permissions: MiriPermissionStatus,
        actionSink: @escaping (UIAction) -> Void
    ) {
        sourceConfig = config
        originalDraft = SettingsDraft(config: config)
        draft = originalDraft
        self.availableApps = availableApps
        self.permissions = permissions
        self.actionSink = actionSink
    }

    var isDirty: Bool {
        draft != originalDraft
    }

    var feedbackText: String {
        switch feedback {
        case .none:
            return isDirty ? "Unsaved changes" : "All changes saved"
        case .saving:
            return "Saving…"
        case .saved:
            return "Saved and reloaded"
        case let .error(message):
            return message
        }
    }

    func refresh(
        config: MiriConfig,
        availableApps: [RuleAppInfo],
        permissions: MiriPermissionStatus
    ) {
        sourceConfig = config
        originalDraft = SettingsDraft(config: config)
        draft = originalDraft
        self.availableApps = availableApps
        self.permissions = permissions
        feedback = .none
    }

    func updatePermissions(_ permissions: MiriPermissionStatus) {
        self.permissions = permissions
    }

    func revert() {
        draft = originalDraft
        feedback = .none
    }

    func requestAccessibilityPermission() {
        actionSink(.requestAccessibilityPermission)
    }

    func requestScreenRecordingPermission() {
        actionSink(.requestScreenRecordingPermission)
    }

    @discardableResult
    func submit(closeOnSuccess: Bool) -> Bool {
        guard let config = validatedConfig() else { return false }
        feedback = .saving
        actionSink(.saveConfig(config, closeOnSuccess: closeOnSuccess))
        return true
    }

    @discardableResult
    func saveAndRestart() -> Bool {
        guard let config = validatedConfig() else { return false }
        feedback = .saving
        actionSink(.saveConfigAndRestart(config))
        return true
    }

    func presentSaveSuccess() {
        sourceConfig = draft.applying(to: sourceConfig)
        originalDraft = SettingsDraft(config: sourceConfig)
        draft = originalDraft
        feedback = .saved
    }

    func presentSaveFailure(reason: String) {
        feedback = .error("Could not save: \(reason)")
    }

    private func validatedConfig() -> MiriConfig? {
        if let message = draft.validationMessage() {
            feedback = .error(message)
            return nil
        }
        return draft.applying(to: sourceConfig)
    }
}
