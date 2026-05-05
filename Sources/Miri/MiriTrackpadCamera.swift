import CoreGraphics
import Foundation

extension Miri {
    func handleTrackpadNavigationEvent(_ event: TrackpadNavigationEvent) {
        guard trackpadNavigationEnabled,
              !transientSystemWindowIsActive(),
              trackpadNavigationAllowedForActiveWindow
        else {
            return
        }

        switch event {
        case .began:
            beginTrackpadCamera()
        case .changed(let delta, let velocity):
            moveTrackpadCamera(delta: delta, velocity: velocity)
        case .ended(let velocity):
            endTrackpadCamera(velocity: velocity)
        }
    }

    func beginTrackpadCamera() {
        guard manualResizeElement == nil else {
            return
        }

        suppressHoverFocusAfterTrackpadMovement()
        cancelHoverFocus()
        hoverFocusRequiresRearm = false
        stopTrackpadMomentum()
        stopAnimation(clearPresentation: false)
        rescanWindows(adoptFocused: false)
        trackpadPendingCameraDelta = .zero
        trackpadLatestCameraVelocity = .zero
        seedTrackpadCamera(viewport: currentViewport())
        startTrackpadRenderLoop()
    }

    func moveTrackpadCamera(delta: CGPoint, velocity: CGPoint) {
        guard manualResizeElement == nil else {
            return
        }

        suppressHoverFocusAfterTrackpadMovement()
        let viewport = currentViewport()
        seedTrackpadCamera(viewport: viewport)
        let cameraDelta = trackpadCameraDelta(from: delta, velocity: velocity, viewport: viewport)
        trackpadPendingCameraDelta.width += cameraDelta.width
        trackpadPendingCameraDelta.height += cameraDelta.height
        trackpadLatestCameraVelocity = trackpadCameraVelocity(from: velocity, viewport: viewport)
        trackpadCameraVelocity = trackpadLatestCameraVelocity
        startTrackpadRenderLoop()
    }

    func endTrackpadCamera(velocity: CGPoint) {
        suppressHoverFocusAfterTrackpadMovement()
        flushTrackpadCameraFrame()
        stopTrackpadRenderLoop()
        let viewport = currentViewport()
        trackpadCameraVelocity = trackpadCameraVelocity(from: velocity, viewport: viewport)
        if abs(trackpadCameraVelocity.x) < abs(trackpadLatestCameraVelocity.x) {
            trackpadCameraVelocity.x = trackpadLatestCameraVelocity.x
        }
        if abs(trackpadCameraVelocity.y) < abs(trackpadLatestCameraVelocity.y) {
            trackpadCameraVelocity.y = trackpadLatestCameraVelocity.y
        }
        guard abs(trackpadCameraVelocity.x) >= trackpadNavigationMomentumMinVelocity
            || abs(trackpadCameraVelocity.y) >= trackpadNavigationMomentumMinVelocity
        else {
            settleTrackpadCamera(focusActiveWindow: true)
            return
        }

        startTrackpadMomentum()
    }

    func trackpadCameraDelta(from delta: CGPoint, velocity: CGPoint, viewport: CGRect) -> CGSize {
        let multiplier = trackpadCameraVelocityGain(for: velocity)
        return CGSize(
            width: -delta.x * viewport.width * trackpadNavigationSensitivity * multiplier,
            height: delta.y * viewport.height * trackpadNavigationSensitivity * multiplier
        )
    }

    func trackpadCameraVelocity(from velocity: CGPoint, viewport: CGRect) -> CGPoint {
        let multiplier = trackpadCameraVelocityGain(for: velocity)
        return CGPoint(
            x: -velocity.x * viewport.width * trackpadNavigationSensitivity * multiplier,
            y: velocity.y * viewport.height * trackpadNavigationSensitivity * multiplier
        )
    }

    func trackpadCameraVelocityGain(for velocity: CGPoint) -> CGFloat {
        let speed = hypot(velocity.x, velocity.y)
        let extra = min(max((speed - 0.35) / 1.4, 0), trackpadNavigationVelocityGain)
        return 1 + extra
    }

    func seedTrackpadCamera(viewport: CGRect) {
        if trackpadCameraY == nil {
            trackpadCameraY = CGFloat(activeWorkspace) * viewport.height
        }

        if let workspace = activeWorkspaceObject(), workspace.scrollOffset == nil {
            workspace.scrollOffset = horizontalCameraOffset(for: workspace, viewport: viewport)
        }
    }

