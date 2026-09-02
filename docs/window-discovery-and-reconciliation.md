# Window Discovery And Reconciliation

miri tries to avoid constant polling. It scans on startup when the user session
is available and then relies on NSWorkspace and AX events, with a long safety
timer for missed notifications.

## Ownership And Admission

`WindowObservationController`, owned by `WindowManagement`, exclusively stores
NSWorkspace/AX observers, delayed probes, discovery timers, and their generation
bookkeeping. Callbacks emit typed facts or `ReconciliationIntent` values and do
not mutate the workspace graph or start layout.

The main-actor coordinator is the single reconciliation admission point. It
coalesces pending intent while layout is active, sorts targeted PID batches,
and asks `WindowManagement` to apply the shared missing-window classifier to
the canonical model. Layout and persistence consume immutable snapshots or
narrow queries rather than mutable coordinator forwarding collections.

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

- Launch: track the app PID for a 30-second settling period and reconcile only
  that process once per second. The period continues after the first window is
  found so later windows and changing metadata are still adopted.
- Activation: reconcile the previously active app, then reconcile and adopt
  focus for the newly active app. This catches windows that vanished while their
  former app was frontmost. The delayed activation settle verifies that the app
  is still globally frontmost before adopting its focused window.
- Termination: remove the process from every logical context and transition
  store immediately; defer only the resulting layout/reconciliation work when
  presentation admission is closed.
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
release recovery. Target validation runs asynchronously on the relevant PID
lane. The coordinator then remains in a recovering phase until pre-lock AX work
is quiescent, stale frame/focus caches are reset, a fresh focused identity is
known, and a current full rescan establishes the model. Only after that barrier
does it restart periodic and active-rescan timers or replay queued commands.

## Created Windows

Some apps emit `AXCreated` before the real window is manageable. Electron,
Chromium-based apps, JetBrains IDEs, and terminal apps often emit small
placeholder windows such as `64x64` title-empty AX windows.

miri treats real, manageable, or plausible first-window `AXCreated` events from
regular apps as process-level hints and schedules a coalesced settle sequence
for that PID. Independently, an observed application launch starts a targeted
30-second scan period for its PID. This launch period does not stop when the
first window appears, because apps such as JetBrains IDEs and Electron apps can
expose placeholders or only part of their final window set before settling.
PIDs that already have managed windows use a short placeholder probe,
rate-limited by
`ax_created_placeholder_probe_cooldown_ms`, so bursts during focus movement do
not build a large reconciliation backlog.

During the launch-settling period, a valid new window is adopted immediately.
A previously managed window missing from a scan is retained for a short grace
period before removal, preventing one transiently incomplete AX enumeration
from causing layout churn. The settling state is removed when its deadline
expires or the process terminates, and a new process lifetime receives a fresh
period.

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
per second and after debounced user input. These scans use background-priority
per-PID AX lanes and cannot preempt physical focus/layout work. This redundant
work has a small CPU/battery cost, but it improves UX for apps such as Notion
that can otherwise leave stale windows behind until another event happens.

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
tracking is unavailable or still awaiting that interaction. During recovery,
one full rescan is admitted directly as a completion barrier; normal
reconciliation remains deferred until the coordinator returns to running.

Routine AX movement, resize, and creation events should prefer targeted per-PID
reconciliation. Every asynchronous snapshot carries the PID/global lifecycle
generation observed at submission; hide, minimize, fullscreen, destruction,
launch, termination, and Space changes invalidate older results rather than
allowing them to resurrect stale windows. Focus adoption is a separate fresh
probe validated against the current frontmost PID.

## Debug Signals

Useful log lines in `~/.config/miri/debug.log`:

- `raw ax window source=...`: AX snapshot details captured off the main actor
  before filtering.
- `window discovered`: a window accepted into the managed model.
- `app launch settling started`: an observed regular-app launch opened its
  30-second targeted reconciliation period.
- `reconciliation admitted ... source=launchSettling`: an initial or
  once-per-second scan was admitted for a settling PID.
- `preserving launch-settling window`: a known window was absent from one scan
  and retained during the transient-miss grace period.
- `app launch settling finished`: the deadline expired, the process terminated,
  or the process became unavailable.
- `ax creation reconciliation scheduled`: delayed per-PID creation retry.
- `reconcile skipped reason=...`: per-app reconciliation was deliberately
  skipped, for example because the app was not regular yet or AX was in a
  transient system state.
- `reconciliation deferred`: work was coalesced while layout/animation was
  busy.
- `reconciliation admitted`: reconciliation begins, including work admitted
  after a deferred request drains.
- `reconcile result discarded reason=stale-state`: a lifecycle event invalidated
  an in-flight app snapshot; a current replacement reconciliation was queued.
- `focus adopted reason=focused-window-probe:...`: the input fallback found a
  different managed focused window and adopted its column.
- `ax observer registration failed`: registering an AX notification for an app
  failed; the line includes the PID, notification name, and AX error code.
- `ax operation=... pid=... disposition=...`: a slow, failed, circuit-open, or
  superseded per-PID operation. The line includes AX error, elapsed time, and
  adaptive `retryAfter`; known discovery state remains preserved when the
  operation is unavailable.
- `snapshot missing image`: snapshot capture failed for a tracked window and
  queued targeted PID reconciliation.
- `active rescan reason=...`: optional active rescan ran for a configured
  bundle currently present in the tiled layout.
- `ignoring malformed root-only ax-windows response`: an app returned only a
  non-window root from `AXWindows`; known state was preserved. A malformed mixed
  response instead logs the `accepted windows from malformed mixed ax-windows response`
  message and preserves omitted known windows.
- `layout tracking paused for unavailable session`: lock, inactive session, or
  sleep suspended discovery and layout work.
- `layout tracking awaiting managed-window interaction`: the desktop is
  available but recovery is still guarded.
- `session recovery requested` / `layout tracking resumed`: a validated target
  released recovery and the rescan completed.
- `removing missing window`: reconciliation removed a stale tracked window.
- `layout request=... workspace=...`: layout projection and application began.
