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
            for (activeColumn, offset, direction) in [(2, CGFloat(700), -1), (1, CGFloat(500), 1)] {
                let (miri, workspace) = try fixture(
                    alignment: alignment,
                    widths: Array(repeating: 0.5, count: 4),
                    activeColumn: activeColumn,
                    scrollOffset: offset
                )
                let before = projectedFrames(miri)
                let target = activeColumn + direction
                XCTAssertFalse(viewport.contains(before[target]))

                miri.focusColumn(by: direction, in: workspace, viewport: viewport)

                let after = projectedFrames(miri)
                XCTAssertEqual(workspace.activeColumn, target)
                XCTAssertEqual(workspace.scrollOffset, 600)
                XCTAssertTrue(viewport.contains(after[target]))
                XCTAssertEqual(abs(after[target].minX - before[target].minX), 100)
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

    func testSmartCenteredStillCentersAnAlreadyVisibleWideTarget() throws {
        let (miri, workspace) = try fixture(
            alignment: .centeredSmart,
            widths: [0.25, 0.75, 0.25],
            activeColumn: 0,
            scrollOffset: 0
        )
        XCTAssertTrue(viewport.contains(projectedFrames(miri)[1]))

        miri.focusColumn(by: 1, in: workspace, viewport: viewport)

        XCTAssertEqual(workspace.activeColumn, 1)
        XCTAssertEqual(workspace.scrollOffset, 150)
        XCTAssertEqual(projectedFrames(miri)[1].midX, viewport.midX)
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
        scrollOffset: CGFloat?
    ) throws -> (Miri, Workspace) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("miri-focus-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configURL = directory.appendingPathComponent("config.json")
        var config = MiriConfig.fallback
        config.focusAlignment = alignment
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

    private func projectedFrames(_ miri: Miri) -> [CGRect] {
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
                innerGap: 0,
                parkedSliverWidth: 1,
                physicalPixelScale: 1
            ),
            parkHidden: false
        )).map(\.frame)
    }
}
