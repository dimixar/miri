# Configuration

miri selects the first existing JSON configuration path in this order:

1. `MIRI_CONFIG`
2. `./miri.config.json`
3. `$XDG_CONFIG_HOME/miri/config.json`
4. `~/.config/miri/config.json`

It does not skip a malformed selected file in favor of a lower-priority path.
The active config file is watched and valid changes are hot-reloaded. If a
change cannot be parsed, miri keeps running with the previous config and reports
the failure. Unknown root keys and unknown keys inside `rules` are rejected
instead of being silently discarded by Settings. The legacy
`center_focused_column` key is accepted only for the documented
focus-alignment migration.

`ConfigStore` exclusively owns the selected source, modification metadata,
last valid document, and resolved runtime configuration. Reload and Settings
save results return to the coordinator, which reconfigures workspace capacity,
input, persistence, reconciliation timers, discovery, and layout in that
order. A timer or UI controller never mutates configuration consumers directly.

The repository includes a complete default config at
[`miri.config.json`](../miri.config.json).

## Example

```json
{
  "default_width_ratio": 0.67,
  "preset_width_ratios": [0.33, 0.5, 0.67, 1.0],
  "animation_strategy": "snapshot",
  "snapshot_animation_speed": 50,
  "animation_fps": 60,
  "focus_alignment": "default",
  "new_window_position": "after_active",
  "minimum_workspace_count": 1,
  "workspace_auto_back_and_forth": false,
  "keyboard_shortcut_backend": "event_tap",
  "excluded_keybindings": ["cmd+shift+5"],
  "keybindings": {
    "column_left": ["lalt+h"],
    "column_right": ["lalt+l"]
  },
  "restore_on_exit": true,
  "persist_layout": true,
  "window_reconciliation_interval_ms": 60000,
  "ax_created_placeholder_probe_cooldown_ms": 1000,
  "active_rescan_enabled": true,
  "active_rescan_bundle_ids": ["notion.id"],
  "rules": [
    {
      "bundle_id": "com.apple.finder",
      "behavior": "ignore"
    }
  ]
}
```

## Layout

- `default_width_ratio`: default column width as a fraction of the viewport.
- `preset_width_ratios`: ratios used by width cycling commands.
- `focus_alignment`: `default`, `centered`, or `centered_smart`. Default moves
  only enough to fully reveal the focused window. Centered always centers it.
  Centered smart always centers a workspace's only tiled window. With multiple
  windows, changing focus to a fully visible window preserves the current view,
  even when a smaller neighbor is offscreen. Visibility is checked before
  applying smart alignment. For a partially visible or offscreen target, it
  minimally reveals a focused window below half width. At half width or wider,
  it fits the smallest eligible immediate neighbor alongside the focus,
  or centers the focus if neither neighbor fits. Equal-width neighbors favor the
  existing view, then the least scrolling, then the left neighbor. An already
  visible selected pair stays stationary; otherwise the focus stays as close to
  center as the pair allows. Width changes reevaluate smart alignment.
  Widths are measured within the usable viewport;
  fitting does not resize or reorder windows. Legacy `left` and `smart` values are
  migrated to `default`; legacy `center` is migrated to `centered`. The obsolete
  `center_focused_column` key is removed during migration. Loading a legacy
  value atomically rewrites the active config with its normalized replacement.
  Strict centering can leave empty space at the display edge when the first or
  last column is narrower than the viewport.
- `new_window_position`: `before_active`, `after_active`, or `end`.
- `drag_scroll_speed_percent`: speed of edge scrolling while dragging a tiled
  window, clamped to `25...500`. Defaults to `100` (120–720 points per second,
  increasing as the pointer approaches the edge). `50` halves the speed; `200`
  doubles it. Settings → Layout → Window dragging exposes the same control.
  Apply or Save takes effect without restarting; the edge zone and dwell delay
  remain unchanged.
- `manual_floating_outline_enabled`: show a click-through Liquid Glass rim
  tinted with the adaptive system accent around manually floated windows.
  Defaults to `true`; Settings → Layout → Floating windows can disable it.
  Applying the setting hides or restores existing outlines without restarting
  or changing floating state. Rule-floated and ignored windows are never outlined.
- `manual_floating_outline_thickness`: outline thickness in logical points,
  clamped to `1...10`, default `2`. Settings → Layout → Floating windows exposes
  the same range in 1pt increments; Apply or Save updates existing outlines.
  Corner radii follow each window's macOS 26+ WindowServer metadata, including
  square corners, without screen capture. Radii refresh on resize and once per
  second while visible. Unavailable or asymmetric metadata uses a 10pt radius
  fallback; custom-drawn silhouettes are not inferred from screenshots.
