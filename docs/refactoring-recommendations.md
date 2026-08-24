# Miri Refactoring Analysis and Recommendations

I agree that unit tests do not need to be the immediate priority. The larger current risk is event ordering, duplicated reconciliation behavior, stale delayed callbacks, and state whose ownership is unclear.

## Review scope

I reviewed:

- All 42 Swift files under `Sources/Miri/`
- All current and historical documents under `docs/`
- `README.md`, `miri.config.json`, packaging scripts, and the release workflow
- Relevant prior animation and logical-Space work
- Current call sites and unused-symbol paths

`swift build` succeeds. No source changes were made as part of the analysis.

## Architectural understanding

The application has three intended layers:

1. **Logical state**
   - `Workspace`, `ManagedWindow`, active workspace/column, widths, and scroll offsets.
2. **Presentation state**
   - Snapshot layers, presentation frames, and animation targets.
3. **Applied system state**
   - Real AX window frames, visibility caches, SkyLight transforms, and levels.

That is the correct overall model.

The previous refactor successfully split a 4,000-line file into domain files, but it was a **file-level refactor**, not an ownership refactor. Almost every subsystem still directly modifies roughly 95 properties on `Miri`.

The most important problem is therefore not large files by themselves. It is that several cross-subsystem invariants are conventional rather than enforced:

- reconciliation must not mutate the model during layout/snapshot work;
- only the newest delayed callback should release a layout lock;
- active logical-Space state must be copied back into its context;
- stale buffered windows must eventually be removed;
- persistence must not write before the initial model exists;
- snapshot session targets, layers, and hidden real windows must remain synchronized.

## Recommendations

### 1. Fix snapshot session and layout-lock correctness first

Files:

- `Sources/Miri/Layout/MiriSnapshotAnimation.swift`
- `Sources/Miri/Layout/MiriLayoutAnimation.swift`
- `Sources/Miri/Layout/MiriLayoutApplication.swift`
- `Sources/Miri/Core/Miri.swift`

There are three concrete problems.

#### Stale no-op retarget

When an active snapshot session receives a new request that falls into the no-op branch, the code updates:

- `requestGeneration`
- projected layout
- final layout

But it does **not** update `targetFramesByWindowID`.

The frame runner now considers itself current but can continue moving toward the previous target. This matches the class of “logical focus changed but presentation stayed stale” problems encountered during the animation work.

#### Obsolete layers can remain visible

Retargeting replaces `targetFramesByWindowID`, but layers absent from the new target are not removed. The frame loop simply skips layers without targets, potentially leaving a frozen snapshot visible until the session ends.

#### An old delayed unlock can release a newer layout

`releaseLayoutLock(after:)` has no generation token. An older callback can execute during a newer direct layout and set:

```swift
isApplyingLayout = false
```

too early, allowing reconciliation while the newer layout is still settling.

#### Recommended change

Introduce a single request token covering layout lock ownership:

```swift
struct LayoutApplicationToken: Equatable {
    let generation: UInt64
}
```

Only the request that owns the lock may release it.

For snapshot sessions:

- update targets even in the active-session no-op branch;
- remove layers no longer represented by the target;
- explicitly cancel or complete a stale-generation session instead of returning forever;
- keep layers, target frames, hidden windows, and final layout under one owner.

This should be the first batch because it is localized and directly reduces existing animation issues.

---

### 2. Introduce one reconciliation gateway

Files:

- `Sources/Miri/Windows/MiriWindowDiscovery.swift`
- `Sources/Miri/Windows/MiriAXObserver.swift`
- `Sources/Miri/Windows/MiriActiveRescan.swift`
- `Sources/Miri/Windows/MiriAppLaunchSettling.swift`
- `Sources/Miri/Core/MiriStatusProvider.swift`

Right now, callers are expected to remember to inspect `axReconciliationShouldDefer`. That invariant is not enforced by `rescanWindows` or `reconcileWindows` themselves.

Some paths call raw reconciliation directly, including periodic and menu-driven rescans. This means model mutation can occur during snapshot/layout work even though most AX paths carefully defer it.

There is another issue in `drainPendingAXReconciliationIfReady()`:

```swift
for pid in pids {
    reconcileWindows(forPID: pid, adoptFocused: adoptFocused)
}
```

The first PID can project a layout and reacquire `isApplyingLayout`. The loop nevertheless continues reconciling the remaining PIDs. PID iteration order is also unspecified.

#### Recommended shape

Create one entry point:

```swift
enum ReconciliationScope {
    case process(pid_t)
    case full
}

func requestReconciliation(
    _ scope: ReconciliationScope,
    adoptFocused: Bool,
    reason: ReconciliationReason
)
```

It alone decides whether to execute or coalesce.

The underlying immediate methods should no longer be called by timers, menu actions, or AX callbacks directly. The deferred drain should re-check the layout gate after each process or combine the requested PIDs into one controlled reconciliation pass.

