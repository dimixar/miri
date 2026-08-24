import ApplicationServices
import Foundation

/// Owns only external resize observation state and debounce timing. Logical
/// width mutation stays with the model; layout reapplication stays with
/// LayoutController.
final class ManualResizeController: @unchecked Sendable {
    private var endTimer: DispatchSourceTimer?
    private var element: AXUIElement?
    private var suppressedUntil: CFAbsoluteTime = 0
    private let sameWindow: (AXUIElement, AXUIElement) -> Bool
    private let emitEnded: (AXUIElement) -> Void

    init(
        sameWindow: @escaping (AXUIElement, AXUIElement) -> Bool,
        emitEnded: @escaping (AXUIElement) -> Void
    ) {
        self.sameWindow = sameWindow
        self.emitEnded = emitEnded
    }

    var isTracking: Bool { element != nil }
    var notificationsSuppressed: Bool { CFAbsoluteTimeGetCurrent() < suppressedUntil }

    func beginOrContinue(_ candidate: AXUIElement) -> Bool {
        if let element, !sameWindow(element, candidate) { return false }
        element = candidate
        endTimer?.cancel()
        endTimer = nil
        return true
    }

    func scheduleEnd(for candidate: AXUIElement) {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + .milliseconds(140), leeway: .milliseconds(20))
        timer.setEventHandler { [weak self] in self?.emitEnded(candidate) }
        endTimer = timer
        timer.resume()
    }

    func finish(_ candidate: AXUIElement) -> Bool {
        endTimer?.cancel()
        endTimer = nil
        guard element.map({ sameWindow($0, candidate) }) == true else { return false }
        element = nil
        return true
    }

    func isCurrent(_ candidate: AXUIElement) -> Bool {
        element.map { sameWindow($0, candidate) } ?? false
    }

    func suppress(for duration: TimeInterval) {
        guard duration > 0 else { return }
        suppressedUntil = max(suppressedUntil, CFAbsoluteTimeGetCurrent() + duration)
    }

    func cancel() {
        endTimer?.cancel()
        endTimer = nil
        element = nil
    }
}
