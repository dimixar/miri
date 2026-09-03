import XCTest
@testable import miri

@MainActor
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

    func testViewModelGatesProgressUsingPermissionsAndAnimationChoice() {
        var persisted: [OnboardingProgress] = []
        let model = OnboardingViewModel(
            progress: .fresh(config: MiriConfig.fallback),
            permissions: MiriPermissionStatus(accessibility: .missing, screenRecording: .missing),
            progressSink: { persisted.append($0) },
            actionSink: { _ in }
        )

        XCTAssertFalse(model.canGoNext)
        model.updatePermissions(MiriPermissionStatus(accessibility: .granted, screenRecording: .missing))
        XCTAssertTrue(model.canGoNext)
        model.goNext()
        XCTAssertEqual(model.progress.step, .layout)
        model.goNext()
        XCTAssertEqual(model.progress.step, .animation)
        XCTAssertFalse(model.canGoNext)

        model.progress.animationsEnabled = true
        XCTAssertFalse(model.canGoNext)
        model.updatePermissions(MiriPermissionStatus(accessibility: .granted, screenRecording: .granted))
        XCTAssertTrue(model.canGoNext)
        XCTAssertFalse(persisted.isEmpty)
    }

    func testResetForRestartPersistsFreshProgressFromCurrentConfig() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent("onboarding.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        var config = MiriConfig.fallback
        config.focusAlignment = .centeredSmart
        config.outerGap = 19
        let store = OnboardingStore(
            config: config,
            hasExistingConfiguration: true,
            storageURL: url
        )
        XCTAssertEqual(store.progress.step, .completed)

        store.resetForRestart(config: config)

        XCTAssertEqual(store.progress.step, .accessibility)
        XCTAssertEqual(store.progress.focusAlignment, .centeredSmart)
        XCTAssertEqual(store.progress.outerGap, 19)
        XCTAssertNil(store.progress.animationsEnabled)
        let persisted = try JSONDecoder().decode(
            OnboardingProgress.self,
            from: Data(contentsOf: url)
        )
        XCTAssertEqual(persisted, store.progress)
    }

    func testInstantAnimationChoiceDoesNotRequireScreenRecording() {
        let progress = OnboardingProgress(
            step: .animation,
            focusAlignment: .default,
            outerGap: 0,
            animationsEnabled: false
        )
        let model = OnboardingViewModel(
            progress: progress,
            permissions: MiriPermissionStatus(accessibility: .granted, screenRecording: .missing),
            progressSink: { _ in },
            actionSink: { _ in }
        )

        XCTAssertTrue(model.canGoNext)
        model.goNext()
        XCTAssertEqual(model.progress.step, .ready)
    }
}
