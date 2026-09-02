import ApplicationServices
import CoreGraphics
import Foundation

enum MiriPermissionState: Equatable {
    case missing
    case granted
    case restartRequired
}

struct MiriPermissionStatus: Equatable {
    let accessibility: MiriPermissionState
    let screenRecording: MiriPermissionState
}

enum MiriPermissionPolicy {
    static func state(
        grantedAtLaunch: Bool,
        grantedNow: Bool,
        grantObservedDuringRun: Bool = false
    ) -> MiriPermissionState {
        guard grantedNow || grantObservedDuringRun else {
            return .missing
        }
        return grantedAtLaunch ? .granted : .restartRequired
    }
}

@MainActor
final class MiriPermissionController {
    private var accessibilityGrantedAtLaunch: Bool
    private let screenRecordingGrantedAtLaunch: Bool
    private var accessibilityGrantObservedDuringRun = false
    private var screenRecordingGrantObservedDuringRun = false

    init() {
        accessibilityGrantedAtLaunch = AXIsProcessTrusted()
        screenRecordingGrantedAtLaunch = CGPreflightScreenCaptureAccess()
    }

    var status: MiriPermissionStatus {
        MiriPermissionStatus(
            accessibility: MiriPermissionPolicy.state(
                grantedAtLaunch: accessibilityGrantedAtLaunch,
                grantedNow: AXIsProcessTrusted(),
                grantObservedDuringRun: accessibilityGrantObservedDuringRun
            ),
            screenRecording: MiriPermissionPolicy.state(
                grantedAtLaunch: screenRecordingGrantedAtLaunch,
                grantedNow: CGPreflightScreenCaptureAccess(),
                grantObservedDuringRun: screenRecordingGrantObservedDuringRun
            )
        )
    }

    func acknowledgeAccessibilityForCurrentRun() {
        if AXIsProcessTrusted() {
            accessibilityGrantedAtLaunch = true
            accessibilityGrantObservedDuringRun = true
        }
    }

    @discardableResult
    func requestAccessibility() -> MiriPermissionStatus {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        accessibilityGrantObservedDuringRun = AXIsProcessTrustedWithOptions(options)
        return status
    }

    @discardableResult
    func requestScreenRecording() -> MiriPermissionStatus {
        screenRecordingGrantObservedDuringRun = CGRequestScreenCaptureAccess()
        return status
    }
}
