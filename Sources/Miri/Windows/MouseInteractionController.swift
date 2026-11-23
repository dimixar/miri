import CoreGraphics
import Foundation

enum MouseInteractionPhase {
    case pending, dragging, resizing
}

enum MouseScrollDirection {
    case left, right
}

enum MouseInteractionPreview {
    case none
    case swap(target: ManagedWindow, frame: CGRect)
    case scroll(direction: MouseScrollDirection, canScroll: Bool)
}

@MainActor
struct MouseInteractionSession {
    let generation: UInt64
    let window: ManagedWindow
    let workspace: Workspace
    let logicalSpaceID: Int
    let initialFrame: CGRect
    let initialScrollOffset: CGFloat
    let initialPointer: CGPoint
    var latestFrame: CGRect
    var pointer: CGPoint
    var phase: MouseInteractionPhase
    var preview: MouseInteractionPreview
    var scrollOffset: CGFloat
    var ending: Bool
}

@MainActor
final class MouseInteractionController {
    private(set) var session: MouseInteractionSession?
    var isActive: Bool { session != nil }

    private let emitTick: (UInt64) -> Void
    private(set) var generation: UInt64 = 0
    private var timer: DispatchSourceTimer?
    private var edgeDirection: MouseScrollDirection?
    private var edgeEnteredAt: CFAbsoluteTime?
    private var lastScrollAt: CFAbsoluteTime?
    private var edgeViewport: CGRect?

    init(emitTick: @escaping (UInt64) -> Void) {
        self.emitTick = emitTick
    }

    deinit {
        timer?.cancel()
    }

