# Window Discovery And Reconciliation

miri tries to avoid constant polling. It scans on startup and then relies on
NSWorkspace and AX events, with a long safety timer for missed notifications.

## Startup

Startup performs a full discovery pass:

1. Iterate regular running applications.
2. Read each app's `AXWindows`.
3. Filter out hidden, minimized, fullscreen, unknown-subrole, transient, and
   ignored windows.
4. Convert accepted AX elements into `ManagedWindow` values.
5. Restore persisted layout and logical Space context when available.

This full scan gives miri a baseline before event-driven updates begin.

## App Events

NSWorkspace events provide process-level signals:

- Launch: start observing the app and schedule the same coalesced settle
  sequence used for delayed created windows.
- Activation: adopt focus and reconcile the app.
- Termination: remove windows for that process or defer removal until layout is
  safe.
- Native Space change: save the current logical Space context, wait briefly,
  then rescan visible windows to activate the best matching context.

## AX Events

AX observers provide window-level signals:

- `AXCreated`
- `AXUIElementDestroyed`
- `AXFocusedWindowChanged`
- `AXWindowMoved`
- `AXWindowResized`
- `AXWindowMiniaturized`
- `AXWindowDeminiaturized`
- `AXApplicationHidden`
- `AXApplicationShown`

When layout or snapshot animation is busy, miri queues affected process IDs and
drains that queue after the animation and layout lock settle. This keeps
window-list changes from mutating the real layout while the snapshot overlay is
still presenting a movement.

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
used when a queued event explicitly requires global reconciliation.

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
- `snapshot missing image`: snapshot capture failed for a tracked window and
  queued targeted PID reconciliation.
- `active rescan reason=...`: optional active rescan ran for a configured
  bundle currently present in the tiled layout.
- `removing vanished window`: CG fallback removed a stale tracked window.
- `layout workspace=...`: layout projection and application happened.
