import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

@MainActor
protocol LayoutWindowSystemAdapting: AnyObject {
    func frame(of window: ManagedWindow) -> CGRect?
    func setFrame(_ frame: CGRect, for window: ManagedWindow)
    func setLevel(_ level: Int32, for windowID: UInt32?)
    func transform(for windowID: UInt32) -> CGAffineTransform?
    func setTransform(_ transform: CGAffineTransform, for windowID: UInt32) -> Bool
    func moveWithTransaction(_ windowID: UInt32, to origin: CGPoint) -> Bool
    func move(_ windowID: UInt32, to origin: CGPoint) -> Bool
    func translate(_ windowID: UInt32, from transform: CGAffineTransform, by offset: CGPoint) -> Bool
    func focus(_ window: ManagedWindow)
}

final class LayoutWindowSystemAdapter: LayoutWindowSystemAdapting {
    func frame(of window: ManagedWindow) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window.element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(window.element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue,
              let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }
    func setFrame(_ frame: CGRect, for window: ManagedWindow) { setAXFrame(frame, for: window) }
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
    func focus(_ window: ManagedWindow) {
        NSRunningApplication(processIdentifier: window.pid)?.activate(options: [.activateIgnoringOtherApps])
        AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    }
}

struct LayoutRequestToken: Hashable, CustomStringConvertible, Sendable {
    let rawValue: UInt64
    var description: String { String(rawValue) }
}

struct LayoutControllerActivity: Sendable {
    var requestToken: LayoutRequestToken?
    var isSnapshotActive: Bool
    var isSnapshotPreparing: Bool
    var hasDeferredSubmission: Bool

    var isActive: Bool {
        requestToken != nil || isSnapshotActive || isSnapshotPreparing || hasDeferredSubmission
    }
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
    let axFrame: (AXUIElement) -> CGRect?
    let parkedSliverPoints: (CGRect) -> CGFloat
    let location: (AXUIElement) -> (workspace: Int, column: Int)?
    let tiledWindows: () -> [ManagedWindow]
    let debugLog: (String) -> Void
    let stripMetrics: (Workspace, CGRect) -> (origins: [CGFloat], widths: [CGFloat])
    let maxHorizontalCameraOffset: (Workspace, CGRect) -> CGFloat
    let visualFrame: (CGRect, CGRect) -> CGRect
    let deferReconciliation: (pid_t, Bool, String) -> Void
    let setFocusedNotificationSuppressionUntil: (CFAbsoluteTime) -> Void
    let workspaceProjection: (Int) -> Workspace?
}

/// Owns the complete presentation lifecycle. Model state remains owned by
/// `WindowManagement`; every frame, visibility, snapshot, token and compositor artifact is
/// retained here and is cleared through explicit controller operations.
@MainActor
final class LayoutController {
    private let dependencies: LayoutControllerDependencies
    let emit: (LayoutEvent) -> Void
    let windowSystem: LayoutWindowSystemAdapting

    var appliedFrames: [ObjectIdentifier: CGRect] = [:]
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

    var floatingRaiseGeneration: UInt64 = 0
    var focusRequestGeneration: UInt64 = 0
    private var nextRequestTokenValue: UInt64 = 0
    var activeRequestToken: LayoutRequestToken?

    init(
        dependencies: LayoutControllerDependencies,
        windowSystem: LayoutWindowSystemAdapting = LayoutWindowSystemAdapter(),
        emit: @escaping (LayoutEvent) -> Void
    ) {
        self.dependencies = dependencies
        self.windowSystem = windowSystem
        self.emit = emit
    }