    @discardableResult
    func begin(
        window: ManagedWindow,
        workspace: Workspace,
        logicalSpaceID: Int,
        frame: CGRect,
        scrollOffset: CGFloat,
        pointer: CGPoint
    ) -> UInt64 {
        stopTimer()
        resetEdge()
        generation += 1
        let token = generation
        session = MouseInteractionSession(
            generation: token, window: window, workspace: workspace,
            logicalSpaceID: logicalSpaceID, initialFrame: frame,
            initialScrollOffset: scrollOffset, initialPointer: pointer,
            latestFrame: frame, pointer: pointer, phase: .pending,
            preview: .none, scrollOffset: scrollOffset, ending: false
        )
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1.0 / 30, repeating: 1.0 / 30)
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == token,
                      let session = self.session, !session.ending else { return }
                self.emitTick(token)
            }
        }
        self.timer = timer
        timer.resume()
        return token
    }

    func updatePointer(_ point: CGPoint) {
        guard session?.ending == false else { return }
        session?.pointer = point
        classifyGesture()
        if let viewport = edgeViewport, edge(at: point, viewport: viewport) != edgeDirection {
            resetEdge()
        }
        session?.preview = .none
    }

    func observeFrame(_ frame: CGRect, finishing: Bool = false) {
        guard let current = session, !current.ending || finishing else { return }
        session?.latestFrame = frame
        classifyGesture()
        if session?.phase != .dragging {
            session?.preview = .none
            resetEdge()
        }
    }

    static func sourceAtMouseDown(
        _ event: MousePointerEvent,
        in workspace: Workspace,
        frameForID: (UInt32) -> CGRect?,
        hitTest: (CGPoint) -> UInt32?
    ) -> (window: ManagedWindow, frame: CGRect)? {
        func hit(_ id: UInt32) -> (ManagedWindow, CGRect)? {
            guard let window = workspace.windows.first(where: { $0.windowID == id }),
                  !window.isMinimized, !window.fullscreenOS,
                  let frame = frameForID(id), frame.contains(event.location) else { return nil }
            return (window, frame)
        }

        for id in [event.windowID, event.alternateWindowID].compactMap({ $0 }) {
            if let source = hit(id) { return source }
        }
        // A nonzero event ID can still be stale or refer to a helper window.
        // Use only the actual frontmost hit, not a tile underneath another app.
        return hitTest(event.location).flatMap(hit)
    }

    static func swapPreview(
        at point: CGPoint, excluding source: ManagedWindow, items: [LayoutItem], viewport: CGRect
    ) -> MouseInteractionPreview {
        guard viewport.contains(point), let target = items.first(where: {
            $0.window !== source && $0.visible && $0.frame.contains(point)
        }) else { return .none }
        return .swap(target: target.window, frame: target.frame)
    }

    func updatePreview(
        items: [LayoutItem], viewport: CGRect, scrollBounds: ClosedRange<CGFloat>,
        now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    ) -> MouseInteractionPreview {
        guard let current = session, current.phase == .dragging, !current.ending else {
            session?.preview = .none
            resetEdge()
            return .none
        }
        let preview: MouseInteractionPreview
        if let direction = trackEdge(viewport: viewport, now: now) {
            preview = .scroll(direction: direction, canScroll: canScroll(direction, bounds: scrollBounds))
        } else {
            preview = Self.swapPreview(at: current.pointer, excluding: current.window, items: items, viewport: viewport)
        }
        session?.preview = preview
        return preview
    }

    func advanceScroll(
        viewport: CGRect, bounds: ClosedRange<CGFloat>,
        speedPercent: Int = 100,
        now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    ) -> CGFloat? {
        guard let current = session, current.phase == .dragging, !current.ending,
              let direction = trackEdge(viewport: viewport, now: now),
              let entered = edgeEnteredAt else { return nil }
        guard canScroll(direction, bounds: bounds) else {
            lastScrollAt = now
            return nil
        }
        let start = max(lastScrollAt ?? entered, entered + 0.25)
        lastScrollAt = now
        guard now > start else { return nil }
        let distance = direction == .left
            ? current.pointer.x - viewport.minX : viewport.maxX - current.pointer.x
        // At 100%: 120–720 points per second, increasing toward the physical edge.
        let speed = (120 + 600 * (1 - min(max(distance / 32, 0), 1))) * CGFloat(speedPercent) / 100
        let delta = speed * CGFloat(now - start) * (direction == .left ? -1 : 1)
        let offset = min(max(current.scrollOffset + delta, bounds.lowerBound), bounds.upperBound)
        guard offset != current.scrollOffset else { return nil }
        session?.scrollOffset = offset
        return offset
    }

    func markEnding() {
        guard session != nil else { return }
        session?.ending = true
        session?.preview = .none
        stopTimer()
        resetEdge()
    }

    @discardableResult
    func finish() -> MouseInteractionSession? {
        guard let result = session else { return nil }
        session = nil
        stopTimer()
        resetEdge()
        return result
    }

    @discardableResult
    func cancel() -> MouseInteractionSession? {
        finish()
    }

    private func classifyGesture() {
        guard let current = session else { return }
        let dx = current.pointer.x - current.initialPointer.x
        let dy = current.pointer.y - current.initialPointer.y
        guard current.phase != .pending || dx * dx + dy * dy >= 9 else { return }
        if abs(current.latestFrame.width - current.initialFrame.width) >= 2
            || abs(current.latestFrame.height - current.initialFrame.height) >= 2 {
            session?.phase = .resizing
        } else if current.phase == .pending,
                  abs(current.latestFrame.minX - current.initialFrame.minX) >= 2
                    || abs(current.latestFrame.minY - current.initialFrame.minY) >= 2 {
            session?.phase = .dragging
        }
    }

    private func edge(at point: CGPoint, viewport: CGRect) -> MouseScrollDirection? {
        guard viewport.contains(point) else { return nil }
        if point.x - viewport.minX <= 32 { return .left }
        if viewport.maxX - point.x <= 32 { return .right }
        return nil
    }

    private func trackEdge(viewport: CGRect, now: CFAbsoluteTime) -> MouseScrollDirection? {
        let direction = session.flatMap { edge(at: $0.pointer, viewport: viewport) }
        if direction != edgeDirection {
            resetEdge()
            edgeDirection = direction
            if direction != nil { edgeEnteredAt = now }
        }
        edgeViewport = viewport
        return direction
    }

    private func canScroll(_ direction: MouseScrollDirection, bounds: ClosedRange<CGFloat>) -> Bool {
        guard let session else { return false }
        return direction == .left
            ? session.scrollOffset > bounds.lowerBound : session.scrollOffset < bounds.upperBound
    }

    private func resetEdge() {
        edgeDirection = nil
        edgeEnteredAt = nil
        lastScrollAt = nil
        edgeViewport = nil
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
        generation += 1
    }
}
