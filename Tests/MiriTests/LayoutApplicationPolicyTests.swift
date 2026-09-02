import XCTest
@testable import miri

final class LayoutApplicationPolicyTests: XCTestCase {
    func testVisibleWindowIsCorrectivelyRewrittenEvenWhenTargetIsUnchanged() {
        XCTAssertTrue(shouldApplyProjectedFrame(
            forceFrame: false,
            isVisible: true,
            wasVisible: true,
            frameChanged: false
        ))
    }

    func testFocusedWindowForceAlwaysWinsCachedRequest() {
        XCTAssertTrue(shouldApplyProjectedFrame(
            forceFrame: true,
            isVisible: true,
            wasVisible: true,
            frameChanged: false
        ))
    }

    func testStableParkedWindowCanSkipRedundantWrite() {
        XCTAssertFalse(shouldApplyProjectedFrame(
            forceFrame: false,
            isVisible: false,
            wasVisible: false,
            frameChanged: false
        ))
    }
}
