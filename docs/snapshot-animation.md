# Snapshot Animation

The snapshot backend avoids per-frame AX movement. It captures window images,
animates those images in an overlay, parks real windows underneath, and applies
final AX frames once the animation settles.

Snapshot animation requires Screen Recording permission because it captures
window images.

## Goals

- Keep keyboard focus responsive.
- Avoid heavy per-frame AX position and size writes.
- Keep repeated focus movement visually continuous.
- Avoid fighting real window frames while an overlay animation is active.
- Leave parked real windows with only the configured sliver visible.

## Pipeline

1. A command changes the logical layout.
2. miri computes target frames for all tiled windows in the active workspace.
3. miri captures snapshots of those windows.
4. Real windows are parked or left staged under the overlay.
5. A transparent overlay window displays CALayer snapshots.
6. The manual frame runner moves layers toward target frames.
7. Further focus commands retarget the active snapshot session.
8. When the session settles, miri applies final AX frames once.
9. Deferred AX reconciliation is drained after layout is safe again.

AX focus calls are allowed during snapshot animation so keyboard input follows
the user's requested focus. AX position and size changes for tiled windows are
deferred until completion.

## Layout Copies

The animation path separates three states:

- Logical layout: latest requested Miri state.
- Presentation layout: current snapshot layer frames and target frames.
- AX-applied layout: real macOS window frames.

Retargeting uses the presentation layout as its start point and the current
logical target as its destination. It should not read live AX frames to decide
where the snapshot should move next.

## Speed

Snapshot movement is controlled by `snapshot_animation_speed`, not by a fixed
millisecond duration. The runner derives pixels per second from that speed and
advances layers frame by frame.

`animation_fps` controls the runner cadence. Large main-thread stalls are
capped per tick so a delayed frame does not turn into a visible jump.

`animation_pixel_threshold` controls when a layer snaps to its target.

## Parking

Real windows may be moved offscreen while the overlay owns the visible motion.
`parked_sliver_width` controls how much of the parked real window remains
visible. The default is `1`.

Parking is intentionally separate from final layout. A parked real window is
not the presentation state; it is only a staging detail to keep the overlay
clean.

## Debug Signals

Useful log lines:

- `snapshot request`: a command requested snapshot animation.
- `snapshot start`: a new session started.
- `snapshot captured`: window images were captured and the overlay is ready.
- `snapshot target`: start and end frame for a layer.
- `snapshot retarget`: active session received a new target.
- `snapshot tick`: per-frame progress, step size, and unsettled layer count.
- `snapshot no-op`: target layout had no meaningful motion.
- `layout deferred during snapshot`: real AX layout was deferred.
- `ax reconciliation deferred`: AX events were queued until animation settled.

## Fallback AX Animation

If `animation_strategy` is `off`, snapshot animation is disabled. Some fallback
AX animation settings remain for non-snapshot paths and compatibility:

- `animation_duration_ms`
- `keyboard_animation_ms`
- `move_column_animation_ms`
- `width_animation_ms`
- `animation_curve`
