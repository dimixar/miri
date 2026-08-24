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

## Session Interruption

If the screen locks, the console session becomes inactive, or the system sleeps
during an animation, miri stops the animation and clears its snapshot
presentation. No further snapshot, layout, or final AX-frame work is performed
while the session is unavailable. After the desktop is available and a relevant
managed-window interaction releases the recovery guard, a full rescan projects
the current layout from preserved logical state.

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
visible along each axis in physical pixels. The default is `1`; this leaves a
small corner instead of a full-height strip. Accessibility placement runs
first; a dynamically resolved SkyLight transaction then attempts to move the
window and its compositor group beyond the lower display corner. Miri verifies the
WindowServer position before accepting that move. WindowServer shadow
parameters are included in both edge calculations, with direct movement and
compositor transforms retained as verified fallbacks.

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

## Disabled Animation

If `animation_strategy` is `off`, snapshot animation is disabled and final AX
frames are applied immediately under the normal layout lock. The following
obsolete AX-animation keys remain accepted for configuration compatibility but
are ignored:

- `animation_duration_ms`
- `keyboard_animation_ms`
- `move_column_animation_ms`
- `width_animation_ms`
- `animation_curve`
