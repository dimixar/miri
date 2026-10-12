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
        config.dragScrollSpeedPercent = nil
        config.manualFloatingOutlineEnabled = nil
        config.manualFloatingOutlineThickness = nil

        let draft = SettingsDraft(config: config)

        XCTAssertEqual(draft.restoreOnExit, MiriConfig.fallback.restoreOnExit)
        XCTAssertEqual(draft.focusAlignment, MiriConfig.fallback.focusAlignment)
        XCTAssertEqual(draft.animationStrategy, MiriConfig.fallback.animationStrategy)
        XCTAssertEqual(draft.workspaceBarVisibleIconCount, MiriConfig.fallback.workspaceBarVisibleIconCount)
        XCTAssertEqual(draft.activeRescanBundleIDs, MiriConfig.fallback.activeRescanBundleIDs)
        XCTAssertEqual(draft.dragScrollSpeedPercent, 100)
        XCTAssertTrue(draft.manualFloatingOutlineEnabled)
        XCTAssertEqual(draft.manualFloatingOutlineThickness, 2)
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

    func testDraftRoundTripsAllEditableValues() throws {
        var original = SettingsDraft(config: MiriConfig.fallback)
        original.focusAlignment = .centeredSmart
        original.outerGap = 14
        original.dragScrollSpeedPercent = 500
        original.manualFloatingOutlineEnabled = false
        original.manualFloatingOutlineThickness = 7
        original.animationStrategy = .off
        original.workspaceBarCenterStyle = .border
        original.activeRescanBundleIDs = ["com.example.One", "com.example.Two"]
        original.rules.append(WindowRule(appName: "Example", behavior: .float, workspace: 3))

        let saved = original.applying(to: MiriConfig.fallback)
        let encoded = try JSONEncoder().encode(saved)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(object["drag_scroll_speed_percent"] as? Int, 500)
        XCTAssertEqual(object["manual_floating_outline_enabled"] as? Bool, false)
        XCTAssertEqual(object["manual_floating_outline_thickness"] as? Int, 7)
        let restored = SettingsDraft(config: try JSONDecoder().decode(MiriConfig.self, from: encoded))

        XCTAssertEqual(restored, original)
    }

    func testFloatingOutlineThicknessCompatibilityAndLimits() throws {
        let legacy = try JSONDecoder().decode(
            MiriConfig.self,
            from: Data(#"{"default_width_ratio":0.67,"rules":[]}"#.utf8)
        )
        XCTAssertEqual(legacy.resolved().manualFloatingOutlineThickness, 2)
        XCTAssertEqual(SettingsDraft(config: legacy).manualFloatingOutlineThickness, 2)

        for (requested, expected) in [(-4, 1), (0, 1), (1, 1), (7, 7), (10, 10), (11, 10)] {
            var draft = SettingsDraft(config: legacy)
            draft.manualFloatingOutlineThickness = requested
            XCTAssertEqual(draft.applying(to: legacy).manualFloatingOutlineThickness, expected)

            let data = Data("{\"default_width_ratio\":0.67,\"rules\":[],\"manual_floating_outline_thickness\":\(requested)}".utf8)
            let decoded = try JSONDecoder().decode(MiriConfig.self, from: data)
            XCTAssertEqual(MiriConfig.normalize(decoded).resolved().manualFloatingOutlineThickness, expected)
        }
    }

    func testDragScrollSpeedCompatibilityAndLimits() throws {
        let legacy = try JSONDecoder().decode(
            MiriConfig.self,
            from: Data(#"{"default_width_ratio":0.67,"rules":[]}"#.utf8)
        )
        XCTAssertEqual(legacy.resolved().dragScrollSpeedPercent, 100)
        XCTAssertEqual(SettingsDraft(config: legacy).dragScrollSpeedPercent, 100)

        for (requested, expected) in [(-1, 25), (25, 25), (175, 175), (300, 300), (301, 301), (500, 500), (501, 500)] {
            var draft = SettingsDraft(config: legacy)
            draft.dragScrollSpeedPercent = requested
            XCTAssertEqual(draft.applying(to: legacy).dragScrollSpeedPercent, expected)
        }
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

    func testFullscreenAndFloatingShortcutsAreInheritedAndExplicitOverridesRoundTrip() {
        var legacy = MiriConfig.fallback
        legacy.keybindings = ["column_left": ["lalt+x"]]
        let draft = SettingsDraft(config: legacy)
        XCTAssertEqual(draft.keybindings["toggle_workspace_fullscreen"], ["lalt+shift+f"])
        XCTAssertEqual(draft.keybindings["toggle_window_floating"], ["lalt+ctrl+f"])
        XCTAssertEqual(draft.keybindings["column_left"], ["lalt+x"])
        XCTAssertNil(draft.validationMessage())

        let command = KeybindingResolver.commandForKeyEvent(
            modifiers: CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | CGEventFlags.maskShift.rawValue | 0x20),
            keyCode: KeyCode.f,
            keyText: "ƒ",
            commandByKeybinding: KeybindingResolver.makeCommandByKeybinding(config: legacy)
        )
        guard case .toggleWorkspaceFullscreen? = command else {
            return XCTFail("The inherited default must resolve to the fullscreen toggle")
        }

        let floatingCommand = KeybindingResolver.commandForKeyEvent(
            modifiers: CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | CGEventFlags.maskControl.rawValue | 0x20),
            keyCode: KeyCode.f, keyText: "ƒ",
            commandByKeybinding: KeybindingResolver.makeCommandByKeybinding(config: legacy)
        )
        guard case .toggleWindowFloating? = floatingCommand else {
            return XCTFail("Control-Option-F must toggle only the focused window's floating state")
        }

        for action in ["toggle_workspace_fullscreen", "toggle_window_floating"] {
            for bindings in [["lalt+ctrl+g"], []] {
                var custom = legacy
                custom.keybindings?[action] = bindings
                let overridden = SettingsDraft(config: custom)
                XCTAssertEqual(overridden.keybindings[action], bindings)
                XCTAssertEqual(overridden.applying(to: custom).keybindings?[action], bindings)
                XCTAssertNil(overridden.validationMessage())
                let defaultBinding = action == "toggle_workspace_fullscreen" ? "shift+lalt+f" : "ctrl+lalt+f"
                XCTAssertNil(KeybindingResolver.makeCommandByKeybinding(config: overridden.applying(to: custom))[defaultBinding])
            }
        }

        legacy.keybindings?["toggle_workspace_fullscreen"] = ["leftoption+control+f"]
        let preserved = SettingsDraft(config: legacy)
        XCTAssertEqual(preserved.keybindings["toggle_workspace_fullscreen"], ["leftoption+control+f"])
        XCTAssertEqual(preserved.keybindings["toggle_window_floating"], [])
        guard case .toggleWorkspaceFullscreen? = KeybindingResolver.makeCommandByKeybinding(config: legacy)["ctrl+lalt+f"] else {
            return XCTFail("The new floating default must not steal an explicitly configured fullscreen shortcut")
        }
    }
}

