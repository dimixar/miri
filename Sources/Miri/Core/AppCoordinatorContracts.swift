import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

/// The coordinator-owned lifecycle used to admit or defer cross-domain work.
enum AppPhase: String {
    case starting
    case running
    case sessionUnavailable
    case terminating
    case terminated
}

struct EventSequence: Hashable, Comparable, CustomStringConvertible {
    let rawValue: UInt64

    static func < (lhs: EventSequence, rhs: EventSequence) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var description: String { String(rawValue) }
}

struct LayoutRequest {
    let token: LayoutRequestToken
    let previousLayout: LayoutSnapshot?
    let currentLayout: LayoutSnapshot
    let focusActiveWindow: Bool
    let animated: Bool
}

enum LayoutEvent {
    case completed(token: LayoutRequestToken)
    case cancelled(token: LayoutRequestToken)
    case captureFailed(token: LayoutRequestToken, reason: String)
    case externallyResized(windowID: UInt32?)
}

typealias LayoutSnapshot = LayoutState

struct ModelChange {
    var previousLayout: LayoutSnapshot?
    var currentLayout: LayoutSnapshot
    var layoutRequired: Bool
    var focusRequested: Bool
    var persistenceChanged: Bool
    var statusChanged: Bool
}

struct ReconciliationIntent {
    enum Scope {
        case allWindows
        case applications(Set<pid_t>)
    }

    enum Source: String, Equatable {
        case startup
        case accessibility
        case workspace
        case periodicTimer
        case activeRescan
        case launchSettling
        case sessionRecovery
        case userInterface
        case delayedProbe
    }

    var id: EventSequence?
    var scope: Scope
    var adoptFocused: Bool
    var source: Source
    var reason: String

    static func all(
        adoptFocused: Bool,
        source: Source,
        reason: String
    ) -> ReconciliationIntent {
        ReconciliationIntent(
            id: nil,
            scope: .allWindows,
            adoptFocused: adoptFocused,
            source: source,
            reason: reason
        )
    }

    static func application(
        pid: pid_t,
        adoptFocused: Bool,
        source: Source,
        reason: String
    ) -> ReconciliationIntent {
        ReconciliationIntent(
            id: nil,
            scope: .applications([pid]),
            adoptFocused: adoptFocused,
            source: source,
            reason: reason
        )
    }

    mutating func merge(_ other: ReconciliationIntent) {
        adoptFocused = adoptFocused || other.adoptFocused
        if reason != other.reason {
            reason = "coalesced"
        }
        switch (scope, other.scope) {
        case (.allWindows, _), (_, .allWindows):
            scope = .allWindows
        case (.applications(let lhs), .applications(let rhs)):
            scope = .applications(lhs.union(rhs))
        }
    }
}

enum InputEvent {
    case command(Command, animateWorkspace: Bool)
    case sessionRecoveryRequested(reason: String, command: Command?)
    case userInteraction
    case focusedWindowProbeRequested(reason: String)
    case focusedWindowProbeDue(reason: String, generation: UInt64)
    case eventTapDisabled(CGEventType)
    case sessionRecoveryEventTapDisabled
    case sessionRecoveryCandidate(event: CGEvent, type: CGEventType)
}

enum SessionEvent {
    case stateChanged(
        screenLocked: Bool?,
        workspaceActive: Bool?,
        systemSleeping: Bool?,
        reason: String
    )
    case recoveryReady(generation: UInt64, reason: String)
}

enum WorkspaceEvent {
    case applicationActivated(NSRunningApplication)
    case applicationActivationSettled(NSRunningApplication)
    case applicationLaunched(NSRunningApplication)
    case applicationTerminated(NSRunningApplication)
    case activeSpaceChanged
}

enum WindowEvent {
    case accessibilityNotification(name: String, element: AXUIElement)
    case reconciliationRequested(ReconciliationIntent)
    case removeTerminatedApplication(pid_t)
    case environmentGuardEvaluated(blocked: Bool, recovered: Bool)
}

enum TimerEvent {
    case manualResizeEnded(element: AXUIElement)
    case reconciliationDrain(generation: UInt64)
}

enum UIAction {
    case showSettings
    case openConfig
    case reloadConfig
    case rescanWindows
    case saveConfig(MiriConfig, closeOnSuccess: Bool)
    case quit
}

enum ConfigEvent {
    case loaded(source: URL?)
    case reloadFailed(reason: String)
    case saved(destination: URL)
    case saveFailed(reason: String)
}

enum PersistenceEvent {
    enum SnapshotKind: String {
        case layout
        case logicalSpaces
        case exitRestoration
    }

    case autosaveDue(kind: SnapshotKind)
    case writeCompleted(kind: SnapshotKind)
    case writeFailed(kind: SnapshotKind, reason: String)
}

/// Some payloads wrap AppKit/AX references. They are never transferred away from
/// the main actor; unchecked sendability only permits the checked main-queue
/// bridge in `Miri.enqueue`.
enum AppEvent: @unchecked Sendable {
    case input(InputEvent)
    case session(SessionEvent)
    case workspace(WorkspaceEvent)
    case windows(WindowEvent)
    case layout(LayoutEvent)
    case config(ConfigEvent)
    case persistence(PersistenceEvent)
    case timer(TimerEvent)
    case ui(UIAction)
    case terminate(reason: String)
}

struct SequencedAppEvent {
    let sequence: EventSequence
    let event: AppEvent
}
