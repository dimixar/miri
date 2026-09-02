# Architecture

miri is a source-first macOS window manager coordinated by the main-actor
`Miri` application delegate. The coordinator owns event ordering, application
phase, admission, and startup/termination orchestration; stateful domain data
is owned by dedicated controllers.

The current architecture is designed and tested for one active display: a
MacBook using only its built-in screen. It does not maintain independent layout
models or viewport ownership for multiple displays.

```text
Sources/Miri/Core/          coordinator, typed events, commands, status snapshots
Sources/Miri/Config/        ConfigStore, config model, effective settings
Sources/Miri/Input/         InputController, keybinding and recovery policy
Sources/Miri/Layout/        LayoutController, geometry, AX application, animation
Sources/Miri/Windows/       WindowManagement, observation, reconciliation, placement
Sources/Miri/Persistence/   PersistenceController and restoration documents
Sources/Miri/UI/            action-sink settings and status controllers
Sources/Miri/Debug/         debug logging
Sources/Miri/System/        SessionController, Accessibility and SkyLight wrappers
```

All stateful application components are main-actor isolated. Components emit
typed facts or requests to the coordinator and do not retain one another. The
layout controller receives narrow query/action closures instead of retaining
the coordinator. The only unchecked cross-thread wrappers are the
lock-protected display-link adapter, the synchronous main-run-loop callback
value bridge, and the low-level SkyLight wrapper.

## Core Model

miri keeps its own logical model instead of treating the current AX frames as
the source of truth.

- `Workspace`: ordered columns plus active-column and scroll state.
- `ManagedWindow`: AX element, process ID, optional CG window ID, bundle ID,
  app name, title, and width metadata.
- `LogicalSpaceContext`: an inferred native macOS Space context with its own
  Miri workspaces, floating windows, active workspace, and visible signature.

AX is used to discover, focus, move, and resize real app windows. Those calls
are synchronous IPC into each target application, so interactive AX work runs
outside the main actor on independent serial per-PID lanes. A loading app can
consume its 250 ms global AX messaging timeout without blocking input, layout
state, or healthy applications. Each PID shares an adaptive circuit breaker
across discovery, focused-window reads, frame writes, focus actions, transient
checks, and observer registration. Superseded frame/focus work is discarded,
failed latest state is retried after recovery, and unchanged frame targets are
not written. Lifecycle and focus generations reject snapshots invalidated while
AX work was in flight; discovery never adopts focus directly, and only a fresh
frontmost-PID probe may change logical focus. Snapshot animation waits for the
first bounded parking/restoration result before exposing or removing overlays.
CoreGraphics window IDs and bounds provide nonblocking identity and geometry
data for reconciliation, persistence, Space-context matching, debugging, and
cleanup.

## Event Flow

At startup, the coordinator starts session and NSWorkspace observers, configures input,
and performs a full window scan only if the console session is available. AX
observers are attached as regular applications are discovered. Long-period
safety timers run only while layout tracking is allowed.

External callbacks first emit a typed `AppEvent`. The coordinator drains those
events through a non-reentrant FIFO on the main actor, admits or coalesces
reconciliation, and invokes the owning component. After startup, the normal
path is event driven with one bounded polling phase for newly launched
applications:

1. NSWorkspace reports app launch, termination, activation, or Space change.
2. A regular-app launch records that process lifetime and starts a 30-second
   per-PID settling deadline. One shared timer reconciles only settling PIDs
   once per second, continuing after the first window appears so later windows
   and changing rule metadata are adopted. A valid new window is accepted
   immediately; a previously managed window missing from a scan receives a
   short grace period before removal.
3. AX observers report window creation, destruction, focused/main-window
   changes, movement, resize, minimization, hiding, and showing.
4. Mouse clicks and Command-based window switching schedule a debounced,
   asynchronous focused-window probe as a fallback for applications that miss
   focus events. Hot-key admission itself reads only cached transient-window
   state and never waits for AX IPC.
5. miri adopts a different managed focused column only from the globally
   frontmost application. App-local focus notifications from background
   processes may inform discovery but cannot change layout focus.
6. Layout projection computes logical target frames using the configured focus
   alignment policy.
7. Snapshot animation presents movement when configured; `off` applies final
   AX frames immediately while retaining the layout/reconciliation lock.
8. Final AX frames are committed once presentation work has settled.

The periodic reconciliation timer remains as a safety net for missed or delayed
Accessibility notifications. The launch-settling deadline is retired after 30
seconds and cannot restart for that PID until the application terminates. A
relaunch receives a new PID and a fresh settling period.

