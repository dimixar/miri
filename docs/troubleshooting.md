# Troubleshooting

## Permissions

miri needs Accessibility permission to focus, move, and resize app windows.

The `event_tap` shortcut backend may also require Input Monitoring permission.
Snapshot animation needs Screen Recording permission because it captures window
images.

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
rg "window discovered|ax reconciliation|snapshot|layout workspace" ~/.config/miri/debug.log
```

## Window Did Not Tile

Check for the app in the log:

```bash
rg "App Name|bundle.id|AXCreated|window discovered" ~/.config/miri/debug.log
```

Common causes:

- The app emitted a placeholder `AXCreated` before the real window was ready.
- The window is minimized, hidden, fullscreen, or has an unknown subrole.
- A rule matched the app or title with `behavior: "ignore"` or `"float"`.
- macOS has not granted Accessibility permission to the process running miri.
- The app does not expose a settable AX position or size.

Look for `raw ax window source=...` and compare `manageable`, `known`, role,
subrole, frame, minimized, and fullscreen fields.

## Window Stayed In Layout After Closing

Useful log lines:

- `AXUIElementDestroyed`
- `NSWorkspaceDidTerminate`
- `removing vanished window`
- `ax reconciliation draining`
- `layout workspace=...`

Some apps do not emit useful destroy events for their real windows. miri uses
per-PID reconciliation and a CoreGraphics fallback to remove tracked windows
whose CG window ID no longer exists.

## High CPU Or Battery Usage

First check whether debug logging is enabled. Debug logging is intentionally
verbose and can create extra I/O.

Then check for repeated work:

```bash
rg "source=scan|ax reconciliation draining|layout workspace|snapshot tick" ~/.config/miri/debug.log
```

Things to look for:

- Frequent `source=scan` while idle.
- Repeated full rescans without app, Space, or config changes.
- Repeated `AXCreated` placeholder windows from one app.
- Menu bar redraws without status changes.
- Snapshot ticks continuing after `settled=true`.

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
