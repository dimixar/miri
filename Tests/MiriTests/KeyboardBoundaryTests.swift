import CoreGraphics
import XCTest
@testable import miri

@MainActor
final class KeyboardBoundaryInputTests: XCTestCase {
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
