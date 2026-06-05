# Configuration

miri loads JSON configuration from the first readable path in this order:

1. `MIRI_CONFIG`
2. `./miri.config.json`
3. `$XDG_CONFIG_HOME/miri/config.json`
4. `~/.config/miri/config.json`

The active config file is watched. Valid changes are hot-reloaded. If a save
cannot be parsed, miri keeps running with the previous config.

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
  "focus_alignment": "smart",
  "new_window_position": "after_active",
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
- `focus_alignment`: `left`, `center`, or `smart`.
- `new_window_position`: `before_active`, `after_active`, or `end`.
- `workspace_auto_back_and_forth`: when true, focusing the active workspace
  jumps back to the previous workspace.
- `center_focused_column`: legacy centering behavior. `focus_alignment` is the
  preferred setting.
- `inner_gap` / `outer_gap`: layout gaps in pixels.
- `parked_sliver_width`: number of pixels left visible when real windows are
  parked offscreen during snapshot animation or hidden-workspace staging.
- `width_resize_mode`: `default` or `intelligent`.
- `ax_created_placeholder_probe_cooldown_ms`: per-app cooldown for short
  placeholder-window probes after an already-tracked app emits a tiny
  `AXCreated` placeholder. `0` disables this rate limit.

## Animation

- `animation_strategy`: `snapshot` or `off`.
- `snapshot_animation_speed`: `1` to `100`; drives snapshot movement speed.
- `animation_fps`: manual snapshot runner frame rate, clamped to `1...120`.
- `animation_pixel_threshold`: distance under which a snapshot layer snaps to
  its target.
- `animation_curve`: `smooth`, `snappy`, or `linear`.
- `animation_duration_ms`, `keyboard_animation_ms`,
  `move_column_animation_ms`, and `width_animation_ms`: fallback AX animation
  durations. Snapshot focus movement uses `snapshot_animation_speed` instead.

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

`keybindings` is merged with built-in defaults by action name. Set an action to
`[]` to disable it. `excluded_keybindings` always wins when using `event_tap`.

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

- `window_reconciliation_interval_ms`: long safety timer for missed
  notifications, clamped to `5000...300000`.
- `likely_fullscreen_transition_grace_ms`: grace window for native fullscreen
  transitions.
- `fullscreen_space_change_guard_ms`: guard window for fullscreen Space changes.
- `logical_space_autosave_interval_minutes`: autosave interval for inferred
  macOS Space contexts.
- `restore_on_exit`: restore managed windows on normal exit and via cleanup
  watcher after abrupt termination.
- `persist_layout`: persist layout and logical Space state.
- `state_path`: override the path for `layout.json`; `logical-spaces.json` is
  stored next to it.
- `debug_logging`: write debug logs to `~/.config/miri/debug.log`.

## Menu Bar

- `workspace_bar_highlight_color`: named color or `#RRGGBB`.
- `workspace_bar_visible_icon_count`: visible app icons per workspace, clamped
  to `1...6`.
- `workspace_bar_overflow_style`: `plus_count`, `dots_count`, `chevron`, or
  `none`.
- `workspace_bar_show_fullscreen`: show remembered fullscreen apps in the bar.
- `workspace_bar_active_style`: `braces`, `filled_pointer`, `filled_dot`,
  `square_brackets`, `angle_brackets`, `outline`, or `filled_outline`.
- `workspace_bar_center_style`: `delimiter`, `border`, or `filled_border`.
- `workspace_bar_delimiter_color`: named color or `#RRGGBB`.
- `workspace_bar_center_border_outset`: `0...5`.
- `workspace_bar_center_border_thickness`: `1...3`.
