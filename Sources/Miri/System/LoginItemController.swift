import Foundation
import ServiceManagement

enum LoginItemStatus: Equatable {
    case unavailable
    case onboardingRequired
    case notRegistered
    case enabled
    case requiresApproval
    case notFound

    var isRequested: Bool {
        self == .enabled || self == .requiresApproval
    }

    var canChange: Bool {
        self != .unavailable && self != .onboardingRequired
    }

    var detail: String {
        switch self {
        case .unavailable:
            return "Open the packaged Miri.app to manage launch at login."
        case .onboardingRequired:
            return "Finish onboarding before enabling launch at login."
        case .notRegistered:
            return "Start Miri automatically when you log in. Changes apply immediately."
        case .enabled:
            return "Miri will start automatically when you log in. Changes apply immediately."
        case .requiresApproval:
            return "Registered, but blocked by macOS. Allow Miri in System Settings → Login Items to start at login."
        case .notFound:
            return "macOS could not find this login item. Try enabling it again from the installed Miri.app."
        }
    }
}

@MainActor
final class LoginItemController {
    private let isPackagedApp: Bool
    private let readStatus: () -> SMAppService.Status
    private let register: () throws -> Void
    private let unregister: () throws -> Void

    init(
        isPackagedApp: Bool = Bundle.main.bundleURL.pathExtension.lowercased() == "app",
        readStatus: @escaping () -> SMAppService.Status = { SMAppService.mainApp.status },
        register: @escaping () throws -> Void = { try SMAppService.mainApp.register() },
        unregister: @escaping () throws -> Void = { try SMAppService.mainApp.unregister() }
    ) {
        self.isPackagedApp = isPackagedApp
        self.readStatus = readStatus
        self.register = register
        self.unregister = unregister
    }

    func status(onboardingCompleted: Bool) -> LoginItemStatus {
        guard isPackagedApp else { return .unavailable }
        guard onboardingCompleted else { return .onboardingRequired }
        switch readStatus() {
        case .notRegistered: return .notRegistered
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        @unknown default: return .notFound
        }
    }

    @discardableResult
    func setEnabled(_ enabled: Bool, onboardingCompleted: Bool) throws -> LoginItemStatus {
        let current = status(onboardingCompleted: onboardingCompleted)
        guard current.canChange else {
            throw NSError(domain: "MiriLoginItem", code: 1, userInfo: [NSLocalizedDescriptionKey: current.detail])
        }
        guard current.isRequested != enabled else { return current }
        do {
            if enabled { try register() } else { try unregister() }
        } catch {
            // Registration may throw when macOS requires consent, or when an
            // external change has already achieved the requested state.
            let actual = status(onboardingCompleted: onboardingCompleted)
            guard actual.isRequested == enabled, actual != .notFound else { throw error }
        }
        return status(onboardingCompleted: onboardingCompleted)
    }
}
