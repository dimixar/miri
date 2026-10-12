import ApplicationServices
import CoreGraphics
import Darwin
import Foundation
import XCTest
@testable import miri

@MainActor
final class StackedColumnTests: XCTestCase {
    private func window(_ id: Int32, width: CGFloat = 0.5) -> ManagedWindow {
        let window = ManagedWindow(element: AXUIElementCreateApplication(id), pid: id, windowID: nil,
                                   bundleID: nil, appName: "Test", title: "Window \(id)")
        window.manualWidthRatio = width
        return window
    }

    private func management() -> WindowManagement {
        WindowManagement(axOperations: AXOperationController(log: { _ in }), emit: { _ in })
    }

    private func coordinator() throws -> Miri {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("miri-stacks-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.json")
        var config = MiriConfig.fallback
        config.rowsPerColumn = 3
        config.persistLayout = false
        config.restoreOnExit = false
        try JSONEncoder().encode(config).write(to: url)
        let previous = ProcessInfo.processInfo.environment["MIRI_CONFIG"]
        setenv("MIRI_CONFIG", url.path, 1)
        defer {
            if let previous { setenv("MIRI_CONFIG", previous, 1) } else { unsetenv("MIRI_CONFIG") }
        }
        let miri = Miri()
        miri.sessionController.pauseForUnavailableSession()
        return miri
    }

    private func project(_ column: Column, fullscreen: Bool = false, scale: CGFloat = 2) -> [LayoutItem] {
        let rows = column.windows.map {
            LayoutEngineWindow(window: $0, widthRatio: column.widthRatio ?? 0.5, renderedOutsets: (0, 0, 0, 0))
        }
        var engineColumn = rows[0]
        engineColumn.rows = rows
        engineColumn.heightRatios = column.heightRatios
        engineColumn.activeRow = column.activeRow
        return LayoutEngine.project(LayoutEngineInput(
            workspaces: [LayoutEngineWorkspace(columns: [engineColumn], activeColumn: 0, scrollOffset: 0)],
            state: LayoutState(activeWorkspace: 0, activeColumns: [0], scrollOffsets: [0], fullscreenWorkspaces: [fullscreen]),
            viewport: CGRect(x: 0, y: 0, width: 1000, height: 800),
            settings: LayoutEngineSettings(focusAlignment: .default, innerGap: 12, parkedSliverWidth: 1, physicalPixelScale: scale),
            parkHidden: true
        ))
    }

    func testAsymmetricTwoAndThreeRowGeometryUsesRemainingHeightAndPhysicalPixels() {
        for shares: [CGFloat] in [[0.25, 0.75], [0.2, 0.3, 0.5]] {
            let column = Column(windows: shares.indices.map { window(Int32(100 + $0)) }, heightRatios: shares)
            for scale: CGFloat in [1, 2] {
                let items = project(column, scale: scale)
                let gap = 12 / scale
                let usable = 800 - gap * CGFloat(shares.count - 1)
                XCTAssertEqual(items.count, shares.count)
                XCTAssertEqual(items.first?.frame.minY, 0)
                XCTAssertEqual(items.last?.frame.maxY, 800)
                for (index, item) in items.enumerated() {
                    XCTAssertTrue(item.visible)
                    XCTAssertEqual(item.frame.height, usable * shares[index], accuracy: 1 / scale)
                    XCTAssertEqual(item.frame.minY * scale, (item.frame.minY * scale).rounded())
                    if index > 0 { XCTAssertEqual(item.frame.minY - items[index - 1].frame.maxY, gap, accuracy: 1 / scale) }
                }
            }
        }
    }

    func testHeightRedistributesSiblingsProportionallyAndHonorsMinimum() {
        let column = Column(windows: [window(1), window(2), window(3)], heightRatios: [0.2, 0.3, 0.5])
        XCTAssertTrue(column.setHeightRatio(0.4, row: 0))
        XCTAssertEqual(column.heightRatios[1], 0.225, accuracy: 0.0001)
        XCTAssertEqual(column.heightRatios[2], 0.375, accuracy: 0.0001)
        XCTAssertTrue(column.setHeightRatio(1, row: 0, minimum: 0.1))
        for (actual, expected) in zip(column.heightRatios, [CGFloat(0.8), 0.1, 0.1]) {
            XCTAssertEqual(actual, expected, accuracy: 0.0001)
        }
        XCTAssertFalse(Column(windows: [window(4)]).setHeightRatio(0.5, row: 0))
    }

