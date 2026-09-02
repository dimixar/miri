import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

@MainActor
protocol LayoutWindowSystemAdapting: AnyObject {
    func setLevel(_ level: Int32, for windowID: UInt32?)
    func transform(for windowID: UInt32) -> CGAffineTransform?
    func setTransform(_ transform: CGAffineTransform, for windowID: UInt32) -> Bool
    func moveWithTransaction(_ windowID: UInt32, to origin: CGPoint) -> Bool
    func move(_ windowID: UInt32, to origin: CGPoint) -> Bool
    func translate(_ windowID: UInt32, from transform: CGAffineTransform, by offset: CGPoint) -> Bool
}

final class LayoutWindowSystemAdapter: LayoutWindowSystemAdapting {
    func setLevel(_ level: Int32, for windowID: UInt32?) { _ = SkyLight.shared.setLevel(level, for: windowID) }
    func transform(for windowID: UInt32) -> CGAffineTransform? { SkyLight.shared.transform(for: windowID) }
    func setTransform(_ transform: CGAffineTransform, for windowID: UInt32) -> Bool {
        SkyLight.shared.setTransform(transform, for: windowID)
    }
    func moveWithTransaction(_ windowID: UInt32, to origin: CGPoint) -> Bool {
        SkyLight.shared.moveWithTransaction(windowID, to: origin)
    }
    func move(_ windowID: UInt32, to origin: CGPoint) -> Bool { SkyLight.shared.move(windowID, to: origin) }
    func translate(_ windowID: UInt32, from transform: CGAffineTransform, by offset: CGPoint) -> Bool {
        SkyLight.shared.translate(windowID, from: transform, by: offset)
    }
}

struct LayoutRequestToken: Hashable, CustomStringConvertible, Sendable {
    let rawValue: UInt64
    var description: String { String(rawValue) }
}

func shouldApplyProjectedFrame(
    forceFrame: Bool,
    isVisible: Bool,
    wasVisible: Bool?,
    frameChanged: Bool
) -> Bool {
    forceFrame || isVisible || wasVisible != false || frameChanged
}

private struct LayoutSubmission {
    let token: LayoutRequestToken
    let previousState: LayoutState?
    let targetState: LayoutState
    let viewport: CGRect
    let focusActiveWindow: Bool
    let animated: Bool
    let lockDelay: TimeInterval
}

struct LayoutControllerSettings {
    let focusAlignment: FocusAlignment
    let innerGap: CGFloat
    let parkedSliverWidth: CGFloat
    let animationStrategy: AnimationStrategy
    let debugLogging: Bool
    let snapshotAnimationSpeed: Int
    let animationFPS: Int
    let animationPixelThreshold: CGFloat
    let floatingWindowLevel: Int32
}

struct LayoutControllerDependencies {
    let modelSnapshot: () -> WorkspaceModelSnapshot
    let settings: () -> LayoutControllerSettings
    let activeWindow: () -> ManagedWindow?
    let widthRatio: (ManagedWindow) -> CGFloat
    let renderedOutsets: (ManagedWindow) -> (left: CGFloat, right: CGFloat, top: CGFloat, bottom: CGFloat)
    let screenContaining: (CGRect) -> NSScreen?
    let suppressManualResize: (TimeInterval) -> Void
    let isLayoutTrackingAllowed: () -> Bool
    let currentViewport: () -> CGRect
    let parkedSliverPoints: (CGRect) -> CGFloat
    let location: (AXUIElement) -> (workspace: Int, column: Int)?
    let tiledWindows: () -> [ManagedWindow]
    let debugLog: (String) -> Void
    let stripMetrics: (Workspace, CGRect) -> (origins: [CGFloat], widths: [CGFloat])
    let maxHorizontalCameraOffset: (Workspace, CGRect) -> CGFloat
    let visualFrame: (CGRect, CGRect) -> CGRect
    let deferReconciliation: (pid_t, Bool, String) -> Void
    let setFocusedNotificationSuppressionUntil: (CFAbsoluteTime) -> Void
    let notePhysicalFocusTarget: (ManagedWindow) -> Void
    let workspaceProjection: (Int) -> Workspace?
}