    var activity: LayoutControllerActivity {
        LayoutControllerActivity(
            requestToken: activeRequestToken ?? pendingSubmission?.token,
            isSnapshotActive: snapshotAnimationSession != nil,
            isSnapshotPreparing: snapshotAnimationPreparing,
            hasDeferredSubmission: pendingSubmission != nil
        )
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

    @discardableResult
    func submit(
        previousState: LayoutState?,
        targetState: LayoutState,
        viewport: CGRect,
        focusActiveWindow: Bool,
        animated: Bool,
        lockDelay: TimeInterval
    ) -> LayoutRequestToken {
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
        if !animated, snapshotAnimationSession != nil || snapshotAnimationPreparing {
            deferSubmission(submission)
        } else {
            execute(submission)
        }
        return submission.token
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
        appliedVisibility.removeValue(forKey: id)
        hiddenWorkspaceWindowIDs.remove(id)
        presentationFrames.removeValue(forKey: id)
    }

    func resetTracking() {
        appliedFrames.removeAll()
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

    func isHiddenForInactiveWorkspace(_ window: ManagedWindow) -> Bool {
        hiddenWorkspaceWindowIDs.contains(ObjectIdentifier(window))
    }

    func cancel(reason: String) {
        cancelPendingSubmission(reason: reason)
        stopAnimation(clearPresentation: true)
        cancelActiveRequest(reason: reason)
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

    func restoreForTermination(
        tiledWindows: [ManagedWindow],
        floatingWindows: [ManagedWindow],
        viewport: CGRect,
        restoreFrames: Bool
    ) {
        cancel(reason: "termination")
        for (windowID, transform) in originalWindowTransforms {
            _ = windowSystem.setTransform(transform, for: windowID)
        }
        originalWindowTransforms.removeAll()
        guard restoreFrames else { return }
        for window in tiledWindows {
            windowSystem.setFrame(viewport, for: window)
        }
        for window in floatingWindows {
            windowSystem.setLevel(dependencies.settings().floatingWindowLevel, for: window.windowID)
        }
    }

    func apply(_ layout: [LayoutItem], focusActiveWindow: Bool) {
        let activeWindow = focusActiveWindow ? dependencies.activeWindow() : nil
        if let activeWindow {
            for item in layout where item.visible && item.window !== activeWindow {
                apply(item)
            }
            if let activeItem = layout.first(where: { $0.window === activeWindow }) {
                apply(activeItem, forceFrame: true)
            }
        } else {
            for item in layout where item.visible {
                apply(item)
            }
        }
        for item in layout where !item.visible {
            apply(item)
        }
        if let activeWindow {
            focus(activeWindow)
        }
    }

    func apply(_ item: LayoutItem, forceFrame: Bool = false) {
        let id = ObjectIdentifier(item.window)
        let wasVisible = appliedVisibility[id]
        let previousFrame = appliedFrames[id]
        let shouldApplyFrame = forceFrame
            || item.visible
            || wasVisible != false
            || previousFrame.map { frameDelta(from: $0, to: item.frame) >= dependencies.settings().animationPixelThreshold } ?? true
        let visibilityChanged = wasVisible != item.visible
        if visibilityChanged && !item.visible { appliedVisibility[id] = false }
        if shouldApplyFrame {
            resetCompositorTransform(for: item.window)
            windowSystem.setFrame(item.frame, for: item.window)
            if !item.visible { applyCompositorParkingCorrection(to: item.frame, for: item.window) }
            appliedFrames[id] = item.frame
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

    func applyCompositorParkingCorrection(to targetFrame: CGRect, for window: ManagedWindow) {
        guard let windowID = window.windowID, let observedFrame = windowSystem.frame(of: window) else { return }
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

    func focus(_ window: ManagedWindow) {
        focusRequestGeneration &+= 1
        let generation = focusRequestGeneration
        dependencies.setFocusedNotificationSuppressionUntil(CFAbsoluteTimeGetCurrent() + 1.0)
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window,
                  generation == self.focusRequestGeneration,
                  self.dependencies.activeWindow() === window else { return }
            self.dependencies.setFocusedNotificationSuppressionUntil(CFAbsoluteTimeGetCurrent() + 1.0)
            self.windowSystem.focus(window)
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
    func axFrame(_ element: AXUIElement) -> CGRect? { dependencies.axFrame(element) }
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