    func testAppHeightConstraintsRedistributeOrDetachWithoutLosingFocus() throws {
        let management = management()
        let workspace = try XCTUnwrap(management.activeWorkspaceObject())
        let first = window(1), second = window(2), third = window(3)
        first.minimumHeight = 350
        second.minimumHeight = 150
        third.minimumHeight = 200
        let column = Column(windows: [first, second, third], activeRow: 2, heightRatios: [0.2, 0.3, 0.5])
        workspace.columns = [column]
        XCTAssertTrue(management.enforceRowHeights(height: 800, gap: 6))
        for (actual, expected) in zip(project(column).map { $0.frame.height }, [CGFloat(350), 164.25, 273.75]) {
            XCTAssertEqual(actual, expected, accuracy: 0.5)
        }
        XCTAssertFalse(management.enforceRowHeights(height: 800, gap: 6))
        XCTAssertFalse(column.setHeightRatio(0.1, row: 0, minimums: [350 / 788, 150 / 788, 200 / 788]))
        third.minimumHeight = 450
        XCTAssertTrue(management.enforceRowHeights(height: 800, gap: 6))
        XCTAssertEqual(workspace.columns.map { $0.windows.count }, [2, 1])
        XCTAssertTrue(workspace.activeWindow === third)
        XCTAssertEqual(Set(workspace.windows.map(ObjectIdentifier.init)).count, 3)
    }

    func testNewWindowsAlwaysCreateColumnsAndJoiningDetachingRetainsPreference() throws {
        let management = management()
        let workspace = try XCTUnwrap(management.activeWorkspaceObject())
        management.enforceRowCapacity(3)
        let first = window(1, width: 0.3)
        let second = window(2, width: 0.7)
        _ = management.insert(first, in: workspace, at: 0, focus: true)
        _ = management.insert(second, in: workspace, at: 1, focus: true)
        XCTAssertEqual(workspace.columns.count, 2)
        XCTAssertTrue(management.moveActiveWindowHorizontally(by: -1, capacity: 3))
        XCTAssertEqual(workspace.columns.count, 1)
        XCTAssertEqual(workspace.columns[0].widthRatio, 0.3)
        XCTAssertEqual(second.manualWidthRatio, 0.7)
        management.setWidthRatio(0.6, for: second)
        XCTAssertEqual(workspace.columns[0].widthRatio, 0.6)
        XCTAssertEqual(second.manualWidthRatio, 0.7)
        XCTAssertTrue(management.moveActiveWindowHorizontally(by: 1, capacity: 3))
        XCTAssertEqual(workspace.columns[1].widthRatio, 0.7)
        XCTAssertTrue(workspace.activeWindow === second)
        XCTAssertFalse(management.moveActiveWindowHorizontally(by: 1, capacity: 3))
    }

    func testFullNeighborCreatesColumnPastItAndDefaultCapacityDoesNotStack() throws {
        for capacity in [1, 2, 3] {
            let management = management()
            let workspace = try XCTUnwrap(management.activeWorkspaceObject())
            let moving = window(10)
            let peers = (0..<capacity).map { window(Int32(20 + $0)) }
            workspace.columns = [Column(windows: [moving]), Column(windows: peers)]
            XCTAssertTrue(management.moveActiveWindowHorizontally(by: 1, capacity: capacity))
            XCTAssertEqual(workspace.columns.count, 2)
            XCTAssertEqual(workspace.columns[0].windows.count, capacity)
            XCTAssertTrue(workspace.columns[1].activeWindow === moving)
        }
    }

    func testRowFocusAndSwapNeverCrossWorkspaceAndShareFollowsWindow() throws {
        let management = management()
        let workspace = try XCTUnwrap(management.activeWorkspaceObject())
        let first = window(1), second = window(2)
        workspace.columns = [Column(windows: [first, second], heightRatios: [0.25, 0.75])]
        XCTAssertFalse(management.focusRow(by: -1))
        XCTAssertTrue(management.focusRow(by: 1))
        XCTAssertFalse(management.focusRow(by: 1))
        XCTAssertTrue(management.moveActiveRow(by: -1))
        XCTAssertTrue(workspace.activeWindow === second)
        XCTAssertEqual(workspace.columns[0].heightRatios, [0.75, 0.25])
        XCTAssertEqual(management.activeWorkspace, 0)
    }

