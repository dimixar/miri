# Snapshot Animation

The snapshot backend avoids per-frame AX movement. It captures window images,
animates those images in an overlay, parks real windows underneath, and applies
final AX frames once the animation settles.

miri requires macOS 26 or newer, even with animations disabled. Snapshot
animation also requires Screen Recording permission because it captures window
images. `WindowSnapshotCapturer` uses ScreenCaptureKit's
`SCScreenshotManager.captureScreenshot` with `SCScreenshotConfiguration`; there is
no legacy CoreGraphics capture fallback.

`LayoutController` owns the request token, frame/visibility caches, snapshot
session, overlay, layers, hidden-window records, compositor transforms, and
display-link adapter. It reads model state through immutable snapshots and
narrow coordinator-supplied closures; it does not retain or mutate
`WindowManagement` or `SessionController`.

## Goals

- Keep keyboard focus responsive.
- Avoid heavy per-frame AX position and size writes.
- Keep repeated focus movement visually continuous.
- Avoid fighting real window frames while an overlay animation is active.
- Leave parked real windows with only the configured sliver visible.

## Pipeline

1. A command changes the logical layout.
2. miri computes target frames for all tiled windows in the active workspace.
3. miri asynchronously captures snapshots of those windows, with at most three
   independent captures in flight.
4. A transparent overlay window displays CALayer snapshots.
5. Real windows are parked under the overlay; preparation waits for parking
   callbacks before starting movement.
6. The manual frame runner moves layers toward target frames.
7. Further focus commands retarget the active snapshot session.
8. When the session settles, miri applies final AX frames once.
9. Deferred AX reconciliation is drained after layout is safe again.

AX focus calls are allowed during snapshot animation so keyboard input follows
the admitted layout request's focus. Requests arriving during preparation wait
until capture and parking finish. Apart from preparation parking, final AX
position and size changes for tiled windows are deferred until completion.

## Capture and Retargeting

Each capture batch enumerates `SCShareableContent` once, including offscreen
windows, and matches managed windows by both WindowServer ID and owner PID.
A desktop-independent filter captures each full window rather than cropping the
visible desktop. Output is an in-memory SDR `CGImage`, sized using the source
filter's point-to-pixel scale, without cursor, shadows, or child windows. Images
are never written to disk and no continuous capture streams are started.

Existing layers are reused during retargeting; only missing windows need new
captures. While capture or AX parking is pending, further layout submissions are
coalesced to the newest request. Animated submissions can retarget immediately
after preparation; non-animated submissions wait until the overlay is removed.
If a retarget needs new captures, its frame runner pauses until preparation is
complete. Request tokens and task cancellation reject late capture results after
cancellation, session unavailability, or replacement.

A missing window ID or a missing window/owner match in the shareable-content list
schedules AX reconciliation. Other capture errors, including permission failures,
are logged separately and do not imply that the managed window is stale. Partial
success animates only captured windows; an entirely failed initial batch falls
back to final AX placement. A failed missing-layer capture during retargeting
leaves existing snapshots usable, with uncaptured windows placed by the final
layout. Minimized windows and content unavailable to ScreenCaptureKit cannot be assumed
to produce a fresh image.

## Session Interruption

If the screen locks, the console session becomes inactive, or the system sleeps
during an animation, miri freezes presentation and supersedes queued AX work.
After in-flight per-PID AX calls reach their bounded completion, parked real
windows are restored with nonblocking compositor moves and only then is the
overlay removed. No further snapshot, layout, or final AX-frame work is admitted
while the session is unavailable. After a relevant managed-window interaction,
recovery clears stale presentation/frame caches and completes a fresh full
rescan before normal commands or reconciliation resume.

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

`animation_fps` controls layer movement, not screenshot capture frequency.
Images remain static during the transition and are reused while retargeting.
Large main-thread stalls are capped per tick so a delayed frame does not turn
into a visible jump.

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
clean. Before projection changes real frames, miri refreshes its versioned exit
snapshot. During quit, presentation generations are invalidated before PID
lanes quiesce, preventing a delayed parking/final-frame write from undoing exit
restoration.

## Debug Signals

Useful log lines:

- `snapshot request`: a command requested snapshot animation.
- `snapshot start`: a new session started.
- `snapshot capture batch`: batch size, captured count, and capture latency.
- `snapshot capture error`: a capture failed without implying a stale AX window.
- `snapshot missing image`: a missing window identity or shareable-content match
  queued targeted PID reconciliation.
- `snapshot captured`: window images were captured and the overlay is ready.
- `snapshot target`: start and end frame for a layer.
- `snapshot retarget`: active session received a new target.
- `snapshot tick`: per-frame progress, step size, and unsettled layer count.
- `snapshot no-op`: target layout had no meaningful motion.
- `layout deferred request=... during snapshot`: real AX layout was deferred.
- `reconciliation deferred ... reason=layout-active`: reconciliation was
  coalesced until animation and layout settled.

## Disabled Animation

If `animation_strategy` is `off`, new layouts use final AX placement without
animation under the normal layout lock. An already-active snapshot session
finishes before a deferred non-animated layout is applied. The following
obsolete AX-animation keys remain accepted for configuration compatibility but
are ignored:

- `animation_duration_ms`
- `keyboard_animation_ms`
- `move_column_animation_ms`
- `width_animation_ms`
- `animation_curve`
