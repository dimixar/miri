import ApplicationServices
import CoreGraphics
import Darwin
import XCTest
@testable import miri

final class RestorationModelTests: XCTestCase {
    @MainActor
    func testSnapshotFactoryCapturesOwnerKindAndTiledPrecedence() {
        let element = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        let tiled = ManagedWindow(
            element: element,
            pid: 100,
            windowID: 42,
            bundleID: nil,
            appName: "Tiled",
            title: "Tiled"
        )
        let duplicateFloating = ManagedWindow(
            element: element,
            pid: 100,
            windowID: 42,
            bundleID: nil,
            appName: "Duplicate",
            title: "Duplicate"
        )
        let floating = ManagedWindow(
            element: element,
            pid: 200,
            windowID: 84,
            bundleID: nil,
            appName: "Floating",
            title: "Floating"
        )

        let records = RestoreSnapshotFactory.records(
            tiledWindows: [tiled],
            floatingWindows: [duplicateFloating, floating]
        )

        XCTAssertEqual(records.map(\.windowID), [42, 84])
        XCTAssertEqual(records.map(\.ownerPID), [100, 200])
        XCTAssertEqual(records.map(\.kind), [.tiled, .floating])
    }

    func testLegacySnapshotDecodesIntoTypedRecords() throws {
        let data = Data(#"{"windowIDs":[10,11],"floatingWindowIDs":[20],"viewport":{"x":1,"y":2,"width":1200,"height":800}}"#.utf8)

        let snapshot = try JSONDecoder().decode(RestoreSnapshot.self, from: data)

        XCTAssertNil(snapshot.version)
        XCTAssertEqual(snapshot.restorationRecords.map(\.windowID), [10, 11, 20])
        XCTAssertEqual(snapshot.restorationRecords.map(\.kind), [.tiled, .tiled, .floating])
        XCTAssertTrue(snapshot.restorationRecords.allSatisfy { $0.ownerPID == nil })
    }

    func testCurrentSnapshotPreservesOwnerAndWindowKind() throws {
        let snapshot = RestoreSnapshot(
            records: [
                RestoreWindowRecord(windowID: 42, ownerPID: pid_t(100), kind: .tiled),
                RestoreWindowRecord(windowID: 84, ownerPID: pid_t(200), kind: .floating),
            ],
            viewport: RectSnapshot(CGRect(x: 0, y: 25, width: 1440, height: 875))
        )

        let decoded = try JSONDecoder().decode(
            RestoreSnapshot.self,
            from: JSONEncoder().encode(snapshot)
        )

        XCTAssertEqual(decoded.version, RestoreSnapshot.currentVersion)
        XCTAssertEqual(decoded.restorationRecords.count, 2)
        XCTAssertEqual(decoded.restorationRecords[0].ownerPID, 100)
        XCTAssertEqual(decoded.restorationRecords[0].kind, .tiled)
        XCTAssertEqual(decoded.restorationRecords[1].ownerPID, 200)
        XCTAssertEqual(decoded.restorationRecords[1].kind, .floating)
        XCTAssertEqual(decoded.windowIDs, [42])
        XCTAssertEqual(decoded.floatingWindowIDs, [84])
    }

    func testCleanupGroupsOnlyTiledWindowsByRelevantPID() {
        let grouped = WindowRestoration.tiledWindowIDsByPID([
            RestoreWindowRecord(windowID: 1, ownerPID: 10, kind: .tiled),
            RestoreWindowRecord(windowID: 2, ownerPID: 10, kind: .tiled),
            RestoreWindowRecord(windowID: 3, ownerPID: 20, kind: .floating),
            RestoreWindowRecord(windowID: 4, ownerPID: nil, kind: .tiled),
        ])

        XCTAssertEqual(grouped, [10: Set([1, 2])])
        XCTAssertNil(grouped[20], "Floating windows must never receive cleanup AX frames")
    }

    func testTerminationSummaryRequiresEveryPIDAndNoTimeout() {
        let success = AXTerminationRestoreSummary(
            requestedPIDs: [1, 2],
            restoredPIDs: [1, 2],
            failedPIDs: [],
            timedOut: false
        )
        let partial = AXTerminationRestoreSummary(
            requestedPIDs: [1, 2],
            restoredPIDs: [1],
            failedPIDs: [2],
            timedOut: false
        )
        let timedOut = AXTerminationRestoreSummary(
            requestedPIDs: [1],
            restoredPIDs: [1],
            failedPIDs: [],
            timedOut: true
        )

        XCTAssertTrue(success.succeeded)
        XCTAssertFalse(partial.succeeded)
        XCTAssertFalse(timedOut.succeeded)
    }
}
