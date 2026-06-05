import AppKit
import ApplicationServices
import CoreGraphics
import QuartzCore

final class SnapshotAnimationSession: @unchecked Sendable {
    let overlay: SnapshotOverlayWindow
    var cancelled = false
    var layersByWindowID: [ObjectIdentifier: CALayer] = [:]
    var targetFramesByWindowID: [ObjectIdentifier: CGRect] = [:]
    var timer: AnimationTimer?
    var pixelsPerSecond: CGFloat = 0
    var lastFrameTime: CFAbsoluteTime = 0
    var startedAt: CFAbsoluteTime = 0
    var lastDebugTickAt: CFAbsoluteTime = 0
    var generation = 0
    var requestGeneration: UInt64 = 0
    var targetProjectedLayout: [LayoutItem] = []
    var finalLayout: [LayoutItem] = []
    var deferredFloatingRaise = false

    init(overlay: SnapshotOverlayWindow) {
        self.overlay = overlay
    }

    func updateTarget(projectedLayout: [LayoutItem], finalLayout: [LayoutItem], requestGeneration: UInt64, deferredFloatingRaise: Bool) {
        self.targetProjectedLayout = projectedLayout
        self.finalLayout = finalLayout
        self.requestGeneration = requestGeneration
        self.deferredFloatingRaise = deferredFloatingRaise
    }

    func presentationFrames() -> [ObjectIdentifier: CGRect] {
        Dictionary(uniqueKeysWithValues: layersByWindowID.map { id, layer in
            let frame = layer.presentation()?.frame ?? layer.frame
            return (id, overlay.axFrame(forLayerFrame: frame))
        })
    }

    func cancel() {
        guard !cancelled else {
            return
        }
        cancelled = true
        timer?.cancel()
        timer = nil
        overlay.hideAndReset()
    }
}

final class SnapshotOverlayWindow: @unchecked Sendable {
    let window: NSWindow
    let rootLayer: CALayer
    let axViewport: CGRect

    init?(axViewport: CGRect) {
        guard axViewport.width > 1, axViewport.height > 1 else {
            return nil
        }
        self.axViewport = axViewport

        let frame = SnapshotOverlayWindow.appKitFrame(fromAXFrame: axViewport)
        let content = NSView(frame: CGRect(origin: .zero, size: frame.size))
        content.wantsLayer = true
        let rootLayer = CALayer()
        rootLayer.frame = CGRect(origin: .zero, size: frame.size)
        rootLayer.masksToBounds = false
        content.layer = rootLayer

        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.animationBehavior = .none
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.level = .screenSaver
        window.contentView = content

        self.window = window
        self.rootLayer = rootLayer
    }

    func addSnapshotLayer(image: CGImage, at startFrame: CGRect) -> CALayer {
        let layer = CALayer()
        layer.contents = image
        layer.contentsGravity = .resize
        layer.contentsScale = window.backingScaleFactor
        layer.magnificationFilter = .linear
        layer.minificationFilter = .linear
        layer.masksToBounds = true
        layer.frame = layerFrame(forAXFrame: startFrame)
        rootLayer.addSublayer(layer)
        debugSnapshotScaleIfNeeded(image: image, startFrame: startFrame, startLayerFrame: layer.frame)
        return layer
    }

    func setSnapshotLayer(_ layer: CALayer, to axFrame: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAllAnimations()
        layer.frame = layerFrame(forAXFrame: axFrame)
        CATransaction.commit()
    }

    func show() {
        window.level = .screenSaver
        window.orderFrontRegardless()
        window.displayIfNeeded()
        CATransaction.flush()
    }

    func hideAndReset() {
        rootLayer.removeAllAnimations()
        rootLayer.sublayers?.forEach { layer in
            layer.removeAllAnimations()
            layer.removeFromSuperlayer()
        }
        window.orderOut(nil)
        window.level = .floating
    }

