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

## Status

miri is source-first software for users who are comfortable building and running
Swift tools locally. GitHub Releases are not part of the current project flow;
use the Swift commands or local packaging scripts below.

## Features

- **Niri-like columns.** A keyboard-first horizontal column layout for macOS.
- **Virtual workspaces.** Independent Miri workspaces with per-workspace focus
  and scroll state.
- **Logical Space contexts.** Separate Miri state per inferred macOS Space,
  without depending on private Space IDs.
- **Event-driven discovery.** Startup does a full scan; normal updates are
  driven by NSWorkspace and AX events with a long safety reconciliation timer.
- **Active stale-window recovery.** Known problematic apps can be targeted for
  extra rescans while tiled, improving UX when they miss Accessibility events.
  This is a mitigation for broken app behavior, not a guarantee that those apps
  will tile predictably.
- **Persistent layout state.** Saved column positions, manual widths, focus, and
  logical Space state across restarts.
- **Snapshot transitions.** Window movement and resizing animations using
  captured snapshots and final Accessibility placement.
- **Precise window rules.** Rule matching and behavior overrides for apps and
  individual window titles.
- **Small private API surface.** Core window management stays Accessibility-led,
  with private APIs reserved for narrow macOS gaps.

## Requirements

- macOS 13 or newer.
- Swift 6 toolchain.
- Accessibility permission for window management.
- Input Monitoring permission may be needed for the `event_tap` shortcut
  backend.
- Screen Recording permission is needed for snapshot animations.

If you run miri from a terminal, macOS may request permissions for that terminal
app rather than for a packaged `Miri.app`.

## Install And Run

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

## Packaging Locally

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

## Default Shortcuts

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

Shortcut handling can use either a CG event tap or Carbon registered hot keys.
See [Configuration](docs/configuration.md#shortcuts).

## Menu Bar And Settings

The menu bar item shows the workspace strip and exposes:

- current workspace, focused window, and active width;
- occupied workspace summaries with app names/icons;
- fullscreen app indicators grouped by source workspace;
- **Settings...** for the GUI config editor;
- **Open Config**, **Reload Config**, and **Rescan Windows**;
- **Quit Miri**, which performs normal window restoration.

The settings editor writes to the active JSON config and reloads miri in place.
It covers layout, animation, fullscreen/Space recovery, logical Space autosave,
active rescans for problematic apps, window rules, excluded shortcuts, and
command keybindings.

## Configuration

miri loads the first readable config from:

1. `MIRI_CONFIG`
2. `./miri.config.json`
3. `$XDG_CONFIG_HOME/miri/config.json`
4. `~/.config/miri/config.json`

The repository includes a complete default [`miri.config.json`](miri.config.json).
See [Configuration](docs/configuration.md) for setting descriptions, shortcut
backend tradeoffs, active-rescan reliability settings, rule syntax, and menu bar
options.

## Architecture

The code is split by domain:

```text
Sources/Miri/Core/          coordinator, commands, status providers
Sources/Miri/Config/        config model and effective settings
Sources/Miri/Input/         event tap, Carbon hot keys, keybinding resolution
Sources/Miri/Layout/        projection, geometry, application, animations
Sources/Miri/Windows/       discovery, placement, lookup, transient windows
Sources/Miri/Persistence/   layout persistence and exit/crash restoration
Sources/Miri/UI/            settings window and status menu
Sources/Miri/Debug/         debug logging
Sources/Miri/System/        Accessibility and SkyLight wrappers
```

Read the current architecture notes in [Architecture](docs/architecture.md).

## Documentation

- [Configuration](docs/configuration.md)
- [Architecture](docs/architecture.md)
- [Window discovery and reconciliation](docs/window-discovery-and-reconciliation.md)
- [Snapshot animation](docs/snapshot-animation.md)
- [Troubleshooting](docs/troubleshooting.md)

Historical notes and research:

- [macOS window management investigation](docs/macos-window-management-investigation.md)
- [Niri behavior notes](docs/niri-mvp-behavior-notes.md)
- [Feature branch change log](docs/feature-local-branch-changes.md)
- [Animation revamp branch changes](docs/animation-revamp-branch-changes.md)
- [Intelligent width resize report](docs/intelligent-width-resize-report.md)
- [Refactoring summary](docs/miri-refactoring-summary.md)

## Private API Usage

miri's core window management is Accessibility-based. Moving, resizing,
focusing, discovering, and observing normal app windows are done through public
macOS Accessibility/AppKit APIs where possible.

The project still uses a small private API surface for things macOS does not
expose publicly:

- `_AXUIElementGetWindow`: maps an `AXUIElement` to a `CGWindowID` for more
  reliable matching, persistence, logical Space recovery, debugging, and exit
  restoration.
- `SLSMainConnectionID` and `SLSSetWindowLevel`: set real floating-window levels
  for windows miri treats as floating.

There is no public macOS API for changing another application's window level.
When private calls are unavailable, floating windows may fall back to normal
raise/focus behavior.

## Notes And Limitations

- Native macOS Space handling is inferred from visible windows. If two Spaces
  contain indistinguishable sets of windows, miri may not be able to tell them
  apart without private Space IDs.
- Snapshot animations need Screen Recording permission because they capture
  window images.
- Mission Control-style transitions, fullscreen enter/exit, and unusual
  app-specific AX behavior may still need a later reconciliation pass.
- Active rescans are enabled by default for known problematic apps such as
  Notion. They help recover stale windows when apps miss Accessibility events,
  but apps that report stale/contradictory AX frames can still behave
  unpredictably while tiled, especially during rapid focus movement or multiple
  window changes.
- Disabling active rescans can reduce idle CPU and battery use. Apps that keep
  missing events or reporting bad AX frames should usually be added to window
  rules with `behavior: "ignore"` instead of being tiled.
- Debug logging is verbose and should usually stay disabled outside
  investigation sessions.
