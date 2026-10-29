import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import XCTest
@testable import miri

@MainActor
final class FocusScrollingTests: XCTestCase {
    private let viewport = CGRect(x: 0, y: 0, width: 1200, height: 800)
    private let minimalRevealModes: [FocusAlignment] = [.default, .centeredSmart]

    func testManualFloatingIsPerLiveWindowAndSurvivesReclassificationAndRediscovery() throws {
        let (miri, workspace) = try fixture(
            alignment: .default, widths: [0.28, 0.67, 0.4], activeColumn: 1, scrollOffset: 45,
            rules: [WindowRule(titleContains: "Rule float", behavior: .float)]
        )
        miri.sessionController.pauseForUnavailableSession()
        // Distinct AX identities, but identical app, PID, and title metadata.
        workspace.columns = workspace.windows.map {
            let window = ManagedWindow(element: $0.element, pid: 4242, windowID: nil,
                                       bundleID: "com.example.editor", appName: "Editor", title: "Untitled")
            window.manualWidthRatio = $0.manualWidthRatio
            return Column(windows: [window])
        }
        let left = workspace.windows[0]
        let target = workspace.windows[1]
        let right = workspace.windows[2]
        let ruleFloating = ManagedWindow(element: AXUIElementCreateApplication(2000), pid: 4242, windowID: nil,
                                         bundleID: target.bundleID, appName: target.appName, title: "Rule float")
        XCTAssertTrue(miri.upsertDiscoveredWindow(ruleFloating))

        XCTAssertTrue(miri.toggleFloatingWindow(for: target.element))
        XCTAssertEqual(workspace.windows.map(\.element), [left.element, right.element])
        XCTAssertEqual(miri.windowManagement.manuallyFloatedWindows.map(\.element), [target.element])
        XCTAssertEqual(miri.behavior(for: left), .tile)
        XCTAssertEqual(miri.behavior(for: right), .tile)
        XCTAssertEqual(miri.behavior(for: ruleFloating), .float)

        // A reload changes the same app's rule; the manual choice must still win
        // for this window, while all its peers adopt the new rule normally.
        var changedConfig = miri.configStore.documentConfig
        changedConfig.rules = [WindowRule(bundleID: target.bundleID, behavior: .ignore)]
        let configDirectory = miri.configStore.destinationURL.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: configDirectory) }
        guard case .saved = miri.configStore.save(changedConfig) else { return XCTFail("Config save failed") }
        let renamed = ManagedWindow(element: target.element, pid: target.pid, windowID: nil,
                                    bundleID: target.bundleID, appName: target.appName, title: "Renamed document")
        _ = miri.upsertDiscoveredWindow(renamed)
        XCTAssertEqual(miri.behavior(for: renamed), .float)
        XCTAssertEqual(miri.behavior(for: left), .ignore)
        XCTAssertEqual(miri.behavior(for: ruleFloating), .ignore)

        // Hide/minimize/Space buffering removes the wrapper, not the live identity.
        miri.removeWindow(target)
        XCTAssertTrue(miri.upsertDiscoveredWindow(renamed))
        XCTAssertEqual(renamed.manualWidthRatio, 0.67)
        XCTAssertEqual(miri.windowManagement.manuallyFloatedWindows.map(\.element), [target.element])
        miri.windowManagement.ensureWorkspaceExists(1)
        XCTAssertTrue(miri.windowManagement.selectWorkspace(1))
        XCTAssertTrue(miri.toggleFloatingWindow(for: renamed.element))
        XCTAssertEqual(miri.windowManagement.activeWorkspace, 0)
        XCTAssertEqual(workspace.windows.map(\.element), [left.element, target.element, right.element])
        XCTAssertEqual(workspace.activeColumn, 1)
        XCTAssertEqual(miri.behavior(for: renamed), .tile)
        XCTAssertEqual(renamed.manualWidthRatio, 0.67)
        XCTAssertTrue(miri.windowManagement.manuallyFloatedWindows.isEmpty)
        _ = miri.upsertDiscoveredWindow(renamed)
        XCTAssertTrue(workspace.windows[1] === renamed, "A rescan must not undo explicit tiling either")
        XCTAssertFalse(miri.toggleFloatingWindow(for: AXUIElementCreateApplication(9999)), "An ignored/unmanaged focus cannot toggle the last tiled column")
    }

    func testRuleFloatingCanBeManuallyTiledAndCleanupDoesNotAffectSameAppPeers() throws {
        let (miri, workspace) = try fixture(
            alignment: .default, widths: [0.28, 0.67], activeColumn: 0, scrollOffset: nil,
            rules: [WindowRule(appName: "Test", behavior: .float)]
        )
        miri.sessionController.pauseForUnavailableSession()
        let target = workspace.windows[0]
        let peer = workspace.windows[1]
        _ = miri.upsertDiscoveredWindow(target)
        _ = miri.upsertDiscoveredWindow(peer)
        XCTAssertTrue(miri.windowManagement.manuallyFloatedWindows.isEmpty)
        XCTAssertTrue(miri.toggleFloatingWindow(for: target.element))
        XCTAssertEqual(miri.behavior(for: target), .tile)
        XCTAssertEqual(miri.behavior(for: peer), .float)
        XCTAssertTrue(miri.windowManagement.manuallyFloatedWindows.isEmpty)
        XCTAssertTrue(miri.toggleFloatingWindow(for: target.element))
        XCTAssertEqual(miri.windowManagement.manuallyFloatedWindows.map(\.element), [target.element])
        XCTAssertTrue(miri.removeDestroyedWindowImmediately(target.element))
        XCTAssertNil(miri.windowManagement.manualBehavior(for: target.element))
        XCTAssertEqual(miri.windowManagement.floatingWindows.map(\.element), [peer.element])

        XCTAssertTrue(miri.toggleFloatingWindow(for: peer.element))
        miri.removeWindow(peer)
        _ = miri.windowManagement.removeGlobally(pid: peer.pid)
        XCTAssertNil(miri.windowManagement.manualBehavior(for: peer.element), "Termination also clears overrides of temporarily absent windows")
    }

    func testManualFloatingExitsWorkspaceFullscreenAndIsNotRestoredAfterRestart() throws {
        let (miri, workspace) = try fixture(
            alignment: .default, widths: [0.28, 0.67], activeColumn: 1, scrollOffset: nil
        )
        miri.sessionController.pauseForUnavailableSession()
        let target = workspace.windows[1]
        XCTAssertTrue(miri.windowManagement.toggleWorkspaceFullscreen())
        XCTAssertTrue(miri.toggleFloatingWindow(for: target.element))
        XCTAssertEqual(workspace.fullscreenState, .off)
        let snapshot = try XCTUnwrap(miri.windowManagement.persistentLogicalSpaceSnapshot(identity: miri.persistentIdentity(for:)))
        let (restarted, _) = try fixture(alignment: .default, widths: [], activeColumn: 0, scrollOffset: nil)
        restarted.sessionController.pauseForUnavailableSession()
        let restored = restarted.logicalSpaceContext(from: snapshot.contexts[0], discovered: miri.allWindows())
        restarted.windowManagement.activateContext(restored)
        _ = restarted.upsertDiscoveredWindow(target)
        XCTAssertEqual(restarted.behavior(for: target), .tile)
        XCTAssertTrue(restarted.windowManagement.floatingWindows.isEmpty)
        XCTAssertTrue(restarted.windowManagement.manuallyFloatedWindows.isEmpty)
    }

    func testWorkspaceFullscreenFollowsExternalFocusAndRestoresEachNormalWidth() throws {
        for alignment: FocusAlignment in [.default, .centered, .centeredSmart] {
            let (miri, workspace) = try fixture(
                alignment: alignment, widths: [0.28, 0.67, 0.4], activeColumn: 1, scrollOffset: 45
            )
            // Exercise commands and projection without writing frames to real apps.
            miri.sessionController.pauseForUnavailableSession()
            let viewport = miri.currentViewport()
            let normalState = miri.captureLayoutState()
            let normalFrames = miri.layoutController.projectItems(
                viewport: viewport, state: normalState, parkHidden: false
            ).map(\.frame)

            miri.perform(.toggleWorkspaceFullscreen)

            XCTAssertEqual(projectedFrames(miri, viewport: viewport)[1], viewport)
            XCTAssertEqual(projectedFrames(miri, viewport: viewport, innerGap: 12, physicalPixelScale: 2)[1], viewport)
            let parked = miri.layoutController.projectItems(
                viewport: viewport, state: miri.captureLayoutState(), parkHidden: true
            )
            XCTAssertEqual(parked.filter(\.visible).map(\.window.title), ["Window 1"])
            XCTAssertEqual(
                miri.layoutController.projectItems(viewport: viewport, state: normalState, parkHidden: false).map(\.frame),
                normalFrames
            )

            let target = workspace.windows[2]
            XCTAssertTrue(miri.adoptFocusedElement(target.element, pid: target.pid, applyLayout: false))
            XCTAssertEqual(projectedFrames(miri, viewport: viewport)[2], viewport)
            XCTAssertEqual(workspace.windows.map(\.manualWidthRatio), [0.28, 0.67, 0.4])
            XCTAssertFalse(miri.updateManualWidthRatio(for: target.element, observedFrame: viewport))

            miri.perform(.toggleWorkspaceFullscreen)

            let restored = projectedFrames(miri, viewport: viewport)
            XCTAssertEqual(workspace.activeColumn, 2)
            XCTAssertTrue(viewport.contains(restored[2]))
            for (frame, ratio) in zip(restored, [CGFloat(0.28), 0.67, 0.4]) {
                XCTAssertEqual(frame.width, viewport.width * ratio, accuracy: 1)
            }
            XCTAssertTrue(miri.focusColumn(at: 0))
        }
    }

    func testFullscreenRowShortcutsDoNotWarnOrNavigateHiddenRowsAndWorkspaceSwitchPreservesFocus() throws {
        _ = NSApplication.shared
        let (miri, workspace) = try fixture(
            alignment: .default, widths: [0.28, 0.67, 0.4], activeColumn: 1, scrollOffset: 45
        )
        workspace.columns = [Column(windows: workspace.windows, activeRow: 1)]
        workspace.activeColumn = 0
        miri.windowManagement.ensureWorkspaceExists(2)
        XCTAssertTrue(miri.windowManagement.moveActiveColumn(toWorkspace: 1))
        let source = try XCTUnwrap(miri.activeWorkspaceObject())
        XCTAssertTrue(miri.windowManagement.toggleWorkspaceFullscreen())
        for index in [0, 2] {
            let destination = miri.windowManagement.workspaces[index]
            let rows = (0..<3).map { row in
                let pid = pid_t(2000 + index * 10 + row)
                return ManagedWindow(element: AXUIElementCreateApplication(pid), pid: pid,
                                     windowID: nil, bundleID: nil, appName: "Test", title: "Destination \(index) row \(row)")
            }
            destination.columns = [Column(windows: rows, activeRow: 1)]
            destination.fullscreenState = index == 2 ? .active : .off
        }
        miri.appPhase = .running
        defer {
            miri.cancelWorkspaceBoundaryHold()
            miri.workspaceBoundaryFeedbackController.hide()
            miri.workspaceFullscreenFeedbackController.hide()
        }
        let state = miri.captureLayoutState()
        let focused = source.activeWindow
        for (command, key) in [(Command.rowDown, KeyCode.j), (.rowUp, KeyCode.k)] {
            // No physical key is held and no real AX focus is supplied: cancel
            // rather than moving, but never fall through to a fullscreen notice.
            miri.enqueue(.input(.shortcut(command, keyCode: key, modifiers: .maskAlternate, isRepeat: false)))
            XCTAssertEqual(miri.captureLayoutState(), state)
            XCTAssertTrue(source.activeWindow === focused)
            XCTAssertFalse(NSApp.windows.contains {
                $0.identifier?.rawValue == "miri.workspace-fullscreen-feedback" && $0.isVisible
            })
            miri.enqueue(.input(.shortcutReleased))
        }
        miri.sessionController.pauseForUnavailableSession()
        for (command, index) in [(Command.workspaceDown, 2), (.workspaceUp, 0)] {
            XCTAssertTrue(miri.windowManagement.selectWorkspace(1, rememberPrevious: false) || miri.windowManagement.activeWorkspace == 1)
            let destination = miri.windowManagement.workspaces[index]
            let remembered = destination.activeWindow
            let fullscreen = destination.fullscreenState
            miri.perform(command)
            XCTAssertEqual(miri.windowManagement.activeWorkspace, index)
            XCTAssertTrue(destination.activeWindow === remembered)
            XCTAssertEqual(destination.fullscreenState, fullscreen)
            XCTAssertEqual(source.fullscreenState, .active)
            XCTAssertTrue(source.activeWindow === focused)
        }
    }

    func testCommittedRowBoundaryCrossingPreservesFullscreenFocusButUsesNormalEntryRows() throws {
        for direction: WorkspaceBoundaryDirection in [.up, .down] {
            for fullscreen: WorkspaceFullscreenState in [.active, .suspended, .off] {
                let (miri, workspace) = try fixture(
                    alignment: .default, widths: [0.5, 0.5], activeColumn: 0, scrollOffset: nil
                )
                miri.sessionController.pauseForUnavailableSession()
                let windows = workspace.windows
                let rememberedRow = direction == .up ? 0 : 1
                workspace.columns = [Column(windows: windows, activeRow: rememberedRow)]
                miri.windowManagement.ensureWorkspaceExists(1)
                if direction == .down {
                    XCTAssertTrue(miri.windowManagement.moveActiveColumn(toWorkspace: 1))
                }
                let destination = try XCTUnwrap(miri.activeWorkspaceObject())
                destination.fullscreenState = fullscreen
                let targetIndex = miri.windowManagement.activeWorkspace
                XCTAssertTrue(miri.windowManagement.selectWorkspace(direction == .up ? 1 : 0))
                let source = try XCTUnwrap(miri.activeWorkspaceObject())
                var gate = try XCTUnwrap(WorkspaceBoundaryGate(now: 0, milliseconds: 750, isRepeat: false))
                XCTAssertTrue(gate.commitIfReady(now: 0.75, held: true, sourceValid: true))
                let hold = WorkspaceBoundaryHold(
                    gate: gate, thresholdFocusValidated: true,
                    command: direction == .up ? .rowUp : .rowDown,
                    direction: direction, movesWindow: false,
                    keyCode: direction == .up ? KeyCode.k : KeyCode.j, modifiers: .maskAlternate,
                    workspace: source, window: nil,
                    sourceIndex: miri.windowManagement.activeWorkspace, targetIndex: targetIndex,
                    targetWorkspace: destination, contextID: miri.windowManagement.activeLogicalSpaceContextID,
                    focusGeneration: miri.focusStateGeneration, sessionGeneration: miri.sessionController.resumeGeneration
                )
                miri.workspaceBoundaryHold = hold
                defer { miri.cancelWorkspaceBoundaryHold() }
                miri.performWorkspaceBoundaryTransition(hold)
                let expectedRow = fullscreen == .off ? (direction == .up ? 1 : 0) : rememberedRow
                XCTAssertTrue(miri.activeWorkspaceObject() === destination)
                XCTAssertTrue(miri.activeWindow() === windows[expectedRow])
                XCTAssertEqual(destination.windows.map(\.title), windows.map(\.title))
                if fullscreen != .off {
                    XCTAssertEqual(destination.fullscreenState, .active)
                    let visible = miri.layoutController.projectItems(
                        viewport: viewport, state: miri.captureLayoutState(), parkHidden: true
                    ).filter(\.visible)
                    XCTAssertEqual(visible.count, 1)
                    XCTAssertTrue(visible.first?.window === windows[rememberedRow])
                    XCTAssertEqual(visible.first?.frame, viewport)
                }
            }
        }
    }

    func testWorkspaceFullscreenConsumesColumnNavigationAndResizeWithoutBlockingExternalFocus() async throws {
        _ = NSApplication.shared
        let screen = try XCTUnwrap(NSScreen.main)
        let (miri, workspace) = try fixture(
            alignment: .default, widths: [0.28, 0.67, 0.4], activeColumn: 1, scrollOffset: 45
        )
        defer { miri.workspaceFullscreenFeedbackController.hide() }
        XCTAssertTrue(miri.windowManagement.toggleWorkspaceFullscreen())
        let state = miri.captureLayoutState()
        miri.appPhase = .running

        func feedbackPanel() -> NSWindow? {
            NSApp.windows.first {
                $0.identifier?.rawValue == "miri.workspace-fullscreen-feedback" && $0.isVisible
            }
        }
        func displayedText(in view: NSView) -> [String] {
            if let label = view as? NSTextField { return [label.stringValue] }
            return view.subviews.flatMap { displayedText(in: $0) }
        }

        let commands: [Command] = [
            .columnLeft, .columnRight, .columnFirst, .columnLast,
            .cycleWidthPresetBackward, .cycleWidthPresetForward, .nudgeWidthNarrower, .nudgeWidthWider,
            .cycleAllWidthPresetsBackward, .cycleAllWidthPresetsForward, .nudgeAllWidthsNarrower, .nudgeAllWidthsWider,
        ]
        var panel: NSWindow?
        for (index, command) in commands.enumerated() {
            miri.submit(command)
            XCTAssertEqual(miri.captureLayoutState(), state)
            XCTAssertEqual(workspace.windows.map(\.manualWidthRatio), [0.28, 0.67, 0.4])
            let notice = try XCTUnwrap(feedbackPanel())
            if let panel { XCTAssertTrue(notice === panel, "Repeated shortcuts must reuse the notice") }
            panel = notice
            let message = index < 4
                ? "Exit workspace fullscreen to change focus"
                : "Exit workspace fullscreen to resize"
            XCTAssertEqual(displayedText(in: try XCTUnwrap(notice.contentView)), [message])
            XCTAssertTrue(notice.ignoresMouseEvents)
            XCTAssertFalse(notice.canBecomeKey)
            XCTAssertFalse(notice.canBecomeMain)
            XCTAssertEqual(notice.frame.midX, screen.visibleFrame.midX, accuracy: 1)
            XCTAssertLessThan(notice.frame.maxY, screen.visibleFrame.maxY)
        }

        // A rejected focus command must not grant keyboard focus authority and
        // suppress the subsequent macOS focus notification.
        let target = workspace.windows[0]
        XCTAssertTrue(miri.adoptFocusedElement(target.element, pid: target.pid, applyLayout: false))
        XCTAssertEqual(workspace.activeColumn, 0)
        XCTAssertEqual(projectedFrames(miri)[0], viewport)

        try await Task.sleep(for: .milliseconds(800))
        // Also cover a command reaching execution after fullscreen was enabled.
        miri.perform(.columnRight)
        try await Task.sleep(for: .milliseconds(900))
        XCTAssertNotNil(feedbackPanel(), "A repeated shortcut restarts the dismissal interval")
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertNil(feedbackPanel(), "The notice must disappear without more input")

        miri.perform(.columnLeft)
        XCTAssertNotNil(feedbackPanel())
        miri.sessionController.pauseForUnavailableSession()
        miri.perform(.toggleWorkspaceFullscreen)
        XCTAssertNil(feedbackPanel(), "Exiting fullscreen dismisses stale feedback immediately")
        miri.perform(.columnRight)
        XCTAssertEqual(workspace.activeColumn, 1)
        XCTAssertNil(feedbackPanel(), "Normal focus commands do not show fullscreen feedback")
        miri.perform(.toggleWorkspaceFullscreen)
        miri.perform(.nudgeWidthWider)
        XCTAssertNil(feedbackPanel(), "Unavailable sessions must not show feedback")
    }

    func testExternalFocusKeepsFullscreenInItsWorkspaceAndClearsWhenLastWindowCloses() throws {
        for sourceState: WorkspaceFullscreenState in [.active, .suspended] {
            for destinationState: WorkspaceFullscreenState in [.off, .active, .suspended] {
                let (miri, source) = try fixture(
                    alignment: .default, widths: [0.28, 0.67, 0.4], activeColumn: 1, scrollOffset: 45
                )
                miri.sessionController.pauseForUnavailableSession()
                miri.windowManagement.ensureWorkspaceExists(1)
                let destination = miri.windowManagement.workspaces[1]
                let target = source.windows[2]
                _ = miri.windowManagement.insert(target, in: destination, at: 0, focus: false)
                miri.perform(.toggleWorkspaceFullscreen)
                if sourceState == .suspended {
                    XCTAssertTrue(miri.windowManagement.suspendWorkspaceFullscreen())
                }
                destination.fullscreenState = destinationState
                let sourceFocus = try XCTUnwrap(source.activeWindow)
                let destinationFullscreen = destinationState != .off
                let expectedDestinationState: WorkspaceFullscreenState = destinationFullscreen ? .active : .off

                XCTAssertTrue(miri.adoptFocusedElement(target.element, pid: target.pid, applyLayout: false))
                XCTAssertEqual(miri.windowManagement.activeWorkspace, 1)
                XCTAssertEqual(source.fullscreenState, sourceState)
                XCTAssertTrue(source.activeWindow === sourceFocus)
                XCTAssertEqual(destination.fullscreenState, expectedDestinationState)
                XCTAssertEqual(projectedFrames(miri)[2].width, destinationFullscreen ? 1200 : 480)
                XCTAssertEqual(projectedFrames(miri)[2].height, 800)
                var summaries = miri.currentWorkspaceBarStatus().workspaceSummaries
                XCTAssertTrue(summaries[0].isWorkspaceFullscreen)
                XCTAssertEqual(summaries[1].isWorkspaceFullscreen, destinationFullscreen)
                XCTAssertEqual(summaries[1].lastFocusedWindow?.title, target.title)

                // Returning through external focus resumes only the source's own mode.
                XCTAssertTrue(miri.adoptFocusedElement(sourceFocus.element, pid: sourceFocus.pid, applyLayout: false))
                XCTAssertEqual(miri.windowManagement.activeWorkspace, 0)
                XCTAssertEqual(source.fullscreenState, .active)
                XCTAssertEqual(destination.fullscreenState, expectedDestinationState)
                XCTAssertEqual(projectedFrames(miri)[1], viewport)

                // Explicit workspace navigation also leaves each workspace's mode in place.
                XCTAssertTrue(miri.focusWorkspace(2))
                XCTAssertEqual(source.fullscreenState, .active)
                XCTAssertEqual(destination.fullscreenState, expectedDestinationState)
                summaries = miri.currentWorkspaceBarStatus().workspaceSummaries
                XCTAssertFalse(summaries[0].isActive)
                XCTAssertTrue(summaries[0].isWorkspaceFullscreen)
                XCTAssertEqual(summaries[1].isWorkspaceFullscreen, destinationFullscreen)
                miri.windowManagement.remove(target)
                XCTAssertEqual(destination.fullscreenState, .off)
                XCTAssertEqual(source.fullscreenState, .active)
                XCTAssertFalse(miri.currentWorkspaceBarStatus().workspaceSummaries[1].isWorkspaceFullscreen)
                XCTAssertFalse(miri.windowManagement.toggleWorkspaceFullscreen())
            }
        }
    }

    func testWorkspaceFullscreenPreservesLayoutForExcludedFocusAndFollowsReplacementWindow() throws {
        let (miri, workspace) = try fixture(
            alignment: .default, widths: [0.28, 0.67, 0.4], activeColumn: 1, scrollOffset: 45,
            rules: [WindowRule(titleContains: "Floating", behavior: .float)]
        )
        miri.sessionController.pauseForUnavailableSession()
        miri.perform(.toggleWorkspaceFullscreen)
        let before = miri.captureLayoutState()

        // Distinct synthetic AX identities represent windows in the same app
        // and another app; no AX messaging is performed by this fixture.
        for pid in [workspace.windows[1].pid, 9000] {
            let floating = ManagedWindow(
                element: AXUIElementCreateApplication(pid_t(5000 + pid)), pid: pid,
                windowID: nil, bundleID: nil, appName: "Test", title: "Floating"
            )
            _ = miri.windowManagement.insertFloating(floating)
            XCTAssertTrue(miri.adoptFocusedElement(floating.element, pid: pid, applyLayout: false))
            let unmanaged = AXUIElementCreateApplication(pid_t(6000 + pid))
            XCTAssertFalse(miri.adoptFocusedElement(unmanaged, pid: pid, applyLayout: false))
            XCTAssertEqual(miri.captureLayoutState(), before)
            XCTAssertEqual(workspace.fullscreenState, .active)
            XCTAssertEqual(projectedFrames(miri)[1], viewport)
            XCTAssertFalse(miri.focusColumn(at: 0))
            XCTAssertEqual(workspace.windows.map(\.manualWidthRatio), [0.28, 0.67, 0.4])
        }

        let target = workspace.windows[1]
        XCTAssertTrue(miri.adoptFocusedElement(target.element, pid: target.pid, applyLayout: false))
        XCTAssertEqual(projectedFrames(miri)[1], viewport)
        miri.windowManagement.remove(target, preferRightFocus: true)
        XCTAssertEqual(miri.activeWindow()?.title, "Window 2")
        XCTAssertEqual(projectedFrames(miri)[1], viewport)
        miri.perform(.toggleWorkspaceFullscreen)
        XCTAssertEqual(projectedFrames(miri)[1].width, 480)
    }

    func testWorkspaceFullscreenClassifiesFreshFocusedTitleBeforeFollowingWindow() throws {
        for behavior: WindowBehavior in [.float, .ignore] {
            let (miri, workspace) = try fixture(
                alignment: .default, widths: [0.28, 0.67, 0.4], activeColumn: 1, scrollOffset: 45,
                rules: [WindowRule(appName: "Test", titleContains: "Excluded", behavior: behavior)]
            )
            miri.sessionController.pauseForUnavailableSession()
            miri.perform(.toggleWorkspaceFullscreen)
            let previous = workspace.windows[1]
            let target = workspace.windows[2]
            func focusedSnapshot(title: String) -> AXWindowReadSnapshot {
                AXWindowReadSnapshot(
                    handle: AXElementHandle(element: target.element, pid: target.pid, windowID: nil),
                    role: kAXWindowRole, subrole: kAXStandardWindowSubrole, title: title,
                    minimized: false, fullscreenOS: false, frame: viewport,
                    positionSettable: true, sizeSettable: true
                )
            }

            _ = miri.adoptFocusedElement(
                target.element, pid: target.pid, applyLayout: false,
                snapshot: focusedSnapshot(title: "EXCLUDED panel")
            )

            XCTAssertTrue(miri.activeWindow() === previous)
            XCTAssertEqual(workspace.fullscreenState, .active)
            XCTAssertEqual(projectedFrames(miri)[1], viewport)
            XCTAssertEqual(workspace.windows.map(\.manualWidthRatio), [0.28, 0.67])
            XCTAssertFalse(workspace.windows.contains { $0 === target })
            XCTAssertEqual(miri.windowManagement.floatingWindows.contains { $0 === target }, behavior == .float)
            XCTAssertEqual(miri.allWindows().contains { $0 === target }, behavior == .float)
            XCTAssertTrue(miri.currentWorkspaceBarStatus().workspaceSummaries[0].isWorkspaceFullscreen)
            XCTAssertEqual(miri.currentWorkspaceBarStatus().workspaceSummaries[0].lastFocusedWindow?.title, previous.title)

            if behavior == .float {
                // A window that stops matching its floating rule is eligible
                // again, and receives fullscreen without losing its ratio.
                XCTAssertTrue(miri.adoptFocusedElement(
                    target.element, pid: target.pid, applyLayout: false,
                    snapshot: focusedSnapshot(title: "Document")
                ))
                XCTAssertTrue(miri.activeWindow() === target)
                XCTAssertEqual(workspace.fullscreenState, .active)
                XCTAssertEqual(projectedFrames(miri)[workspace.activeColumn], viewport)
                miri.perform(.toggleWorkspaceFullscreen)
                XCTAssertEqual(projectedFrames(miri)[workspace.activeColumn].width, 480)
            } else {
                let tiled = workspace.windows[0]
                XCTAssertTrue(miri.adoptFocusedElement(tiled.element, pid: tiled.pid, applyLayout: false))
                XCTAssertEqual(projectedFrames(miri)[0], viewport)
                miri.perform(.toggleWorkspaceFullscreen)
                XCTAssertEqual(projectedFrames(miri)[0].width, 336)
            }
        }
    }

    func testHorizontalFocusChoosesClosestRowCentersAndKeepsRememberedRowOnTies() throws {
        let cases: [([CGFloat], Int, [CGFloat], Int, Int)] = [
            ([0.5, 0.5], 0, [0.5, 0.5], 1, 0),
            ([0.5, 0.5], 1, [0.5, 0.5], 0, 1),
            ([0.4, 0.6], 0, [0.1, 0.2, 0.7], 2, 1),
            ([1], 0, [0.5, 0.5], 1, 1),
        ]
        for (sourceShares, sourceRow, targetShares, remembered, expected) in cases {
            for direction in [-1, 1] {
                let (miri, workspace) = try fixture(
                    alignment: .default,
                    widths: Array(repeating: 0.5, count: sourceShares.count + targetShares.count),
                    activeColumn: 0, scrollOffset: 0
                )
                miri.sessionController.pauseForUnavailableSession()
                let windows = workspace.windows
                let source = Column(windows: Array(windows.prefix(sourceShares.count)), activeRow: sourceRow, heightRatios: sourceShares)
                let target = Column(windows: Array(windows.dropFirst(sourceShares.count)), activeRow: remembered, heightRatios: targetShares)
                workspace.columns = direction > 0 ? [source, target] : [target, source]
                workspace.activeColumn = direction > 0 ? 0 : 1
                miri.focusColumn(by: direction, in: workspace, viewport: viewport)
                XCTAssertTrue(workspace.activeWindow === target.windows[expected])
                XCTAssertEqual(source.activeRow, sourceRow)
                XCTAssertEqual(workspace.scrollOffset, 0, "Visible columns must not move the camera")
                miri.focusColumn(by: direction, in: workspace, viewport: viewport)
                XCTAssertTrue(workspace.activeWindow === target.windows[expected], "A clamped column move must not change rows")
                workspace.activeColumn = direction > 0 ? 0 : 1
                target.activeRow = remembered
                XCTAssertTrue(miri.focusColumn(at: direction > 0 ? 1 : 0))
                XCTAssertTrue(workspace.activeWindow === target.windows[expected], "First/last column navigation also follows geometry")
            }
        }
    }

    func testFocusBetweenTwoVisibleWindowsKeepsFramesStationary() throws {
        for alignment in minimalRevealModes {
            let (miri, workspace) = try fixture(
                alignment: alignment,
                widths: Array(repeating: 0.5, count: 4),
                activeColumn: 2,
                scrollOffset: 600
            )
            let before = projectedFrames(miri)
            XCTAssertTrue(viewport.contains(before[1]))
            XCTAssertTrue(viewport.contains(before[2]))

            miri.focusColumn(by: -1, in: workspace, viewport: viewport)

            XCTAssertEqual(workspace.activeColumn, 1)
            XCTAssertEqual(workspace.scrollOffset, 600)
            XCTAssertEqual(projectedFrames(miri), before)

            miri.focusColumn(by: 1, in: workspace, viewport: viewport)

            XCTAssertEqual(workspace.activeColumn, 2)
            XCTAssertEqual(projectedFrames(miri), before)
        }
    }

    func testFocusAcrossThreeVisibleWindowsKeepsFramesStationary() throws {
        for alignment in minimalRevealModes {
            let (miri, workspace) = try fixture(
                alignment: alignment,
                widths: Array(repeating: 1.0 / 3.0, count: 5),
                activeColumn: 3,
                scrollOffset: 400
            )
            let before = projectedFrames(miri)
            for index in 1...3 {
                XCTAssertTrue(viewport.contains(before[index]))
            }

            for direction in [-1, -1, 1, 1] {
                miri.focusColumn(by: direction, in: workspace, viewport: viewport)
                XCTAssertEqual(projectedFrames(miri), before)
            }
            XCTAssertEqual(workspace.activeColumn, 3)
        }
    }

    func testFocusPreservesCameraWhenOffsetWasImplicit() throws {
        for alignment in minimalRevealModes {
            let (miri, workspace) = try fixture(
                alignment: alignment,
                widths: Array(repeating: 0.5, count: 4),
                activeColumn: 2,
                scrollOffset: nil
            )
            let before = projectedFrames(miri)
            XCTAssertTrue(viewport.contains(before[1]))

            miri.focusColumn(by: -1, in: workspace, viewport: viewport)

            XCTAssertEqual(workspace.activeColumn, 1)
            XCTAssertEqual(workspace.scrollOffset, 600)
            XCTAssertEqual(projectedFrames(miri), before)
        }
    }

    func testClippedTargetScrollsOnlyEnoughToBecomeVisible() throws {
        for alignment in minimalRevealModes {
            for (activeColumn, offset, direction, expectedOffset) in [
                (2, CGFloat(540), -1, CGFloat(480)),
                (1, CGFloat(180), 1, CGFloat(240)),
            ] {
                let (miri, workspace) = try fixture(
                    alignment: alignment,
                    widths: Array(repeating: 0.4, count: 4),
                    activeColumn: activeColumn,
                    scrollOffset: offset
                )
                let before = projectedFrames(miri)
                let target = activeColumn + direction
                XCTAssertFalse(viewport.contains(before[target]))

                miri.focusColumn(by: direction, in: workspace, viewport: viewport)

                let after = projectedFrames(miri)
                XCTAssertEqual(workspace.activeColumn, target)
                XCTAssertEqual(workspace.scrollOffset, expectedOffset)
                XCTAssertTrue(viewport.contains(after[target]))
                XCTAssertEqual(abs(after[target].minX - before[target].minX), 60)
            }
        }
    }

    func testFullyFittingStripAndBoundaryFocusStayStationary() throws {
        for alignment in minimalRevealModes {
            let (miri, workspace) = try fixture(
                alignment: alignment,
                widths: Array(repeating: 1.0 / 3.0, count: 3),
                activeColumn: 1,
                scrollOffset: 0
            )
            let before = projectedFrames(miri)

            for direction in [-1, -1, 1, 1, 1] {
                miri.focusColumn(by: direction, in: workspace, viewport: viewport)
                XCTAssertEqual(projectedFrames(miri), before)
            }
        }
    }

    func testCenteredModeStillCentersTheNewFocus() throws {
        let (miri, workspace) = try fixture(
            alignment: .centered,
            widths: Array(repeating: 0.5, count: 4),
            activeColumn: 2,
            scrollOffset: 900
        )

        miri.focusColumn(by: -1, in: workspace, viewport: viewport)

        XCTAssertEqual(workspace.activeColumn, 1)
        XCTAssertEqual(workspace.scrollOffset, 300)
        XCTAssertEqual(projectedFrames(miri)[1].midX, viewport.midX)
    }

    func testSmartCenteredPreservesAnAlreadyVisibleWidePair() throws {
        let (miri, workspace) = try fixture(
            alignment: .centeredSmart,
            widths: [0.25, 0.75, 0.25],
            activeColumn: 0,
            scrollOffset: 0
        )
        let before = projectedFrames(miri)
        XCTAssertTrue(viewport.contains(before[1]))

        miri.focusColumn(by: 1, in: workspace, viewport: viewport)

        XCTAssertEqual(workspace.activeColumn, 1)
        XCTAssertEqual(workspace.scrollOffset, 0)
        XCTAssertEqual(projectedFrames(miri), before)

        miri.focusColumn(by: -1, in: workspace, viewport: viewport)
        XCTAssertEqual(projectedFrames(miri), before)
    }

    func testSmartCenteredCentersALoneWindowAtAnyWidth() throws {
        for width: CGFloat in [0.25, 0.5, 0.75, 1, 1.5] {
            for offset: CGFloat? in [nil, -100, 900] {
                let (miri, workspace) = try fixture(
                    alignment: .centeredSmart,
                    widths: [width],
                    activeColumn: 0,
                    scrollOffset: offset
                )

                XCTAssertEqual(projectedFrames(miri)[0].midX, viewport.midX)
                miri.revealActiveColumnIfNeeded(in: workspace, viewport: viewport)
                XCTAssertEqual(projectedFrames(miri)[0].midX, viewport.midX)
                XCTAssertEqual(workspace.scrollOffset, (width - 1) * viewport.width / 2)
            }
        }
    }

    func testSmartCenteredPreservesVisibleFocusDespiteASmallerHiddenNeighbor() throws {
        for (widths, activeColumn, direction, offset) in [
            ([CGFloat(0.33), 0.5, 0.5], 2, -1, CGFloat(396)),
            ([CGFloat(0.5), 0.5, 0.33], 0, 1, CGFloat(0)),
            ([CGFloat(0.35), 0.6, 0.25], 0, 1, CGFloat(0)),
            ([CGFloat(0.25), 0.6, 0.35], 2, -1, CGFloat(300)),
        ] {
            let (miri, workspace) = try fixture(
                alignment: .centeredSmart,
                widths: widths,
                activeColumn: activeColumn,
                scrollOffset: offset
            )
            let before = projectedFrames(miri)
            XCTAssertTrue(viewport.contains(before[activeColumn]))
            XCTAssertTrue(viewport.contains(before[1]))
            XCTAssertFalse(viewport.contains(before[2 - activeColumn]))

            miri.focusColumn(by: direction, in: workspace, viewport: viewport)

            XCTAssertEqual(workspace.activeColumn, 1)
            XCTAssertEqual(workspace.scrollOffset, offset)
            XCTAssertEqual(projectedFrames(miri), before)
            // Later projection/reconciliation must not reselect the hidden neighbor.
            miri.revealActiveColumnIfNeeded(in: workspace, viewport: viewport)
            XCTAssertEqual(projectedFrames(miri), before)
            miri.focusColumn(by: -direction, in: workspace, viewport: viewport)
            XCTAssertEqual(projectedFrames(miri), before)
        }
    }

    func testSmartCenteredPreservesImplicitVisibleFocusDespiteASmallerHiddenNeighbor() throws {
        for (widths, activeColumn, direction) in [
            ([CGFloat(0.33), 0.5, 0.5], 2, -1),
            ([CGFloat(0.5), 0.5, 0.33], 0, 1),
        ] {
            let (miri, workspace) = try fixture(
                alignment: .centeredSmart,
                widths: widths,
                activeColumn: activeColumn,
                scrollOffset: nil
            )
            let before = projectedFrames(miri)
            XCTAssertTrue(viewport.contains(before[1]))

            miri.focusColumn(by: direction, in: workspace, viewport: viewport)

            XCTAssertEqual(projectedFrames(miri), before)
            XCTAssertEqual(miri.stripFrames(
                for: workspace,
                viewport: viewport,
                activeColumn: workspace.activeColumn,
                scrollOffset: workspace.scrollOffset
            ), before)
        }
    }

    func testSmartCenteredStillSelectsSmallestNeighborForClippedAndOffscreenFocus() throws {
        for (widths, activeColumn, direction, offset, expectedOffset, neighbor) in [
            // One point of clipping must run smart centering, just like a fully hidden target.
            ([CGFloat(0.33), 0.5, 0.5], 2, -1, CGFloat(397), CGFloat(0), 0),
            ([CGFloat(0.5), 0.5, 0.33], 0, 1, CGFloat(-1), CGFloat(396), 2),
            ([CGFloat(0.33), 0.5, 0.5], 2, -1, CGFloat(996), CGFloat(0), 0),
            ([CGFloat(0.5), 0.5, 0.33], 0, 1, CGFloat(-600), CGFloat(396), 2),
        ] {
            let (miri, workspace) = try fixture(
                alignment: .centeredSmart,
                widths: widths,
                activeColumn: activeColumn,
                scrollOffset: offset
            )
            let before = projectedFrames(miri)
            XCTAssertTrue(viewport.contains(before[activeColumn]))
            XCTAssertFalse(viewport.contains(before[1]))

            miri.focusColumn(by: direction, in: workspace, viewport: viewport)

            let after = projectedFrames(miri)
            XCTAssertEqual(try XCTUnwrap(workspace.scrollOffset), expectedOffset, accuracy: 0.001)
            XCTAssertTrue(viewport.contains(after[1]))
            XCTAssertTrue(viewport.contains(after[neighbor]))
            XCTAssertFalse(viewport.contains(after[2 - neighbor]))
        }
    }

    func testSmartCenteredUsesNeighborFittingAtExactlyHalfWidth() throws {
        let (miri, workspace) = try fixture(
            alignment: .centeredSmart,
            widths: [0.4, 0.5, 0.3],
            activeColumn: 1,
            scrollOffset: nil
        )

        miri.revealActiveColumnIfNeeded(in: workspace, viewport: viewport)

        let frames = projectedFrames(miri)
        XCTAssertEqual(workspace.scrollOffset, 240)
        XCTAssertTrue(viewport.contains(frames[1]))
        XCTAssertTrue(viewport.contains(frames[2]))
        XCTAssertFalse(viewport.contains(frames[0]))
    }

    func testSmartCenteredResumesAlignmentAfterLeavingAPreservedVisiblePair() throws {
        let (miri, workspace) = try fixture(
            alignment: .centeredSmart,
            widths: [0.33, 0.5, 0.5, 0.25],
            activeColumn: 2,
            scrollOffset: 396
        )
        let before = projectedFrames(miri)
        miri.focusColumn(by: -1, in: workspace, viewport: viewport)
        XCTAssertEqual(projectedFrames(miri), before)
        miri.focusColumn(by: 1, in: workspace, viewport: viewport)
        XCTAssertEqual(projectedFrames(miri), before)

        // Reveal the hidden narrow window, then focus its now-visible neighbor.
        miri.focusColumn(by: 1, in: workspace, viewport: viewport)
        let revealed = projectedFrames(miri)
        XCTAssertTrue(viewport.contains(revealed[3]))
        XCTAssertFalse(viewport.contains(revealed[1]))
        miri.focusColumn(by: -1, in: workspace, viewport: viewport)
        XCTAssertEqual(projectedFrames(miri), revealed)

        // Returning to the clipped half-width window must choose its smaller neighbor.
        miri.focusColumn(by: -1, in: workspace, viewport: viewport)
        let after = projectedFrames(miri)
        XCTAssertEqual(workspace.scrollOffset, 0)
        XCTAssertTrue(viewport.contains(after[0]))
        XCTAssertTrue(viewport.contains(after[1]))
        XCTAssertFalse(viewport.contains(after[2]))
    }

    func testSmartCenteredLeavesNarrowFocusAloneEvenWhenANeighborCouldBeRevealed() throws {
        let (miri, workspace) = try fixture(
            alignment: .centeredSmart,
            widths: [0.6, 0.49, 0.2],
            activeColumn: 1,
            scrollOffset: 240
        )
        let before = projectedFrames(miri)
        XCTAssertTrue(viewport.contains(before[1]))
        XCTAssertFalse(viewport.contains(before[2]))

        miri.revealActiveColumnIfNeeded(in: workspace, viewport: viewport)

        XCTAssertEqual(workspace.scrollOffset, 240)
        XCTAssertEqual(projectedFrames(miri), before)
    }

    func testSmartCenteredDoesNotCenterNarrowFocusWhenNeitherNeighborFits() throws {
        let (miri, workspace) = try fixture(
            alignment: .centeredSmart,
            widths: [0.8, 0.49, 0.8],
            activeColumn: 1,
            scrollOffset: nil
        )

        miri.revealActiveColumnIfNeeded(in: workspace, viewport: viewport)

        let frame = projectedFrames(miri)[1]
        XCTAssertEqual(frame.maxX, viewport.maxX)
        XCTAssertNotEqual(frame.midX, viewport.midX)
    }

    func testSmartCenteredCentersWhenNeitherAdjacentNeighborFits() throws {
        for widths: [CGFloat] in [[0.6, 0.5, 0.6], [0.35, 0.8, 0.35], [0.2, 1.2, 0.2]] {
            let (miri, workspace) = try fixture(
                alignment: .centeredSmart,
                widths: widths,
                activeColumn: 1,
                scrollOffset: 0
            )

            miri.revealActiveColumnIfNeeded(in: workspace, viewport: viewport)

            XCTAssertEqual(projectedFrames(miri)[1].midX, viewport.midX)
        }
    }

    func testSmartCenteredDoesNotSkipAnAdjacentWindowToReachASmallerOne() throws {
        let (miri, _) = try fixture(
            alignment: .centeredSmart,
            widths: [0.2, 0.8, 0.7, 0.8, 0.2],
            activeColumn: 2,
            scrollOffset: nil
        )

        XCTAssertEqual(projectedFrames(miri)[2].midX, viewport.midX)
    }

    func testSmartCenteredKeepsFocusAsCloseToCenterAsPairAllowsAtStripBoundaries() throws {
        for (widths, activeColumn, expectedMinX) in [
            ([CGFloat(0.6), 0.25], 0, CGFloat(180)),
            ([CGFloat(0.25), 0.6], 1, CGFloat(300)),
        ] {
            let (miri, workspace) = try fixture(
                alignment: .centeredSmart,
                widths: widths,
                activeColumn: activeColumn,
                scrollOffset: nil
            )

            miri.revealActiveColumnIfNeeded(in: workspace, viewport: viewport)

            let frames = projectedFrames(miri)
            XCTAssertTrue(frames.allSatisfy(viewport.contains))
            XCTAssertEqual(frames[activeColumn].minX, expectedMinX)
            XCTAssertEqual(miri.stripFrames(
                for: workspace,
                viewport: viewport,
                activeColumn: activeColumn,
                scrollOffset: workspace.scrollOffset
            ), frames)
        }
    }

    func testSmartCenteredExactFitHonorsGapsAndDisplayScale() throws {
        let viewport = CGRect(x: 120, y: 80, width: 1001, height: 800)
        let (miri, _) = try fixture(
            alignment: .centeredSmart,
            widths: [0.3, 0.7, 0.4],
            activeColumn: 1,
            scrollOffset: nil
        )
        for scale: CGFloat in [1, 2] {
            let frames = projectedFrames(miri, viewport: viewport, innerGap: 12, physicalPixelScale: scale)

            XCTAssertTrue(viewport.contains(frames[0]))
            XCTAssertTrue(viewport.contains(frames[1]))
            XCTAssertEqual(frames[0].minX, viewport.minX)
            XCTAssertEqual(frames[1].maxX, viewport.maxX)
            XCTAssertEqual(frames[1].minX - frames[0].maxX, 12 / scale, accuracy: 1 / scale)
        }
    }

    func testSmartCenteredPairAtViewportEdgeStaysStationaryWhenNarrowMemberGainsFocus() throws {
        for (widths, activeColumn, direction) in [
            ([CGFloat(0.6), 0.25], 0, 1),
            ([CGFloat(0.25), 0.5], 1, -1),
        ] {
            let (miri, workspace) = try fixture(
                alignment: .centeredSmart,
                widths: widths,
                activeColumn: activeColumn,
                scrollOffset: nil
            )
            let before = projectedFrames(miri)

            miri.focusColumn(by: direction, in: workspace, viewport: viewport)
            XCTAssertEqual(projectedFrames(miri), before)

            miri.focusColumn(by: -direction, in: workspace, viewport: viewport)
            XCTAssertEqual(projectedFrames(miri), before)
        }
    }

    func testSmartCenteredReevaluatesAfterNeighborInsertionAndRemoval() throws {
        let (miri, workspace) = try fixture(
            alignment: .centeredSmart,
            widths: [0.25, 0.3],
            activeColumn: 0,
            scrollOffset: 0
        )
        let neighbor = workspace.windows[1]
        XCTAssertEqual(projectedFrames(miri)[0].minX, viewport.minX)

        miri.windowManagement.remove(neighbor)
        XCTAssertEqual(projectedFrames(miri)[0].midX, viewport.midX)

        _ = miri.windowManagement.insert(neighbor, in: workspace, at: 1, focus: false)
        XCTAssertEqual(projectedFrames(miri)[0].minX, viewport.minX)
    }

    func testSmartCenteredExternalFocusPreservesImplicitVisiblePair() throws {
        let (miri, workspace) = try fixture(
            alignment: .centeredSmart,
            widths: Array(repeating: 0.5, count: 4),
            activeColumn: 2,
            scrollOffset: nil
        )
        let viewport = miri.currentViewport()
        let before = projectedFrames(miri, viewport: viewport)
        let target = workspace.windows[1]

        XCTAssertTrue(miri.adoptFocusedElement(target.element, pid: target.pid, applyLayout: false))

        XCTAssertEqual(workspace.activeColumn, 1)
        XCTAssertEqual(projectedFrames(miri, viewport: viewport), before)
    }

    func testSmartCenteredExternalFocusUsesVisibilityBeforeSelectingANeighbor() throws {
        for (widths, activeColumn, offsetRatio, expectedOffsetRatio) in [
            ([CGFloat(0.33), 0.5, 0.5], 2, CGFloat(0.33), CGFloat(0.33)),
            ([CGFloat(0.5), 0.5, 0.33], 0, CGFloat(0), CGFloat(0)),
            ([CGFloat(0.33), 0.5, 0.5], 2, CGFloat(0.4), CGFloat(0)),
            ([CGFloat(0.5), 0.5, 0.33], 0, CGFloat(-0.1), CGFloat(0.33)),
            ([CGFloat(0.33), 0.5, 0.5], 2, CGFloat(0.83), CGFloat(0)),
            ([CGFloat(0.5), 0.5, 0.33], 0, CGFloat(-0.5), CGFloat(0.33)),
        ] {
            let (miri, workspace) = try fixture(
                alignment: .centeredSmart,
                widths: widths,
                activeColumn: activeColumn,
                scrollOffset: nil
            )
            let viewport = miri.currentViewport()
            miri.windowManagement.setScrollOffset(offsetRatio * viewport.width, in: workspace)
            let before = projectedFrames(miri, viewport: viewport)
            let target = workspace.windows[1]
            let shouldStayStationary = offsetRatio == expectedOffsetRatio
            XCTAssertEqual(viewport.contains(before[1]), shouldStayStationary)

            XCTAssertTrue(miri.adoptFocusedElement(target.element, pid: target.pid, applyLayout: false))

            XCTAssertEqual(workspace.activeColumn, 1)
            XCTAssertEqual(
                try XCTUnwrap(workspace.scrollOffset),
                expectedOffsetRatio * viewport.width,
                accuracy: 0.001
            )
            let after = projectedFrames(miri, viewport: viewport)
            XCTAssertTrue(viewport.contains(after[1]))
            if shouldStayStationary {
                XCTAssertEqual(after, before)
            } else {
                XCTAssertNotEqual(after, before)
            }
        }
    }

    func testSmartCenteredVisibleFocusStaysStationaryWithGapsAndFractionalWidths() throws {
        let viewport = CGRect(x: 120, y: 80, width: 1001, height: 800)
        let (miri, workspace) = try fixture(
            alignment: .centeredSmart,
            widths: [0.33, 0.5, 0.5],
            activeColumn: 2,
            scrollOffset: 0.33 * viewport.width
        )
        let before = projectedFrames(miri, viewport: viewport, innerGap: 12, physicalPixelScale: 2)

        miri.focusColumn(by: -1, in: workspace, viewport: viewport)

        XCTAssertEqual(
            projectedFrames(miri, viewport: viewport, innerGap: 12, physicalPixelScale: 2),
            before
        )
    }

    func testSmartCenteredResizeStillReconsidersSmallestNeighbor() throws {
        for resizeMode: WidthResizeMode in [.default, .intelligent] {
            let (miri, workspace) = try fixture(
                alignment: .centeredSmart,
                widths: [0.35, 0.5, 0.25],
                activeColumn: 0,
                scrollOffset: 0,
                resizeMode: resizeMode
            )
            let viewport = miri.currentViewport()
            miri.focusColumn(by: 1, in: workspace, viewport: viewport)
            let before = projectedFrames(miri, viewport: viewport)
            XCTAssertTrue(viewport.contains(before[0]))
            XCTAssertFalse(viewport.contains(before[2]))

            XCTAssertTrue(miri.setActiveWindowWidthRatio(0.6))

            let after = projectedFrames(miri, viewport: viewport)
            XCTAssertTrue(viewport.contains(after[1]))
            XCTAssertTrue(viewport.contains(after[2]))
            XCTAssertFalse(viewport.contains(after[0]))
        }
    }

    func testSmartCenteredWidthChangesTransitionBetweenPairingAndCentering() throws {
        for resizeMode: WidthResizeMode in [.default, .intelligent] {
            let (miri, workspace) = try fixture(
                alignment: .centeredSmart,
                widths: [0.25, 0.49, 0.3],
                activeColumn: 1,
                scrollOffset: 0,
                resizeMode: resizeMode
            )
            let viewport = miri.currentViewport()

            for width: CGFloat in [0.65, 0.8, 0.65] {
                XCTAssertTrue(miri.setActiveWindowWidthRatio(width))
                let frames = projectedFrames(miri, viewport: viewport)
                if width == 0.8 {
                    XCTAssertEqual(frames[1].midX, viewport.midX, accuracy: 0.5)
                } else {
                    XCTAssertTrue(viewport.contains(frames[0]))
                    XCTAssertTrue(viewport.contains(frames[1]))
                }
                if resizeMode == .intelligent {
                    XCTAssertEqual(
                        miri.horizontalCameraOffset(for: workspace, viewport: viewport),
                        try XCTUnwrap(workspace.scrollOffset),
                        accuracy: 0.001
                    )
                }
            }
        }
    }

    func testSmartCenteredManualResizeStillReconsidersSmallestNeighbor() throws {
        let (miri, workspace) = try fixture(
            alignment: .centeredSmart,
            widths: [0.35, 0.5, 0.25],
            activeColumn: 0,
            scrollOffset: 0
        )
        let viewport = miri.currentViewport()
        miri.focusColumn(by: 1, in: workspace, viewport: viewport)
        var resizedFrame = projectedFrames(miri, viewport: viewport)[1]
        resizedFrame.size.width = 0.6 * viewport.width
        let target = workspace.windows[1]
        // Manual resize normally runs inside a coordinator event. Keep its
        // emitted notification queued in this fixture, which has no runtime.
        miri.isHandlingCoordinatorEvent = true
        defer { miri.isHandlingCoordinatorEvent = false }

        XCTAssertTrue(miri.updateManualWidthRatio(for: target.element, observedFrame: resizedFrame))

        let after = projectedFrames(miri, viewport: viewport)
        XCTAssertTrue(viewport.contains(after[1]))
        XCTAssertTrue(viewport.contains(after[2]))
        XCTAssertFalse(viewport.contains(after[0]))
        XCTAssertFalse(miri.updateManualWidthRatio(for: target.element, observedFrame: resizedFrame))
    }

    func testFirstAndLastJumpsKeepTheirExistingCameraReset() throws {
        for alignment in minimalRevealModes {
            let (miri, workspace) = try fixture(
                alignment: alignment,
                widths: Array(repeating: 0.5, count: 4),
                activeColumn: 2,
                scrollOffset: 600
            )

            XCTAssertTrue(miri.focusColumn(at: 0))
            XCTAssertNil(workspace.scrollOffset)
            XCTAssertEqual(projectedFrames(miri)[0].minX, viewport.minX)

            XCTAssertTrue(miri.focusColumn(at: 3))
            XCTAssertNil(workspace.scrollOffset)
            XCTAssertEqual(projectedFrames(miri)[3].maxX, viewport.maxX)
        }
    }

    func testPerWindowFullscreenRestoresNormalLayoutOnKeyboardAndExternalFocus() throws {
        for alignment: FocusAlignment in [.default, .centered, .centeredSmart] {
            let (miri, workspace) = try fixture(
                alignment: alignment, widths: [0.28, 0.67, 0.4], activeColumn: 1,
                scrollOffset: 45, fullscreenMode: .perWindow
            )
            miri.sessionController.pauseForUnavailableSession()
            let fullscreen = workspace.windows[1]
            let normal = workspace.windows[2]
            miri.perform(.toggleWorkspaceFullscreen)
            XCTAssertTrue(fullscreen.fullscreenLayout)
            XCTAssertFalse(fullscreen.fullscreenOS)
            XCTAssertEqual(projectedFrames(miri)[1], viewport)

            XCTAssertFalse(miri.consumeCommandBlockedByWorkspaceFullscreen(.columnRight))
            miri.perform(.columnRight)
            XCTAssertTrue(workspace.activeWindow === normal)
            XCTAssertFalse(normal.fullscreenLayout)
            XCTAssertEqual(projectedFrames(miri)[2].width, viewport.width * 0.4, accuracy: 0.01)
            XCTAssertFalse(miri.currentWorkspaceBarStatus().workspaceSummaries[0].isWorkspaceFullscreen)

            // The external adoption path is shared by Dock, Cmd-Tab and window activation.
            XCTAssertTrue(miri.adoptFocusedElement(fullscreen.element, pid: fullscreen.pid, applyLayout: false))
            XCTAssertEqual(projectedFrames(miri)[1], viewport)
            XCTAssertTrue(miri.currentWorkspaceBarStatus().workspaceSummaries[0].isWorkspaceFullscreen)
            XCTAssertTrue(miri.adoptFocusedElement(normal.element, pid: normal.pid, applyLayout: false))
            XCTAssertEqual(projectedFrames(miri)[2].width, viewport.width * 0.4, accuracy: 0.01)
            miri.perform(.columnLeft)
            XCTAssertEqual(projectedFrames(miri)[1], viewport)
            miri.perform(.toggleWorkspaceFullscreen)
            XCTAssertFalse(fullscreen.fullscreenLayout)
            XCTAssertEqual(projectedFrames(miri)[1].width, viewport.width * 0.67, accuracy: 0.01)
            XCTAssertEqual(workspace.windows.map(\.manualWidthRatio), [0.28, 0.67, 0.4])
        }
    }

    func testPerWindowFullscreenIsRememberedIndependentlyForMultipleWindowsAndWorkspaces() throws {
        let (miri, source) = try fixture(
            alignment: .default, widths: [0.4, 0.67], activeColumn: 0,
            scrollOffset: nil, fullscreenMode: .perWindow
        )
        miri.sessionController.pauseForUnavailableSession()
        miri.perform(.toggleWorkspaceFullscreen)
        miri.perform(.columnRight)
        XCTAssertEqual(miri.windowManagement.activeFullscreenState, .off)
        miri.perform(.toggleWorkspaceFullscreen)
        XCTAssertTrue(source.windows.allSatisfy(\.fullscreenLayout))
        miri.perform(.columnLeft)
        XCTAssertEqual(miri.windowManagement.activeFullscreenState, .active)

        miri.windowManagement.ensureWorkspaceExists(1)
        let destination = miri.windowManagement.workspaces[1]
        let other = ManagedWindow(element: AXUIElementCreateApplication(3000), pid: 3000,
                                  windowID: nil, bundleID: nil, appName: "Test", title: "Other")
        other.manualWidthRatio = 0.5
        destination.columns = [Column(windows: [other])]
        miri.perform(.workspaceDown)
        XCTAssertEqual(miri.windowManagement.activeFullscreenState, .off)
        XCTAssertEqual(miri.workspaceSummaries().map(\.isWorkspaceFullscreen), [true, false])
        miri.perform(.workspaceUp)
        XCTAssertTrue(source.activeWindow === source.windows[0])
        XCTAssertEqual(miri.windowManagement.activeFullscreenState, .active)
        miri.perform(.toggleWorkspaceFullscreen)
        XCTAssertEqual(miri.workspaceSummaries().map(\.isWorkspaceFullscreen), [false, false],
                       "Remembered fullscreen on an unfocused peer must not light the indicator")
        miri.perform(.workspaceDown)
        XCTAssertFalse(miri.workspaceSummaries()[0].isWorkspaceFullscreen)
    }

    func testPerWindowFullscreenVerticalNavigationDefaultPreservesWorkspaceBehavior() throws {
        let (miri, workspace) = try fixture(
            alignment: .default, widths: [0.4, 0.4], activeColumn: 0,
            scrollOffset: nil, fullscreenMode: .perWindow
        )
        miri.sessionController.pauseForUnavailableSession()
        workspace.columns = [Column(windows: workspace.windows)]
        miri.perform(.toggleWorkspaceFullscreen)
        guard case .workspaceDown = miri.resolvedFullscreenNavigationCommand(.rowDown),
              case .workspaceUp = miri.resolvedFullscreenNavigationCommand(.rowUp) else {
            return XCTFail("The default must switch workspaces despite an available row")
        }
        XCTAssertEqual(workspace.columns[0].activeRow, 0)
    }

    func testPerWindowFullscreenVerticalNavigationFocusesRowsAndFallsBackAtEdges() throws {
        let (miri, workspace) = try fixture(
            alignment: .default, widths: [0.4, 0.4, 0.4], activeColumn: 0,
            scrollOffset: nil, fullscreenMode: .perWindow, verticalNavigation: .focusWindowsFirst
        )
        miri.sessionController.pauseForUnavailableSession()
        let windows = workspace.windows
        workspace.columns = [Column(windows: windows, activeRow: 1, widthRatio: 0.4)]
        miri.perform(.toggleWorkspaceFullscreen)
        for command in [Command.rowDown, .rowUp] {
            switch (command, miri.resolvedFullscreenNavigationCommand(command)) {
            case (.rowDown, .rowDown), (.rowUp, .rowUp): break
            default: XCTFail("An available row must take priority")
            }
        }
        // Exercise keyboard boundary routing before executing the immediate row command.
        XCTAssertFalse(miri.handleWorkspaceBoundaryShortcut(.rowDown, keyCode: KeyCode.j,
                                                           modifiers: .maskAlternate, isRepeat: false))
        miri.perform(.rowDown)
        XCTAssertTrue(workspace.activeWindow === windows[2])
        XCTAssertEqual(miri.windowManagement.activeFullscreenState, .off)
        let normal = miri.layoutController.projectItems(viewport: viewport, state: miri.captureLayoutState(), parkHidden: false)
        XCTAssertEqual(normal[2].frame.height, viewport.height / 3, accuracy: 0.5)
        miri.perform(.rowUp)
        XCTAssertTrue(workspace.activeWindow === windows[1])
        XCTAssertEqual(miri.windowManagement.activeFullscreenState, .active)
        let fullscreen = miri.layoutController.projectItems(viewport: viewport, state: miri.captureLayoutState(), parkHidden: false)
        XCTAssertEqual(fullscreen.filter(\.visible).map(\.window.title), [windows[1].title])
        XCTAssertEqual(fullscreen[1].frame, viewport)

        miri.perform(.rowDown)
        miri.perform(.toggleWorkspaceFullscreen)
        guard case .workspaceDown = miri.resolvedFullscreenNavigationCommand(.rowDown) else {
            return XCTFail("The bottom row must fall back to workspace navigation")
        }
        miri.perform(.rowUp)
        XCTAssertEqual(miri.windowManagement.activeFullscreenState, .active,
                       "Moving between two fullscreen windows must retain fullscreen presentation")
        miri.perform(.rowUp)
        miri.perform(.toggleWorkspaceFullscreen)
        guard case .workspaceUp = miri.resolvedFullscreenNavigationCommand(.rowUp) else {
            return XCTFail("The top row must fall back to workspace navigation")
        }
        workspace.columns = [Column(windows: [windows[0]])]
        for command in [Command.rowDown, .rowUp] {
            switch miri.resolvedFullscreenNavigationCommand(command) {
            case .workspaceDown, .workspaceUp: break
            default: XCTFail("A lone window must use workspace navigation")
            }
        }
    }

    func testPerWindowFullscreenWorkspaceFallbackPreservesRememberedRows() throws {
        for navigation: FullscreenVerticalNavigation in [.switchWorkspaces, .focusWindowsFirst] {
            let (miri, source) = try fixture(
                alignment: .default, widths: [0.4, 0.4], activeColumn: 0,
                scrollOffset: nil, fullscreenMode: .perWindow, verticalNavigation: navigation
            )
            miri.sessionController.pauseForUnavailableSession()
            source.columns = [Column(windows: source.windows, activeRow: 1)]
            miri.perform(.toggleWorkspaceFullscreen)
            miri.windowManagement.ensureWorkspaceExists(1)
            let destination = miri.windowManagement.workspaces[1]
            let windows = (0..<2).map { row in
                let pid = pid_t(4000 + row)
                return ManagedWindow(element: AXUIElementCreateApplication(pid), pid: pid,
                                     windowID: nil, bundleID: nil, appName: "Test", title: "Row \(row)")
            }
            destination.columns = [Column(windows: windows, activeRow: 1)]
            var gate = try XCTUnwrap(WorkspaceBoundaryGate(now: 0, milliseconds: 750, isRepeat: false))
            XCTAssertTrue(gate.commitIfReady(now: 0.75, held: true, sourceValid: true))
            let command = miri.resolvedFullscreenNavigationCommand(.rowDown)
            guard case .workspaceDown = command else { return XCTFail("Expected workspace fallback") }
            let hold = WorkspaceBoundaryHold(
                gate: gate, thresholdFocusValidated: true, command: command, direction: .down,
                movesWindow: false, keyCode: KeyCode.j, modifiers: .maskAlternate,
                workspace: source, window: source.activeWindow, sourceIndex: 0, targetIndex: 1,
                targetWorkspace: destination, contextID: miri.windowManagement.activeLogicalSpaceContextID,
                focusGeneration: miri.focusStateGeneration, sessionGeneration: miri.sessionController.resumeGeneration
            )
            miri.performWorkspaceBoundaryTransition(hold)
            XCTAssertTrue(miri.activeWindow() === windows[1], "Fullscreen fallback must preserve the destination row")
            XCTAssertEqual(miri.windowManagement.activeFullscreenState, .off)
            XCTAssertTrue(miri.workspaceSummaries()[0].isWorkspaceFullscreen)
            XCTAssertEqual(source.columns[0].activeRow, 1)
            miri.perform(.workspaceUp)
            XCTAssertEqual(miri.windowManagement.activeFullscreenState, .active)
            XCTAssertEqual(source.columns[0].activeRow, 1)
        }
    }

    func testLayoutFullscreenModeChangesApplyWithoutRecreatingWindowManagement() throws {
        let (miri, workspace) = try fixture(
            alignment: .default, widths: [0.4, 0.67], activeColumn: 0,
            scrollOffset: nil, fullscreenMode: .perWindow
        )
        miri.sessionController.pauseForUnavailableSession()
        miri.perform(.toggleWorkspaceFullscreen)
        XCTAssertEqual(miri.windowManagement.activeFullscreenState, .active)
        var config = miri.configStore.documentConfig
        config.layoutFullscreenMode = .perWorkspace
        let directory = miri.configStore.destinationURL.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }
        guard case .saved = miri.configStore.save(config) else { return XCTFail("Config save failed") }
        XCTAssertEqual(miri.windowManagement.activeFullscreenState, .off)
        XCTAssertTrue(workspace.windows[0].fullscreenLayout)
        config.layoutFullscreenMode = .perWindow
        guard case .saved = miri.configStore.save(config) else { return XCTFail("Config save failed") }
        XCTAssertEqual(miri.windowManagement.activeFullscreenState, .active)
        miri.perform(.columnLast)
        XCTAssertTrue(workspace.activeWindow === workspace.windows[1])
        XCTAssertEqual(miri.windowManagement.activeFullscreenState, .off)
        miri.perform(.columnFirst)
        XCTAssertTrue(workspace.activeWindow === workspace.windows[0])
        XCTAssertEqual(miri.windowManagement.activeFullscreenState, .active)
    }

    func testPerWindowFullscreenPreservesPresentationForFloatingAndUnmanagedFocus() throws {
        let (miri, workspace) = try fixture(
            alignment: .default, widths: [0.4, 0.67, 0.5], activeColumn: 0,
            scrollOffset: nil, fullscreenMode: .perWindow
        )
        miri.sessionController.pauseForUnavailableSession()
        let fullscreen = workspace.windows[0]
        let normal = workspace.windows[1]
        let floating = workspace.windows[2]
        XCTAssertTrue(miri.windowManagement.toggleFloating(floating))
        miri.perform(.toggleWorkspaceFullscreen)
        let fullscreenState = miri.captureLayoutState()
        for applyLayout in [false, true] {
            XCTAssertTrue(miri.adoptFocusedElement(floating.element, pid: floating.pid, applyLayout: applyLayout))
            XCTAssertFalse(miri.adoptFocusedElement(AXUIElementCreateApplication(9999), pid: 9999, applyLayout: applyLayout))
            XCTAssertTrue(workspace.activeWindow === fullscreen)
            XCTAssertTrue(fullscreen.fullscreenLayout)
            XCTAssertEqual(miri.windowManagement.activeFullscreenState, .active)
            XCTAssertTrue(miri.workspaceSummaries()[0].isWorkspaceFullscreen)
            XCTAssertEqual(miri.captureLayoutState(), fullscreenState)
            XCTAssertEqual(projectedFrames(miri)[0], viewport)
        }

        XCTAssertTrue(miri.adoptFocusedElement(normal.element, pid: normal.pid, applyLayout: false))
        XCTAssertEqual(miri.windowManagement.activeFullscreenState, .off)
        XCTAssertFalse(miri.workspaceSummaries()[0].isWorkspaceFullscreen)
        XCTAssertEqual(projectedFrames(miri)[1].width, viewport.width * 0.67, accuracy: 0.01)
        XCTAssertTrue(miri.adoptFocusedElement(fullscreen.element, pid: fullscreen.pid, applyLayout: false))
        XCTAssertEqual(miri.windowManagement.activeFullscreenState, .active)
        XCTAssertEqual(projectedFrames(miri)[0], viewport)
    }

    func testExternalNativeFullscreenFocusSuspendsOnlyPerWorkspacePresentation() throws {
        for mode: LayoutFullscreenMode in [.perWindow, .perWorkspace] {
            let (miri, workspace) = try fixture(
                alignment: .default, widths: [0.4, 0.5], activeColumn: 0,
                scrollOffset: nil, fullscreenMode: mode
            )
            miri.sessionController.pauseForUnavailableSession()
            miri.perform(.toggleWorkspaceFullscreen)
            let expectedState: WorkspaceFullscreenState = mode == .perWindow ? .active : .suspended
            let external = workspace.windows[1]
            miri.fullscreenSpaceChangeGuardUntil = CFAbsoluteTimeGetCurrent() + 10
            XCTAssertFalse(miri.adoptFocusedElement(external.element, pid: external.pid, applyLayout: false))
            XCTAssertEqual(miri.windowManagement.activeFullscreenState, expectedState)
            miri.fullscreenSpaceChangeGuardUntil = 0

            _ = miri.windowManagement.resumeWorkspaceFullscreen(in: workspace)
            miri.rememberFullscreenOSWindowState(external)
            miri.removeWindow(external)
            XCTAssertEqual(miri.windowManagement.fullscreenOSWindowStates.count, 1)
            XCTAssertFalse(miri.adoptFocusedElement(external.element, pid: external.pid, applyLayout: false))
            XCTAssertEqual(miri.windowManagement.activeFullscreenState, expectedState)
        }
    }

    func testExplicitlyFloatingPerWindowFullscreenClearsOnlyThatWindowsDesignation() throws {
        let (miri, workspace) = try fixture(
            alignment: .default, widths: [0.4, 0.67], activeColumn: 0,
            scrollOffset: nil, fullscreenMode: .perWindow
        )
        miri.sessionController.pauseForUnavailableSession()
        let peer = workspace.windows[0]
        let target = workspace.windows[1]
        miri.perform(.toggleWorkspaceFullscreen)
        miri.perform(.columnRight)
        miri.perform(.toggleWorkspaceFullscreen)
        XCTAssertTrue(miri.toggleFloatingWindow(for: target.element))
        XCTAssertFalse(target.fullscreenLayout)
        XCTAssertTrue(peer.fullscreenLayout)
        XCTAssertEqual(miri.windowManagement.activeFullscreenState, .suspended)
        XCTAssertEqual(projectedFrames(miri)[0].width, viewport.width * 0.4, accuracy: 0.01)
        XCTAssertTrue(miri.adoptFocusedElement(peer.element, pid: peer.pid, applyLayout: false))
        XCTAssertEqual(projectedFrames(miri)[0], viewport)
    }

    func testPerWindowFullscreenSurvivesRediscoveryAndNativeFullscreenWithoutLeakingToNewWindows() throws {
        let (miri, workspace) = try fixture(
            alignment: .default, widths: [0.4, 0.67], activeColumn: 0,
            scrollOffset: nil, fullscreenMode: .perWindow
        )
        miri.sessionController.pauseForUnavailableSession()
        let original = workspace.windows[0]
        miri.perform(.toggleWorkspaceFullscreen)
        miri.removeWindow(original)
        let rediscovered = ManagedWindow(element: original.element, pid: original.pid, windowID: nil,
                                         bundleID: nil, appName: "Test", title: "Changed title")
        XCTAssertTrue(miri.upsertDiscoveredWindow(rediscovered))
        XCTAssertTrue(rediscovered.fullscreenLayout)
        XCTAssertTrue(miri.adoptFocusedElement(rediscovered.element, pid: rediscovered.pid, applyLayout: false))
        miri.rememberFullscreenOSWindowState(rediscovered)
        miri.removeWindow(rediscovered)
        let nativeReturn = ManagedWindow(element: original.element, pid: original.pid, windowID: nil,
                                        bundleID: nil, appName: "Test", title: "Changed again")
        XCTAssertTrue(miri.restoreExitedFullscreenOSWindows(discovered: [nativeReturn]))
        XCTAssertTrue(nativeReturn.fullscreenLayout)
        XCTAssertFalse(nativeReturn.fullscreenOS)
        XCTAssertTrue(miri.removeDestroyedWindowImmediately(nativeReturn.element))
        let replacement = ManagedWindow(element: original.element, pid: original.pid, windowID: nil,
                                       bundleID: nil, appName: "Test", title: "Replacement")
        XCTAssertTrue(miri.upsertDiscoveredWindow(replacement))
        XCTAssertFalse(replacement.fullscreenLayout)
    }

    private func fixture(
        alignment: FocusAlignment,
        widths: [CGFloat],
        activeColumn: Int,
        scrollOffset: CGFloat?,
        resizeMode: WidthResizeMode = .default,
        fullscreenMode: LayoutFullscreenMode = .perWorkspace,
        verticalNavigation: FullscreenVerticalNavigation = .switchWorkspaces,
        rules: [WindowRule] = []
    ) throws -> (Miri, Workspace) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("miri-focus-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configURL = directory.appendingPathComponent("config.json")
        var config = MiriConfig.fallback
        config.focusAlignment = alignment
        config.widthResizeMode = resizeMode
        config.layoutFullscreenMode = fullscreenMode
        config.fullscreenVerticalNavigation = verticalNavigation
        config.rules = rules
        config.persistLayout = false
        config.restoreOnExit = false
        try JSONEncoder().encode(config).write(to: configURL)
        let previousConfigPath = ProcessInfo.processInfo.environment["MIRI_CONFIG"]
        setenv("MIRI_CONFIG", configURL.path, 1)
        defer {
            if let previousConfigPath {
                setenv("MIRI_CONFIG", previousConfigPath, 1)
            } else {
                unsetenv("MIRI_CONFIG")
            }
        }

        // Construct only the model: no runtime, observers, or AX work is started.
        let miri = Miri()
        XCTAssertEqual(miri.focusAlignment, alignment)
        let workspace = try XCTUnwrap(miri.activeWorkspaceObject())
        workspace.columns = widths.enumerated().map { index, width in
            let window = ManagedWindow(
                element: AXUIElementCreateApplication(pid_t(1000 + index)),
                pid: pid_t(1000 + index),
                windowID: nil,
                bundleID: nil,
                appName: "Test",
                title: "Window \(index)"
            )
            window.manualWidthRatio = width
            return Column(windows: [window])
        }
        workspace.activeColumn = activeColumn
        workspace.scrollOffset = scrollOffset
        return (miri, workspace)
    }

    private func projectedFrames(
        _ miri: Miri,
        viewport requestedViewport: CGRect? = nil,
        innerGap: CGFloat = 0,
        physicalPixelScale: CGFloat = 1
    ) -> [CGRect] {
        let viewport = requestedViewport ?? self.viewport
        let snapshot = miri.windowManagement.snapshot()
        let workspaces = snapshot.workspaces.map { workspace in
            LayoutEngineWorkspace(
                columns: workspace.windows.map { window in
                    LayoutEngineWindow(
                        window: window,
                        widthRatio: miri.widthRatio(for: window),
                        renderedOutsets: (0, 0, 0, 0)
                    )
                },
                activeColumn: workspace.activeColumn,
                scrollOffset: workspace.scrollOffset
            )
        }
        return LayoutEngine.project(LayoutEngineInput(
            workspaces: workspaces,
            state: snapshot.layoutState,
            viewport: viewport,
            settings: LayoutEngineSettings(
                focusAlignment: miri.focusAlignment,
                innerGap: innerGap,
                parkedSliverWidth: 1,
                physicalPixelScale: physicalPixelScale
            ),
            parkHidden: false
        )).map(\.frame)
    }
}