/// Owns the complete presentation lifecycle. Model state remains owned by
/// `WindowManagement`; every frame, visibility, snapshot, token and compositor artifact is
/// retained here and is cleared through explicit controller operations.
@MainActor
final class LayoutController {
    private let dependencies: LayoutControllerDependencies
    private let axOperations: AXOperationController
    let emit: (LayoutEvent) -> Void
    let windowSystem: LayoutWindowSystemAdapting

    var appliedFrames: [ObjectIdentifier: CGRect] = [:]
    var requestedFrames: [ObjectIdentifier: CGRect] = [:]
    var frameRetryGenerations: [ObjectIdentifier: UInt64] = [:]
    var frameWriteEpoch: UInt64 = 0
    var authoredFrameWriteGenerations: [ObjectIdentifier: UInt64] = [:]
    var authoredFrameNotificationUntil: [ObjectIdentifier: CFAbsoluteTime] = [:]
    var appliedVisibility: [ObjectIdentifier: Bool] = [:]
    var hiddenWorkspaceWindowIDs = Set<ObjectIdentifier>()
    var presentationFrames: [ObjectIdentifier: CGRect] = [:]
    var originalWindowTransforms: [UInt32: CGAffineTransform] = [:]

    var snapshotAnimationSession: SnapshotAnimationSession?
    var snapshotOverlayWindow: SnapshotOverlayWindow?
    var snapshotHiddenWindows: [ManagedWindow] = []
    var snapshotAnimationPreparing = false
    var snapshotAnimationPreparingRequestGeneration: UInt64?

    private var pendingSubmission: LayoutSubmission?
    private var deferredSubmissionGeneration: UInt64 = 0
    private var sessionPauseGeneration: UInt64 = 0

    var floatingRaiseGeneration: UInt64 = 0
    var focusRequestGeneration: UInt64 = 0
    private var nextRequestTokenValue: UInt64 = 0
    var activeRequestToken: LayoutRequestToken?

    init(
        dependencies: LayoutControllerDependencies,
        axOperations: AXOperationController,
        windowSystem: LayoutWindowSystemAdapting = LayoutWindowSystemAdapter(),
        emit: @escaping (LayoutEvent) -> Void
    ) {
        self.dependencies = dependencies
        self.axOperations = axOperations
        self.windowSystem = windowSystem
        self.emit = emit
    }

    var isActive: Bool {
        activeRequestToken != nil
            || snapshotAnimationSession != nil
            || snapshotAnimationPreparing
            || pendingSubmission != nil
    }

    func assertInvariants() {
#if DEBUG
        if let session = snapshotAnimationSession {
            assert(session.requestToken == activeRequestToken, "The snapshot session must belong to the active layout request")
        }
        if snapshotAnimationPreparing {
            assert(snapshotAnimationPreparingRequestGeneration == activeRequestToken?.rawValue, "Snapshot preparation must belong to the active layout request")
        } else {
            assert(snapshotAnimationPreparingRequestGeneration == nil, "Inactive snapshot preparation cannot retain a request")
        }
        assert(pendingSubmission?.token != activeRequestToken, "A deferred request cannot also own the application gate")
#endif
    }

    func recordPresentationFrame(_ frame: CGRect, for window: ManagedWindow) {
        presentationFrames[ObjectIdentifier(window)] = frame
    }

    func clearPresentationFrames() {
        presentationFrames.removeAll()
    }

    func seedPresentationFrames(_ frames: [ObjectIdentifier: CGRect]) {
        presentationFrames = frames
    }

    func externalResizeObserved(frame: CGRect, window: ManagedWindow) {
        recordPresentationFrame(frame, for: window)
        emit(.externallyResized(windowID: window.windowID))
    }

