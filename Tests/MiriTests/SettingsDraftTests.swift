import XCTest
@testable import miri

final class SettingsDraftTests: XCTestCase {
    func testDraftResolvesOptionalValuesFromFallback() {
        var config = MiriConfig.fallback
        config.restoreOnExit = nil
        config.focusAlignment = nil
        config.animationStrategy = nil
        config.workspaceBarVisibleIconCount = nil
        config.activeRescanBundleIDs = nil

        let draft = SettingsDraft(config: config)

        XCTAssertEqual(draft.restoreOnExit, MiriConfig.fallback.restoreOnExit)
        XCTAssertEqual(draft.focusAlignment, MiriConfig.fallback.focusAlignment)
        XCTAssertEqual(draft.animationStrategy, MiriConfig.fallback.animationStrategy)
        XCTAssertEqual(draft.workspaceBarVisibleIconCount, MiriConfig.fallback.workspaceBarVisibleIconCount)
        XCTAssertEqual(draft.activeRescanBundleIDs, MiriConfig.fallback.activeRescanBundleIDs)
    }

    func testApplyingDraftPreservesUnexposedConfiguration() {
        var source = MiriConfig.fallback
        source.animationDurationMS = 175
        source.keyboardAnimationMS = 95
        source.animationCurve = .snappy
        source.statePath = "/tmp/miri-state.json"
        var draft = SettingsDraft(config: source)
        draft.restoreOnExit = false
        draft.outerGap = 18

        let result = draft.applying(to: source)

        XCTAssertEqual(result.restoreOnExit, false)
        XCTAssertEqual(result.outerGap, 18)
        XCTAssertEqual(result.animationDurationMS, 175)
        XCTAssertEqual(result.keyboardAnimationMS, 95)
        XCTAssertEqual(result.animationCurve, .snappy)
        XCTAssertEqual(result.statePath, "/tmp/miri-state.json")
    }

    func testDraftRoundTripsAllEditableValues() {
        var original = SettingsDraft(config: MiriConfig.fallback)
        original.focusAlignment = .centeredSmart
        original.outerGap = 14
        original.animationStrategy = .off
        original.workspaceBarCenterStyle = .border
        original.activeRescanBundleIDs = ["com.example.One", "com.example.Two"]
        original.rules.append(WindowRule(appName: "Example", behavior: .float, workspace: 3))

        let saved = original.applying(to: MiriConfig.fallback)
        let restored = SettingsDraft(config: saved)

        XCTAssertEqual(restored, original)
    }

    func testDuplicateKeybindingsAreRejectedCaseInsensitively() {
        var draft = SettingsDraft(config: MiriConfig.fallback)
        draft.keybindings = [
            "first": ["lalt+1"],
            "second": ["LALT+1"],
        ]

        XCTAssertEqual(
            draft.validationMessage(),
            "Keybinding 'LALT+1' is assigned to both 'first' and 'second'."
        )
    }
}

@MainActor
final class SettingsStoreTests: XCTestCase {
    func testDirtyRevertAndSaveLifecycle() {
        var submittedConfig: MiriConfig?
        var shouldClose: Bool?
        let store = SettingsStore(
            config: MiriConfig.fallback,
            availableApps: [],
            permissions: MiriPermissionStatus(accessibility: .granted, screenRecording: .missing),
            actionSink: { action in
                guard case let .saveConfig(config, closeOnSuccess) = action else { return }
                submittedConfig = config
                shouldClose = closeOnSuccess
            }
        )

        XCTAssertFalse(store.isDirty)
        store.draft.outerGap = 22
        XCTAssertTrue(store.isDirty)
        XCTAssertEqual(store.feedbackText, "Unsaved changes")

        store.revert()
        XCTAssertFalse(store.isDirty)
        XCTAssertEqual(store.draft.outerGap, MiriConfig.fallback.outerGap)

        store.draft.outerGap = 24
        XCTAssertTrue(store.submit(closeOnSuccess: false))
        XCTAssertEqual(submittedConfig?.outerGap, 24)
        XCTAssertEqual(shouldClose, false)
        XCTAssertEqual(store.feedback, .saving)

        store.presentSaveSuccess()
        XCTAssertFalse(store.isDirty)
        XCTAssertEqual(store.feedback, .saved)
    }

    func testRefreshReplacesEditingSessionAndPermissions() {
        let store = SettingsStore(
            config: MiriConfig.fallback,
            availableApps: [],
            permissions: MiriPermissionStatus(accessibility: .missing, screenRecording: .missing),
            actionSink: { _ in }
        )
        store.draft.outerGap = 12

        var refreshed = MiriConfig.fallback
        refreshed.outerGap = 30
        store.refresh(
            config: refreshed,
            availableApps: [RuleAppInfo(bundleID: "com.example.app", appName: "Example")],
            permissions: MiriPermissionStatus(accessibility: .granted, screenRecording: .restartRequired)
        )

        XCTAssertFalse(store.isDirty)
        XCTAssertEqual(store.draft.outerGap, 30)
        XCTAssertEqual(store.availableApps.count, 1)
        XCTAssertEqual(store.permissions.accessibility, .granted)
        XCTAssertEqual(store.permissions.screenRecording, .restartRequired)
    }
}
