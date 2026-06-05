# Architecture

miri is a source-first macOS window manager built around a small coordinator
object, `Miri`, split into domain extensions. The code is organized by what the
extension owns rather than by framework.

```text
Sources/Miri/Core/          app coordinator, commands, status providers
Sources/Miri/Config/        config model and effective settings
Sources/Miri/Input/         event tap, Carbon hot keys, keybinding resolution
Sources/Miri/Layout/        projection, geometry, AX application, animation
Sources/Miri/Windows/       discovery, placement, lookup, transient windows
Sources/Miri/Persistence/   layout persistence and exit/crash restoration
Sources/Miri/UI/            settings window and status menu
Sources/Miri/Debug/         debug logging
Sources/Miri/System/        Accessibility and SkyLight wrappers
```

## Core Model

miri keeps its own logical model instead of treating the current AX frames as
the source of truth.

- `Workspace`: ordered columns plus active-column and scroll state.
- `ManagedWindow`: AX element, process ID, optional CG window ID, bundle ID,
  app name, title, and width metadata.
- `LogicalSpaceContext`: an inferred native macOS Space context with its own
  Miri workspaces, floating windows, active workspace, and visible signature.

AX is used to discover, focus, move, and resize real app windows. CoreGraphics
window IDs are used to make reconciliation, persistence, Space-context matching,
debugging, and cleanup more stable.

## Event Flow

At startup, miri performs a full scan, installs NSWorkspace and AX observers,
configures input, and starts long-period safety timers.

After startup, the normal path is event driven:

1. NSWorkspace reports app launch, termination, activation, or Space change.
2. AX observers report window creation, destruction, focus, movement, resize,
   minimization, hiding, and showing.
3. miri reconciles the affected process when possible.
4. Layout projection computes logical target frames.
5. Snapshot animation or fallback AX animation presents movement.
6. Final AX frames are applied once the animation has settled.

The periodic reconciliation timer remains as a safety net for missed or delayed
Accessibility notifications.

## Layout Pipeline

`projectLayout` computes a target layout from the current logical state. The
layout code separates three ideas:

- Logical layout: the Miri state that represents requested focus, order,
  widths, workspaces, and floating windows.
- Presentation layout: snapshot-layer frames used while animation is running.
- AX-applied layout: real macOS window frames.

During snapshot animation, miri may focus the requested real window, but it
defers final real-window position and size changes until the animation settles.
This prevents AX frame writes from fighting the overlay animation.

## Native Space Handling

miri does not ask macOS for private Space IDs. It infers logical macOS Space
contexts from visible and manageable windows.

On native Space change, miri saves the current context, waits briefly, rescans
visible AX windows, and chooses the best matching context. Matching prefers
CG window IDs and falls back to persistent window identity when needed.

Moved windows are handled non-destructively. If a known live window disappears
because it moved to another native Space, miri buffers its old placement and
reattaches it when the window appears in another context.

## Private API Scope

Most window control is Accessibility/AppKit-led. Private APIs are limited to
narrow macOS gaps:

- `_AXUIElementGetWindow`: maps an AX element to a `CGWindowID`.
- `SLSMainConnectionID` and `SLSSetWindowLevel`: set real floating-window levels
  for windows miri treats as floating.

There is no public macOS API for changing another application's WindowServer
level. If SkyLight calls are unavailable, floating windows can still be raised
and focused, but they may not stay at a true floating level.

## Files Worth Watching

These files are intentionally dense and are good candidates for future splits
after behavior settles:

- `Sources/Miri/Layout/MiriSnapshotAnimation.swift`
- `Sources/Miri/UI/Settings/SettingsWindowController.swift`
- `Sources/Miri/UI/StatusMenu/StatusMenuController.swift`
- `Sources/Miri/Windows/MiriWindowDiscovery.swift`
- `Sources/Miri/Windows/MiriAXObserver.swift`
