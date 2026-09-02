# Troubleshooting

## Permissions

miri needs Accessibility permission to focus, move, and resize app windows.

The `event_tap` shortcut backend may also require Input Monitoring permission.
The temporary event tap that validates managed-window interaction after an
unlock, login, or wake may need the same permission even with the
`registered_hot_keys` backend. Configured Carbon hot keys remain an alternate
recovery path when a managed window is focused. Snapshot animation needs Screen
Recording permission because it captures window images.

If miri is run from Terminal, iTerm, kitty, or another shell app, macOS may grant
permissions to that terminal app rather than to a packaged `Miri.app`.

## Debug Logs

Set this in config:

```json
{
  "debug_logging": true
}
```

Logs are written to:

```text
~/.config/miri/debug.log
```

Useful commands:

```bash
tail -n 300 ~/.config/miri/debug.log
rg "window discovered|reconciliation (deferred|admitted)|snapshot|layout request=" ~/.config/miri/debug.log
```

## An Unresponsive App Does Not Move

Accessibility operations are synchronous calls into the application that owns
a window, but miri executes interactive AX IPC on independent per-process lanes
rather than on its event loop. Each call remains bounded to 250 ms. A timeout
opens a shared adaptive circuit for that PID, so repeated key presses do not
accumulate more calls while healthy applications continue to move and focus.
Frame and focus requests are coalesced; after recovery, only the latest requested
state is retried. Lifecycle generations also discard reads made stale by a
concurrent hide, minimize, fullscreen, destruction, termination, or Space
change.

With debug logging enabled, check:

```bash
rg "ax operation=.*disposition=" ~/.config/miri/debug.log
```

A discovery timeout preserves known window state instead of treating the app's
temporarily unavailable `AXWindows` response as proof that its windows closed.
Input-triggered active rescans are debounced and run at background priority, so
they do not preempt focus/layout work.

## Miri Appears Paused After Unlock Or Wake

This can be expected briefly. miri deliberately remains paused after the
desktop session becomes available until input targets a relevant window. Click
or scroll an on-screen managed window, type while one is focused, or invoke a
configured Miri Carbon hot key while a managed window is focused. Input on the
lock/login UI does not count.

`SessionController` owns the lock/sleep/console flags, recovery generation, and
recovery event tap. Those fields are main-actor isolated and externally
read-only; the coordinator pauses and resumes other components only after the
controller reports a typed state or recovery event. Recovery remains in a
separate coordinator phase until old AX lanes quiesce and one current full
reconciliation finishes, so queued commands cannot run against the pre-lock
model.

Check the recovery sequence:

```bash
rg "session state|layout tracking|session recovery|malformed ax-windows" ~/.config/miri/debug.log
```

Expected lines include:

- `layout tracking paused for unavailable session`
- `session AX operations quiesced generation=...`
- `layout tracking awaiting managed-window interaction`
- `session recovery requested reason=...`
- `layout tracking resumed reason=...`

If the first two appear but no recovery request follows a valid click, scroll,
or key press, verify Input Monitoring permission for the process actually
running miri. With `registered_hot_keys`, a configured Miri shortcut can test
the independent Carbon recovery path.

## Window Did Not Tile

Check for the app in the log:

```bash
rg "App Name|bundle.id|AXCreated|window discovered|app launch settling" ~/.config/miri/debug.log
```

Common causes:

- The app emitted a placeholder `AXCreated` before the real window was ready.
- The window is minimized, hidden, fullscreen, or has an unknown subrole.
- A rule matched the app or title with `behavior: "ignore"` or `"float"`.
- macOS has not granted Accessibility permission to the process running miri.
- The app does not expose a settable AX position or size.

Look for `raw ax window source=...` and compare `manageable`, `known`, role,
subrole, frame, minimized, and fullscreen fields.

For an application launched while miri is already running, the log should show
`app launch settling started`, followed by an initial reconciliation and
targeted scans once per second for 30 seconds. Scanning deliberately continues
after the first accepted window so secondary windows and late title, role, or
rule metadata changes are still discovered. `app launch settling finished
reason=deadline` confirms the bounded scan period ended normally.

If a previously accepted window disappears from only one launch-settling scan,
miri logs `preserving launch-settling window` and waits through a short grace
period before treating the absence as authoritative. This avoids layout churn
from one transiently incomplete Accessibility enumeration.

## Window Stayed In Layout After Closing

Useful log lines:

- `AXUIElementDestroyed`
- `NSWorkspaceDidTerminate`
- `removing missing window`
- `reconciliation deferred` / `reconciliation admitted`
- `layout request=... workspace=...`

