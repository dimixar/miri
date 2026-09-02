import XCTest
@testable import miri

final class PermissionPolicyTests: XCTestCase {
    func testMissingPermissionRemainsMissing() {
        XCTAssertEqual(
            MiriPermissionPolicy.state(grantedAtLaunch: false, grantedNow: false),
            .missing
        )
    }

    func testPermissionGrantedAfterLaunchRequiresRestart() {
        XCTAssertEqual(
            MiriPermissionPolicy.state(grantedAtLaunch: false, grantedNow: true),
            .restartRequired
        )
    }

    func testGrantReturnedByRequestRequiresRestartEvenBeforePreflightUpdates() {
        XCTAssertEqual(
            MiriPermissionPolicy.state(
                grantedAtLaunch: false,
                grantedNow: false,
                grantObservedDuringRun: true
            ),
            .restartRequired
        )
    }

    func testPermissionAvailableAtLaunchIsReady() {
        XCTAssertEqual(
            MiriPermissionPolicy.state(grantedAtLaunch: true, grantedNow: true),
            .granted
        )
    }

    func testRevokedPermissionIsReportedMissing() {
        XCTAssertEqual(
            MiriPermissionPolicy.state(grantedAtLaunch: true, grantedNow: false),
            .missing
        )
    }
}
