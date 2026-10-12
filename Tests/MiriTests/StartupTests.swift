import XCTest
@testable import miri

@MainActor
final class StartupTests: XCTestCase {
    func testInstanceLockRejectsDuplicatesAndAllowsRestartAfterRelease() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("instance.lock")
        var first = try ApplicationInstanceLock(url: url)
        XCTAssertNotNil(first)
        XCTAssertNil(try ApplicationInstanceLock(url: url))
        first = nil
        let restarted = try ApplicationInstanceLock(url: url)
        XCTAssertNotNil(restarted)
        try withExtendedLifetime(restarted) {
            XCTAssertNil(try ApplicationInstanceLock(url: url))
        }
    }

    func testInstanceLockReportsFileErrorsRatherThanPretendingAnotherInstanceExists() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertThrowsError(try ApplicationInstanceLock(url: directory))
    }
}
