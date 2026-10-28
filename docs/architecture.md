# Architecture

miri is a source-first macOS window manager coordinated by the main-actor
`Miri` application delegate. The coordinator owns event ordering, application
phase, admission, and startup/termination orchestration; stateful domain data
is owned by dedicated controllers.

Only one Miri instance can run per user, including simultaneous login/manual
launches or a command-line launch alongside the app. Extra instances exit before
onboarding, window discovery, or shortcuts start. The lock is released by macOS
on exit or crash; cleanup watchers are exempt so window restoration still works.

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

- `Workspace`: ordered columns plus active-column and scroll state, the
  per-workspace fullscreen override, and per-window presentation suspension.
- `ManagedWindow`: AX element, process ID, optional CG window ID, bundle ID,
  app name, title, width metadata, native macOS `fullscreenOS` state, and the
  independent per-window `fullscreenLayout` designation.
- `LogicalSpaceContext`: an inferred native macOS Space context with its own
  Miri workspaces, floating windows, active workspace, and visible signature.

AX is used to discover, focus, move, and resize real app windows. Target-app
reads, writes, actions, settable checks, observer registration, and private
window-ID mapping are synchronous IPC, so they run outside the main actor on
independent serial per-PID lanes. Local AX identity/value/run-loop operations
remain allowlisted on the main actor. A loading app can consume its 250 ms
global AX messaging timeout without blocking input, layout state, or healthy
applications. Composite reads also have whole-operation budgets, and full scans
have an outer completion deadline. Each PID shares an adaptive circuit breaker
across discovery, focused-window reads, frame writes, focus actions, transient
checks, and observer registration. Superseded frame/focus work is physically removed from lane queues and failed
latest state is retried after recovery. Visible windows are correctively written
even when the cached requested frame is unchanged; stable parked windows may
still skip redundant writes. PID-local lifecycle generations reject stale app
snapshots, a global generation invalidates full scans across native Space or
session boundaries, and a separate global focus-adoption generation rejects
A→B→A activation races. Discovery never adopts focus directly; an authoritative
frontmost-PID probe may use its fresh result, a still-managed cached focused
identity, or the sole managed window for that PID. Snapshot animation shows the
overlay before parking real windows, waits for bounded parking results before
starting the frame runner, and waits for final AX application before removing
the overlay.
CoreGraphics window IDs and bounds provide geometry data for reconciliation,
persistence, Space-context matching, debugging, and cleanup. Private AX-to-ID
mapping is optional worker-side enrichment and does not gate focused-window or
notification snapshots.

## Event Flow

At startup, the coordinator starts session and NSWorkspace observers, configures input,
and performs a full window scan only if the console session is available and a
bounded transient-window refresh admits it. A currently active transient dialog
causes the startup gate to retry rather than permanently losing initial discovery.
AX observers are attached as regular applications are discovered. Long-period
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
5. miri adopts a managed focused column only from the globally frontmost
   application. Cmd-Tab activation performs a fresh frontmost-validated read
   and re-projects the adopted column even when logical focus was unchanged.
   App-local focus notifications from background processes may inform discovery
   but cannot change layout focus.
6. Layout projection computes logical target frames using the configured focus
   alignment policy.
7. Snapshot animation presents movement when configured; `off` applies final
   AX frames immediately while retaining the layout/reconciliation lock.
8. Final AX frames are committed once presentation work has settled.

The periodic reconciliation timer remains as a safety net for missed or delayed
Accessibility notifications. Application enumeration runs in one-window lane
turns; a bounded partial pass advances a rotating per-PID cursor and uses the
same bounded settling window to continue discovering large healthy applications.
Persistent startup placement is applied incrementally to newly discovered
windows without reapplying already-restored windows. The launch-settling deadline
is retired after 30 seconds and cannot restart for that PID until the application
terminates, except that a session pause cancels it in a restartable state. A
relaunch receives a new PID and a fresh settling period.

## Termination And Cleanup

Normal termination first closes AX admission, cancels presentation work, and
quiesces all existing PID lanes without orphaning running jobs. Tiled-window
frames are then restored in independent per-PID batches under one global
termination deadline. Compositor transforms and window levels are normalized
without target-app AX IPC. The restore snapshot and cleanup watcher are removed
only when every requested PID succeeds.

Before each layout projection and lifecycle save, miri writes a versioned exit
snapshot containing window ID, owner PID, tiled/floating kind, and viewport. If
normal restoration is incomplete or the process exits abruptly, the standalone
watcher restores only relevant owner PIDs in parallel. It changes AX frames only
for tiled windows; floating windows retain their geometry while compositor
state is normalized.

## Session Availability Flow

Screen lock, inactive-console-session, and system-sleep signals suspend layout
tracking. miri invalidates reconciliation generations and timers, supersedes
queued AX/layout work, resets per-PID circuit health, and quiesces in-flight AX
lanes before finalizing the pause. Snapshot presentation is frozen during that
bounded quiescence; parked real windows are restored with nonblocking compositor
moves before the overlay is removed. Discovery, AX notifications, and layout
application remain ignored while the session is unavailable.

An unlock, login activation, or wake signal makes the session eligible but does
not immediately restart layout work. When windows are known, miri temporarily
watches for a mouse press or scroll targeting a relevant on-screen window, a key
press directed to the focused managed window, or a registered Carbon hot key
with a managed window in focus. Lock/login UI input cannot release this guard
because both console state and the target window are validated. Focused and
hit-window AX validation runs on the target PID lane rather than the main actor.

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

