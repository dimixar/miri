import AppKit

/// Samples a changing menu-bar environment for a fixed interval, then returns
/// to event-driven refreshes. Appearance callbacks never open a settling window.
@MainActor
final class WorkspaceBarRefreshScheduler {
    typealias Schedule = (TimeInterval, @escaping @MainActor () -> Void) -> Void

    private let now: () -> TimeInterval
    private let schedule: Schedule
    private let refresh: () -> Void
    private let pollInterval: TimeInterval
    private let settlingDuration: TimeInterval
    private var settlingDeadline: TimeInterval?
    private var refreshScheduled = false

    init(
        pollInterval: TimeInterval = 0.15,
        settlingDuration: TimeInterval = 2,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        schedule: @escaping Schedule = { delay, action in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                action()
            }
        },
        refresh: @escaping () -> Void
    ) {
        precondition(pollInterval > 0 && settlingDuration > 0)
        self.pollInterval = pollInterval
        self.settlingDuration = settlingDuration
        self.now = now
        self.schedule = schedule
        self.refresh = refresh
    }

    func requestRefresh() {
        guard !refreshScheduled else { return }
        enqueueRefresh(after: 0)
    }

    func beginSettling() {
        // Coalesce the model and OS notifications for the same animation.
        // Repeated callbacks must not move the original deadline forward.
        guard settlingDeadline == nil else { return }
        settlingDeadline = now() + settlingDuration
        requestRefresh()
    }

    private func enqueueRefresh(after delay: TimeInterval) {
        refreshScheduled = true
        schedule(delay) { [weak self] in
            self?.performRefresh()
        }
    }

    private func performRefresh() {
        // Keep admission closed while drawing: drawing itself can synchronously
        // trigger AppKit appearance callbacks.
        refresh()
        refreshScheduled = false

        guard let deadline = settlingDeadline else { return }
        let remaining = deadline - now()
        guard remaining > 0 else {
            settlingDeadline = nil
            return
        }
        enqueueRefresh(after: min(pollInterval, remaining))
    }
}

/// Compare resolved values, not NSAppearance object identity: AppKit temporarily
/// swaps appearances while taking fullscreen status-item snapshots.
struct WorkspaceBarAppearanceSignature: Equatable {
    let name: NSAppearance.Name?
    let labelColor: NSColor?
    let accentColor: NSColor?
    let increaseContrast: Bool

    init(appearance: NSAppearance, increaseContrast: Bool) {
        name = appearance.bestMatch(from: [.darkAqua, .aqua])
        self.increaseContrast = increaseContrast
        var labelColor: NSColor?
        var accentColor: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            labelColor = NSColor.labelColor.usingColorSpace(.sRGB)
            accentColor = NSColor.controlAccentColor.usingColorSpace(.sRGB)
        }
        self.labelColor = labelColor
        self.accentColor = accentColor
    }
}