- `minimum_workspace_count`: number of empty-or-occupied numbered workspaces
  Miri always keeps available, clamped to `1...9`. Moving a column or applying
  a window rule to a higher workspace creates every numbered slot through that
  destination. Empty interior slots are retained so occupied workspaces never
  change numbers; unused trailing dynamic workspaces may be removed.
- `workspace_auto_back_and_forth`: when true, focusing the active workspace
  jumps back to the previous workspace. It defaults to `false`; the dedicated
  `focus_previous_workspace` command provides explicit back-and-forth behavior.
- `inner_gap` / `outer_gap`: layout gaps in physical pixels. `inner_gap`
  applies only between adjacent columns; `outer_gap` independently insets the
  usable display viewport. Values are converted using the display's backing
  scale and final frame edges are aligned to physical pixels.
- `parked_sliver_width`: number of pixels left visible in each axis when real
  windows are parked beyond the lower-left or lower-right display corner
  during snapshot animation or hidden-workspace staging.
  Miri reads the WindowServer shadow parameters and uses a transactional
  SkyLight group move after Accessibility sizing so the configured corner
  extent includes the rendered shadow. Accessibility positioning remains the
  fallback when the required private symbols are unavailable.
- `width_resize_mode`: `default` or `intelligent`.
- `ax_created_placeholder_probe_cooldown_ms`: per-app cooldown for short
  placeholder-window probes after an already-tracked app emits a tiny
  `AXCreated` placeholder. `0` disables this rate limit.
- `active_rescan_enabled`: reliability mode for apps that miss useful
  Accessibility window events. When enabled and a listed bundle is present in
  the tiled layout, miri runs targeted per-PID rescans once per second and on
  user input until that bundle is gone. It is enabled by default for better
  stale-window recovery. This is only a mitigation for broken app Accessibility
  behavior; apps that miss lifecycle events or report stale AX frames can still
  behave unpredictably while tiled.
- `active_rescan_bundle_ids`: bundle IDs that trigger active rescans. The
  default list includes `notion.id`. Disable active rescans to reduce idle CPU
  and battery use; if a disabled app still causes stale-window trouble, prefer
  adding that app to window rules with `behavior: "ignore"` so miri does not
  tile it.

## Animation

Snapshot mode uses asynchronous ScreenCaptureKit screenshots and requires Screen
Recording permission. Without access, the effective strategy is `off`. The
application requires macOS 26 or newer even when animations are disabled; there
is no older-OS capture fallback. No new configuration keys are needed for the
ScreenCaptureKit backend. See [Snapshot animation](snapshot-animation.md).

- `animation_strategy`: `snapshot` or `off`. `off` applies the final layout
  without animation under the normal layout lock, waiting for an existing
  snapshot session to finish if necessary. Nonzero animation-duration settings
  do not override it.
- `snapshot_animation_speed`: `1` to `100`; drives snapshot movement speed.
- `animation_fps`: manual snapshot runner frame rate, clamped to `1...120`.
  This controls layer movement, not screenshot capture frequency.
- `animation_pixel_threshold`: distance under which a snapshot layer snaps to
  its target.
- `animation_duration_ms`, `keyboard_animation_ms`,
  `move_column_animation_ms`, `width_animation_ms`, and `animation_curve` are
  accepted only for compatibility with older config files and are ignored.

## Shortcuts

`keyboard_shortcut_backend` controls how global shortcuts are captured:

- `event_tap`: full compatibility. miri uses a CG event tap, supports
  side-specific `lalt`/`ralt`, supports excluded shortcuts, and can consume
  matching keys. The tap receives every `keyDown`, so this route has more
  per-keystroke wakeups.
- `registered_hot_keys`: lower typing overhead. miri registers configured
  shortcuts with macOS using Carbon `RegisterEventHotKey`, so it wakes only for
  those shortcuts. This route cannot distinguish left vs right Option/Alt,
  treats `lalt` and `ralt` as generic `alt`, and does not support `fn`/Globe
  bindings.

After lock, login-session changes, or sleep, miri temporarily uses a listen-only
CG event tap to detect a qualifying interaction with a managed window even when
`registered_hot_keys` is selected. Input Monitoring permission may be required
for pointer/key recovery through that tap. A configured Carbon hot key can also
release recovery without relying on the temporary tap, provided a relevant
managed window is focused.

`keybindings` is merged with built-in defaults by action name. Set an action to
`[]` to disable it. `excluded_keybindings` always wins when using `event_tap`.