This is more useful than immediately extracting a generic `WindowRegistry`.

---

### 3. Unify the duplicated missing-window logic

`reconcileDiscoveredWindows(...)` and `rescanWindows(...)` contain substantially duplicated logic for deciding whether a missing tracked window is:

- entering fullscreen;
- in a pending fullscreen transition;
- protected by a global fullscreen guard;
- hidden or minimized;
- moving to another native Space;
- temporarily missing during launch settling;
- actually destroyed.

The two implementations have already diverged. For example, the full rescan includes global fullscreen-transition preservation that the targeted per-PID reconciliation does not apply identically.

Extract something like:

```swift
enum MissingWindowDisposition {
    case preserve
    case rememberFullscreen
    case rememberMinimized
    case bufferForSpaceMove
    case remove
}
```

Then use the same classifier in both targeted and global reconciliation. Global-only operations—logical-Space switching and bulk disappearance freezing—should wrap that shared core rather than duplicate it.

This is probably the highest-leverage behavior-preserving refactor in the Windows subsystem.

---

### 4. Repair shutdown and emergency restoration

Files:

- `Sources/Miri/Core/Miri.swift`
- `Sources/Miri/Core/MiriStatusProvider.swift`
- `Sources/Miri/Persistence/MiriExitRestoration.swift`
- `Sources/Miri/Persistence/Restoration.swift`

The cleanup watcher currently does not appear operational:

- `startCleanupWatcher()` starts it before discovery.
- `CleanupWatcher.run()` exits immediately when the snapshot file does not exist.
- `writeRestoreSnapshot(viewport:)` has no call site anywhere in the project.

Therefore the watcher normally exits before any restoration snapshot could be written.

Shutdown logic is also duplicated across:

- `applicationWillTerminate`
- signal handlers
- `quitFromMenu`

Menu quit restores and writes state, then `NSApp.terminate` invokes `applicationWillTerminate`, which does it again.

#### Recommended change

Create one idempotent method:

```swift
func prepareForTermination(reason: TerminationReason)
```

guarded by an `isTerminating` flag.

Then:

- menu quit should normally only request `NSApp.terminate`;
- AppKit termination performs the finalization;
- signal handlers call the same finalization before exiting;
- the cleanup watcher should remain alive while the parent is alive even if no snapshot exists yet;
- a restore snapshot should be synchronized whenever the managed-window set changes or before the first AX layout mutation.

This is a correctness fix and a simplification at the same time.

---

### 5. Give logical-Space buffering a lifecycle

Files:

- `Sources/Miri/Windows/MiriLogicalSpaces.swift`
- `Sources/Miri/Windows/MiriWindowDiscovery.swift`
- `Sources/Miri/Core/Models.swift`

`BufferedSpaceWindow` stores:

- source workspace;
- source column;
- floating index;
- `bufferedAt`.

None of those placement/time fields is currently consumed after buffering. More importantly, buffered entries have no expiration or termination cleanup.

A stale buffered entry can remain indefinitely. Because persistence safety requires:

```swift
spaceBufferedWindows.isEmpty
```

one dead buffered window can permanently suppress safe logical-Space persistence.

Also, `removeWindows(forPID:)` operates on the active layout but does not purge the terminated PID from:

- inactive `logicalSpaceContexts`;
- `spaceBufferedWindows`;
- other context-specific restoration state.

#### Recommended change

Extract a focused `SpaceWindowBuffer` that owns:

- add;
- consume;
- purge by PID;
- purge windows whose CG ID no longer exists;
- optional bounded expiration.

Either use the saved source placement or remove those unused fields. Do not leave partially implemented restoration metadata.

---

### 6. Scope fullscreen/minimized state to a logical Space

`fullscreenWindowStates`, `minimizedWindowStates`, and fullscreen guard workspace indexes are global to `Miri`.

`FullscreenWindowState` stores a Miri workspace index but not a logical-Space context ID. After loading another native Space, the same numeric workspace index can refer to an unrelated context.

Recommended changes:

- record `logicalSpaceContextID` in fullscreen and minimized restoration state;
- scope guard enforcement to that context;
- clear restoration entries globally when a process terminates;
- avoid keying multiple same-app windows solely by `PersistentWindowIdentity` where collisions are possible.

I would address this before attempting to make `LogicalSpaceContext` a more isolated service.

---

### 7. Remove the dormant animation subsystem

There is a meaningful amount of dead animation code:

- `MiriAnimationStrategy.swift` is effectively unreachable.
- `animationProfile` always returns `nil`.
- `applyAnimationFrame`, easing curves, and AX interpolation are unused.
- `Miri.animationTimer` is never assigned.
- `animatedWindowIDs` is passed through several layers but never consumed.
- Snapshot `duration` is passed around but snapshot speed determines movement.
- `WindowMotion.participates` and `sizeStable` are always created as `true`.
- `prepareInterruptedSnapshotAnimationForNextCapture()` is unused.
- Several geometry/visibility helpers are no longer referenced.
- `hiddenWorkspaceWindowIDs` has no live consumer beyond its unused query helper.

