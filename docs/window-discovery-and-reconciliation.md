# Window Discovery And Reconciliation

miri tries to avoid constant polling. It scans on startup when the user session
is available and then relies on NSWorkspace and AX events, with a long safety
timer for missed notifications.

## Startup

Startup performs a full discovery pass:

1. Iterate regular running applications.
2. Read each app's `AXWindows`.
3. Filter out hidden, minimized, fullscreen, unknown-subrole, transient, and
   ignored windows.
4. Convert accepted AX elements into `ManagedWindow` values.
5. Restore persisted layout and logical Space context when available.

This full scan gives miri a baseline before event-driven updates begin. If miri
starts while the screen is locked, the console session is inactive, or the Mac
is sleeping, discovery waits for session recovery instead.

## App Events

NSWorkspace events provide process-level signals:

- Launch: start observing the app and schedule the same coalesced settle
  sequence used for delayed created windows.
- Activation: reconcile the previously active app, then reconcile and adopt
  focus for the newly active app. This catches windows that vanished while their
  former app was frontmost. The delayed activation settle verifies that the app
  is still globally frontmost before adopting its focused window.
- Termination: remove windows for that process or defer removal until layout is
  safe.
- Native Space change: save the current logical Space context, wait briefly,
  then rescan visible windows to activate the best matching context.

## AX Events

AX observers provide window-level signals:

- `AXCreated`
- `AXUIElementDestroyed`
- `AXFocusedWindowChanged`
- `AXMainWindowChanged`
- `AXWindowMoved`
- `AXWindowResized`
- `AXWindowMiniaturized`
- `AXWindowDeminiaturized`
- `AXApplicationHidden`
- `AXApplicationShown`

`AXFocusedWindowChanged` and `AXMainWindowChanged` describe focus inside the
emitting application; they are not proof that the application is globally
frontmost. miri therefore adopts those signals only when the emitting PID
matches `NSWorkspace`'s current frontmost application. Non-frontmost signals
may still schedule discovery for an unknown manageable window, but they cannot
change the active layout column.

When layout or snapshot animation is busy, miri queues affected process IDs and
drains that queue after the animation and layout lock settle. Authoritative
focus and main-window signals are queued too instead of being discarded. This
keeps window-list changes from mutating the real layout while frames are being
applied and adopts the frontmost application's final focused window afterward.

## Focus Tracking Fallback

Some applications do not reliably emit `AXFocusedWindowChanged` when the user
switches between windows of the already-active app. miri therefore schedules a
lightweight focused-window probe after:

- a left, right, or other mouse-button press; and
- Command+Backtick or Command+Tab.

After an 80 ms settle delay, the probe asks the frontmost application for its AX
focused window. If that window belongs to a different managed layout column,
miri adopts the column and applies the configured focus alignment. If the
focused window is unmanaged or the active column has not changed, no layout is
projected. Rapid inputs are coalesced, and a probe that lands during layout or
snapshot work is deferred through the normal per-PID reconciliation queue.

`AXWindowMiniaturized` for a known tiled window is handled immediately when the
layout is safe: miri remembers its placement, removes it from the tiled model,
and projects the remaining windows. Deminiaturization follows the normal
reconciliation path and can restore the remembered placement.

## Session Gating

Discovery and reconciliation stop while the screen is locked, the console
session is inactive, or the system is sleeping. They remain stopped after the
desktop becomes available until a mouse, scroll, keyboard, or registered-hot-key
interaction is validated against a relevant managed window. This avoids using
events from the lock/login UI as evidence that the desktop is ready.

Applications launched during this waiting period are recorded but not scanned
immediately. A valid interaction with one of their manageable windows can
release recovery, after which a full rescan establishes the current model and
restarts periodic and active-rescan timers.

## Created Windows

Some apps emit `AXCreated` before the real window is manageable. Electron,
Chromium-based apps, JetBrains IDEs, and terminal apps often emit small
placeholder windows such as `64x64` title-empty AX windows.

miri treats real, manageable, or plausible first-window `AXCreated` events from
regular apps as process-level hints and schedules a coalesced settle sequence
for that PID. New PIDs get a longer backoff window because apps such as
JetBrains IDEs can expose only placeholder AX windows for several seconds before
their real window is manageable. PIDs that already have managed windows use a
short placeholder probe, rate-limited by
`ax_created_placeholder_probe_cooldown_ms`, so bursts during focus movement do
not build a large reconciliation backlog.