    func startTrackpadMomentum() {
        stopTrackpadMomentum()
        trackpadMomentumLastFrameAt = CFAbsoluteTimeGetCurrent()

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(16), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            self?.stepTrackpadMomentum()
        }
        trackpadMomentumTimer = timer
        timer.resume()
    }

    func startTrackpadRenderLoop() {
        guard trackpadRenderTimer == nil else {
            return
        }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(16), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            self?.flushTrackpadCameraFrame()
        }
        trackpadRenderTimer = timer
        timer.resume()
    }

    func stopTrackpadRenderLoop() {
        trackpadRenderTimer?.cancel()
        trackpadRenderTimer = nil
    }

    func flushTrackpadCameraFrame() {
        guard abs(trackpadPendingCameraDelta.width) >= 0.5 || abs(trackpadPendingCameraDelta.height) >= 0.5 else {
            return
        }

        guard manualResizeElement == nil else {
            trackpadPendingCameraDelta = .zero
            stopTrackpadRenderLoop()
            return
        }

        let viewport = currentViewport()
        seedTrackpadCamera(viewport: viewport)
        let delta = trackpadPendingCameraDelta
        trackpadPendingCameraDelta = .zero
        _ = applyTrackpadCameraDelta(delta, viewport: viewport)
        projectLayout(focusActiveWindow: false, layoutLockDelay: 0)
    }

    func stepTrackpadMomentum() {
        suppressHoverFocusAfterTrackpadMovement()
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = min(max(now - trackpadMomentumLastFrameAt, 1.0 / 120.0), 1.0 / 20.0)
        trackpadMomentumLastFrameAt = now

        let viewport = currentViewport()
        let decay = exp(-trackpadNavigationDeceleration * elapsed)
        trackpadCameraVelocity.x *= decay
        trackpadCameraVelocity.y *= decay

        let cameraDelta = CGSize(
            width: trackpadCameraVelocity.x * elapsed,
            height: trackpadCameraVelocity.y * elapsed
        )
        let clamped = applyTrackpadCameraDelta(cameraDelta, viewport: viewport)
        if clamped.x {
            trackpadCameraVelocity.x = 0
        }
        if clamped.y {
            trackpadCameraVelocity.y = 0
        }

        projectLayout(focusActiveWindow: false, layoutLockDelay: 0)

        if abs(trackpadCameraVelocity.x) < trackpadNavigationMomentumMinVelocity,
           abs(trackpadCameraVelocity.y) < trackpadNavigationMomentumMinVelocity
        {
            stopTrackpadMomentum()
            settleTrackpadCamera(focusActiveWindow: true)
        }
    }

    func stopTrackpadMomentum() {
        trackpadMomentumTimer?.cancel()
        trackpadMomentumTimer = nil
    }

    @discardableResult
    func applyTrackpadCameraDelta(_ delta: CGSize, viewport: CGRect) -> (x: Bool, y: Bool) {
        let currentY = trackpadCameraY ?? CGFloat(activeWorkspace) * viewport.height
        let maxY = max(0, CGFloat(max(workspaces.count - 1, 0)) * viewport.height)
        let nextY = min(max(currentY + delta.height, 0), maxY)
        trackpadCameraY = nextY

        let workspaceIndex = trackpadCameraWorkspaceIndex(cameraY: nextY, viewport: viewport)
        var clampedX = false
        if workspaces.indices.contains(workspaceIndex) {
            let workspace = workspaces[workspaceIndex]
            if !workspace.columns.isEmpty {
                let currentX = horizontalCameraOffset(for: workspace, viewport: viewport)
                let maxX = maxHorizontalCameraOffset(for: workspace, viewport: viewport)
                let nextX = min(max(currentX + delta.width, 0), maxX)
                workspace.scrollOffset = nextX
                clampedX = abs(nextX - (currentX + delta.width)) > 0.5
            }
        }

        let clampedY = abs(nextY - (currentY + delta.height)) > 0.5
        return (clampedX, clampedY)
    }

    func settleTrackpadCamera(focusActiveWindow: Bool) {
        guard !workspaces.isEmpty else {
            trackpadCameraY = nil
            return
        }

        let viewport = currentViewport()
        seedTrackpadCamera(viewport: viewport)
        let previousState = captureLayoutState()
        let targetWorkspace = trackpadCameraWorkspaceIndex(
            cameraY: trackpadCameraY ?? CGFloat(activeWorkspace) * viewport.height,
            viewport: viewport
        )
        setActiveWorkspace(targetWorkspace)

        if let workspace = activeWorkspaceObject(), !workspace.columns.isEmpty {
            let offset = horizontalCameraOffset(for: workspace, viewport: viewport)
            switch trackpadNavigationSnap {
            case .nearestColumn:
                workspace.activeColumn = closestColumn(to: offset, in: workspace, viewport: viewport)
                workspace.scrollOffset = nil
            case .nearestVisible:
                workspace.activeColumn = mostVisibleColumn(in: workspace, viewport: viewport, scrollOffset: offset)
                workspace.scrollOffset = offset
            case .none:
                workspace.activeColumn = mostVisibleColumn(in: workspace, viewport: viewport, scrollOffset: offset)
                workspace.scrollOffset = offset
            }
        }

        if trackpadNavigationSnap != .none {
            trackpadCameraY = nil
        }
        trackpadCameraVelocity = .zero
        trackpadLatestCameraVelocity = .zero
        trackpadPendingCameraDelta = .zero
        hoverFocusRequiresRearm = true
        suppressHoverFocusAfterTrackpadMovement()

        let targetState = captureLayoutState()
        projectLayout(
            focusActiveWindow: focusActiveWindow,
            animated: previousState != targetState,
            from: previousState,
            animationDuration: trackpadSettleAnimationDuration,
            layoutLockDelay: 0.04
        )
    }

    func clearTrackpadCamera() {
        stopTrackpadRenderLoop()
        stopTrackpadMomentum()
        trackpadPendingCameraDelta = .zero
        trackpadLatestCameraVelocity = .zero
        trackpadCameraY = nil
        trackpadCameraVelocity = .zero
    }

    func freezeTrackpadCameraForTransition() {
        stopTrackpadRenderLoop()
        stopTrackpadMomentum()

        if abs(trackpadPendingCameraDelta.width) >= 0.5 || abs(trackpadPendingCameraDelta.height) >= 0.5 {
            let viewport = currentViewport()
            seedTrackpadCamera(viewport: viewport)
            _ = applyTrackpadCameraDelta(trackpadPendingCameraDelta, viewport: viewport)
            trackpadPendingCameraDelta = .zero
        }

        trackpadLatestCameraVelocity = .zero
        trackpadCameraVelocity = .zero
    }

}