@MainActor
final class SettingsStoreTests: XCTestCase {
    func testLoginItemUpdatesAreImmediateAndIndependentOfConfigDraft() {
        let store = SettingsStore(
            config: MiriConfig.fallback,
            availableApps: [],
            permissions: MiriPermissionStatus(accessibility: .granted, screenRecording: .missing),
            loginItemStatus: .notRegistered,
            actionSink: { _ in }
        )
        store.draft.outerGap = 18
        store.updateLoginItemStatus(.enabled)
        XCTAssertEqual(store.draft.outerGap, 18)
        XCTAssertTrue(store.isDirty)
        store.revert()
        XCTAssertEqual(store.loginItemStatus, .enabled)
        XCTAssertFalse(store.isDirty)

        store.updateLoginItemStatus(.enabled, error: "Registration failed")
        XCTAssertEqual(store.loginItemError, "Registration failed")
        XCTAssertEqual(store.feedback, .none)
        store.updateLoginItemStatus(.requiresApproval)
        XCTAssertNil(store.loginItemError)
        XCTAssertTrue(store.loginItemStatus.isRequested)
        XCTAssertFalse(store.isDirty)
    }

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
        store.draft.dragScrollSpeedPercent = 50
        store.draft.manualFloatingOutlineThickness = 1
        XCTAssertTrue(store.isDirty)
        XCTAssertEqual(store.feedbackText, "Unsaved changes")

        store.revert()
        XCTAssertFalse(store.isDirty)
        XCTAssertEqual(store.draft.outerGap, MiriConfig.fallback.outerGap)
        XCTAssertEqual(store.draft.dragScrollSpeedPercent, 100)
        XCTAssertEqual(store.draft.manualFloatingOutlineThickness, 2)

        store.draft.outerGap = 24
        store.draft.dragScrollSpeedPercent = 200
        store.draft.manualFloatingOutlineThickness = 10
        XCTAssertTrue(store.submit(closeOnSuccess: false))
        XCTAssertEqual(submittedConfig?.outerGap, 24)
        XCTAssertEqual(submittedConfig?.dragScrollSpeedPercent, 200)
        XCTAssertEqual(submittedConfig?.manualFloatingOutlineThickness, 10)
        XCTAssertEqual(shouldClose, false)
        XCTAssertEqual(store.feedback, .saving)

        store.presentSaveSuccess()
        XCTAssertFalse(store.isDirty)
        XCTAssertEqual(store.draft.dragScrollSpeedPercent, 200)
        XCTAssertEqual(store.draft.manualFloatingOutlineThickness, 10)
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
