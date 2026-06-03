# Niri Behavior Notes for the Swift MVP

Niri commit inspected: `1f07cffa`

## Source Behavior

- Niri arranges windows in horizontal columns on an infinite strip; new windows
  do not resize existing windows. Workspaces are dynamic vertical rows per
  monitor, with an empty workspace at the bottom.
  [README.md lines 17-24](https://github.com/niri-wm/niri/blob/1f07cffa/README.md#L17-L24)

- Niri's default config binds horizontal focus to `Mod+H/L` and arrow keys.
  [default-config.kdl lines 403-410](https://github.com/niri-wm/niri/blob/1f07cffa/resources/default-config.kdl#L403-L410)

- Niri's workspace-up/down commands operate on the focused monitor's vertical
  workspace list.
  [default-config.kdl lines 459-466](https://github.com/niri-wm/niri/blob/1f07cffa/resources/default-config.kdl#L459-L466)

- Niri binds `Mod+1` through `Mod+9` to `focus-workspace 1..9`, and documents
  that indexes past the current workspace count clamp to the last, empty
  workspace.
  [default-config.kdl lines 509-525](https://github.com/niri-wm/niri/blob/1f07cffa/resources/default-config.kdl#L509-L525)

- Niri's workspace docs clarify that workspace indexes are dynamic positions,
  not stable identities.
  [Workspaces.md lines 32-40](https://github.com/niri-wm/niri/blob/1f07cffa/docs/wiki/Workspaces.md#L32-L40)

- The input action path calls layout focus methods directly for columns and
  workspaces.
  [input/mod.rs lines 1066-1092](https://github.com/niri-wm/niri/blob/1f07cffa/src/input/mod.rs#L1066-L1092)
  [input/mod.rs lines 1451-1474](https://github.com/niri-wm/niri/blob/1f07cffa/src/input/mod.rs#L1451-L1474)

- Column focus is a bounded active-column index change.
  [scrolling.rs lines 1551-1565](https://github.com/niri-wm/niri/blob/1f07cffa/src/layout/scrolling.rs#L1551-L1565)

- Workspace up/down is a bounded active-workspace index change; direct
  workspace index focus also clamps to the last workspace.
  [monitor.rs lines 978-1013](https://github.com/niri-wm/niri/blob/1f07cffa/src/layout/monitor.rs#L978-L1013)

- Adding a window to the bottom empty workspace creates another empty workspace
  below it; empty non-active middle workspaces are cleaned up.
  [monitor.rs lines 537-585](https://github.com/niri-wm/niri/blob/1f07cffa/src/layout/monitor.rs#L537-L585)
  [monitor.rs lines 625-640](https://github.com/niri-wm/niri/blob/1f07cffa/src/layout/monitor.rs#L625-L640)

## MVP Mapping

- `Cmd+1..9`: focus dynamic workspace index, clamped to the last empty row.
- `Cmd+J/K`: focus workspace down/up.
- `Cmd+H/L`: focus column left/right.
- Every managed window is a single full-screen-sized column.
- The current workspace and column projects to the visible macOS frame.
- Other windows remain physically parked just past a side edge so Cmd-Tab can
  still find them and macOS does not relocate fully offscreen windows.
- Cmd-Tab is not intercepted. When macOS activates a window, the daemon adopts
  that window's stored row/column and reprojects.
- The daemon writes a restore snapshot and spawns `miri --cleanup-watch`.
  Normal signal exits restore every managed window to the visible maximized
  frame directly. If the main process dies unexpectedly, the watcher uses the
  snapshot to do the same cleanup.
