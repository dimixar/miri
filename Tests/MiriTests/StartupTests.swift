import ServiceManagement
import XCTest
@testable import miri

@MainActor
final class StartupTests: XCTestCase {
    func testLoginItemRequiresPackagedAppAndCompletedOnboarding() throws {
        var nativeStatus = SMAppService.Status.notRegistered
        for packaged in [false, true] {
            let controller = LoginItemController(
                isPackagedApp: packaged,
                readStatus: { nativeStatus },
                register: { nativeStatus = .enabled },
                unregister: { nativeStatus = .notRegistered }
            )
            XCTAssertEqual(controller.status(onboardingCompleted: false), packaged ? .onboardingRequired : .unavailable)
            XCTAssertThrowsError(try controller.setEnabled(true, onboardingCompleted: false))
            XCTAssertEqual(nativeStatus, .notRegistered)
            if !packaged {
                XCTAssertThrowsError(try controller.setEnabled(true, onboardingCompleted: true))
                XCTAssertEqual(nativeStatus, .notRegistered)
            } else {
                XCTAssertEqual(try controller.setEnabled(true, onboardingCompleted: true), .enabled)
                XCTAssertEqual(try controller.setEnabled(false, onboardingCompleted: true), .notRegistered)
            }
        }
    }

    func testLoginItemTracksExternalChangesAndPendingApprovalCanBeCancelled() throws {
        var nativeStatus = SMAppService.Status.enabled
        let controller = LoginItemController(
            isPackagedApp: true,
            readStatus: { nativeStatus },
            register: { nativeStatus = .enabled },
            unregister: { nativeStatus = .notRegistered }
        )
        XCTAssertEqual(controller.status(onboardingCompleted: true), .enabled)
        nativeStatus = .requiresApproval
        XCTAssertEqual(controller.status(onboardingCompleted: true), .requiresApproval)
        XCTAssertTrue(controller.status(onboardingCompleted: true).isRequested)
        XCTAssertEqual(try controller.setEnabled(true, onboardingCompleted: true), .requiresApproval)
        XCTAssertEqual(try controller.setEnabled(false, onboardingCompleted: true), .notRegistered)
        nativeStatus = .enabled
        XCTAssertEqual(controller.status(onboardingCompleted: true), .enabled)
    }

    func testRegistrationReportsRequiredApprovalEvenWhenNativeAPIThrows() throws {
        var nativeStatus = SMAppService.Status.notRegistered
        let controller = LoginItemController(
            isPackagedApp: true,
            readStatus: { nativeStatus },
            register: {
                nativeStatus = .requiresApproval
                throw NSError(domain: SMAppServiceErrorDomain, code: kSMErrorLaunchDeniedByUser)
            },
            unregister: { nativeStatus = .notRegistered }
        )
        XCTAssertEqual(try controller.setEnabled(true, onboardingCompleted: true), .requiresApproval)
        XCTAssertEqual(try controller.setEnabled(false, onboardingCompleted: true), .notRegistered)
    }

    func testFailedLoginItemChangeDoesNotClaimSuccess() {
        var nativeStatus = SMAppService.Status.notRegistered
        let controller = LoginItemController(
            isPackagedApp: true,
            readStatus: { nativeStatus },
            register: { throw NSError(domain: SMAppServiceErrorDomain, code: kSMErrorInvalidSignature) },
            unregister: { throw NSError(domain: SMAppServiceErrorDomain, code: kSMErrorInternalFailure) }
        )
        XCTAssertThrowsError(try controller.setEnabled(true, onboardingCompleted: true))
        XCTAssertEqual(controller.status(onboardingCompleted: true), .notRegistered)
        nativeStatus = .enabled
        XCTAssertThrowsError(try controller.setEnabled(false, onboardingCompleted: true))
        XCTAssertEqual(controller.status(onboardingCompleted: true), .enabled)
        nativeStatus = .notFound
        XCTAssertThrowsError(try controller.setEnabled(true, onboardingCompleted: true))
        XCTAssertEqual(controller.status(onboardingCompleted: true), .notFound)
    }

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
