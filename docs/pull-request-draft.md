# Pull request draft

## Suggested title

```text
Refactor Miri source layout and add app UI/stability improvements
```

## Suggested pull request body

```markdown
## Disclaimer

I do **not** recommend merging this PR as-is.

This branch contains a very large set of changes, including source reorganization, UI additions, packaging, configuration changes, and stability fixes. It will almost certainly create substantial merge conflicts with ongoing work.

The intended use of this PR is as a **reference implementation** and as a checklist of stability/UX work that would make Miri more pleasant to use. Individual pieces should be reviewed, split out, and ported selectively instead of merging the branch wholesale.

## Summary

This PR refactors Miri from a large single-coordinator source file into focused domain files and folders, while preserving the existing coordinator-oriented architecture.

It also includes the feature work from `feature/local`: a menu bar accessory app experience, settings UI, richer configuration, layout/persistence stability fixes, improved input/keybinding support, and macOS packaging.

Refactoring session:
https://pi.dev/session/#b109e38490f0e70c93bca2a02e3b86b4

## Highlights

- Split the previous large `Miri.swift` implementation into focused `extension Miri` files
- Organized sources by domain:
  - `Core`
  - `Config`
  - `Input`
  - `Trackpad`
  - `Layout`
  - `Windows`
  - `Persistence`
  - `UI`
  - `Debug`
  - `System`
- Added a menu bar status item and workspace bar
- Added an AppKit settings window for editing config, rules, and keybindings
- Improved minimize, hide, fullscreen, destroyed-window, transient-window, and persistent-layout behavior
- Added richer keybinding support, including left/right Option, navigation keys, function keys, and `fn`/Globe handling
- Added event tap recovery when macOS disables the tap
- Added macOS app/DMG packaging support
- Added documentation for the feature branch and refactor

## Detailed changes

### Source refactor

The previous large Miri coordinator file mixed lifecycle, config, input, window discovery, layout, animation, persistence, status UI, debug logging, and AX observer logic.

This PR keeps `Miri` as the central coordinator, but moves cohesive behavior into focused files such as:

- `Sources/Miri/Core/MiriCommands.swift`
- `Sources/Miri/Core/MiriStatusProvider.swift`
- `Sources/Miri/Input/MiriEventTap.swift`
- `Sources/Miri/Input/KeybindingResolver.swift`
- `Sources/Miri/Layout/MiriLayoutApplication.swift`
- `Sources/Miri/Layout/MiriLayoutAnimation.swift`
- `Sources/Miri/Windows/MiriWindowDiscovery.swift`
- `Sources/Miri/Windows/MiriWindowPlacement.swift`
- `Sources/Miri/Windows/MiriAXObserver.swift`
- `Sources/Miri/Persistence/MiriPersistentLayout.swift`
- `Sources/Miri/Persistence/MiriExitRestoration.swift`

The refactor is documented in:

- `docs/miri-refactoring-summary.md`

### App UI and settings

This branch turns Miri into a more user-facing macOS accessory app:

- starts an accessory `NSApplication`
- adds a menu bar status item
- shows active workspace/window state
- adds menu actions for reload, rescan, settings, config, and quit
- adds a settings window for general, layout, focus, animation, trackpad, rule, and keybinding configuration
- adds a configurable workspace bar with app icons and overflow indicators

### Configuration and keybindings

- Default keybindings move from Command-based shortcuts to left Option-based shortcuts
- Keybinding normalization supports generic/left/right Option variants
- Added broader support for letters, punctuation, arrows, navigation keys, function keys, and `fn`/Globe
- Added MacBook `fn` navigation aliases such as `fn+left` matching `home`
- Added config/settings support for animation throttling and workspace bar options

### Layout, persistence, and window stability

This PR includes stability improvements for:

- minimized windows
- hidden apps
- fullscreen transitions
- destroyed windows
- Chromium transient and Picture-in-Picture windows
- persistent layout snapshot matching
- reduced layout churn and redundant AX operations
- event tap recovery after macOS disables the tap

It also ports selected main-branch fixes into the refactored source layout, including:

- floating-window stacking via SkyLight window levels
- animation visibility tracking for windows entering/leaving a layout
- richer input/keybinding handling

### Packaging

Adds release/local packaging support:

- `.github/workflows/release.yml`
- `scripts/package-macos.sh`
- `scripts/package-app.sh`

`package-app.sh` now delegates to `package-macos.sh` while preserving the local development output at:

```text
dist/Miri.app
```

## Documentation

Added/updated docs:

- `docs/feature-local-branch-changes.md`
- `docs/miri-refactoring-summary.md`

These describe the original feature branch changes, the refactoring, and the manually ported main-branch work.

## Validation

Tested locally:

- [x] `swift build`
- [x] `scripts/package-app.sh`

## Notes for reviewers

Selected main-branch changes were hand-ported instead of cherry-picked because this branch significantly reorganizes the source tree.

The source refactor is mostly structural: behavior was kept in `extension Miri` files to preserve the existing coordinator model while making the code easier to navigate and review by domain.
```