## Session Availability Flow

Screen lock, inactive-console-session, and system-sleep signals suspend layout
tracking. miri invalidates reconciliation generations and timers, supersedes
queued AX/layout work, resets per-PID circuit health, and quiesces in-flight AX
lanes before finalizing the pause. Snapshot presentation is frozen during that
bounded quiescence; parked real windows are restored with nonblocking compositor
moves before the overlay is removed. Discovery, AX notifications, and layout
application remain ignored while the session is unavailable.

An unlock, login activation, or wake signal makes the session eligible but does
not immediately restart layout work. miri temporarily watches for a mouse press
or scroll targeting a relevant on-screen window, a key press directed to the
focused managed window, or a registered Carbon hot key with a managed window in
focus. Lock/login UI input cannot release this guard because both console state
and the target window are validated. Focused and hit-window AX validation runs
on the target PID lane rather than the main actor.

After a qualifying interaction, the coordinator enters a distinct recovering
phase. It refreshes transient-window state against the current active PID set,
waits for pause quiescence, clears stale frame/visibility/focus caches, obtains
a fresh frontmost focused-window identity, and completes one current full
rescan. Only then does it return to running, restart safety timers, and replay a
queued triggering command. Regular applications launched while waiting are
remembered so their first valid window interaction can qualify. After recovery,
each remembered live application also receives its own 30-second
launch-settling period. Any settling periods that were already running when the
session became unavailable are cancelled rather than rearmed after unlock or
wake.

## Layout Pipeline

`projectLayout` computes a target layout from the current logical state. The
layout code separates three ideas:

- Logical layout: the Miri state that represents requested focus, order,
  widths, workspaces, and floating windows.
- Presentation layout: snapshot-layer frames used while animation is running.
- AX-applied layout: real macOS window frames.

Workspace numbers are stable within a logical Space context. Miri maintains
the configured `minimum_workspace_count`, creates every missing slot through a
higher destination when a column or rule targets it, and removes only unused
trailing dynamic workspaces. Interior empty slots are retained so occupied
workspaces cannot be renumbered. Selecting an empty workspace gives it temporary
focus authority: stale AX focus and reconciliation signals cannot return to a
parked window, and the authority is retired when a new window is inserted into
the selected workspace.

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
because it moved to another native Space, miri buffers the window and its source
logical-Space context. When the window appears in another context, miri removes
any stale source-context reference and adopts it through normal placement.

## Private And Undocumented API Scope

Most window control is Accessibility/AppKit-led. Private APIs are limited to
narrow macOS gaps:

- `_AXUIElementGetWindow`: maps an AX element to a `CGWindowID`.
- `SLSMainConnectionID`, `SLSSetWindowLevel`, `SLSTransactionCreate`,
  `SLSTransactionMoveWindowWithGroup`, `SLSTransactionCommit`,
  `SLSGetWindowShadowAndRimParameters`, `SLSMoveWindow`, and
  `SLSGetWindowTransform`/`SLSSetWindowTransform`: maintain true
  floating-window levels and correct parked positions and shadow outsets when
  Accessibility placement is constrained.

miri also consumes undocumented system contracts rather than private callable
symbols:

- `com.apple.screenIsLocked` and `com.apple.screenIsUnlocked` distributed
  notifications, plus the `IOConsoleLocked` IORegistry property, for lock-state
  monitoring and guarded session recovery.
- `AXFullScreen` for native fullscreen detection.
- `AXEnhancedUserInterface`, conditionally and temporarily toggled while frames
  are applied.

There is no public macOS API for changing another application's WindowServer
level or compositor position. If SkyLight calls are unavailable, floating
windows can still be raised and focused, while exact parking becomes
best-effort. The private symbols are dynamically resolved so their absence is
non-fatal; the undocumented notifications, properties, and attributes remain
macOS-version-sensitive.

CoreGraphics session dictionaries, NSWorkspace session/sleep notifications, CG
event taps and fields, and CoreGraphics window-list/image functions used by miri
are public SDK APIs despite being relatively low-level.

## Files Worth Watching

These files are intentionally dense and are good candidates for future splits
after behavior settles:

- `Sources/Miri/Layout/MiriSnapshotAnimation.swift`
- `Sources/Miri/UI/Settings/SettingsWindowController.swift`
- `Sources/Miri/UI/StatusMenu/StatusMenuController.swift`
- `Sources/Miri/Windows/MiriWindowDiscovery.swift`
- `Sources/Miri/Windows/MiriAXObserver.swift`