If the whole runtime window model is empty, miri instead attempts recovery
automatically and retries every half-second while the session/transient guards
block it. Floating, fullscreen, minimized, and Space-buffered windows count as
known state; saved layout metadata alone does not. Startup and successful
empty-model recovery also open a 30-second discovery settling period, requesting
full rescans every second without superseding a full scan still in progress.
This captures apps and windows restored after the first scan. An empty scan does
not re-enable the interaction requirement. Lock, sleep, or termination cancels
the settling work; afterward, normal observation and periodic rescans take over.

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

`LayoutController` delegates image capture to `WindowSnapshotCapturer`, using
ScreenCaptureKit's macOS 26 `SCScreenshotManager.captureScreenshot` API. Each
batch enumerates shareable windows once, including offscreen windows, and
captures each matching window independently with at most three requests in
flight. Capture is asynchronous; the resulting in-memory images feed the
existing layer animation rather than a continuous stream. CoreGraphics remains
in use for window metadata, not screenshot capture.

Submissions received during capture or parking are coalesced to the newest
request. After preparation, animated requests can retarget existing layers;
only missing layers need additional captures. Cancellation and request tokens
prevent late results from modifying a superseded or unavailable session. See
[Snapshot animation](snapshot-animation.md) for configuration and failure policy.

During snapshot animation, miri may focus the requested real window, but it
defers final real-window position and size changes until the animation settles.
Preparation still parks real windows under the overlay. This prevents normal
layout frame writes from fighting the overlay animation.

## Layout Fullscreen State

`WindowManagement.fullscreenState(in:)` resolves the effective presentation from
`layout_fullscreen_mode`. Per-workspace mode uses `Workspace.fullscreenState`
(`off`, `active`, or `suspended`). Per-window mode uses the workspace's active
window's `fullscreenLayout` flag, with presentation suspended while floating or
unmanaged focus is active. Refocusing a tiled window resumes only its own state.
The mode is read from the current config, so changes apply without recreating
the window model.

`WorkspaceModelSnapshot` carries this resolved presentation into
`LayoutState.fullscreenWorkspaces`. The layout engine projects the active row
across the viewport and hides its peers without changing the stored column
widths, row shares, or order. Moving focus to a normal window returns to normal
tiling; moving to another fullscreen window preserves fullscreen presentation.

Keyboard boundary routing resolves vertical focus shortcuts before arming the
existing hold gate. Per-workspace mode and the per-window default route directly
to workspace navigation. Per-window `focus_windows_first` allows an available
row in the requested direction, then falls back to workspace navigation at the
edge. Fullscreen workspace fallback preserves the destination's remembered row.
The existing hold duration, repeat handling, and focus validation still apply.

The workspace bar consumes the same resolved state. In per-window mode it marks
only a workspace whose focused window has an active fullscreen presentation.
Inactive workspaces retain their last focused window and indicator; an
unfocused peer's fullscreen designation alone does not mark the workspace.

Per-window designations belong to live AX identities. A runtime registry
restores the flag when discovery creates another wrapper for the same window,
including after minimization or native fullscreen. Title or app-name matches
cannot transfer this designation to another window. Destruction, process
termination, explicit floating, or toggling off clears it. Layout fullscreen
state is not serialized across Miri restarts.

Native macOS fullscreen remains independent: `AXWindowReadSnapshot.fullscreenOS`
and `ManagedWindow.fullscreenOS` describe `AXFullScreen`.
`FullscreenOSWindowState`, `fullscreenOSWindowStates`, and pending native
transition records preserve placement while macOS moves that window to a native
fullscreen Space. Miri's layout fullscreen does not create or switch native
Spaces. See [configuration](configuration.md#layout-fullscreen) for the settings.

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

- `_AXUIElementGetWindow`: maps an AX element to a `CGWindowID`; it is invoked
  only as optional enrichment inside an isolated PID worker.
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
- `AXEnhancedUserInterface`, temporarily disabled while frames are applied only
  when it was already enabled and readable; its previous value is restored
  immediately afterward.

There is no public macOS API for changing another application's WindowServer
level or compositor position. If SkyLight calls are unavailable, floating
windows can still be raised and focused, while exact parking becomes
best-effort. The private symbols are dynamically resolved so their absence is
non-fatal; the undocumented notifications, properties, and attributes remain
macOS-version-sensitive.

If private AX-to-window-ID mapping is absent, identity matching and recovery
use weaker fallbacks rather than failing window management.

CoreGraphics session dictionaries, NSWorkspace session/sleep notifications, CG
event taps and fields, CoreGraphics window-list metadata, and ScreenCaptureKit
screenshot capture are public SDK APIs.

## Files Worth Watching

These files are intentionally dense and are good candidates for future splits
after behavior settles:

- `Sources/Miri/Layout/MiriSnapshotAnimation.swift`
- `Sources/Miri/UI/Settings/SettingsWindowController.swift`
- `Sources/Miri/UI/StatusMenu/StatusMenuController.swift`
- `Sources/Miri/Windows/MiriWindowDiscovery.swift`
- `Sources/Miri/Windows/MiriAXObserver.swift`