    func testWorkspaceTransferMovesOnlyFocusedRowAndWholeColumnMoveRemainsDistinct() throws {
        let management = management()
        let source = try XCTUnwrap(management.activeWorkspaceObject())
        let first = window(1), second = window(2)
        source.columns = [Column(windows: [first, second], activeRow: 1)]
        XCTAssertTrue(management.moveActiveWindow(toWorkspace: 1))
        XCTAssertTrue(source.activeWindow === first)
        XCTAssertTrue(management.activeWindow() === second)
        XCTAssertTrue(management.moveActiveColumn(toWorkspace: 0))
        XCTAssertEqual(source.columns.count, 2)
        XCTAssertEqual(Set(source.windows.map(ObjectIdentifier.init)).count, 2)
    }

    func testCapacityReductionSplitsAllContextsPreservingFocusAndWindows() throws {
        let management = management()
        let workspace = try XCTUnwrap(management.activeWorkspaceObject())
        let windows = [window(1), window(2), window(3)]
        workspace.columns = [Column(windows: windows, activeRow: 2, heightRatios: [0.2, 0.3, 0.5])]
        let inactive = LogicalSpaceContext(id: 1)
        inactive.workspaces[0].columns = [Column(windows: [window(4), window(5), window(6)], activeRow: 1)]
        management.appendContext(inactive)
        management.enforceRowCapacity(2)
        XCTAssertEqual(workspace.columns.map { $0.windows.count }, [2, 1])
        XCTAssertTrue(workspace.activeWindow === windows[2])
        XCTAssertEqual(inactive.workspaces[0].columns.map { $0.windows.count }, [2, 1])
        XCTAssertEqual(workspace.columns[0].heightRatios[0], 0.4, accuracy: 0.0001)
        management.enforceRowCapacity(1)
        XCTAssertEqual(workspace.columns.count, 3)
        XCTAssertTrue(workspace.activeWindow === windows[2])
    }

    func testFullscreenOnlyProjectsFocusedRowAndLeavesStackUnchanged() {
        let column = Column(windows: [window(1), window(2), window(3)], activeRow: 1, heightRatios: [0.2, 0.3, 0.5])
        let normal = project(column).map(\.frame)
        let fullscreen = project(column, fullscreen: true)
        XCTAssertEqual(fullscreen.filter(\.visible).map { $0.window.title }, ["Window 2"])
        XCTAssertEqual(fullscreen[1].frame, CGRect(x: 0, y: 0, width: 1000, height: 800))
        XCTAssertEqual(project(column).map(\.frame), normal)
    }

    func testFloatingAndRemovedRowsRestoreOriginalGroupRowAndShares() throws {
        let management = management()
        management.enforceRowCapacity(3)
        let workspace = try XCTUnwrap(management.activeWorkspaceObject())
        let first = window(1), second = window(2), third = window(3)
        let column = Column(windows: [first, second, third], activeRow: 1, heightRatios: [0.2, 0.3, 0.5])
        workspace.columns = [column]
        XCTAssertTrue(management.toggleFloating(second))
        XCTAssertEqual(workspace.windows.count, 2)
        XCTAssertTrue(management.toggleFloating(second))
        XCTAssertTrue(workspace.columns[0] === column)
        XCTAssertTrue(workspace.activeWindow === second)
        XCTAssertEqual(column.heightRatios[1], 0.3, accuracy: 0.0001)
        management.remove(second)
        XCTAssertTrue(management.restoreRemovedRow(second, focus: false))
        XCTAssertEqual(column.windows.map(\.title), ["Window 1", "Window 2", "Window 3"])
    }

