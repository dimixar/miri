import ApplicationServices
import CoreGraphics
import Darwin
import XCTest
@testable import miri

@MainActor
final class FocusScrollingTests: XCTestCase {
    private let viewport = CGRect(x: 0, y: 0, width: 1200, height: 800)
    private let minimalRevealModes: [FocusAlignment] = [.default, .centeredSmart]

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

    func testSmartCenteredChoosesSmallestNeighborEvenWhenLargerPairWasVisible() throws {
        for (widths, offset, neighbor, expectedOffset) in [
            ([CGFloat(0.35), 0.6, 0.25], CGFloat(0), 2, CGFloat(240)),
            ([CGFloat(0.25), 0.6, 0.35], CGFloat(240), 0, CGFloat(0)),
        ] {
            let (miri, workspace) = try fixture(
                alignment: .centeredSmart,
                widths: widths,
                activeColumn: 1,
                scrollOffset: offset
            )

            miri.revealActiveColumnIfNeeded(in: workspace, viewport: viewport)

            let frames = projectedFrames(miri)
            XCTAssertEqual(try XCTUnwrap(workspace.scrollOffset), expectedOffset, accuracy: 0.001)
            XCTAssertTrue(viewport.contains(frames[1]))
            XCTAssertTrue(viewport.contains(frames[neighbor]))
            XCTAssertFalse(viewport.contains(frames[2 - neighbor]))
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
        resizeMode: WidthResizeMode = .default
    ) throws -> (Miri, Workspace) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("miri-focus-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configURL = directory.appendingPathComponent("config.json")
        var config = MiriConfig.fallback
        config.focusAlignment = alignment
        config.widthResizeMode = resizeMode
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
