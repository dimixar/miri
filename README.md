<div align="center">

# miri

[![License](https://img.shields.io/badge/license-MIT-111111?style=flat-square)](./LICENSE)

[Watch the demo video](https://dimixar.github.io/miri/assets/repo/demo.html)

_Niri-ish, keyboard-first window management for macOS._

</div>

miri is a standalone macOS window manager inspired by
[Niri](https://github.com/YaLTeR/niri) and by the previously forked, now archived
[`maria-rcks/miri`](https://github.com/maria-rcks/miri) project. This repository
is maintained independently and is no longer presented as a fork.

It tiles normal app windows through macOS Accessibility APIs, keeps a virtual
workspace/column model, and adds macOS-specific recovery for app hiding,
minimize, native fullscreen, Space switching, and process/window churn.

## Table of contents

- [Status](#status)
- [Features](#features)
- [Requirements and permissions](#requirements-and-permissions)
- [Private API usage](#private-api-usage)
- [Install and run](#install-and-run)
- [Packaging locally](#packaging-locally)
- [Default shortcuts](#default-shortcuts)
- [Menu bar and settings](#menu-bar-and-settings)
- [Configuration](#configuration)
- [Native macOS Space handling](#native-macos-space-handling)
- [Persistence and recovery](#persistence-and-recovery)
- [Project structure](#project-structure)
- [Notes and limitations](#notes-and-limitations)
- [Related documentation](#related-documentation)

## Status

miri is source-first software for users who are comfortable building and running
Swift tools locally. GitHub Releases are not part of the current project flow;
use the Swift commands or local packaging scripts below.

## Features

### Window layout

- Niri-like horizontal columns grouped into virtual workspaces.
- Configurable default column width and width presets.
- Focus alignment modes: `left`, `center`, and `smart`.
- New-window placement before the active column, after it, or at the end.
- Optional hover-to-focus with edge and visible-area controls.
- App/window rules for tiled, floating, and ignored windows.

### Input

- Keyboard-first defaults using **left Option** (`lalt`) instead of `cmd`, so
  common macOS shortcuts keep working.
- Side-specific keybinding support for `lalt`/`ralt` plus common modifier and
  key aliases.
- `excluded_keybindings` for shortcuts that miri should leave to macOS or other
  apps.
- Three-finger trackpad navigation using Apple's private MultitouchSupport
  framework, with configurable sensitivity, momentum, snapping, and inversion.

### Animation and resizing

- Snapshot animation backend: captures tiled windows, animates snapshots in a
  transparent overlay, parks real windows underneath, and applies final
  Accessibility frames at the end.
- Retargetable keyboard animations for repeated commands during an active
  snapshot session.
- Optional no-animation mode with `animation_strategy: "off"`.
- Animation throttling through `animation_fps` and
  `animation_pixel_threshold`.
- Optional `width_resize_mode: "intelligent"` that chooses resize direction and
  scroll offset so the active column stays visually stable and visible.

### macOS integration and recovery

- Tracks app launches/exits, Cmd+Tab focus changes, manual resizes, minimized
  and hidden apps, destroyed windows, fullscreen transitions, and transient
  overlays.
- Protects native fullscreen Spaces from destructive rescans while macOS is
  entering, using, or leaving fullscreen.
- Infers separate logical macOS Space contexts without private Spaces APIs.
- Persists layout, manual widths, active columns, focus context, and inferred
  Space contexts across restarts.
- Restores tiled/floating windows on normal exit and uses cleanup snapshots for
  crash or kill recovery.
- Parks off-workspace windows near the side edge so inactive workspaces do not
  overlap the active workspace.

## Requirements and permissions

- macOS 13 or newer.
- Swift 6 toolchain.
- Accessibility permission for window management.
- Input Monitoring permission may be needed for the event tap.
- Screen Recording permission is needed for snapshot animations.

If you run miri from a terminal, macOS may request permissions for that terminal
app rather than for a packaged `Miri.app`.

## Private API usage

miri's core window management is Accessibility-based. Moving, resizing,
focusing, discovering, and observing normal app windows are done through public
macOS Accessibility/AppKit APIs where possible.

The project still uses a small private API surface for things macOS does not
expose publicly:

### Window IDs

`Sources/Miri/System/SkyLight.swift` loads HIServices and resolves:

```text
_AXUIElementGetWindow
```

This maps an `AXUIElement` to a `CGWindowID`. miri uses that ID to persist and
match windows more reliably across rescans, Space-context changes, fullscreen
recovery, debug logging, and cleanup snapshots. The main call sites are window
discovery, fullscreen/manual-resize matching, logical Space persistence, and
exit/crash restoration.

### Floating window levels

`Sources/Miri/System/SkyLight.swift` also loads SkyLight and resolves:

```text
SLSMainConnectionID
SLSSetWindowLevel
```

`SLSSetWindowLevel` is used only for windows that miri treats as floating. When
floating windows are restored or raised, miri attempts to put them at macOS's
floating-window level. During cleanup/restoration, miri resets tracked windows
back to the normal window level so a managed app window is not left above other
apps after miri exits.

There is no public macOS API for changing another application's window level.
The public fallback is only raise/focus ordering, which is not the same thing as
a real WindowServer level change.

### Trackpad contact frames

`Sources/Miri/Trackpad/ThreeFingerTrackpadNavigation.swift` loads Apple's
private MultitouchSupport framework and resolves:

```text
MTDeviceCreateList
MTRegisterContactFrameCallback
MTDeviceStart
```

This powers raw multi-finger trackpad navigation for columns/workspaces. It is
independent from SkyLight and can be disabled with `trackpad_navigation: false`.

## Install and run

Build and run from source:

```bash
git clone https://github.com/dimixar/miri.git
cd miri
swift run miri
```

Build an optimized binary:

```bash
swift build -c release
.build/release/miri
```

For development:

```bash
swift build
swift run miri
```

## Packaging locally

Build a local `.app` bundle:

```bash
scripts/package-app.sh
open dist/Miri.app
```

Build a local Apple Silicon macOS DMG:

```bash
scripts/package-macos.sh --version 0.1.0
open dist/Miri-0.1.0-arm64-darwin.dmg
```

## Default shortcuts

Default shortcuts use **left Option** (`lalt`). Everything else passes through
unless configured otherwise.

| Shortcut | Action |
| :-- | :-- |
| `LAlt+1`..`LAlt+9` | Focus workspace by dynamic index |
| `LAlt+0` | Focus previous workspace |
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
| Three-finger trackpad swipe | Navigate columns / workspaces |

## Menu bar and settings

The menu bar item shows the workspace strip and exposes:

- current workspace, focused window, and active width;
- occupied workspace summaries with app names/icons;
- **Settings…** for the GUI config editor;
- **Open Config**, **Reload Config**, and **Rescan Windows**;
- **Quit Miri**, which performs normal window restoration.

The settings editor writes to the active JSON config and reloads miri in place.
It covers layout, focus behavior, animation options, fullscreen/Space recovery,
logical Space autosave, trackpad tuning, window rules, excluded shortcuts, and
command keybindings.

## Configuration

miri loads the first readable config from:

1. `MIRI_CONFIG`
2. `./miri.config.json`
3. `$XDG_CONFIG_HOME/miri/config.json`
4. `~/.config/miri/config.json`

The active config file is watched. Valid JSON changes are hot-reloaded; if a
save cannot be parsed, miri keeps running with the previous config.

The repository includes a full default [`miri.config.json`](miri.config.json).
A compact example:

```json
{
  "default_width_ratio": 0.67,
  "preset_width_ratios": [0.33, 0.5, 0.67, 1.0],
  "animation_strategy": "snapshot",
  "animation_fps": 60,
  "hover_to_focus": true,
  "focus_alignment": "smart",
  "new_window_position": "after_active",
  "workspace_auto_back_and_forth": true,
  "excluded_keybindings": ["cmd+shift+5"],
  "keybindings": {
    "column_left": ["lalt+h"],
    "column_right": ["lalt+l"],
    "workspace_down": ["lalt+j"],
    "workspace_up": ["lalt+k"]
  },
  "trackpad_navigation": true,
  "restore_on_exit": true,
  "persist_layout": true,
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

### Keybindings

`keybindings` is merged with built-in defaults by action name, so a config can
override only selected actions. Set an action to `[]` to disable it.
`excluded_keybindings` always wins.

Supported modifier names include `cmd`, `win`, `windows`, `super`, `meta`,
`ctrl`, `shift`, `alt`, `option`, side-specific `lalt`/`ralt`, and `fn`/`globe`.
Common aliases are supported for arrows, navigation keys, page keys, function
keys, and punctuation. See [`miri.config.json`](miri.config.json) for the full
default command list.

### Common string settings

- `animation_curve`: `smooth`, `snappy`, or `linear`
- `animation_strategy`: `snapshot` or `off`
- `hover_focus_mode`: `off`, `visible_only`, or `edge_or_visible`
- `focus_alignment`: `left`, `center`, or `smart`
- `new_window_position` / rule `open_position`: `before_active`,
  `after_active`, or `end`
- `trackpad_navigation_snap`: `nearest_column`, `nearest_visible`, or `none`
- `width_resize_mode`: `default` or `intelligent`
- `workspace_bar_overflow_style`: `plus_count`, `dots_count`, `chevron`, or
  `none`

### Rules

Rules can match on `bundle_id`, `app_name`, or `title_contains`.

- `behavior: "ignore"`: leave matching windows alone.
- `behavior: "float"`: keep matching windows visible but untiled.
- `behavior: "tile"`: force matching windows into the tiled model.
- `width_ratio`: override the default column width.
- `workspace`: open on a specific Miri workspace.
- `open_position`: choose where matching windows are inserted.
- `trackpad_navigation` and `hover_to_focus`: override those features for
  matching windows.

## Native macOS Space handling

miri does not ask macOS for private Space IDs. Instead, it infers a logical
macOS Space context from currently visible/manageable windows. Each logical
context owns its own Miri workspaces, columns, floating windows, active
workspace, scroll offsets, and visible window signature.

On `NSWorkspace.activeSpaceDidChangeNotification`, miri saves the current
context, waits briefly, rescans visible Accessibility windows, and activates the
best matching context. Matching prefers raw window IDs, then falls back to
persistent window identity when needed.

Moved windows are handled non-destructively. If a known live window disappears
because it moved to another native Space, miri buffers its old placement and
reattaches it when the window appears in another context.

## Persistence and recovery

With `persist_layout` enabled, miri writes state under `$XDG_STATE_HOME/miri/` or
`~/.local/state/miri/` by default:

- `layout.json`: global layout fallback with tiled window identities,
  workspace/column positions, active workspace, scroll offsets, manual widths,
  and focused window.
- `logical-spaces.json`: inferred macOS Space contexts with logical IDs,
  signatures, tiled placements, floating order, raw window IDs where available,
  and persistent window identities.

Set `state_path` to override the `layout.json` location. `logical-spaces.json`
is stored next to it.

Logical Space persistence is intentionally conservative. Contexts are saved on
normal quit and by `logical_space_autosave_interval_minutes` when miri is not in
a fullscreen guard, fullscreen transition, pending Space switch, or moved-window
buffer state.

## Project structure

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

## Notes and limitations

- miri uses public Accessibility APIs for core window control.
- Snapshot animations need Screen Recording permission because they capture
  window images.
- SkyLight floating-window level changes are private; when unavailable, floating
  windows may fall back to normal raise/focus behavior.
- Trackpad navigation uses Apple's private MultitouchSupport framework and may
  need updates across macOS releases.
- Native macOS Space handling is inferred from visible windows. If two Spaces
  contain indistinguishable sets of windows, miri may not be able to tell them
  apart without private Space IDs.
- Mission Control, Exposé-like transitions, and fullscreen enter/exit can expose
  partial Accessibility snapshots. miri freezes during common cases, but unusual
  transitions may still need a later rescan.

## Related documentation

- Original archived inspiration: https://github.com/maria-rcks/miri
- Research notes: [docs/macos-window-management-investigation.md](docs/macos-window-management-investigation.md)
- Niri behavior notes: [docs/niri-mvp-behavior-notes.md](docs/niri-mvp-behavior-notes.md)
- Local change notes: [docs/feature-local-branch-changes.md](docs/feature-local-branch-changes.md), [docs/animation-revamp-branch-changes.md](docs/animation-revamp-branch-changes.md), [docs/intelligent-width-resize-report.md](docs/intelligent-width-resize-report.md), [docs/miri-refactoring-summary.md](docs/miri-refactoring-summary.md)