    func projectItems(viewport: CGRect, state: LayoutState, parkHidden: Bool) -> [LayoutItem] {
        let scale = max((dependencies.screenContaining(viewport) ?? NSScreen.main)?.backingScaleFactor ?? 1, 1)
        let modelSnapshot = dependencies.modelSnapshot()
        let workspaces = modelSnapshot.workspaces.map { workspace in
            LayoutEngineWorkspace(
                columns: workspace.columns.map { window in
                    LayoutEngineWindow(
                        window: window,
                        widthRatio: dependencies.widthRatio(window),
                        renderedOutsets: dependencies.renderedOutsets(window)
                    )
                },
                activeColumn: workspace.activeColumn,
                scrollOffset: workspace.scrollOffset
            )
        }
        return LayoutEngine.project(
            LayoutEngineInput(
                workspaces: workspaces,
                state: state,
                viewport: viewport,
                settings: LayoutEngineSettings(
                    focusAlignment: dependencies.settings().focusAlignment,
                    innerGap: dependencies.settings().innerGap,
                    parkedSliverWidth: dependencies.settings().parkedSliverWidth,
                    physicalPixelScale: scale
                ),
                parkHidden: parkHidden
            )
        )
    }

    func submit(
        previousState: LayoutState?,
        targetState: LayoutState,
        viewport: CGRect,
        focusActiveWindow: Bool,
        animated: Bool,
        lockDelay: TimeInterval
    ) {
        let submission = LayoutSubmission(
            token: allocateRequestToken(),
            previousState: previousState,
            targetState: targetState,
            viewport: viewport,
            focusActiveWindow: focusActiveWindow,
            animated: animated,
            lockDelay: lockDelay
        )
        cancelPendingSubmission(reason: "replaced-by-newer-submission")
        let snapshotIsFinalizing = snapshotAnimationSession?.finalizing == true
        if snapshotIsFinalizing
            || (!animated && (snapshotAnimationSession != nil || snapshotAnimationPreparing))
        {
            deferSubmission(submission)
        } else {
            execute(submission)
        }
    }

    private func execute(_ submission: LayoutSubmission) {
        hideInactiveWorkspaceWindows(activeWorkspace: submission.targetState.activeWorkspace)
        let settings = dependencies.settings()
        let modelSnapshot = dependencies.modelSnapshot()
        let shouldAnimate = submission.animated && settings.animationStrategy == .snapshot
        dependencies.debugLog(
            "layout request=\(submission.token) workspace=\(submission.targetState.activeWorkspace + 1) tiled=\(modelSnapshot.tiledWindows.count) floating=\(modelSnapshot.floatingWindows.count) animationRequested=\(submission.animated) animationStrategy=\(settings.animationStrategy.rawValue) animationActive=\(shouldAnimate)"
        )
        dependencies.suppressManualResize((shouldAnimate ? 0.25 : 0) + max(submission.lockDelay, 0.25))
        if shouldAnimate, let previousState = submission.previousState {
            activateRequest(submission.token, reason: "snapshot")
            animateLayoutWithSnapshots(
                from: previousState,
                to: submission.targetState,
                viewport: submission.viewport,
                focusActiveWindow: submission.focusActiveWindow,
                requestToken: submission.token
            )
            return
        }
        stopAnimation(clearPresentation: true)
        cancelActiveRequest(reason: "replaced-by-immediate-layout")
        activateRequest(submission.token, reason: "immediate")
        apply(
            projectItems(viewport: submission.viewport, state: submission.targetState, parkHidden: true),
            focusActiveWindow: submission.focusActiveWindow
        )
        restoreFloatingVisibility(raise: true, deferred: submission.focusActiveWindow)
        completeRequest(submission.token, after: submission.lockDelay)
    }

    private func deferSubmission(_ submission: LayoutSubmission) {
        pendingSubmission = submission
        deferredSubmissionGeneration &+= 1
        let generation = deferredSubmissionGeneration
        dependencies.debugLog("layout deferred request=\(submission.token) during snapshot focus=\(submission.focusActiveWindow) lockDelay=\(String(format: "%.2f", submission.lockDelay))")
        pollDeferredSubmission(generation: generation)
    }