Non-regular apps and helper processes are logged but do not enter the settle
retry path. This avoids spending background work on menu-bar helpers, text input
services, launchers, and other AX-noisy processes that are not tileable app
windows.

If a focused-window notification points at an unknown but manageable window,
miri treats that as another creation hint. This catches apps where focus becomes
the first reliable signal that the window is ready.

This catches delayed real windows without returning to frequent global scans.

## Destroyed And Vanished Windows

If a destroyed AX element matches a known tiled or floating window, miri removes
it immediately and relayouts.

If the destroyed AX element is unknown, miri ignores it. This filters frequent
noise from system helpers such as text input services.

Some apps do not emit a useful destroy event for their real window. In that
case, per-app reconciliation has a CoreGraphics fallback: when AX window
discovery for a PID becomes unavailable, miri checks tracked windows for that
PID by CG window ID and removes any whose CG window no longer exists.

An AX query can also succeed but return structurally invalid data. Telegram has
been observed returning its `AXApplication` root inside `AXWindows` during a
screen-lock transition. Because `AXWindows` should contain window elements,
miri treats the whole response as unreliable and retains the app's known
windows. Merely filtering out the root could turn the transient response into an
apparently empty window list and discard layout order or manual width state.

Notion is known to be inconsistent here. Closing its last window without
quitting the app may produce no useful Accessibility event for the tracked
window: no destroyed, minimized, deminimized, hidden, shown, focused-window, or
main-window change notification. It can also report stale or contradictory AX
frames for multiple real windows, for example distinct windows temporarily
claiming the same position and size. When a tracked window reaches snapshot
animation but CoreGraphics can no longer produce an image for its window ID,
miri treats that missing snapshot image as a stale-window hint and queues a
targeted reconciliation for that PID after layout and snapshot animation are
safe. This keeps the fallback event-driven and avoids reintroducing frequent
global scans.

For apps with this class of missing notifications, `active_rescan_enabled` is
enabled by default with matching `active_rescan_bundle_ids`. While any listed
bundle is present in the tiled layout, miri runs targeted per-PID rescans once
per second and on user input. This redundant work has a small CPU/battery cost,
but it improves UX for apps such as Notion that can otherwise leave stale
windows behind until another event happens.

Active rescans are a mitigation, not a guarantee that a broken Accessibility
implementation becomes well behaved. If an app lies about AX frames, misses
window lifecycle events, or changes several windows while the user rapidly moves
focus, miri may still show unpredictable layout or animation behavior. Users who
want lower idle CPU and battery use can disable active rescans; for problematic
apps, the recommended fallback is adding a window rule with
`behavior: "ignore"` so miri does not tile those windows.

## Full Rescans

Full rescans are still used for startup, native Space changes, config reloads,
explicit menu-bar rescans, and the long reconciliation timer. They are also
used when a queued event explicitly requires global reconciliation and once
after a valid session-recovery interaction. Rescans are ignored while session
tracking is unavailable or still awaiting that interaction.

Routine AX movement, resize, and creation events should prefer targeted per-PID
reconciliation.

## Debug Signals

Useful log lines in `~/.config/miri/debug.log`:

- `raw ax window source=...`: raw AX window details before filtering.
- `window discovered`: a window accepted into the managed model.
- `ax creation reconciliation scheduled`: delayed per-PID creation retry.
- `reconcile skipped reason=...`: per-app reconciliation was deliberately
  skipped, for example because the app was not regular yet or AX was in a
  transient system state.
- `ax reconciliation deferred`: event queued while layout/animation is busy.
- `ax reconciliation draining`: queued PID reconciliation begins.
- `focus adopted reason=focused-window-probe:...`: the input fallback found a
  different managed focused window and adopted its column.
- `ax observer registration failed`: registering an AX notification for an app
  failed; the line includes the PID, notification name, and AX error code.
- `snapshot missing image`: snapshot capture failed for a tracked window and
  queued targeted PID reconciliation.
- `active rescan reason=...`: optional active rescan ran for a configured
  bundle currently present in the tiled layout.
- `ignoring malformed ax-windows response containing AXApplication`: an app
  returned a non-window root from `AXWindows`; known state was preserved.
- `layout tracking paused for unavailable session`: lock, inactive session, or
  sleep suspended discovery and layout work.
- `layout tracking awaiting managed-window interaction`: the desktop is
  available but recovery is still guarded.
- `session recovery requested` / `layout tracking resumed`: a validated target
  released recovery and the rescan completed.
- `removing vanished window`: CG fallback removed a stale tracked window.
- `layout workspace=...`: layout projection and application happened.
