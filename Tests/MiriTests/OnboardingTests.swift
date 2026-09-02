import XCTest
@testable import miri

final class OnboardingTests: XCTestCase {
    func testFreshProgressUsesCurrentLayoutDefaultsAndStartsAtAccessibility() {
        var config = MiriConfig.fallback
        config.focusAlignment = .centeredSmart
        config.outerGap = 14

        let progress = OnboardingProgress.fresh(config: config)

        XCTAssertEqual(progress.step, .accessibility)
        XCTAssertEqual(progress.focusAlignment, .centeredSmart)
        XCTAssertEqual(progress.outerGap, 14)
        XCTAssertNil(progress.animationsEnabled)
    }

    func testAnimationStepSurvivesPersistenceForPermissionRestart() throws {
        let progress = OnboardingProgress(
            step: .animation,
            focusAlignment: .centered,
            outerGap: 12,
            animationsEnabled: true
        )

        let data = try JSONEncoder().encode(progress)
        let restored = try JSONDecoder().decode(OnboardingProgress.self, from: data)

        XCTAssertEqual(restored, progress)
        XCTAssertEqual(restored.step, .animation)
        XCTAssertTrue(restored.animationsEnabled == true)
    }
}