    private func pollDeferredSubmission(generation: UInt64) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self,
                  self.pendingSubmission != nil,
                  self.deferredSubmissionGeneration == generation,
                  self.dependencies.isLayoutTrackingAllowed() else { return }
            guard self.snapshotAnimationSession == nil,
                  !self.snapshotAnimationPreparing,
                  self.activeRequestToken == nil else {
                self.pollDeferredSubmission(generation: generation)
                return
            }
            guard let submission = self.pendingSubmission else { return }
            self.pendingSubmission = nil
            self.execute(submission)
        }
    }

    func removeTracking(for window: ManagedWindow) {
        let id = ObjectIdentifier(window)
        resetCompositorTransform(for: window)
        if let windowID = window.windowID {
            originalWindowTransforms.removeValue(forKey: windowID)
        }
        appliedFrames.removeValue(forKey: id)
        requestedFrames.removeValue(forKey: id)
        frameRetryGenerations.removeValue(forKey: id)
        authoredFrameWriteGenerations.removeValue(forKey: id)
        authoredFrameNotificationUntil.removeValue(forKey: id)
        appliedVisibility.removeValue(forKey: id)
        hiddenWorkspaceWindowIDs.remove(id)
        presentationFrames.removeValue(forKey: id)
    }

    func resetTracking() {
        frameWriteEpoch &+= 1
        appliedFrames.removeAll()
        requestedFrames.removeAll()
        frameRetryGenerations.removeAll()
        authoredFrameWriteGenerations.removeAll()
        authoredFrameNotificationUntil.removeAll()
        appliedVisibility.removeAll()
        hiddenWorkspaceWindowIDs.removeAll()
        presentationFrames.removeAll()
    }

    func hideInactiveWorkspaceWindows(activeWorkspace activeIndex: Int) {
        let snapshot = dependencies.modelSnapshot()
        let activeIDs = workspaceWindowIDs(workspaceIndex: activeIndex)
        for (workspaceIndex, workspace) in snapshot.workspaces.enumerated() where workspaceIndex != activeIndex {
            for window in workspace.columns {
                let id = ObjectIdentifier(window)
                appliedVisibility[id] = false
                hiddenWorkspaceWindowIDs.insert(id)
            }
        }
        hiddenWorkspaceWindowIDs = hiddenWorkspaceWindowIDs.filter { !activeIDs.contains($0) }
    }

    func cancel(reason: String) {
        cancelPendingSubmission(reason: reason)
        stopAnimation(clearPresentation: true)
        cancelActiveRequest(reason: reason)
    }

    func beginUnavailableSessionPause() -> UInt64 {
        sessionPauseGeneration &+= 1
        let generation = sessionPauseGeneration
        cancelPendingSubmission(reason: "session-unavailable")
        snapshotAnimationPreparing = false
        snapshotAnimationPreparingRequestGeneration = nil
        if let session = snapshotAnimationSession {
            session.cancelled = true
            session.timer?.cancel()
            session.timer = nil
        }
        focusRequestGeneration &+= 1
        floatingRaiseGeneration &+= 1
        frameWriteEpoch &+= 1
        frameRetryGenerations.removeAll()
        authoredFrameWriteGenerations.removeAll()
        authoredFrameNotificationUntil.removeAll()
        cancelActiveRequest(reason: "session-unavailable")
        return generation
    }

    func completeUnavailableSessionPause(generation: UInt64) {
        guard generation == sessionPauseGeneration else { return }
        if let session = snapshotAnimationSession {
            let frames = session.presentationFrames()
            for window in tiledWindows() {
                guard let windowID = window.windowID,
                      let frame = frames[ObjectIdentifier(window)]
                else { continue }
                resetCompositorTransform(for: window)
                if !windowSystem.moveWithTransaction(windowID, to: frame.origin) {
                    _ = windowSystem.move(windowID, to: frame.origin)
                }
            }
            session.overlay.hideAndReset()
        } else {
            restoreSnapshotHiddenWindows()
            snapshotOverlayWindow?.hideAndReset()
        }
        snapshotAnimationSession = nil
        snapshotOverlayWindow = nil
        snapshotHiddenWindows.removeAll()
        resetTracking()
    }

    func resetForSessionRecovery() {
        sessionPauseGeneration &+= 1
        focusRequestGeneration &+= 1
        floatingRaiseGeneration &+= 1
        frameWriteEpoch &+= 1
        resetTracking()
    }

    func stopAnimation(clearPresentation: Bool) {
        snapshotAnimationPreparing = false
        snapshotAnimationPreparingRequestGeneration = nil
        if snapshotAnimationSession != nil {
            prepareInterruptedSnapshotAnimationForNextCapture()
        } else {
            restoreSnapshotHiddenWindows()
        }
        snapshotOverlayWindow?.hideAndReset()
        snapshotOverlayWindow = nil
        if clearPresentation { presentationFrames.removeAll() }
    }

    private func allocateRequestToken() -> LayoutRequestToken {
        nextRequestTokenValue &+= 1
        return LayoutRequestToken(rawValue: nextRequestTokenValue)
    }

    private func activateRequest(_ token: LayoutRequestToken, reason: String) {
        if activeRequestToken != nil {
            cancelActiveRequest(reason: "replaced-by-\(reason)")
        }
        activeRequestToken = token
        dependencies.debugLog("layout request begin request=\(token) reason=\(reason)")
    }

    private func cancelPendingSubmission(reason: String) {
        guard let pendingSubmission else { return }
        self.pendingSubmission = nil
        deferredSubmissionGeneration &+= 1
        dependencies.debugLog("layout request cancelled request=\(pendingSubmission.token) reason=\(reason)")
        emit(.cancelled(token: pendingSubmission.token))
    }

    func cancelActiveRequest(reason: String) {
        guard let token = activeRequestToken else { return }
        activeRequestToken = nil
        dependencies.debugLog("layout request cancelled request=\(token) reason=\(reason)")
        emit(.cancelled(token: token))
    }

    func completeRequest(_ token: LayoutRequestToken, after delay: TimeInterval = 0.08) {
        guard delay > 0 else {
            completeRequestIfCurrent(token)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.completeRequestIfCurrent(token)
        }
    }

    private func completeRequestIfCurrent(_ token: LayoutRequestToken) {
        guard activeRequestToken == token,
              snapshotAnimationSession == nil,
              !snapshotAnimationPreparing else {
            dependencies.debugLog("layout release ignored request=\(token) active=\(activeRequestToken?.description ?? "none")")
            return
        }
        activeRequestToken = nil
        dependencies.debugLog("layout request complete request=\(token)")
        emit(.completed(token: token))
    }

    /// Stops presentation work and restores compositor-owned state. AX frame
    /// restoration is deliberately owned by `AXOperationController` so this
    /// main-actor controller cannot perform target-process IPC during quit.
    func preparePresentationForTermination(windows: [ManagedWindow]) {
        cancel(reason: "termination")
        focusRequestGeneration &+= 1
        floatingRaiseGeneration &+= 1
        frameWriteEpoch &+= 1
        frameRetryGenerations.removeAll()
        requestedFrames.removeAll()
        for (windowID, transform) in originalWindowTransforms {
            _ = windowSystem.setTransform(transform, for: windowID)
        }
        originalWindowTransforms.removeAll()
        let normalLevel = Int32(CGWindowLevelForKey(.normalWindow))
        for window in windows {
            windowSystem.setLevel(normalLevel, for: window.windowID)
        }
    }

    func apply(
        _ layout: [LayoutItem],
        focusActiveWindow: Bool,
        completion: @escaping () -> Void = {}
    ) {
        let activeWindow = focusActiveWindow ? dependencies.activeWindow() : nil
        var orderedItems: [(item: LayoutItem, forceFrame: Bool)] = []
        if let activeWindow {
            if let activeItem = layout.first(where: { $0.window === activeWindow }) {
                orderedItems.append((activeItem, true))
            }
            orderedItems.append(contentsOf: layout
                .filter { $0.visible && $0.window !== activeWindow }
                .map { ($0, false) })
        } else {
            orderedItems.append(contentsOf: layout.filter(\.visible).map { ($0, false) })
        }
        orderedItems.append(contentsOf: layout.filter { !$0.visible }.map { ($0, false) })

        guard !orderedItems.isEmpty else {
            if let activeWindow { focus(activeWindow) }
            completion()
            return
        }
        var remaining = orderedItems.count
        var submittedActiveFocus = false
        for entry in orderedItems {
            apply(entry.item, forceFrame: entry.forceFrame) {
                remaining -= 1
                if remaining == 0 { completion() }
            }
            if let activeWindow,
               entry.item.window === activeWindow,
               !submittedActiveFocus
            {
                submittedActiveFocus = true
                focus(activeWindow)
            }
        }
        if let activeWindow, !submittedActiveFocus { focus(activeWindow) }
    }

    func apply(
        _ item: LayoutItem,
        forceFrame: Bool = false,
        completion: @escaping () -> Void = {}
    ) {
        let id = ObjectIdentifier(item.window)
        let wasVisible = appliedVisibility[id]
        let requestedFrame = requestedFrames[id]
        let frameChanged = requestedFrame.map {
            frameDelta(from: $0, to: item.frame) >= dependencies.settings().animationPixelThreshold
        } ?? true
        let visibilityChanged = wasVisible != item.visible
        // Preserve the pre-async corrective semantics: every visible window is
        // rewritten on projection, and the focused item is always forced. A
        // cached request describes intent, not authoritative physical geometry.
        let shouldApplyFrame = shouldApplyProjectedFrame(
            forceFrame: forceFrame,
            isVisible: item.visible,
            wasVisible: wasVisible,
            frameChanged: frameChanged
        )
        if visibilityChanged && !item.visible { appliedVisibility[id] = false }
        if shouldApplyFrame {
            resetCompositorTransform(for: item.window)
            setWindowFrame(
                item.frame,
                for: item.window,
                correctParking: !item.visible
            ) { _ in completion() }
        } else {
            completion()
        }
        if visibilityChanged && item.visible { appliedVisibility[id] = true }
    }

    func restoreFloatingVisibility(windows: [ManagedWindow]? = nil, raise: Bool = false, deferred: Bool = false) {
        let windows = windows ?? dependencies.modelSnapshot().floatingWindows
        if raise {
            for window in windows {
                windowSystem.setLevel(dependencies.settings().floatingWindowLevel, for: window.windowID)
            }
        }
        if raise && deferred { scheduleFloatingWindowRaise() }
    }

    func resetCompositorTransform(for window: ManagedWindow) {
        guard let windowID = window.windowID, let original = originalWindowTransforms[windowID] else { return }
        if windowSystem.setTransform(original, for: windowID) {
            originalWindowTransforms.removeValue(forKey: windowID)
        }
    }

    func windowServerFrame(for windowID: UInt32) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionIncludingWindow],
            CGWindowID(windowID)
        ) as? [[String: Any]],
              let bounds = list.first?[kCGWindowBounds as String] as? NSDictionary
        else { return nil }
        var frame = CGRect.zero
        return CGRectMakeWithDictionaryRepresentation(bounds as CFDictionary, &frame) ? frame : nil
    }

    func applyCompositorParkingCorrection(to targetFrame: CGRect, for window: ManagedWindow) {
        guard let windowID = window.windowID,
              let observedFrame = windowServerFrame(for: windowID)
        else { return }
        let viewport = dependencies.currentViewport()
        let parksBeforeViewport = targetFrame.midX < viewport.midX
        let correctedOrigin = CGPoint(
            x: parksBeforeViewport ? targetFrame.maxX - observedFrame.width : targetFrame.minX,
            y: targetFrame.minY
        )
        if windowSystem.moveWithTransaction(windowID, to: correctedOrigin) {
            dependencies.debugLog("parking correction method=transaction id=\(windowID) target=(\(correctedOrigin.x),\(correctedOrigin.y)) observed=(\(observedFrame.minX),\(observedFrame.minY),\(observedFrame.width),\(observedFrame.height))")
            return
        }
        if windowSystem.move(windowID, to: correctedOrigin) {
            dependencies.debugLog("parking correction method=direct-move id=\(windowID) target=(\(correctedOrigin.x),\(correctedOrigin.y))")
            return
        }
        let offset = CGPoint(x: correctedOrigin.x - observedFrame.minX, y: correctedOrigin.y - observedFrame.minY)
        guard abs(offset.x) >= 0.001 || abs(offset.y) >= 0.001 else { return }
        let original = originalWindowTransforms[windowID]
            ?? windowSystem.transform(for: windowID)
            ?? CGAffineTransform(translationX: -observedFrame.minX, y: -observedFrame.minY)
        if windowSystem.translate(windowID, from: original, by: offset) {
            originalWindowTransforms[windowID] = original
            dependencies.debugLog("parking correction method=transform id=\(windowID) offset=(\(offset.x),\(offset.y))")
        } else {
            dependencies.debugLog("parking correction failed id=\(windowID) target=(\(correctedOrigin.x),\(correctedOrigin.y))")
        }
    }

    private func scheduleFloatingWindowRaise() {
        guard !dependencies.modelSnapshot().floatingWindows.isEmpty else { return }
        floatingRaiseGeneration &+= 1
        let generation = floatingRaiseGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self, generation == self.floatingRaiseGeneration else { return }
            self.restoreFloatingVisibility(raise: true)
        }
    }

    func setWindowFrame(
        _ frame: CGRect,
        for window: ManagedWindow,
        correctParking: Bool = false,
        completion: @escaping (AXOperationResult<CGRect>) -> Void = { _ in }
    ) {
        let id = ObjectIdentifier(window)
        requestedFrames[id] = frame
        frameRetryGenerations[id, default: 0] &+= 1
        let retryGeneration = frameRetryGenerations[id, default: 0]
        let writeEpoch = frameWriteEpoch
        authoredFrameWriteGenerations[id] = retryGeneration
        let handle = AXElementHandle(
            element: window.element,
            pid: window.pid,
            windowID: window.windowID
        )
        axOperations.setFrame(
            frame,
            handle: handle,
            disableEnhancedUserInterface: true
        ) { [weak self, weak window] result in
            completion(result)
            guard let self, let window,
                  self.frameWriteEpoch == writeEpoch else { return }
            if self.authoredFrameWriteGenerations[id] == retryGeneration {
                self.authoredFrameWriteGenerations.removeValue(forKey: id)
                self.authoredFrameNotificationUntil[id] = CFAbsoluteTimeGetCurrent() + 0.3
            }
            guard self.requestedFrames[id] == frame else { return }
            guard result.disposition == .completed else {
                if result.disposition == .superseded { return }
                guard result.disposition == .circuitOpen || result.error == .cannotComplete else {
                    self.requestedFrames.removeValue(forKey: id)
                    return
                }
                let delay = max(result.retryAfter ?? miriAXFailureRetryDelay, 0.1)
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak window] in
                    guard let self, let window,
                          self.frameWriteEpoch == writeEpoch,
                          self.frameRetryGenerations[id] == retryGeneration,
                          self.requestedFrames[id] == frame,
                          self.dependencies.isLayoutTrackingAllowed()
                    else { return }
                    self.setWindowFrame(frame, for: window, correctParking: correctParking)
                }
                return
            }
            self.appliedFrames[id] = frame
            if correctParking {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self, weak window] in
                    guard let self, let window,
                          self.frameWriteEpoch == writeEpoch,
                          self.requestedFrames[id] == frame else { return }
                    self.applyCompositorParkingCorrection(to: frame, for: window)
                }
            }
        }
    }

    func shouldIgnoreAuthoredFrameNotification(for window: ManagedWindow) -> Bool {
        let id = ObjectIdentifier(window)
        if authoredFrameWriteGenerations[id] != nil { return true }
        guard let deadline = authoredFrameNotificationUntil[id] else { return false }
        if CFAbsoluteTimeGetCurrent() <= deadline { return true }
        authoredFrameNotificationUntil.removeValue(forKey: id)
        return false
    }

    func focus(_ window: ManagedWindow) {
        dependencies.notePhysicalFocusTarget(window)
        focusRequestGeneration &+= 1
        let generation = focusRequestGeneration
        dependencies.setFocusedNotificationSuppressionUntil(CFAbsoluteTimeGetCurrent() + 1.0)
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window,
                  generation == self.focusRequestGeneration,
                  self.dependencies.activeWindow() === window else { return }
            self.dependencies.setFocusedNotificationSuppressionUntil(CFAbsoluteTimeGetCurrent() + 1.0)
            NSRunningApplication(processIdentifier: window.pid)?.activate(options: [.activateIgnoringOtherApps])
            self.submitPhysicalFocus(window, generation: generation)
        }
    }

    private func submitPhysicalFocus(_ window: ManagedWindow, generation: UInt64) {
        let handle = AXElementHandle(
            element: window.element,
            pid: window.pid,
            windowID: window.windowID
        )
        axOperations.focus(handle: handle) { [weak self, weak window] result in
            guard let self, let window,
                  generation == self.focusRequestGeneration,
                  self.dependencies.activeWindow() === window
            else { return }
            guard result.disposition != .completed else { return }
            guard result.disposition == .circuitOpen || result.error == .cannotComplete else { return }
            let delay = max(result.retryAfter ?? miriAXFailureRetryDelay, 0.1)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak window] in
                guard let self, let window,
                      generation == self.focusRequestGeneration,
                      self.dependencies.activeWindow() === window,
                      self.dependencies.isLayoutTrackingAllowed()
                else { return }
                self.submitPhysicalFocus(window, generation: generation)
            }
        }
    }

    func frameDelta(from oldFrame: CGRect, to newFrame: CGRect) -> CGFloat {
        max(abs(oldFrame.minX - newFrame.minX), abs(oldFrame.minY - newFrame.minY), abs(oldFrame.width - newFrame.width), abs(oldFrame.height - newFrame.height))
    }
}