`toggle_workspace_fullscreen` defaults to `lalt+shift+f` and is editable under
Settings → Shortcuts → Workspace fullscreen. It toggles a temporary full-workspace
override for the focused tiled window, preserving normal ratios. Column navigation,
width shortcuts, and drag-layout gestures are disabled while enabled. External
focus changes transfer the override to the focused tiled window; toggling off
restores normal tiling with that window focused. This is separate from native
macOS fullscreen and does not create a macOS Space.

`toggle_window_floating` defaults to `lalt+ctrl+f` and is editable under
Settings → Shortcuts → Floating windows. It toggles the actual focused managed
window, including a floating window, without changing app rules or its peers.
Both explicit floating and explicit tiling override behavior rules for that live
window. Overrides survive rescans, title changes, hiding/minimization, and session
recovery, but are not restored across Miri restarts. Retiling restores the saved
workspace, adjacent position, and width when possible; after a move to a different
native Space it uses the current workspace instead. Ignored windows, dialogs,
and native-fullscreen windows are not toggled.

Existing explicit shortcuts are preserved. If an older config still explicitly
assigns `lalt+ctrl+f` to fullscreen and does not configure the floating command,
the inherited floating binding is left empty rather than stealing that shortcut.
Change the bindings in Settings to adopt the new defaults, or set either command
to `[]` to disable it.

Supported modifier names include `cmd`, `win`, `windows`, `super`, `meta`,
`ctrl`, `shift`, `alt`, `option`, side-specific `lalt`/`ralt`, and `fn`/`globe`.
Common aliases are supported for arrows, navigation keys, page keys, function
keys, and punctuation.

## Window Rules

Rules can match on `bundle_id`, `app_name`, or `title_contains`.

- `behavior: "ignore"`: leave matching windows alone.
- `behavior: "float"`: keep matching windows visible but untiled.
- `behavior: "tile"`: force matching windows into the tiled model.
- `title_exact_match: true`: make `title_contains` match the whole title.
- `width_ratio`: override the default column width.
- `workspace`: open on a specific Miri workspace.
- `open_position`: `before_active`, `after_active`, or `end`.

## Recovery And Persistence

Session lock/sleep recovery is automatic rather than configurable. Layout work
pauses while the session is unavailable and resumes only after asynchronously
validated interaction with a relevant managed window, AX quiescence, and a
current full rescan. See
[Session Lock And Sleep Recovery](../README.md#session-lock-and-sleep-recovery).

- `window_reconciliation_interval_ms`: long safety timer for missed
  notifications, clamped to `5000...300000`.
- `likely_fullscreen_transition_grace_ms`: grace window for native fullscreen
  transitions.
- `fullscreen_space_change_guard_ms`: guard window for fullscreen Space changes.
- `logical_space_autosave_interval_minutes`: autosave interval for inferred
  macOS Space contexts.
- `restore_on_exit`: restore managed tiled windows on normal exit and via a
  cleanup watcher after abrupt termination. Normal restoration runs per PID
  behind a global deadline; incomplete restoration keeps the current watcher
  snapshot for a post-exit retry. Floating windows retain their frame while
  Miri-owned compositor levels and transforms are normalized.
- `persist_layout`: persist layout and logical Space state.
- `state_path`: override the path for `layout.json`; `logical-spaces.json` is
  stored next to it.
- `debug_logging`: write debug logs to `~/.config/miri/debug.log`.

## Menu Bar

- `workspace_bar_use_custom_colors`: use the saved highlight and
  delimiter/border colors instead of the current macOS system accent color.
  Defaults to `false`. In system-color mode, low-contrast accents are lightened
  in dark appearance and darkened in light appearance. Text always uses
  adaptive system label colors.
- `workspace_bar_highlight_color`: custom focused-window accent, as a named
  color or `#RRGGBB`. Used only when `workspace_bar_use_custom_colors` is true.
- `workspace_bar_visible_icon_count`: visible app icons per workspace, clamped
  to `1...6`.
- `workspace_bar_overflow_style`: `plus_count`, `dots_count`, `chevron`, or
  `none`.
- `workspace_bar_show_fullscreen`: show remembered fullscreen apps in the bar.
- `workspace_bar_active_style`: `braces`, `filled_pointer`, `filled_dot`,
  `square_brackets`, `angle_brackets`, `outline`, or `filled_outline`.
- `workspace_bar_center_style`: `delimiter`, `border`, or `filled_border`.
- `workspace_bar_delimiter_color`: custom delimiter and workspace-border
  accent, as a named color or `#RRGGBB`. Used only when
  `workspace_bar_use_custom_colors` is true.
- `workspace_bar_center_border_outset`: `0...5`.
- `workspace_bar_center_border_thickness`: `1...3`.
