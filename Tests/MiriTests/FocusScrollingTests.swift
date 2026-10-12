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

            let target = workspace.columns[2]
            XCTAssertTrue(miri.adoptFocusedElement(target.element, pid: target.pid, applyLayout: false))
            XCTAssertEqual(projectedFrames(miri, viewport: viewport)[2], viewport)
            XCTAssertEqual(workspace.columns.map(\.manualWidthRatio), [0.28, 0.67, 0.4])
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
            XCTAssertEqual(workspace.columns.map(\.manualWidthRatio), [0.28, 0.67, 0.4])
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
        let target = workspace.columns[0]
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

    func testWorkspaceFullscreenTransfersAcrossWorkspacesAndClearsWhenLastWindowCloses() throws {
        let (miri, source) = try fixture(
            alignment: .default, widths: [0.28, 0.67, 0.4], activeColumn: 1, scrollOffset: 45
        )
        miri.sessionController.pauseForUnavailableSession()
        miri.windowManagement.ensureWorkspaceExists(1)
        let destination = miri.windowManagement.workspaces[1]
        let target = source.columns[2]
        _ = miri.windowManagement.insert(target, in: destination, at: 0, focus: false)
        miri.perform(.toggleWorkspaceFullscreen)

        XCTAssertTrue(miri.adoptFocusedElement(target.element, pid: target.pid, applyLayout: false))
        XCTAssertEqual(miri.windowManagement.activeWorkspace, 1)
        XCTAssertEqual(source.fullscreenState, .off)
        XCTAssertEqual(destination.fullscreenState, .active)
        XCTAssertEqual(projectedFrames(miri)[2], viewport)
        var summaries = miri.currentWorkspaceBarStatus().workspaceSummaries
        XCTAssertFalse(summaries[0].isWorkspaceFullscreen)
        XCTAssertTrue(summaries[1].isWorkspaceFullscreen)
        XCTAssertEqual(summaries[1].lastFocusedWindow?.title, target.title)

        // Explicit workspace navigation leaves each workspace's mode in place.
        XCTAssertTrue(miri.focusWorkspace(1))
        XCTAssertEqual(source.fullscreenState, .off)
        XCTAssertEqual(destination.fullscreenState, .active)
        summaries = miri.currentWorkspaceBarStatus().workspaceSummaries
        XCTAssertFalse(summaries[1].isActive)
        XCTAssertTrue(summaries[1].isWorkspaceFullscreen)
        XCTAssertEqual(summaries[1].lastFocusedWindow?.title, target.title)
        XCTAssertTrue(miri.focusWorkspace(2))
        miri.windowManagement.remove(target)
        XCTAssertEqual(destination.fullscreenState, .off)
        XCTAssertFalse(miri.currentWorkspaceBarStatus().workspaceSummaries[1].isWorkspaceFullscreen)
        XCTAssertFalse(miri.windowManagement.toggleWorkspaceFullscreen())
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
        for pid in [workspace.columns[1].pid, 9000] {
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
            XCTAssertEqual(workspace.columns.map(\.manualWidthRatio), [0.28, 0.67, 0.4])
        }

        let target = workspace.columns[1]
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
            let previous = workspace.columns[1]
            let target = workspace.columns[2]
            func focusedSnapshot(title: String) -> AXWindowReadSnapshot {
                AXWindowReadSnapshot(
                    handle: AXElementHandle(element: target.element, pid: target.pid, windowID: nil),
                    role: kAXWindowRole, subrole: kAXStandardWindowSubrole, title: title,
                    minimized: false, fullscreen: false, frame: viewport,
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
            XCTAssertEqual(workspace.columns.map(\.manualWidthRatio), [0.28, 0.67])
            XCTAssertFalse(workspace.columns.contains { $0 === target })
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
                let tiled = workspace.columns[0]
                XCTAssertTrue(miri.adoptFocusedElement(tiled.element, pid: tiled.pid, applyLayout: false))
                XCTAssertEqual(projectedFrames(miri)[0], viewport)
                miri.perform(.toggleWorkspaceFullscreen)
                XCTAssertEqual(projectedFrames(miri)[0].width, 336)
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
        let neighbor = workspace.columns[1]
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
        let target = workspace.columns[1]

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
            let target = workspace.columns[1]
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
        let target = workspace.columns[1]
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

    private func fixture(
        alignment: FocusAlignment,
        widths: [CGFloat],
        activeColumn: Int,
        scrollOffset: CGFloat?,
        resizeMode: WidthResizeMode = .default,
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
            return window
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
                columns: workspace.columns.map { window in
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
