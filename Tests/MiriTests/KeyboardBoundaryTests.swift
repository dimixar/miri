import CoreGraphics
import XCTest
@testable import miri

final class KeyboardBoundaryGateTests: XCTestCase {
    func testThresholdAndSingleCommit() throws {
        var gate = try XCTUnwrap(WorkspaceBoundaryGate(now: 0, milliseconds: 750, isRepeat: false))
        XCTAssertFalse(gate.commitIfReady(now: 0.749, held: true, sourceValid: true))
        XCTAssertTrue(gate.commitIfReady(now: 0.750, held: true, sourceValid: true))
        XCTAssertFalse(gate.commitIfReady(now: 1.5, held: true, sourceValid: true))
    }

    func testReleaseModifierChangeAndStaleSourceCannotCommit() throws {
        for now in [0.749, 0.750, 2.0] {
            var gate = try XCTUnwrap(WorkspaceBoundaryGate(now: 0, milliseconds: 750, isRepeat: false))
            XCTAssertFalse(gate.commitIfReady(now: now, held: false, sourceValid: true))
            XCTAssertFalse(gate.commitIfReady(now: now, held: true, sourceValid: false))
        }
    }

    func testRepeatCannotArmAfterNavigatingToBoundary() {
        XCTAssertNil(WorkspaceBoundaryGate(now: 10, milliseconds: 750, isRepeat: true))
    }

    func testDurationClampAndMonotonicProgress() throws {
        let short = try XCTUnwrap(WorkspaceBoundaryGate(now: 10, milliseconds: 0, isRepeat: false))
        let long = try XCTUnwrap(WorkspaceBoundaryGate(now: 10, milliseconds: 5000, isRepeat: false))
        XCTAssertEqual(short.duration, 0.25)
        XCTAssertEqual(long.duration, 2)
        XCTAssertEqual(short.progress(now: 9), 0)
        XCTAssertEqual(short.progress(now: 10.125), 0.5)
        XCTAssertEqual(short.progress(now: 11), 1)
    }
}

@MainActor
final class KeyboardBoundaryInputTests: XCTestCase {
    func testConsumedShortcutHasConsumedReleaseEvenAfterModifierChange() throws {
        let controller = InputController(
            emit: { _ in }, isAwaitingSessionRecovery: { false },
            handleRecoveryKey: { _, _ in false }, shouldSuppressCommand: { false }
        )
        controller.configure(.fallback)
        let down = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(KeyCode.j), keyDown: true))
        down.flags = [.maskAlternate, CGEventFlags(rawValue: 0x20)]
        XCTAssertTrue(controller.handleKeyEvent(down))
        let up = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(KeyCode.j), keyDown: false))
        up.flags = []
        XCTAssertTrue(controller.handleKeyEvent(up), "A swallowed down must not leak its release")
        XCTAssertFalse(controller.handleKeyEvent(up), "Unrelated releases remain unconsumed")
    }

    func testBothBackendReleaseRoutesAndModifierChangeCancel() throws {
        var releases = 0
        let controller = InputController(
            emit: { if case .input(.shortcutReleased) = $0 { releases += 1 } },
            isAwaitingSessionRecovery: { false }, handleRecoveryKey: { _, _ in false },
            shouldSuppressCommand: { false }
        )
        let release = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(KeyCode.j), keyDown: false))
        XCTAssertFalse(controller.handleKeyEvent(release), "Unrelated key releases pass through")
        XCTAssertEqual(releases, 1)
        _ = controller.handleCarbonHotKey(id: 1, released: true)
        XCTAssertEqual(releases, 2)
        release.type = .flagsChanged
        XCTAssertFalse(controller.handleKeyEvent(release))
        XCTAssertEqual(releases, 3)
    }

    func testLegacyExplicitBindingsWinOverInheritedRowDefaults() {
        var config = MiriConfig.fallback
        config.keybindings = ["workspace_down": ["lalt+j"], "move_column_left": ["lalt+shift+h"]]
        let configured = KeybindingResolver.configuredKeybindings(config: config)
        XCTAssertEqual(configured["row_down"], [])
        XCTAssertEqual(configured["move_window_left"], [])
        let commands = KeybindingResolver.makeCommandByKeybinding(config: config)
        guard case .workspaceDown? = commands["lalt+j"] else { return XCTFail("Legacy workspace binding stolen") }
        guard case .moveColumnLeft? = commands["shift+lalt+h"] else { return XCTFail("Legacy column binding stolen") }
    }

    func testNewDefaultsAndNumberedWorkspaceBindings() {
        let commands = KeybindingResolver.makeCommandByKeybinding(config: .fallback)
        guard case .rowDown? = commands["lalt+j"] else { return XCTFail("Missing row command") }
        guard case .moveWindowDown? = commands["shift+lalt+j"] else { return XCTFail("Missing window command") }
        guard case .cycleHeightPresetForward? = commands["ctrl+lalt+k"] else { return XCTFail("Missing height command") }
        guard case .focusWorkspace(1)? = commands["lalt+1"] else { return XCTFail("Numbered shortcut must remain direct") }
    }
}