    private func debugSnapshotScaleIfNeeded(image: CGImage, startFrame: CGRect, startLayerFrame: CGRect) {
#if DEBUG
        let imagePointSize = CGSize(
            width: CGFloat(image.width) / max(window.backingScaleFactor, 1),
            height: CGFloat(image.height) / max(window.backingScaleFactor, 1)
        )
        if abs(imagePointSize.width - startFrame.width) > 2 || abs(imagePointSize.height - startFrame.height) > 2 {
            NSLog(
                "miri snapshot scale image=%dx%d imagePoints=(%.1f,%.1f) ax=(%.1f,%.1f) layer=(%.1f,%.1f) scale=%.1f",
                image.width,
                image.height,
                imagePointSize.width,
                imagePointSize.height,
                startFrame.width,
                startFrame.height,
                startLayerFrame.width,
                startLayerFrame.height,
                window.backingScaleFactor
            )
        }
#endif
    }

    func axFrame(forLayerFrame frame: CGRect) -> CGRect {
        CGRect(
            x: axViewport.minX + frame.minX,
            y: axViewport.maxY - frame.maxY,
            width: frame.width,
            height: frame.height
        )
    }

    private func layerFrame(forAXFrame frame: CGRect) -> CGRect {
        CGRect(
            x: frame.minX - axViewport.minX,
            y: axViewport.maxY - frame.maxY,
            width: frame.width,
            height: frame.height
        )
    }

    static func appKitFrame(fromAXFrame frame: CGRect) -> CGRect {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main
        guard let screen else {
            return frame
        }
        return CGRect(
            x: frame.minX,
            y: screen.frame.maxY - frame.maxY,
            width: frame.width,
            height: frame.height
        )
    }
}

extension Miri {
    func hideSnapshotWindows(_ windows: [ManagedWindow], parkIn viewport: CGRect? = nil) {
        var hiddenIDs = Set(snapshotHiddenWindows.map(ObjectIdentifier.init))
        for window in windows {
            let id = ObjectIdentifier(window)
            if hiddenIDs.insert(id).inserted {
                snapshotHiddenWindows.append(window)
            }
            appliedVisibility[id] = false
            if let viewport {
                let frame = axFrame(window.element) ?? CGRect(
                    x: viewport.maxX + 8192,
                    y: viewport.minY,
                    width: 320,
                    height: 240
                )
                let parked = CGRect(
                    x: viewport.maxX + 8192,
                    y: frame.minY,
                    width: frame.width,
                    height: frame.height
                )
                setAXFrame(parked, for: window)
            }
        }
    }

    func restoreSnapshotHiddenWindows() {
        guard !snapshotHiddenWindows.isEmpty else {
            return
        }
        for window in snapshotHiddenWindows {
            guard location(of: window.element)?.workspace == activeWorkspace else {
                continue
            }
            let id = ObjectIdentifier(window)
            appliedVisibility[id] = true
        }
        snapshotHiddenWindows.removeAll()
    }

    func prepareInterruptedSnapshotAnimationForNextCapture() {
        guard let session = snapshotAnimationSession else {
            restoreSnapshotHiddenWindows()
            snapshotOverlayWindow?.hideAndReset()
            return
        }

        let hidden = snapshotHiddenWindows
        let frames = session.presentationFrames()
        session.cancel()
        snapshotAnimationSession = nil
        snapshotHiddenWindows.removeAll()
        for window in tiledWindows() {
            let id = ObjectIdentifier(window)
            guard let frame = frames[id] else {
                continue
            }
            setAXFrame(frame, for: window)
            appliedFrames[id] = frame
            appliedVisibility[id] = true
            presentationFrames[id] = frame
        }
        for window in hidden where frames[ObjectIdentifier(window)] == nil {
            guard location(of: window.element)?.workspace == activeWorkspace else {
                continue
            }
            let id = ObjectIdentifier(window)
            appliedVisibility[id] = true
        }
    }