extension LayoutController {
    var activeWorkspace: Int { dependencies.modelSnapshot().activeWorkspace }
    var debugLogging: Bool { dependencies.settings().debugLogging }
    var snapshotAnimationSpeed: Int { dependencies.settings().snapshotAnimationSpeed }
    var animationFPS: Int { dependencies.settings().animationFPS }
    var animationPixelThreshold: CGFloat { dependencies.settings().animationPixelThreshold }

    func currentViewport() -> CGRect { dependencies.currentViewport() }
    func parkedSliverPoints(for viewport: CGRect) -> CGFloat { dependencies.parkedSliverPoints(viewport) }
    func renderedOutsets(for window: ManagedWindow) -> (left: CGFloat, right: CGFloat, top: CGFloat, bottom: CGFloat) {
        dependencies.renderedOutsets(window)
    }
    func location(of element: AXUIElement) -> (workspace: Int, column: Int)? { dependencies.location(element) }
    func tiledWindows() -> [ManagedWindow] { dependencies.tiledWindows() }
    func debugLog(_ message: @autoclosure () -> String) { dependencies.debugLog(message()) }
    func applyLayout(_ layout: [LayoutItem], focusActiveWindow: Bool) { apply(layout, focusActiveWindow: focusActiveWindow) }
    func applyLayoutItem(_ item: LayoutItem, forceFrame: Bool = false) { apply(item, forceFrame: forceFrame) }
    func releaseLayoutLock(for token: LayoutRequestToken, after delay: TimeInterval = 0.08) { completeRequest(token, after: delay) }
    func layoutByWindow(_ layout: [LayoutItem]) -> [ObjectIdentifier: LayoutItem] {
        Dictionary(uniqueKeysWithValues: layout.map { (ObjectIdentifier($0.window), $0) })
    }
    func stripMetrics(for workspace: Workspace, viewport: CGRect) -> (origins: [CGFloat], widths: [CGFloat]) {
        dependencies.stripMetrics(workspace, viewport)
    }
    func maxHorizontalCameraOffset(for workspace: Workspace, viewport: CGRect) -> CGFloat {
        dependencies.maxHorizontalCameraOffset(workspace, viewport)
    }
    func visualFrame(_ frame: CGRect, viewport: CGRect) -> CGRect { dependencies.visualFrame(frame, viewport) }
    func deferAXReconciliation(pid: pid_t, adoptFocused: Bool, reason: String) {
        dependencies.deferReconciliation(pid, adoptFocused, reason)
    }
    func layoutItems(viewport: CGRect, state: LayoutState, parkHidden: Bool) -> [LayoutItem] {
        projectItems(viewport: viewport, state: state, parkHidden: parkHidden)
    }
    func activeWindow() -> ManagedWindow? { dependencies.activeWindow() }
    func workspaceWindowIDs(workspaceIndex: Int) -> Set<ObjectIdentifier> {
        let workspaces = dependencies.modelSnapshot().workspaces
        guard workspaces.indices.contains(workspaceIndex) else { return [] }
        return Set(workspaces[workspaceIndex].columns.map(ObjectIdentifier.init))
    }

    func workspaceProjection(at index: Int) -> Workspace? { dependencies.workspaceProjection(index) }
}