    func testPersistenceRoundTripPartialRestoreAndLegacySingleColumns() throws {
        let miri = try coordinator()
        let workspace = try XCTUnwrap(miri.activeWorkspaceObject())
        let windows = [window(1), window(2), window(3)]
        workspace.columns = [Column(windows: windows, activeRow: 2, widthRatio: 0.6, heightRatios: [0.2, 0.3, 0.5])]
        let snapshot = try XCTUnwrap(miri.windowManagement.persistentLogicalSpaceSnapshot(identity: miri.persistentIdentity(for:)))
        let decoded = try JSONDecoder().decode(PersistentLogicalSpaceSnapshot.self, from: JSONEncoder().encode(snapshot))
        let restored = miri.logicalSpaceContext(from: decoded.contexts[0], discovered: windows)
        XCTAssertEqual(restored.workspaces[0].columns.count, 1)
        XCTAssertEqual(restored.workspaces[0].columns[0].heightRatios, [0.2, 0.3, 0.5])
        XCTAssertEqual(restored.workspaces[0].columns[0].activeRow, 2)
        let partial = miri.logicalSpaceContext(from: decoded.contexts[0], discovered: [windows[0], windows[2]])
        XCTAssertEqual(partial.workspaces[0].columns.count, 1)
        XCTAssertTrue(partial.workspaces[0].activeWindow === windows[2])
        miri.windowManagement.activateContext(partial)
        miri.insertRestoredWindowNearFocused(windows[1], applyLayout: false, focusNewWindow: false)
        XCTAssertEqual(partial.workspaces[0].columns.count, 1)
        XCTAssertEqual(partial.workspaces[0].windows.map(\.title), windows.map(\.title))
        for (actual, expected) in zip(partial.workspaces[0].columns[0].heightRatios, [CGFloat(0.2), 0.3, 0.5]) {
            XCTAssertEqual(actual, expected, accuracy: 0.0001)
        }
        let sequential = miri.logicalSpaceContext(from: decoded.contexts[0], discovered: [windows[0]])
        miri.windowManagement.activateContext(sequential)
        miri.insertRestoredWindowNearFocused(windows[1], applyLayout: false)
        miri.insertRestoredWindowNearFocused(windows[2], applyLayout: false)
        XCTAssertEqual(sequential.workspaces[0].columns.count, 1)
        for (actual, expected) in zip(sequential.workspaces[0].columns[0].heightRatios, [CGFloat(0.2), 0.3, 0.5]) {
            XCTAssertEqual(actual, expected, accuracy: 0.0001, "Discovery order must not change saved proportions")
        }
        let unrelated = window(4)
        let late = miri.logicalSpaceContext(from: decoded.contexts[0], discovered: [unrelated])
        miri.windowManagement.activateContext(late)
        for window in windows.reversed() {
            miri.insertRestoredWindowNearFocused(window, applyLayout: false)
        }
        XCTAssertEqual(late.workspaces[0].columns.map { $0.windows.count }, [3, 1])
        XCTAssertEqual(late.workspaces[0].columns[0].windows.map(\.title), windows.map(\.title))
        XCTAssertTrue(late.workspaces[0].activeWindow === unrelated)
        for (actual, expected) in zip(late.workspaces[0].columns[0].heightRatios, [CGFloat(0.2), 0.3, 0.5]) {
            XCTAssertEqual(actual, expected, accuracy: 0.0001)
        }
        let legacy = try JSONDecoder().decode(PersistentWindowState.self, from: Data("{\"identity\":{\"appName\":\"Test\",\"title\":\"Old\"},\"workspace\":0,\"column\":0,\"manualWidthRatio\":0.5}".utf8))
        XCTAssertNil(legacy.groupID)
        let legacyWorkspace = Workspace()
        miri.restoreGroupedWindow(windows[0], state: legacy, in: legacyWorkspace)
        miri.restoreGroupedWindow(windows[1], state: legacy, in: legacyWorkspace)
        legacyWorkspace.clampFocus()
        XCTAssertEqual(legacyWorkspace.columns.map { $0.windows.count }, [1, 1])
    }

    func testSnapshotRowSizingAndMembershipAreImmutable() throws {
        let management = management()
        let workspace = try XCTUnwrap(management.activeWorkspaceObject())
        let column = Column(windows: [window(1), window(2)], heightRatios: [0.25, 0.75])
        workspace.columns = [column]
        let snapshot = management.snapshot()
        column.remove(column.windows[0])
        XCTAssertEqual(snapshot.workspaces[0].columns[0].windows.count, 2)
        XCTAssertEqual(snapshot.workspaces[0].columns[0].heightRatios, [0.25, 0.75])
    }

    func testNativeFullscreenReturnRestoresRowWithoutReplacingPeers() throws {
        let miri = try coordinator()
        let workspace = try XCTUnwrap(miri.activeWorkspaceObject())
        let first = window(1), second = window(2, width: 0.7)
        let column = Column(windows: [first, second], activeRow: 1, widthRatio: 0.4, heightRatios: [0.25, 0.75])
        workspace.columns = [column]
        miri.windowManagement.enforceRowCapacity(3)
        miri.rememberFullscreenWindowState(second)
        miri.windowManagement.remove(second)
        XCTAssertTrue(workspace.activeWindow === first)
        XCTAssertTrue(miri.restoreExitedFullscreenWindows(discovered: [second]))
        XCTAssertTrue(workspace.columns[0] === column)
        XCTAssertTrue(workspace.activeWindow === second)
        XCTAssertEqual(column.widthRatio, 0.4)
        XCTAssertEqual(second.manualWidthRatio, 0.7)
        XCTAssertEqual(column.heightRatios, [0.25, 0.75])
    }
}