Some apps do not emit useful destroy events for their real windows. miri uses
per-PID reconciliation and a CoreGraphics fallback to remove tracked windows
whose CG window ID no longer exists.

## Problematic App Accessibility Behavior

Some apps expose incomplete or contradictory Accessibility state. Notion is a
known example: it may miss close, minimize, hide, show, focused-window, or
main-window notifications, and it can report stale AX frames for multiple
distinct windows. Active rescans are enabled by default for configured bundles
such as `notion.id`; they rescan the app once per second and on user input while
one of its windows is tiled.

Telegram has also been observed returning an `AXApplication` element from an
`AXWindows` query during screen locking. miri now rejects that enumeration as
unreliable and preserves its existing window/layout state. The corresponding
log line is `ignoring malformed root-only ax-windows response`. A malformed
mixed response logs `accepted windows from malformed mixed ax-windows response`
and preserves known windows missing from that response.

Active rescans are only a recovery aid. They can remove stale windows sooner,
but they cannot make an app's Accessibility frame data correct. If a problematic
app still behaves unpredictably while tiled, especially during rapid focus
movement or multiple window changes, add a window rule with
`behavior: "ignore"` for that app.

## Same-App Window Focus Does Not Move The Layout

miri normally adopts window focus from `AXFocusedWindowChanged` or
`AXMainWindowChanged`. Because some apps miss those notifications when switching
between their own windows, miri also probes the frontmost AX focused window after
mouse-button presses, Command+Backtick, and Command+Tab.

Enable debug logging and check for:

```bash
rg "AXFocusedWindowChanged|AXMainWindowChanged|focused-window-probe|ax observer registration failed|focus adopted" ~/.config/miri/debug.log
```

- `focus adopted reason=focused-window-probe:mouse-down` confirms mouse fallback.
- `focus adopted reason=focused-window-probe:command-window-switch` confirms a
  Command-based switch fallback.
- `reconciliation deferred ... source=accessibility reason=layout-active` means
  AX work, including a focused-window probe, arrived while layout was active.
  A later `reconciliation admitted ... reason=focused-window-probe:...` confirms
  that the queued probe was admitted after layout settled.
- `ax focus adoption ignored reason=non-frontmost` confirms that an app-local
  focus notification from a background application was intentionally rejected.
- `activation settle ignored reason=stale-app` confirms that another app became
  frontmost before a delayed activation callback ran.
- `ax observer registration failed` identifies an app for which notification
  registration itself failed.

No `focus adopted` line is expected when the probed window is unmanaged or is
already the active layout column, because that case intentionally avoids a
redundant layout projection.

## High CPU Or Battery Usage

First check whether debug logging is enabled. Debug logging is intentionally
verbose and can create extra I/O.

Then check for repeated work:

```bash
rg "source=scan|reconciliation (deferred|admitted)|layout request=|snapshot tick" ~/.config/miri/debug.log
```

Things to look for:

- Frequent `source=scan` while idle.
- Repeated full rescans without app, Space, or config changes.
- Repeated `AXCreated` placeholder windows from one app.
- Menu bar redraws without status changes.
- Snapshot ticks continuing after `settled=true`.

Layout lines distinguish an animation-capable request from actual presentation:

```text
layout request=... workspace=... animationRequested=true animationStrategy=off animationActive=false
```

This is an immediate layout. `animationRequested` records the caller's intent;
`animationActive` records whether snapshot animation is actually running.

`window_reconciliation_interval_ms` controls the long safety rescan interval.
The normal path should be event-driven and targeted per PID.

## Animation Looks Wrong

Useful log lines:

- `snapshot request`
- `snapshot start`
- `snapshot retarget`
- `snapshot target`
- `snapshot tick`
- `snapshot no-op`

Check:

- `animation_strategy` is `snapshot`.
- `snapshot_animation_speed` is within `1...100`.
- `animation_fps` is not too low.
- `animation_pixel_threshold` is not too high.
- Screen Recording permission is granted.

Large `dtRaw` values in `snapshot tick` indicate main-thread stalls. The runner
caps per-frame movement, but repeated stalls can still make animation feel less
smooth.

## Resetting State

Persistent state is stored under `$XDG_STATE_HOME/miri/` or
`~/.local/state/miri/` by default:

- `layout.json`
- `logical-spaces.json`

Set `state_path` to move `layout.json`; `logical-spaces.json` is stored next to
it.

When investigating a state bug, quit miri first, then move these files aside so
they can be restored later if needed.
