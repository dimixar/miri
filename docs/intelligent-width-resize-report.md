# Intelligent Width Resize Report

## Summary

This branch adds an optional intelligent resize mode for keyboard-driven column width changes. The existing behavior remains available as the default, while the new mode keeps the active window visually stable and fully visible when cycling width presets or nudging the active width.

## User-facing configuration

A new config option was added:

```json
"width_resize_mode": "default"
```

Supported values:

- `default` — preserves the previous resize behavior.
- `intelligent` — enables edge-aware resize repositioning for the active column.

The option is exposed in the Settings GUI under the **Layout** tab as **Width resize mode**.

## Scope

The intelligent mode applies to active-window width changes:

- cycle active width preset backward/forward
- nudge active width narrower/wider

All-window width changes keep the old behavior so batch resizing remains predictable and does not try to infer a single active-window anchor for every column.

## Behavior

### Growing

When the active column grows, Miri checks which side of the active window has more free viewport space:

- more free space on the right → grow toward the right
- more free space on the left → grow toward the left

The chosen grow direction is kept sticky for the same window during consecutive grow commands. This prevents direction flipping after the first grow consumes the initially free side.

### Shrinking from full viewport

A ratio of `1.0` is treated as occupying the full viewport.

When shrinking from `>= 1.0`:

- first column shrinks toward the left edge
- last column shrinks toward the right edge
- middle columns shrink according to the last horizontal focus/move direction:
  - last left command → shrink left
  - last right command → shrink right

Horizontal column focus and horizontal column movement update this remembered direction.

### Shrinking below full viewport

When shrinking from a non-full ratio, Miri shrinks opposite the side where the window would grow:

- if it could grow right, it shrinks left
- if it could grow left, it shrinks right

### Full visibility correction

After calculating the intelligent target scroll offset, Miri verifies whether the resized active column would be fully visible.

If the new frame would be cut off and the column can fit inside the viewport, Miri corrects the scroll offset:

- cut on the left → shift left
- cut on the right → shift right

This handles middle-column cases such as `1 2 3`, where growing `2` from a partially shared viewport could otherwise leave `2` at ratio `1.0` but visually clipped.

## Implementation notes

Main files changed:

- `Sources/Miri/Config/Config.swift`
  - added `WidthResizeMode`
  - added `widthResizeMode` config property and coding key
- `Sources/Miri/Config/MiriEffectiveSettings.swift`
  - added effective `widthResizeMode`
- `Sources/Miri/Core/Miri.swift`
  - added state for last horizontal focus direction
  - added sticky intelligent grow direction memory
- `Sources/Miri/Core/MiriCommands.swift`
  - records horizontal focus/move direction
  - applies intelligent scroll-offset adjustment for active width changes
  - keeps grow direction sticky during repeated grow commands
  - corrects scroll offset to keep the resized active column fully visible
- `Sources/Miri/UI/Settings/SettingsWindowController.swift`
  - added Layout-tab popup for `width_resize_mode`
- `README.md` and `miri.config.json`
  - documented and included the new setting

## Validation

The project builds successfully with:

```bash
swift build
```