    func completeSnapshotAnimationSession(_ session: SnapshotAnimationSession) {
        session.timer?.cancel()
        session.timer = nil
        snapshotAnimationPreparing = false
        snapshotHiddenWindows.removeAll()
        applyLayout(session.finalLayout, focusActiveWindow: false)
        restoreFloatingVisibility(raise: true, deferred: session.deferredFloatingRaise)
        presentationFrames.removeAll()
        session.cancel()
        snapshotAnimationSession = nil
        releaseLayoutLock()
    }

    func median(_ values: [CGFloat]) -> CGFloat? {
        guard !values.isEmpty else {
            return nil
        }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    func currentSnapshotLayoutFrames(from session: SnapshotAnimationSession) -> [ObjectIdentifier: CGRect] {
        let presentation = session.presentationFrames()
        let targetByWindow = layoutByWindow(session.targetProjectedLayout)
        let offsets = presentation.compactMap { id, frame -> CGPoint? in
            guard let targetFrame = targetByWindow[id]?.frame else {
                return nil
            }
            return CGPoint(
                x: frame.minX - targetFrame.minX,
                y: frame.minY - targetFrame.minY
            )
        }

        guard let dx = median(offsets.map(\.x)),
              let dy = median(offsets.map(\.y))
        else {
            return presentation
        }

        var frames = Dictionary(uniqueKeysWithValues: targetByWindow.map { id, item in
            (id, item.frame.offsetBy(dx: dx, dy: dy))
        })
        for (id, frame) in presentation {
            frames[id] = frame
        }
        return frames
    }

    func snapshotOverlayFrame(for motions: [WindowMotion], viewport: CGRect, workspaceIndex: Int) -> CGRect {
        var overlayFrame = motions.reduce(viewport) { frame, motion in
            frame.union(motion.startFrame).union(motion.endFrame)
        }

        if workspaces.indices.contains(workspaceIndex) {
            let workspace = workspaces[workspaceIndex]
            let metrics = stripMetrics(for: workspace, viewport: viewport)
            let maxOffset = maxHorizontalCameraOffset(for: workspace, viewport: viewport)

            for index in workspace.columns.indices {
                guard metrics.origins.indices.contains(index),
                      metrics.widths.indices.contains(index)
                else {
                    continue
                }

                for offset in [CGFloat(0), maxOffset] {
                    let frame = CGRect(
                        x: viewport.minX + metrics.origins[index] - offset,
                        y: viewport.minY,
                        width: metrics.widths[index],
                        height: viewport.height
                    )
                    overlayFrame = overlayFrame.union(visualFrame(frame, viewport: viewport))
                }
            }
        }

        return overlayFrame.insetBy(dx: -2, dy: -2)
    }

    func addMissingSnapshotLayer(for motion: WindowMotion, to session: SnapshotAnimationSession) -> CALayer? {
        let id = ObjectIdentifier(motion.window)
        if let layer = session.layersByWindowID[id] {
            return layer
        }

        guard let windowID = motion.window.windowID,
              let image = CGWindowListCreateImage(
                .null,
                .optionIncludingWindow,
                CGWindowID(windowID),
                [.bestResolution, .boundsIgnoreFraming]
              )
        else {
            handleMissingSnapshotImage(for: motion.window)
            return nil
        }

        let layer = session.overlay.addSnapshotLayer(image: image, at: motion.startFrame)
        session.layersByWindowID[id] = layer
        hideSnapshotWindows([motion.window], parkIn: session.overlay.axViewport)
        return layer
    }

    func handleMissingSnapshotImage(for window: ManagedWindow) {
        debugLog(
            "snapshot missing image app=\(window.appName) title=\(window.title) pid=\(window.pid) id=\(window.windowID.map(String.init) ?? "nil")"
        )
        deferAXReconciliation(
            pid: window.pid,
            adoptFocused: true,
            reason: "snapshot-missing-image"
        )
    }

    func snapshotDebugFrame(_ frame: CGRect) -> String {
        String(
            format: "(x=%.1f y=%.1f w=%.1f h=%.1f)",
            frame.minX,
            frame.minY,
            frame.width,
            frame.height
        )
    }

    func snapshotDebugWindow(_ window: ManagedWindow) -> String {
        let title = window.title.isEmpty ? "untitled" : window.title
        return "app='\(window.appName)' title='\(title)' id=\(window.windowID.map(String.init) ?? "nil")"
    }

    func debugSnapshotMotions(_ prefix: String, motions: [WindowMotion]) {
        guard debugLogging else {
            return
        }
        for motion in motions.sorted(by: { $0.startFrame.minX < $1.startFrame.minX }) {
            debugLog(
                "\(prefix) \(snapshotDebugWindow(motion.window)) start=\(snapshotDebugFrame(motion.startFrame)) end=\(snapshotDebugFrame(motion.endFrame)) delta=\(String(format: "%.1f", frameDelta(from: motion.startFrame, to: motion.endFrame))) startsVisible=\(motion.startsVisible) endsVisible=\(motion.endsVisible)"
            )
        }
    }

    func snapshotPixelsPerSecond(viewport: CGRect) -> CGFloat {
        let speed = CGFloat(snapshotAnimationSpeed)
        let viewportWidth = max(viewport.width, 1)
        let widthsPerSecond = 0.6 + (speed / 100) * 5.4
        return max(1, viewportWidth * widthsPerSecond)
    }

    func updateSnapshotAnimationTargets(_ motions: [WindowMotion], in session: SnapshotAnimationSession) {
        session.targetFramesByWindowID = Dictionary(uniqueKeysWithValues: motions.map { motion in
            (ObjectIdentifier(motion.window), motion.endFrame)
        })
        for motion in motions {
            let id = ObjectIdentifier(motion.window)
            if presentationFrames[id] == nil {
                presentationFrames[id] = motion.startFrame
            }
        }
        if debugLogging {
            debugSnapshotMotions("snapshot target generation=\(session.generation) request=\(session.requestGeneration)", motions: motions)
        }
    }

    func ensureSnapshotFrameRunner(
        for session: SnapshotAnimationSession,
        viewport: CGRect
    ) {
        let now = CFAbsoluteTimeGetCurrent()
        session.startedAt = session.startedAt > 0 ? session.startedAt : now
        session.pixelsPerSecond = snapshotPixelsPerSecond(viewport: viewport)
        if session.lastFrameTime <= 0 {
            session.lastFrameTime = now
        }
        if session.lastDebugTickAt <= 0 {
            session.lastDebugTickAt = now
        }
        if session.timer != nil {
            debugLog(
                "snapshot runner retarget generation=\(session.generation) request=\(session.requestGeneration) speed=\(snapshotAnimationSpeed) pxPerSecond=\(String(format: "%.1f", session.pixelsPerSecond)) layers=\(session.layersByWindowID.count) targets=\(session.targetFramesByWindowID.count)"
            )
            return
        }
        debugLog(
            "snapshot runner start generation=\(session.generation) request=\(session.requestGeneration) speed=\(snapshotAnimationSpeed) fps=\(animationFPS) pxPerSecond=\(String(format: "%.1f", session.pixelsPerSecond)) layers=\(session.layersByWindowID.count) targets=\(session.targetFramesByWindowID.count) viewport=\(snapshotDebugFrame(viewport))"
        )
        session.timer = AnimationTimer(preferredFPS: animationFPS) { [weak self, weak session] in
            guard let self, let session else {
                return
            }
            stepSnapshotAnimationSession(session)
        }
    }

    func stepSnapshotAnimationSession(_ session: SnapshotAnimationSession) {
        guard snapshotAnimationSession === session, !session.cancelled else {
            debugLog("snapshot runner stop reason=session-cancelled-or-replaced")
            session.timer?.cancel()
            session.timer = nil
            return
        }
        guard layoutRequestGeneration == session.requestGeneration else {
            debugLog(
                "snapshot runner stale layoutRequest=\(layoutRequestGeneration) sessionRequest=\(session.requestGeneration)"
            )
            return
        }

        let now = CFAbsoluteTimeGetCurrent()
        let rawElapsed = max(0.001, now - session.lastFrameTime)
        let cappedFPS = max(1, animationFPS)
        let elapsed = min(rawElapsed, 1.0 / Double(cappedFPS))
        session.lastFrameTime = now
        let step = max(1, session.pixelsPerSecond * CGFloat(elapsed))
        var allSettled = true
        var maxRemainingDelta: CGFloat = 0
        var unsettledCount = 0
        var nextPresentationFrames: [ObjectIdentifier: CGRect] = [:]

        for (id, layer) in session.layersByWindowID {
            guard let target = session.targetFramesByWindowID[id] else {
                continue
            }

            let current = session.overlay.axFrame(forLayerFrame: layer.frame)
            let delta = frameDelta(from: current, to: target)
            maxRemainingDelta = max(maxRemainingDelta, delta)
            let next: CGRect
            if delta <= max(animationPixelThreshold, 0.5) {
                next = target
            } else {
                let progress = min(1, step / max(delta, 1))
                next = interpolateFrame(from: current, to: target, progress: progress)
                allSettled = false
                unsettledCount += 1
            }

            session.overlay.setSnapshotLayer(layer, to: next)
            nextPresentationFrames[id] = next
        }

        presentationFrames = nextPresentationFrames
        if debugLogging, now - session.lastDebugTickAt >= 0.1 || allSettled {
            let totalElapsed = session.startedAt > 0 ? now - session.startedAt : 0
            debugLog(
                "snapshot tick generation=\(session.generation) elapsed=\(String(format: "%.3f", totalElapsed)) dt=\(String(format: "%.3f", elapsed)) dtRaw=\(String(format: "%.3f", rawElapsed)) step=\(String(format: "%.1f", step)) maxDelta=\(String(format: "%.1f", maxRemainingDelta)) unsettled=\(unsettledCount) layers=\(session.layersByWindowID.count) targets=\(session.targetFramesByWindowID.count) settled=\(allSettled)"
            )
            session.lastDebugTickAt = now
        }

        if allSettled {
            completeSnapshotAnimationSession(session)
        }
    }

    func interpolateFrame(from start: CGRect, to end: CGRect, progress: CGFloat) -> CGRect {
        CGRect(
            x: start.minX + (end.minX - start.minX) * progress,
            y: start.minY + (end.minY - start.minY) * progress,
            width: start.width + (end.width - start.width) * progress,
            height: start.height + (end.height - start.height) * progress
        )
    }

    func animateLayoutWithSnapshots(
        from previousState: LayoutState,
        to targetState: LayoutState,
        viewport: CGRect,
        focusActiveWindow: Bool,
        duration: TimeInterval,
        animatedWindowIDs: Set<ObjectIdentifier>?,
        resizingWindowID: ObjectIdentifier?
    ) {
        let targetProjectedLayout = layoutItems(viewport: viewport, state: targetState, parkHidden: false)
        let finalLayout = layoutItems(viewport: viewport, state: targetState, parkHidden: true)
        let activeSnapshotSession = snapshotAnimationSession

        isApplyingLayout = true
        let requestGeneration = layoutRequestGeneration
        debugLog(
            "snapshot request request=\(requestGeneration) activeSession=\(activeSnapshotSession != nil) focus=\(focusActiveWindow) speed=\(snapshotAnimationSpeed) fps=\(animationFPS) previousWorkspace=\(previousState.activeWorkspace + 1) targetWorkspace=\(targetState.activeWorkspace + 1) previousActiveColumns=\(previousState.activeColumns) targetActiveColumns=\(targetState.activeColumns)"
        )
        if focusActiveWindow, let activeWindow = activeWindow() {
            focus(activeWindow)
        }

        let startLayout = layoutItems(viewport: viewport, state: previousState, parkHidden: false)
        let startByWindow = layoutByWindow(startLayout)
        let targetByWindow = layoutByWindow(targetProjectedLayout)
        let activeSnapshotFrames = activeSnapshotSession
            .flatMap { session -> [ObjectIdentifier: CGRect]? in
                guard !session.cancelled, resizingWindowID == nil else {
                    return nil
                }
                return currentSnapshotLayoutFrames(from: session)
            }
        let targetWorkspaceWindowIDs = workspaceWindowIDs(workspaceIndex: targetState.activeWorkspace)
        parkNonTargetWorkspaceWindows(finalLayout, targetWorkspaceWindowIDs: targetWorkspaceWindowIDs)
        let windowIDs = Set(startByWindow.keys).union(targetByWindow.keys).intersection(targetWorkspaceWindowIDs)

        let motions = windowIDs.compactMap { id -> WindowMotion? in
            guard let window = startByWindow[id]?.window ?? targetByWindow[id]?.window else {
                return nil
            }
            let startFrame = activeSnapshotFrames?[id]
                ?? snapshotAnimationSession?.presentationFrames()[id]
                ?? presentationFrames[id]
                ?? startByWindow[id]?.frame
                ?? targetByWindow[id]?.frame
            let endFrame = targetByWindow[id]?.frame ?? startFrame
            guard let startFrame, let endFrame else {
                return nil
            }
            return WindowMotion(
                window: window,
                startFrame: startFrame,
                endFrame: endFrame,
                startsVisible: startByWindow[id]?.visible ?? false,
                endsVisible: targetByWindow[id]?.visible ?? false,
                participates: true,
                sizeStable: true
            )
        }

        guard motions.contains(where: { $0.endsVisible && frameDelta(from: $0.startFrame, to: $0.endFrame) >= 1 }) else {
            debugLog("snapshot no-op request=\(requestGeneration) motions=\(motions.count)")
            if let activeSnapshotSession, !activeSnapshotSession.cancelled {
                activeSnapshotSession.updateTarget(
                    projectedLayout: targetProjectedLayout,
                    finalLayout: finalLayout,
                    requestGeneration: requestGeneration,
                    deferredFloatingRaise: focusActiveWindow
                )
            } else {
                applyLayout(finalLayout, focusActiveWindow: focusActiveWindow)
                restoreFloatingVisibility(raise: true, deferred: focusActiveWindow)
                presentationFrames.removeAll()
                releaseLayoutLock()
            }
            return
        }

        if let session = snapshotAnimationSession, !session.cancelled {
            session.generation += 1
            let frames = session.presentationFrames()
            presentationFrames = frames
            debugLog(
                "snapshot retarget generation=\(session.generation) request=\(requestGeneration) motions=\(motions.count) sampledFrames=\(frames.count)"
            )
            debugSnapshotMotions("snapshot retarget motion", motions: motions)
            session.updateTarget(
                projectedLayout: targetProjectedLayout,
                finalLayout: finalLayout,
                requestGeneration: requestGeneration,
                deferredFloatingRaise: focusActiveWindow
            )
            for motion in motions {
                guard let layer = addMissingSnapshotLayer(for: motion, to: session) else {
                    continue
                }
                if let currentFrame = presentationFrames[ObjectIdentifier(motion.window)] {
                    session.overlay.setSnapshotLayer(layer, to: currentFrame)
                }
            }
            updateSnapshotAnimationTargets(motions, in: session)
            ensureSnapshotFrameRunner(for: session, viewport: viewport)
            return
        }

        debugLog("snapshot start request=\(requestGeneration) motions=\(motions.count) targetWorkspaceWindows=\(targetWorkspaceWindowIDs.count)")
        debugSnapshotMotions("snapshot start motion", motions: motions)
        presentationFrames = Dictionary(uniqueKeysWithValues: motions.map { motion in
            (ObjectIdentifier(motion.window), motion.startFrame)
        })
        snapshotAnimationPreparing = true

        let snapshotSourceMotions = motions
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            guard snapshotAnimationSession == nil,
                  isApplyingLayout,
                  layoutRequestGeneration == requestGeneration
            else {
                if layoutRequestGeneration == requestGeneration {
                    snapshotAnimationPreparing = false
                }
                return
            }

            let snapshotMotions = snapshotSourceMotions.compactMap { motion -> (WindowMotion, CGImage)? in
                guard let windowID = motion.window.windowID,
                      let image = CGWindowListCreateImage(
                        .null,
                        .optionIncludingWindow,
                        CGWindowID(windowID),
                        [.bestResolution, .boundsIgnoreFraming]
                      )
                else {
                    handleMissingSnapshotImage(for: motion.window)
                    return nil
                }
                return (motion, image)
            }

            guard !snapshotMotions.isEmpty else {
                debugLog("snapshot capture failed request=\(requestGeneration) motions=\(snapshotSourceMotions.count)")
                snapshotAnimationPreparing = false
                applyLayout(finalLayout, focusActiveWindow: false)
                restoreFloatingVisibility(raise: true, deferred: focusActiveWindow)
                presentationFrames.removeAll()
                releaseLayoutLock()
                return
            }

            let overlayFrame = snapshotOverlayFrame(
                for: snapshotMotions.map(\.0),
                viewport: viewport,
                workspaceIndex: targetState.activeWorkspace
            )

            let overlay: SnapshotOverlayWindow
            if let newOverlay = SnapshotOverlayWindow(axViewport: overlayFrame) {
                snapshotOverlayWindow?.hideAndReset()
                snapshotOverlayWindow = newOverlay
                overlay = newOverlay
            } else {
                snapshotAnimationPreparing = false
                applyLayout(finalLayout, focusActiveWindow: false)
                restoreFloatingVisibility(raise: true, deferred: focusActiveWindow)
                presentationFrames.removeAll()
                releaseLayoutLock()
                return
            }

            let session = SnapshotAnimationSession(overlay: overlay)
            snapshotAnimationSession = session
            snapshotAnimationPreparing = false
            session.generation = 1
            session.startedAt = CFAbsoluteTimeGetCurrent()
            session.updateTarget(
                projectedLayout: targetProjectedLayout,
                finalLayout: finalLayout,
                requestGeneration: requestGeneration,
                deferredFloatingRaise: focusActiveWindow
            )

            let snapshotLayers = snapshotMotions.map { motion, image in
                (motion: motion, layer: overlay.addSnapshotLayer(image: image, at: motion.startFrame))
            }
            session.layersByWindowID = Dictionary(uniqueKeysWithValues: snapshotLayers.map { item in
                (ObjectIdentifier(item.motion.window), item.layer)
            })
            debugLog(
                "snapshot captured request=\(requestGeneration) images=\(snapshotLayers.count) overlay=\(snapshotDebugFrame(overlayFrame))"
            )
            overlay.show()

            DispatchQueue.main.async { [weak self, session] in
                guard let self, snapshotAnimationSession === session, !session.cancelled else {
                    return
                }
                hideSnapshotWindows(snapshotMotions.map { $0.0.window }, parkIn: overlay.axViewport)
                updateSnapshotAnimationTargets(snapshotLayers.map(\.motion), in: session)
                ensureSnapshotFrameRunner(for: session, viewport: viewport)
            }
        }
    }

    func parkNonTargetWorkspaceWindows(_ finalLayout: [LayoutItem], targetWorkspaceWindowIDs: Set<ObjectIdentifier>) {
        for item in finalLayout where !item.visible {
            guard !targetWorkspaceWindowIDs.contains(ObjectIdentifier(item.window)) else {
                continue
            }
            applyLayoutItem(item, forceFrame: true)
        }
    }
}
