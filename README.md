<div align="center">

# miri

[![License](https://img.shields.io/badge/license-MIT-111111?style=flat-square)](./LICENSE)
[![Fork](https://img.shields.io/badge/fork-dimixar%2Fmiri-111111?style=flat-square&logo=github)](https://github.com/dimixar/miri)
[![Original](https://img.shields.io/badge/original-maria--rcks%2Fmiri-111111?style=flat-square&logo=github)](https://github.com/maria-rcks/miri)

<img src="./assets/repo/miri-demo.gif" alt="miri macOS window layout preview" width="1000" />

_Niri-ish, keyboard-first window manager for macOS._

</div>

This fork continues the archived upstream project with snapshot-based
animations, left-Option defaults, workspace-bar controls, intelligent width
resizing, stronger state recovery, and many window-management stability fixes.

## Install

Build and run from source:

```bash
git clone https://github.com/dimixar/miri.git
cd miri
swift run miri
```

For a release build:

```bash
swift build -c release
.build/release/miri
```

To build a local `.app` and DMG on Apple Silicon macOS:

```bash
scripts/package-app.sh
open dist/Miri.app
# or:
scripts/package-macos.sh --version 0.1.0
open dist/Miri-0.1.0-arm64-darwin.dmg
```

miri needs Accessibility permission, and the event tap may also need Input
Monitoring permission. Snapshot animations need Screen Recording permission so
miri can capture window images for the animation overlay. If you run it from a
terminal, macOS may ask for the terminal app itself to get those permissions.

## Fork highlights and differences from archived upstream

- **Left Option defaults:** default keybindings use `lalt`/left Option instead
  of `cmd`, leaving common macOS shortcuts alone.
- **Workspace bar:** the menu-bar item can render occupied workspaces with app
  icons, a focused-window highlight, configurable highlight color, configurable
  visible icon count, and overflow styles.
- **Expanded settings coverage:** the settings window includes this fork's extra
  animation strategy/throttling controls, workspace-bar controls, keybinding
  management, rule editing, and `width_resize_mode` selection.
- **Snapshot animation backend:** captures tiled windows into snapshots, animates
  them in a transparent overlay, hides real windows underneath, and applies final
  Accessibility frames once at the end.
- **Retargetable animations:** repeated keyboard commands during an active
  animation retarget the current snapshot session instead of restarting from a
  stale intermediate state.
- **Animation throttling:** `animation_fps` and `animation_pixel_threshold` can
  reduce redundant frame work and Accessibility calls.
- **Optional no-animation mode:** `animation_strategy` is now `snapshot` or
  `off`; old `smooth_ax`/`snappy` values decode as `snapshot`.
- **Intelligent width resizing:** optional `width_resize_mode: "intelligent"`
  chooses grow/shrink direction and scroll offset so the active column stays
  visually stable and fully visible.
- **Better hidden/minimized/fullscreen recovery:** preserves tiled state across
  minimize, app hide, native fullscreen transitions, and fullscreen Space
  switches, then restores windows to their previous workspace, position, width,
  and focus context.
- **Native fullscreen Space protection:** detects fullscreen helper windows and
  remembered fullscreen apps so desktop windows are not removed or reinserted
  into the wrong Miri workspace while macOS is focused on a fullscreen Space.
- **Destroyed-window handling:** removes destroyed tiled/floating windows as soon
  as Accessibility reports them, then reprojects layout without waiting for a
  later rescan.
- **Transient window filtering:** ignores Chromium popups/Picture-in-Picture,
  untitled `AXUnknown` overlays, and other transient system panels that should
  not become tiled columns.
- **Focus visibility fixes:** reveals the active column after horizontal focus
  changes, focus adoption, and frontmost-app window creation so newly opened apps
  do not focus an off-screen tiled column.
- **Persistence improvements:** debounced snapshots store effective manual
  widths and match restored windows by exact identity first, then by
  bundle/app/title fallback with nearest workspace/column preference.
- **Local packaging compatibility:** `scripts/package-app.sh` wraps the DMG
  packager while still leaving a directly openable `dist/Miri.app` for local
  development.
- **Refactored codebase:** splits the former large `Miri.swift` coordinator into
  focused `Core`, `Config`, `Input`, `Trackpad`, `Layout`, `Windows`,
  `Persistence`, `UI`, `Debug`, and `System` folders.

## What it does

- Keeps a Niri-like virtual layout of workspaces and columns on macOS.
- Tiles normal app windows with Accessibility APIs instead of acting as a
  compositor.
- Uses configurable column widths and presets; this fork's sample config starts
  at `0.67` screen width so adjacent columns are easier to see.
- Can center, smart-align, or left-align the focused column while keeping the
  first column pinned when appropriate.
- Tracks `Cmd+Tab`, app launches/exits, manual resizes, minimized/hidden apps,
  fullscreen transitions, fullscreen Space changes, destroyed windows, focus
  changes, and transient overlays so the model follows macOS instead of fighting
  it.
- Supports app rules for tiled, floating, and ignored windows.
- Hot-reloads config changes without restarting, keeping the previous config if
  a saved file cannot be parsed.
- Persists workspace, column order, manual widths, and focused window across
  restarts.
- Parks off-workspace windows near the side edge, with optional SkyLight alpha
  hiding when private symbols are available.
- Restores tiled and floating windows on normal exit and uses cleanup snapshots
  for crash or kill recovery.

## Shortcuts

Default shortcuts use **left Option** (`lalt`). Everything else passes through;
`excluded_keybindings` can reserve shortcuts for macOS or other apps.

| Shortcut | Action |
| :------- | :----- |
| `LAlt+1`..`LAlt+9` | Focus workspace by dynamic index |
| `LAlt+0` | Focus the previous workspace |
| `LAlt+J` / `LAlt+K` | Focus workspace down / up |
| `LAlt+H` / `LAlt+L` | Focus column left / right |
| `LAlt+[` / `LAlt+]` | Focus first / last column |
| `LAlt+Home` / `LAlt+End` | Focus first / last column |
| `LAlt+Shift+1`..`LAlt+Shift+9` | Move column to workspace |
| `LAlt+Shift+J` / `LAlt+Shift+K` | Move column workspace down / up |
| `LAlt+Shift+H` / `LAlt+Shift+L` | Move column left / right |
| `LAlt+Shift+[` / `LAlt+Shift+]` | Move column to first / last |
| `LAlt+Ctrl+H` / `LAlt+Ctrl+L` | Cycle active column width preset |
| `LAlt+Ctrl+-` / `LAlt+Ctrl+=` | Nudge active column width |
| `LAlt+Ctrl+Shift+H` / `LAlt+Ctrl+Shift+L` | Cycle every tiled window width preset |
| `LAlt+Ctrl+Shift+-` / `LAlt+Ctrl+Shift+=` | Nudge every tiled window width |
| three-finger trackpad swipe | Navigate columns / workspaces |

Trackpad navigation uses Apple's private MultitouchSupport framework so Miri can
see raw three-finger movement without stealing normal two-finger scrolling. It
moves a continuous camera with momentum, then focuses the workspace and column
nearest the camera when motion settles.

## Menu bar and settings

The menu bar item exposes:

- current workspace, focused window, and active width;
- occupied workspace summaries with app names;
- **Settings…** for the GUI editor;
- **Open Config**, **Reload Config**, and **Rescan Windows**;
- **Quit Miri**, which performs normal window restoration.

The settings editor saves to the active JSON config and reloads miri in place.
It covers layout defaults, focus behavior, animation options, fullscreen and
fullscreen-Space recovery timing, trackpad tuning, window rules, excluded
shortcuts, and command keybindings.

## Config

miri loads the first config file it can read:

- `MIRI_CONFIG`
- `./miri.config.json`
- `$XDG_CONFIG_HOME/miri/config.json`
- `~/.config/miri/config.json`

The loaded config file is watched for changes. Saving valid JSON reloads
keybindings, rules, layout settings, animations, menu-bar settings, and trackpad
settings in place. If a save cannot be parsed, miri keeps running with the
previous config.

The repo includes a full default config. A compact version looks like this:

```json
{
  "default_width_ratio": 0.67,
  "preset_width_ratios": [0.33, 0.5, 0.67, 1.0],
  "animation_duration_ms": 0,
  "keyboard_animation_ms": 0,
  "hover_focus_animation_ms": 0,
  "trackpad_settle_animation_ms": 0,
  "move_column_animation_ms": 0,
  "width_animation_ms": 0,
  "animation_curve": "smooth",
  "animation_strategy": "snapshot",
  "animation_fps": 60,
  "animation_pixel_threshold": 0.5,
  "hover_to_focus": true,
  "hover_focus_delay_ms": 120,
  "hover_focus_max_scroll_ratio": 0.15,
  "hover_focus_requires_visible_ratio": 0.15,
  "hover_focus_edge_trigger_width": 8,
  "hover_focus_after_trackpad_ms": 280,
  "hover_focus_mode": "edge_or_visible",
  "workspace_auto_back_and_forth": true,
  "center_focused_column": false,
  "focus_alignment": "smart",
  "new_window_position": "after_active",
  "inner_gap": 0,
  "outer_gap": 0,
  "parked_sliver_width": 1,
  "excluded_keybindings": ["cmd+shift+5"],
  "keybindings": {
    "column_left": ["lalt+h"],
    "column_right": ["lalt+l"],
    "workspace_down": ["lalt+j"],
    "workspace_up": ["lalt+k"]
  },
  "trackpad_navigation": true,
  "trackpad_navigation_fingers": 3,
  "trackpad_navigation_sensitivity": 1.6,
  "trackpad_navigation_deceleration": 5.5,
  "trackpad_navigation_hover_suppression_ms": 280,
  "trackpad_navigation_momentum_min_velocity": 80,
  "trackpad_navigation_velocity_gain": 1.35,
  "trackpad_navigation_settle_animation_ms": 240,
  "trackpad_navigation_snap": "nearest_column",
  "trackpad_navigation_invert_x": false,
  "trackpad_navigation_invert_y": false,
  "rescan_interval_ms": 1000,
  "likely_fullscreen_transition_grace_ms": 1500,
  "fullscreen_space_change_guard_ms": 1500,
  "restore_on_exit": true,
  "persist_layout": true,
  "state_path": null,
  "hide_method": "skylight_alpha",
  "debug_logging": false,
  "width_resize_mode": "default",
  "workspace_bar_highlight_color": "#FFD60A",
  "workspace_bar_visible_icon_count": 3,
  "workspace_bar_overflow_style": "plus_count",
  "rules": [
    {
      "bundle_id": "com.apple.finder",
      "behavior": "ignore"
    }
  ]
}
```

`keybindings` is merged with the built-in defaults by action name, so a config
can override only the actions it cares about. Set an action to `[]` to disable
it. `excluded_keybindings` always wins. See `miri.config.json` for the full
command-name list.

Keybinding strings support `cmd`/`win`/`windows`/`super`/`meta`, `ctrl`,
`shift`, `alt`/`option`, side-specific `lalt`/`ralt`, and `fn`/`globe`, plus
common key aliases for arrows, navigation keys, page keys, function keys, and
punctuation.

Fullscreen recovery settings:

- `likely_fullscreen_transition_grace_ms`: grace period for window-level native
  fullscreen transitions, including transient missing CG window info.
- `fullscreen_space_change_guard_ms`: guard period after fullscreen-sized
  `AXUnknown` helper windows appear; during and after the guard, if focus remains
  on a remembered fullscreen app, miri freezes normal rescan/removal/reinsert
  mutations so other workspace windows keep their original Miri layout.

Useful string settings:

- `animation_curve`: `smooth`, `snappy`, or `linear`
- `animation_strategy`: `snapshot` or `off`
- `hover_focus_mode`: `off`, `visible_only`, or `edge_or_visible`
- `focus_alignment`: `left`, `center`, or `smart`
- `new_window_position` and rule `open_position`: `before_active`,
  `after_active`, or `end`
- `trackpad_navigation_snap`: `nearest_column`, `nearest_visible`, or `none`
- `hide_method`: `skylight_alpha` or `park_only`
- `width_resize_mode`: `default` or `intelligent`
- `workspace_bar_overflow_style`: `plus_count`, `dots_count`, `chevron`, or
  `none`

Rules can match on `bundle_id`, `app_name`, or `title_contains`. Use
`behavior: "ignore"` for windows miri should leave alone, `behavior: "float"`
for visible untiled windows that should be raised above tiled columns, and
`width_ratio` to override an app's default column width. Rules can also set
`workspace`, `open_position`, `trackpad_navigation`, and `hover_to_focus` for
matching windows.

With `persist_layout` enabled, miri writes a local layout snapshot to
`$XDG_STATE_HOME/miri/layout.json` or `~/.local/state/miri/layout.json`. Set
`state_path` to override that location. The snapshot uses app names, bundle IDs,
window titles, and window identity hints to match windows after restart.

## Development

```bash
swift build
swift run miri
```

The source tree is organized by responsibility:

```text
Sources/Miri/Core/          coordinator, commands, status providers
Sources/Miri/Config/        config model and effective settings
Sources/Miri/Input/         keyboard/event tap input and keybinding resolution
Sources/Miri/Trackpad/      raw trackpad backend and camera/momentum
Sources/Miri/Layout/        projection, geometry, application, animations
Sources/Miri/Windows/       discovery, placement, lookup, transient windows, AX observers
Sources/Miri/Persistence/   layout persistence and exit/crash restoration
Sources/Miri/UI/            settings window and status menu
Sources/Miri/Debug/         debug logging
Sources/Miri/System/        Accessibility and SkyLight wrappers
```

## Releases

Release artifacts are built by `.github/workflows/release.yml`.

- Push a stable tag like `v0.1.0` to publish a GitHub Release.
- Run the workflow manually with `channel: nightly` to publish a prerelease.
- The scheduled nightly checks whether `main` changed since the last nightly tag
  before publishing.
- The macOS artifact is `Miri-<version>-arm64-darwin.dmg` containing `Miri.app`.

## Notes

- miri targets macOS 13+ and Swift 6.
- It uses public Accessibility APIs for the core window control path.
- The SkyLight path is private and optional; if it is unavailable, hidden
  windows stay parked as side-edge slivers and floating level changes may fall
  back to normal behavior.
- Trackpad navigation and SkyLight integration use private Apple frameworks or
  symbols and may need adjustment across macOS releases.
- This does not use native macOS Spaces.

## Links

- Fork: https://github.com/dimixar/miri
- Original archived repository: https://github.com/maria-rcks/miri
- Research notes: [docs/macos-window-management-investigation.md](docs/macos-window-management-investigation.md)
- Niri behavior notes: [docs/niri-mvp-behavior-notes.md](docs/niri-mvp-behavior-notes.md)
- Fork change notes: [docs/feature-local-branch-changes.md](docs/feature-local-branch-changes.md), [docs/animation-revamp-branch-changes.md](docs/animation-revamp-branch-changes.md), [docs/intelligent-width-resize-report.md](docs/intelligent-width-resize-report.md), [docs/miri-refactoring-summary.md](docs/miri-refactoring-summary.md)