Keep `AnimationTimer`, because snapshot animation uses it. Remove the obsolete AX-animation path.

For config compatibility, old duration/curve keys can remain decodable, but they should not remain in the Settings UI as if they controlled current snapshot behavior. Currently duration settings mainly affect notification-suppression timing rather than visual duration.

This cleanup should happen before extracting a snapshot controller; otherwise dead concepts will be preserved inside the new abstraction.

---

### 8. Extract configuration loading/saving into `ConfigStore`

Files:

- `Sources/Miri/Config/Config.swift`
- `Sources/Miri/Config/MiriEffectiveSettings.swift`
- `Sources/Miri/Core/MiriStatusProvider.swift`
- `Sources/Miri/UI/Settings/SettingsWindowController.swift`

Concrete issues:

- Settings reports success even when saving fails because `saveConfigFromSettings` returns `Void`.
- Invalid numeric text can become `NaN`; `JSONEncoder` then rejects it, but Settings still says it saved.
- Hot reload can skip a malformed higher-priority config and silently load a lower-priority file.
- Saving rewrites the entire JSON and drops unknown keys.
- The shipped `hide_method` key has no model or implementation.
- Source and packaged launches have different defaults.
- Compiled fallback excludes `lalt+shift+5`, which disables the built-in move-to-workspace-5 shortcut; the repository JSON excludes `cmd+shift+5`.

Recommended design:

```swift
struct MiriConfigDocument {
    let sourceURL: URL
    let rawObject: [String: Any]
    let decoded: MiriConfig
    let effective: EffectiveMiriConfig
}

final class ConfigStore {
    func loadInitial() -> Result<MiriConfigDocument, ConfigError>
    func reloadCurrent() -> ConfigReloadResult
    func save(...) -> Result<MiriConfigDocument, ConfigError>
}
```

Keep raw Codable configuration optional for compatibility, but create a fully resolved, nonoptional `EffectiveMiriConfig` for runtime consumption.

Settings should only close or show success when `save` returns success.

---

### 9. Replace implicit thread confinement with `@MainActor`

The code is mostly intentionally main-thread driven:

- AX observers are attached to the main run loop.
- Timers generally run on main.
- Event callbacks dispatch commands to main.
- AppKit and CALayer operations are main-thread operations.

But this is represented using `@unchecked Sendable` on `Miri`, snapshot classes, and `AnimationTimer`.

After the reconciliation and snapshot boundaries are clearer:

- mark `Miri`, `SnapshotAnimationSession`, and `SnapshotOverlayWindow` as `@MainActor`;
- make `AnimationTimer` expose a main-actor frame callback;
- keep C callbacks as small adapters into main-actor methods;
- retain `@unchecked Sendable` only for immutable low-level wrappers such as `SkyLight` where it is justified.

I would not do this first because it will create broad compiler-driven churn around C callbacks.

---

### 10. Refactor UI around models, not just smaller files

For `SettingsWindowController.swift`, the first extraction should be a typed `SettingsDraft`, not arbitrary tab extensions.

It should own:

- parsing controls;
- finite-number validation;
- canonical keybinding validation using `KeybindingResolver`;
- normalization;
- conversion to `MiriConfig`.

The current string-keyed `[String: NSControl]` registry silently turns missing controls into `false`, `0`, or an empty string, which makes future UI edits risky.

For `StatusMenuController.swift`, extract:

- `WorkspaceBarRenderer`
- shared color parsing/formatting
- rendering signature construction

Keep menu lifecycle and actions in `StatusMenuController`.

Color parsing is currently duplicated between Settings and the status renderer, with slightly different color-space construction.

## Recommended implementation sequence

1. Snapshot retarget and layout-lock fixes.
2. Single reconciliation gateway.
3. Shared missing-window classifier.
4. Idempotent shutdown and functional cleanup watcher.
5. Logical-Space buffer/global PID cleanup.
6. Remove dead animation and visibility code.
7. `ConfigStore` plus typed `SettingsDraft`.
8. Extract `SnapshotAnimationController` and reconciliation state owner.
9. Add main-actor isolation.
10. Consider replacing active logical-Space copying with an owned `WorkspaceLayout` object.

## Refactorings I would not start with

I would **not** start by extracting a generic `WorkspaceStore` or converting all reference models to value types. Reference identity is deliberate throughout this project—`===`, `ObjectIdentifier`, weak workspace authority, shared `ManagedWindow` instances, and AX element identity all depend on it.

Those should only change after the event and lifecycle invariants above are explicit.
