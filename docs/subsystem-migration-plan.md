# Miri Subsystem Migration Plan

## Document status

- Plan status: Proposed
- Migration status: In progress
- Last updated: 2026-08-24
- Current phase: Phase 6 — window observation and reconciliation
- Last verified revision: working tree

This is the living plan and progress record for moving Miri from one shared
`Miri` state object with domain extensions to a coordinated set of subsystems
with explicit ownership.

The migration does not depend on an automated test suite or CI environment.
Each phase instead has build checks, runtime invariants, focused logging, and a
manual verification checklist proportional to the behavior changed.

## Intended outcome

The target architecture has one main-actor coordinator that:

- constructs and starts the subsystems;
- receives typed events from external-event sources and UI components;
- owns application phase, cross-subsystem ordering, request admission, and
  pending high-level intents;
- tells subsystems what work to perform;
- never implements window classification, layout geometry, animation,
  persistence encoding, or UI rendering itself.

Subsystems own their state privately and communicate across domain boundaries
through the coordinator. High-frequency internal work, such as animation frame
ticks or timer bookkeeping, remains inside the subsystem that owns it.

## Constraints and non-goals

- Automated tests and CI are not prerequisites for this migration.
- The application remains serialized on the main actor. The migration will not
  introduce one actor or queue per subsystem.
- The migration will preserve `ManagedWindow` and `Workspace` reference identity.
- The first migration will remain in the existing SwiftPM executable target.
  Separate packages or library targets are not required to establish ownership.
- A generic event bus, service locator, or dependency-injection framework will
  not be introduced.
- File splitting, line-count reduction, and protocol creation are not measures
  of completion by themselves.
- Behavior changes must be identified explicitly. Structural work must not hide
  unrelated feature changes.

## Target subsystems and ownership

The names below are working names. A name may change during implementation, but
the ownership boundary must remain explicit and the change must be recorded in
the decision log.

| Component | Owns | Does not own |
| --- | --- | --- |
| `AppCoordinator` | Application phase, event sequencing, layout/reconciliation admission, pending commands and reconciliation intents, startup and termination orchestration | Workspace collections, layout request tokens, AX observers, CALayers, geometry, file encoding, menu rendering |
| `WindowManagement` | Canonical managed windows, workspace contents and focus, logical Space contexts, floating placement, Space buffer, fullscreen/minimized placement state, command mutation, reconciliation decisions | Applying real window frames, snapshot presentation, files, UI |
| `LayoutController` | Layout request lifecycle, applied-frame and visibility caches, snapshot session, overlay, animation timer, hidden real windows, compositor transforms, managed-window focus and level application | Workspace mutation, discovery, persistence policy |
| `SessionController` | Lock, sleep, console-session state, and recovery-input monitoring | Cancelling or restarting unrelated subsystems directly |
| `InputController` | Event tap, Carbon hotkeys, normalized keybindings, focused-window interaction signals | Workspace mutation, recovery policy, layout |
| `ConfigStore` | Config source, parsing, normalization, effective config, reload and save results | Reconfiguring input, layout, timers, or UI directly |
| `PersistenceController` | Persistent file I/O, debounce/autosave timers, cleanup watcher, emergency restore documents | Reading live mutable model state on delayed callbacks |
| UI controllers | Menu/settings lifecycle, rendering, user actions, save-result presentation | Direct mutable access to coordinator or model state |
| `WindowSystemClient` | Low-level AX, CoreGraphics, and SkyLight reads/writes | Application policy or logical ownership |

`WindowManagement` may contain private helpers such as `WorkspaceModel`,
`AXWindowMonitor`, `WindowReconciler`, `LogicalSpaceManager`, and
`TransientWindowDetector`. `LayoutController` may similarly contain a stateless
`LayoutEngine` and a private snapshot presentation controller. These helpers do
not all need to become top-level services or protocols.

## Coordination contract

Cross-domain asynchronous inputs should enter through a typed event envelope:

```swift
enum AppEvent {
    case input(InputEvent)
    case session(SessionEvent)
    case windows(WindowEvent)
    case layout(LayoutEvent)
    case config(ConfigEvent)
    case persistence(PersistenceEvent)
    case ui(UIAction)
}
```

The exact associated values will be defined during Phase 1. The following rules
apply regardless of the final type names:

1. Top-level subsystems do not call one another directly.
2. A subsystem emits facts, results, failures, or requests to the coordinator.
3. The coordinator issues typed commands to the appropriate subsystem.
4. Coordinator event handling is main-actor isolated and non-reentrant.
5. Every delayed operation that can become stale carries a generation or request
   token.
6. Queries use immutable snapshots or narrow synchronous methods; they do not
   expose mutable collections.
7. Animation frames, launch-settling ticks, persistence debounce ticks, and UI
   drawing stay internal unless they create a cross-domain consequence.

## Standard model-change pipeline

Logical mutations should return a single result describing their consequences:

```swift
struct ModelChange {
    var previousLayout: LayoutSnapshot?
    var currentLayout: LayoutSnapshot
    var layoutRequired: Bool
    var focusRequested: Bool
    var persistenceChanged: Bool
    var statusChanged: Bool
}
```

This is a design sketch, not a fixed public API. Its purpose is to replace the
scattered combinations of layout projection, logical-Space saving, persistence
scheduling, and status refreshes.

The coordinator handles a model change in a consistent order:

1. submit or retarget the layout request;
2. mark persistence dirty when required;
3. publish a new UI status snapshot when required;
4. drain permitted pending work after layout becomes idle.

## Migration dashboard

Status values are `Not started`, `In progress`, `Blocked`, and `Complete`.

| Phase | Description | Status | Last update | Notes |
| --- | --- | --- | --- | --- |
| 0 | Correctness prerequisites and observability | Complete | 2026-08-24 | Layout ownership, snapshot consistency, reconciliation, termination, builds, and user-run smoke pass complete |
| 1 | Coordinator contracts and event-routing seam | Complete | 2026-08-24 | Deterministic event queue/routing landed; user reported the application smoke pass healthy |
| 2 | Input and session event sources | Complete | 2026-08-24 | Ownership extracted; debug/release builds and user-run focused runtime pass complete |
| 3 | Configuration, persistence, and UI boundaries | Complete | 2026-08-24 | Ownership extraction, debug/release builds, and focused user-run runtime pass complete |
| 4 | Layout and presentation ownership | Complete | 2026-08-24 | Ownership extraction, debug/release builds, and user-run focused runtime pass complete |
| 5 | Logical window and workspace ownership | Complete | 2026-08-24 | Ownership extraction, debug/release builds, and user-run focused runtime pass complete |
| 6 | Window observation and reconciliation | Not started | 2026-08-24 | Complete the window-management boundary |
| 7 | Integration cleanup and actor isolation | Not started | 2026-08-24 | Remove forwarding and obsolete state |
| 8 | Manual stabilization and migration closeout | Not started | 2026-08-24 | Full scenario pass and documentation |

## Phase 0 — correctness prerequisites and observability

### Objective

Remove known ordering defects that would otherwise be moved into new components,
and establish enough runtime evidence to migrate safely without automated tests.

### Work

- Give every layout request explicit lock ownership using a generation or token.
- Prevent an older delayed unlock from releasing a newer layout request.
- Synchronize snapshot layers, targets, hidden real windows, projected layout,
  and final layout during retarget and no-op requests.
- Cancel, complete, or replace stale-generation snapshot sessions instead of
  allowing their frame runners to remain alive.
- Introduce one reconciliation gateway for AX, timer, menu, launch-settling, and
  full-rescan requests.
- Make termination preparation idempotent and make the cleanup watcher usable
  before and after the first restore snapshot is written.
- Add debug-only state invariants and correlation logging for layout requests,
  reconciliation requests, session transitions, and termination.
- Record a baseline manual behavior pass using the checklist in this document.

### Exit criteria

- Every external reconciliation path enters through the gateway.
- Only the current layout owner can release the layout lock.
- Snapshot session collections cannot silently diverge during retargeting.
- Termination finalization can be called more than once without repeating work.
- `swift build` succeeds.
- Baseline manual scenarios have recorded results and no unresolved critical
  failure is being treated as normal behavior.

## Phase 1 — coordinator contracts and event-routing seam

### Objective

Create the coordinator boundary before transferring large state groups.

### Work

- Introduce working versions of `AppEvent`, `AppPhase`, `ModelChange`,
  `LayoutRequest`, `LayoutEvent`, and `ReconciliationIntent`.
- Add a main-actor, non-reentrant coordinator event queue.
- Give events and delayed results monotonic sequence or generation identifiers.
- Route NSWorkspace, AX, input, session, timer, and UI entry points into the
  coordinator.
- Keep existing implementation methods temporarily, invoked by coordinator
  handlers, so this phase changes routing rather than all behavior at once.
- Move cross-domain pending command and reconciliation admission policy to the
  coordinator.
- Document which events are ignored, deferred, coalesced, or executed in each
  application phase.

### Exit criteria

- External callbacks do not independently decide cross-subsystem sequencing.
- Application phase and pending high-level intents have one owner.
- Coordinator handlers contain orchestration only; existing domain algorithms
  have not been copied into them.
- Event logging shows a deterministic order and associated request identifiers.
- `swift build` succeeds and the relevant manual scenarios pass.

### Implemented application-phase policy

This is the Phase 1 admission policy implemented by the coordinator. Animation
frames, snapshot-internal polling, layout-lock release, persistence debounce,
and UI drawing remain internal to their current owner because they do not create
an independent cross-domain sequencing decision.

| Application phase | Executed | Deferred/coalesced | Ignored |
| --- | --- | --- | --- |
| `starting` | Session transitions and termination | Commands and reconciliation intents | Other callbacks, which are not expected while synchronous startup is running |
| `running` | Workspace, AX, input, session, timer, config/persistence result, UI, and termination events in sequence order | Focus commands while incompatible layout work is active; reconciliation while layout admission is closed | Stale generation results and environment-guarded domain operations |
| `sessionUnavailable` | Session/recovery input, application launch/termination bookkeeping, UI actions, and termination | Commands and reconciliation intents | Reconciliation/launch-settling timers and callbacks whose existing implementation requires layout tracking |
| `terminating` | A repeated termination request reaches the idempotent termination guard | None | All new work |
| `terminated` | None | None | All events |

Reconciliation coalescing is bounded to one pending intent. A full scan dominates
targeted PID scans, PID sets are unioned, and `adoptFocused` is combined with
logical OR. Every queued event receives a monotonic sequence identifier; delayed
focus probes, launch probes, and reconciliation drains additionally retain their
existing generation or request correlation where staleness is possible.

## Phase 2 — input and session event sources

### Objective

Turn input and session monitoring into components that report facts and requests
instead of manipulating unrelated application state.

### Work

- Extract normal event-tap and Carbon-hotkey handles, mappings, and installation
  lifecycle into `InputController`.
- Make input emit typed command and interaction requests.
- Preserve the synchronous event-consumption result required by event-tap and
  Carbon callbacks.
- Move focused-window interaction monitoring into input or a private input
  helper; emit a focused-window probe request rather than reconciling directly.
- Extract lock, sleep, console-session, and recovery-event-tap state into
  `SessionController`.
- Make session monitoring report availability and recovery candidates.
- Move pause, resume, cancellation, rescan, and timer-restart orchestration into
  the coordinator.
- Keep recovery-target validation as a coordinator-mediated query of window
  state and the window-system adapter.

### Exit criteria

- Input owns all normal input handles and mapping state.
- Session owns all session notification and recovery-input handles.
- Neither component starts, stops, rescans, lays out, or mutates another
  subsystem directly.
- Lock, wake, and recovery traces show one coordinator-controlled transition.
- `swift build` succeeds and input/session manual scenarios pass.

## Phase 3 — configuration, persistence, and UI boundaries

### Objective

Remove file and UI policy from the shared coordinator state.

### Work

- Introduce `ConfigStore` with explicit initial-load, reload-current-source, and
  save results.
- Produce one resolved effective configuration for runtime use.
- Make malformed reloads retain the last known-good document and report failure.
- Ensure settings only report success or close after a successful save.
- Decide and document whether unknown JSON keys are preserved or rejected.
- Remove or implement unsupported shipped keys and reconcile fallback/repository
  default differences.
- Extract persistent-layout, logical-Space, debounce/autosave, cleanup-watcher,
  and restore-file state into `PersistenceController`.
- Make persistence accept immutable snapshots supplied by the coordinator.
- Make autosave timers emit an autosave-due request rather than reading live
  mutable model state.
- Replace UI-to-`Miri` calls with typed UI actions and immutable status/config
  view state.
- Make config changes return to the coordinator, which reconfigures affected
  subsystems in a defined order.

### Exit criteria

- Config and persistence file state no longer lives on the coordinator.
- Delayed persistence work cannot capture and read mutable model collections.
- UI controllers have no general-purpose reference that exposes application
  internals.
- Config save/reload failures are visible and do not report success.
- `swift build` succeeds and config, persistence, and UI manual scenarios pass.

## Phase 4 — layout and presentation ownership

### Objective

Create one owner for logical projection output, presentation state, and applied
managed-window frames.

### Work

- Remove the dormant AX-animation path and obsolete animation parameters before
  defining the new controller API.
- Extract stateless geometry/projection operations into `LayoutEngine`, taking
  immutable layout input, viewport, and effective layout settings.
- Move layout request generation, lock ownership, deferred layout state,
  applied frames/visibility, presentation frames, snapshot session, overlay,
  hidden windows, animation timer, transforms, floating raises, and focus
  request generations into `LayoutController`.
- Give `LayoutController` explicit `submit`, `cancel`, `restoreForTermination`,
  and activity-query operations.
- Emit typed layout-completed, capture-failed, and externally-resized events.
- Keep frame ticks, CALayer manipulation, and snapshot retarget bookkeeping
  internal.
- Split manual resize behavior: observation/debounce, logical width mutation,
  and layout reapplication must have explicit owners.
- Ensure no reconciliation path can mutate the model while a layout request owns
  the application gate.

### Exit criteria

- Coordinator and window-management state contain no snapshot layers, overlays,
  presentation caches, AX-applied frame caches, or compositor transforms.
- All managed-window layout writes are issued by `LayoutController` through the
  window-system adapter.
- A layout request has one token from submission through completion/cancellation.
- `swift build` succeeds and rapid retarget, resize, floating, and termination
  manual scenarios pass.

## Phase 5 — logical window and workspace ownership

### Objective

Move the authoritative logical model and all model mutation behind one API.

### Work

- Create the `WindowManagement` facade and its authoritative `WorkspaceModel`.
- Move canonical managed windows, workspaces, floating windows, active and
  previous focus, empty-workspace focus authority, and width metadata.
- Move logical Space contexts, active context, signatures, Space buffer, and
  context save/load behavior.
- Move fullscreen/minimized placement state and scope it to a logical Space.
- Add global PID/window cleanup across active and inactive contexts, buffers,
  and transition records.
- Preserve reference identity; do not convert the model wholesale to value
  types.
- Move command mutation, insertion, removal, workspace capacity, placement,
  width changes, and logical-Space selection into the model boundary.
- Make mutations return `ModelChange` or a narrower typed result.
- Expose immutable layout, persistence, recovery-validation, and status
  snapshots.
- Remove layout, persistence, UI, and file side effects from model methods.

### Exit criteria

- Workspaces and logical Space contexts have one owner.
- A window cannot be mutable through coordinator-owned collections.
- Command and placement methods produce results instead of invoking layout or
  persistence directly.
- Runtime invariants verify unique membership and valid active indexes.
- `swift build` succeeds and command, placement, fullscreen, minimize, and
  native-Space manual scenarios pass.

## Phase 6 — window observation and reconciliation

### Objective

Complete `WindowManagement` by separating OS observations from logical mutation
and centralizing reconciliation behavior.

### Work

- Move AX observer handles and NSWorkspace window/application observation into
  `AXWindowMonitor` or an equivalent private component.
- Represent discovered windows as observations/descriptors; let the model retain
  canonical `ManagedWindow` instances.
- Move focused-window probes, active rescans, launch settling, placeholder
  probes, and periodic discovery scheduling behind the window-management
  boundary.
- Make timers emit reconciliation intents to the coordinator.
- Consolidate targeted and full missing-window handling into one disposition
  classifier with explicit full-scan/native-Space context.
- Re-check coordinator admission after each reconciliation result that can
  trigger layout.
- Make iteration order deterministic where order affects focus or layout.
- Keep transient-system-window detection as a private environment guard and
  report its blocking/recovery result to the coordinator.
- Ensure process termination cleans every logical context and transient record,
  including while normal layout tracking is paused.

### Exit criteria

- AX and NSWorkspace callbacks do not mutate workspaces or invoke layout.
- All scan sources use the same reconciliation admission path.
- Targeted and full reconciliation share missing-window classification.
- Observation/timer state has one owner and logical state has one owner.
- `swift build` succeeds and lifecycle/reconciliation manual scenarios pass.

## Phase 7 — integration cleanup and actor isolation

### Objective

Remove transitional access paths and make the new ownership enforceable.

### Work

- Remove temporary forwarding properties and compatibility methods from `Miri`.
- Rename `Miri` to `AppCoordinator` if that improves clarity after the boundary
  is established.
- Make stateful application components main-actor isolated.
- Keep only justified cross-thread `@unchecked Sendable` wrappers, such as the
  lock-protected display-link adapter or immutable low-level system wrappers.
- Remove obsolete files, unused properties, duplicated helpers, and dead event
  paths left behind by extraction.
- Tighten access control so component-owned state is private or `private(set)`.
- Ensure top-level subsystems retain no direct references to one another.
- Update architecture, configuration, recovery, animation, and reconciliation
  documentation to match the implemented design.

### Exit criteria

- The coordinator owns orchestration state only.
- Component boundaries are enforced by APIs and access control rather than
  comments or naming conventions.
- No top-level subsystem mutates another subsystem's state directly.
- Documentation describes the implemented flow rather than the transitional one.
- Debug and release builds succeed.

## Phase 8 — manual stabilization and migration closeout

### Objective

Exercise the completed architecture across Miri's supported operating scenarios
and close the migration with known limitations recorded.

### Work

- Run the complete manual scenario matrix below on the supported single-display
  setup.
- Review coordinator traces for stale tokens, reentrant handling, unbounded
  queues, repeated termination, and reconciliation during layout.
- Exercise a longer normal-use session with active rescans and persistence
  enabled.
- Verify normal quit and forced termination restoration separately.
- Resolve critical regressions or record non-critical known issues with explicit
  follow-up ownership.
- Update the dashboard, ownership ledger, decision log, and final progress entry.

### Exit criteria

- Every applicable manual scenario has a recorded result.
- No unresolved critical issue violates the ownership or event-ordering model.
- Runtime invariants remain clean during the stabilization pass.
- The current architecture documentation and source ownership agree.
- Migration status is changed to `Complete`.

## Ownership transfer ledger

Update this table when a state group begins and finishes moving. During a
transition, record temporary forwarding explicitly rather than claiming dual
ownership.

| State group | Current owner | Target owner | Phase | Status |
| --- | --- | --- | --- | --- |
| Application phase and cross-domain pending intents | Transitional coordinator core in `Miri`; domain state remains in extensions | `AppCoordinator` | 1 | Complete |
| Event tap, hotkeys, key maps, focused interaction monitor | `InputController`, with temporary lifecycle forwarding methods on `Miri` | `InputController` | 2 | Complete |
| Lock/sleep/console/recovery input state | `SessionController`, with temporary state forwarding properties on `Miri` | `SessionController` | 2 | Complete |
| Loaded config and modification tracking | `ConfigStore`; `Miri.config` temporarily forwards the resolved runtime value | `ConfigStore` | 3 | Complete |
| Persistent timers, state files, restore snapshot, watcher | `PersistenceController`; temporary restoration-state forwarding remains on `Miri` | `PersistenceController` | 3 | Complete |
| Settings/status integration | Typed `UIAction` sink and immutable `StatusMenuViewState`; no UI controller retains `Miri` | UI actions and immutable view state | 3 | Complete |
| Applied frames, visibility, transforms, layout lock | `LayoutController`, through `LayoutWindowSystemAdapter` | `LayoutController` | 4 | Complete |
| Snapshot session, overlay, hidden windows, animation timer | `LayoutController`; frame runner and CALayer bookkeeping stay internal | `LayoutController` | 4 | Complete |
| Workspaces, active focus, floating windows, width state | `WorkspaceModel`, through `WindowManagement`; read-only compatibility views remain on `Miri` | `WorkspaceModel` | 5 | Complete |
| Logical Space contexts and buffer | `WorkspaceModel`, through `WindowManagement`; read-only compatibility views remain on `Miri` | `WindowManagement` | 5 | Complete |
| Fullscreen/minimized transition placement | Active `LogicalSpaceContext`, through `WindowManagement` | `WindowManagement` | 5 | Complete |
| AX observers and discovered-window conversion | `Miri` | `WindowManagement`/`AXWindowMonitor` | 6 | Not started |
| Reconciliation, active rescan, launch settling | `Miri` | `WindowManagement` plus coordinator admission | 6 | Not started |

## Manual verification matrix

Use `Pass`, `Fail`, `Not run`, or `Not applicable`. A phase only needs the
scenarios affected by that phase; Phase 8 requires every applicable scenario.

| Area | Scenario | Baseline | Latest result | Notes |
| --- | --- | --- | --- | --- |
| Startup | Start with existing normal windows | Not run | Not run | |
| Startup | Start with no manageable windows | Not run | Not run | |
| Commands | Rapid left/right focus and snapshot retarget | Not run | Pass | User-reported Phase 4 focused pass |
| Commands | Workspace focus, previous workspace, and empty workspace | Not run | Pass | User-reported Phase 5 focused pass |
| Commands | Move and resize one/all columns | Not run | Pass | User-reported Phase 4 focused pass |
| Lifecycle | Launch app with delayed/placeholder AX windows | Not run | Not run | |
| Lifecycle | Close one window and last window without quitting app | Not run | Not run | |
| Lifecycle | Quit app with windows in active and inactive contexts | Not run | Pass | User-reported Phase 5 focused pass |
| Window state | Minimize and restore a managed window | Not run | Pass | User-reported Phase 5 focused pass |
| Window state | Enter and exit native fullscreen | Not run | Pass | User-reported Phase 5 focused pass |
| Window state | Floating window during layout and workspace changes | Not run | Pass | User-reported Phase 4 focused pass |
| Native Spaces | Move a managed window between macOS Spaces | Not run | Pass | User-reported Phase 5 focused pass |
| Native Spaces | Switch Spaces with buffered and fullscreen windows | Not run | Pass | User-reported Phase 5 focused pass |
| Session | Lock and unlock, then recover by relevant interaction | Not run | Not run | |
| Session | Sleep and wake, then recover by relevant interaction | Not run | Not run | |
| Reliability | Active rescan for configured problematic app | Not run | Not run | |
| Configuration | Reload valid config | Not run | Pass | User-reported Phase 3 focused pass |
| Configuration | Reload malformed config and keep last known-good state | Not run | Pass | User-reported Phase 3 focused pass |
| Configuration | Save valid and invalid Settings drafts | Not run | Pass | User-reported Phase 3 focused pass |
| Persistence | Restart and restore persistent layout/Spaces | Not run | Pass | User-reported Phase 3 focused pass |
| Termination | Normal menu quit restores managed windows once | Not run | Pass | User-reported Phase 3 and Phase 4 focused passes |
| Termination | Forced termination triggers cleanup restoration | Not run | Not run | |

## Runtime invariants

Prefer debug-only assertions plus structured logs. An assertion that risks
terminating a normal release build should remain disabled outside debug builds.

- A managed window has at most one active tiled/floating placement.
- Active workspace and column indexes are valid after every model mutation.
- A runtime window ID is not simultaneously active and buffered without an
  explicitly documented transition.
- Process termination removes the PID from every context and transition store.
- Only the active layout token can finish or release layout ownership.
- Reconciliation does not mutate logical state while layout admission is closed.
- Snapshot targets, layers, hidden-window records, and final layout agree on
  membership after every retarget.
- Coordinator event handling does not re-enter itself.
- Pending command and reconciliation queues remain bounded or coalesced.
- Termination finalization executes at most once.

## Progress reporting rules

This document is the source of truth for migration status. Update it in the same
change as each migration batch.

For every batch:

1. Update `Last updated`, `Migration status`, `Current phase`, and
   `Last verified revision` in Document status.
2. Update the relevant dashboard row.
3. Update every ownership-ledger row affected by the batch.
4. Record build, manual, runtime-invariant, and shadow-comparison evidence.
5. Record intentional behavior changes separately from structural changes.
6. List known regressions, unresolved risks, and temporary forwarding APIs.
7. Add a progress-log entry using the template below.
8. Mark a phase `Complete` only when all of its exit criteria are satisfied.

Progress should be described in terms of ownership and behavior, not files or
line counts. For example, "snapshot session state is now private to
`LayoutController`" is meaningful; "moved 700 lines" is not.

### Progress entry template

```markdown
### YYYY-MM-DD — Phase N: short batch title

- Status: In progress | Blocked | Complete
- Revision/commit: identifier or `working tree`
- Structural changes:
  - What responsibility or state moved, and from where to where.
- Contract changes:
  - Events, commands, snapshots, or result types added/changed.
- Intentional behavior changes:
  - `None`, or an explicit list.
- Temporary compatibility:
  - Forwarding properties, adapters, or duplicated paths still present.
- Verification:
  - `swift build`: Pass/Fail
  - `swift build -c release`: Pass/Fail/Not run
  - Manual scenarios: names and Pass/Fail/Not run
  - Runtime invariants/log review: result
  - Shadow comparison: result or Not applicable
- Known issues and risks:
  - Concrete outstanding problems.
- Decisions:
  - Decision-log identifiers added by this batch.
- Next step:
  - The next bounded ownership transfer.
```

## Progress log

Add new entries above older entries.

### 2026-08-24 — Phase 5: logical window and workspace ownership

- Status: Complete
- Revision/commit: working tree
- Structural changes:
  - `WorkspaceModel` now owns the canonical logical-Space context graph. The
    active workspace projection is the active context itself rather than a
    cloned coordinator-owned mirror.
  - `WindowManagement` is the side-effect-free mutation/query facade for
    workspace selection and capacity, focus, column movement, insertion and
    removal, floating placement, width metadata, logical-Space selection and
    buffering, and fullscreen/minimized placement state.
  - Fullscreen, minimized, and pending fullscreen-transition placement state is
    scoped to its `LogicalSpaceContext`.
  - PID cleanup now removes windows across active and inactive contexts, the
    Space buffer, fullscreen/minimized placement, and transition records.
  - Layout, status, and persistence consumers now capture immutable model
    snapshots; persistent documents are constructed by `WindowManagement` and
    handed to `PersistenceController` for file I/O.
- Contract changes:
  - Added immutable `WorkspaceModelSnapshot` and typed workspace-selection,
    removal, and global-cleanup results.
  - Command orchestration now constructs a `ModelChange`, then submits layout,
    marks persistence dirty, and publishes status in the coordinator-defined
    order.
  - Debug invariants validate unique context IDs, valid workspace/column
    indexes, unique tiled/floating membership, and cross-Space uniqueness with
    an explicit exception for buffered transitions.
- Intentional behavior changes:
  - Process termination cleanup covers inactive logical Spaces and transition
    stores instead of only the active projection.
- Temporary compatibility:
  - `Miri` retains read-only forwarding views and orchestration helpers for
    legacy observation/reconciliation call sites; mutation storage and APIs are
    owned by `WindowManagement`.
  - AX observation and reconciliation scheduling remain on `Miri` until Phase 6.
- Verification:
  - `swift build`: Pass
  - `swift build -c release`: Pass
  - `git diff --check`: Pass
  - Ownership audit: Pass; remaining direct workspace writes outside
    `WindowManagement` construct detached restoration objects before atomic
    adoption
  - Manual scenarios: Pass; user reported workspace/previous/empty focus,
    column movement and width changes, minimize/restore, fullscreen, floating,
    native-Space switching/buffering, cross-context cleanup, and restart
    behavior working correctly
  - Runtime invariants/log review: Pass; debug-only model invariants remained
    quiet during the focused user run
  - Shadow comparison: Not applicable; the existing reference model and
    placement algorithms were retained behind the new owner
- Known issues and risks:
  - Existing AppKit actor-isolation warnings in snapshot overlay code remain
    assigned to Phase 7.
- Decisions:
  - D-013 and D-014.
- Next step:
  - Begin Phase 6 by moving AX observation and reconciliation behind the
    window-management boundary.

### 2026-08-24 — Phase 4: layout and presentation ownership

- Status: Complete
- Revision/commit: working tree
- Structural changes:
  - `LayoutEngine` now projects immutable workspace/window geometry inputs,
    viewport, and effective layout settings without reading coordinator state.
  - `LayoutController` owns request tokens, deferred submissions, applied frame
    and visibility caches, presentation frames, snapshot session/overlay/layers,
    hidden windows, compositor transforms, floating raises, and focus requests.
  - `LayoutWindowSystemAdapter` is the single managed-window frame, level, and
    compositor write boundary used by layout and termination restoration.
  - `ManualResizeController` owns resize observation/debounce and suppression;
    model width mutation remains in window management and reapplication is
    submitted to `LayoutController`.
- Contract changes:
  - `submit`, `cancel`, `restoreForTermination`, and the immutable `activity`
    query are explicit controller operations.
  - Every submission receives one `LayoutRequestToken`, including deferred
    work; replacement, capture failure, completion, and cancellation emit typed
    `LayoutEvent` values carrying that token.
  - Deferred submissions retain their immutable captured layout state and
    viewport instead of recapturing mutable model collections in a delayed
    callback.
  - Reconciliation entry points reject mutation while the controller activity
    gate is owned and coalesce a typed reconciliation request instead.
- Intentional behavior changes:
  - Removed the dormant AX animation implementation and its unused motion flags
    and controller parameters. Legacy AX duration/curve config keys remain
    accepted for compatibility but are ignored and no longer appear in the
    shipped config or Settings UI.
- Temporary compatibility:
  - Workspace collections and width rules remain on `Miri` until Phase 5;
    `LayoutController` receives their captured values for projection but does
    not mutate them.
  - Geometry mutation helpers that update workspace scroll offsets remain with
    command/model code; final projection is exclusively produced by
    `LayoutEngine` through `LayoutController`.
- Verification:
  - `swift build`: Pass
  - `swift build -c release`: Pass
  - `git diff --check`: Pass
  - Ownership audit: Pass; coordinator/window-management source contains no
    snapshot layers, overlays, presentation/applied-frame caches, or compositor
    transform storage, and managed layout writes resolve only through the
    adapter
  - Manual scenarios: Pass; user reported rapid snapshot retarget, column
    move/resize, manual resize, floating-window, and termination checks working
    correctly
- Known issues and risks:
  - Existing AppKit actor-isolation warnings in snapshot overlay code remain for
    Phase 7.
- Decisions:
  - D-011 and D-012.
- Next step:
  - Begin Phase 5 by extracting logical window, workspace, focus, floating, and
    logical-Space ownership from `Miri`.

### 2026-08-24 — Phase 3: config, persistence, and UI ownership

- Status: Complete
- Revision/commit: working tree
- Structural changes:
  - `ConfigStore` now owns source selection, file metadata, strict decoding,
    normalization, last-known-good document state, resolved runtime config, and
    save/reload results.
  - `PersistenceController` now owns state URLs, loaded restoration documents,
    layout debounce and logical-Space autosave timers, the crash restore file,
    and cleanup-watcher lifecycle.
  - Settings and status-menu controllers no longer retain `Miri`; they consume
    typed UI actions and immutable config/status values.
- Contract changes:
  - Persistence timers emit `autosaveDue` and the coordinator supplies a fresh
    immutable layout or logical-Space snapshot before file encoding.
  - Settings save actions carry close-on-success intent, and success/failure is
    presented only after `ConfigStore` returns its result.
  - Config changes return to the coordinator, which applies capacity, input,
    persistence, timer, discovery, and projection reconfiguration in that order.
- Intentional behavior changes:
  - Unknown config root keys and unknown keys inside window rules are rejected;
    the documented legacy focus-alignment key remains accepted for migration.
  - A malformed selected source no longer falls through to a lower-priority
    config, and a malformed reload retains the last known-good document.
  - Removed the unsupported shipped `hide_method` key and aligned compiled
    fallback defaults with the repository config, including the macOS screenshot
    exclusion instead of disabling move-to-workspace-5.
- Temporary compatibility:
  - Restoration snapshots and restore-needed flags have computed forwarding
    properties on `Miri` for Phase 5 call sites; file and timer state is not
    duplicated there.
  - Effective-setting accessors still live on `Miri` and read the single
    resolved config until integration cleanup.
- Verification:
  - `swift build`: Pass
  - `swift build -c release`: Pass
  - Manual scenarios: Pass; user reported the focused valid/malformed reload,
    Settings result, persistence restart, normal quit, and status-menu checks
    working correctly
  - Runtime invariants/log review: ownership audit confirms delayed persistence
    closures only emit due events and UI source files contain no `Miri` reference
  - Shadow comparison: Not applicable
- Known issues and risks:
  - Existing AppKit actor-isolation warnings in snapshot presentation remain for
    Phase 7; no new warning source was introduced by this batch.
  - Exact runtime logs were not retained; the complete trace review remains part
    of Phase 8 stabilization.
- Decisions:
  - D-009 and D-010.
- Next step:
  - Begin Phase 4 by removing obsolete animation concepts and extracting layout
    request and snapshot-presentation ownership.

### 2026-08-24 — Phase 2: input and session source ownership

- Status: Complete
- Revision/commit: working tree
- Structural changes:
  - `InputController` now privately owns the normal event tap and run-loop
    source, Carbon registrations and command map, normalized key maps, and the
    focused-window interaction monitor.
  - `SessionController` now owns lock/sleep/console state, session notification
    subscriptions, recovery generation state, and the recovery event tap.
  - Input and session callbacks emit typed coordinator events. Recovery-target
    validation remains a narrow coordinator-mediated query of window state.
- Contract changes:
  - Added a typed recovery-input candidate carrying the observed event and type.
  - Normal input keeps its synchronous consume/pass-through result while
    commands and interactions enter the coordinator queue in their prior order.
- Intentional behavior changes:
  - None.
- Temporary compatibility:
  - `Miri` retains narrow lifecycle forwarding methods for call sites that will
    be cleaned up in Phase 7.
  - Computed session properties on `Miri` forward to `SessionController`; no
    duplicate session state is stored by the coordinator.
- Verification:
  - `swift build`: Pass
  - `swift build -c release`: Pass
  - Manual scenarios: Pass, user-reported focused post-extraction runtime pass;
    exact shortcut-backend and scenario-by-scenario coverage was not retained
  - Runtime invariants/log review: ownership audit confirms handles and mapping
    collections are stored only by their owning controllers
  - Shadow comparison: Not applicable
- Known issues and risks:
  - Exact shortcut-backend coverage was not recorded and remains part of the
    full Phase 8 stabilization matrix.
- Decisions:
  - D-008.
- Next step:
  - Begin the configuration, persistence, and UI ownership transfer in Phase 3.

### 2026-08-24 — Phase 0: layout request ownership prerequisites

- Status: Complete
- Revision/commit: working tree
- Structural changes:
  - Every admitted layout now receives a monotonic owner token; completion,
    cancellation, snapshot preparation, and delayed unlocks validate that token.
  - Snapshot retargeting now prunes stale layers, targets, hidden-window records,
    and presentation frames as one operation.
- Contract changes:
  - Layout request begin, cancel, and release operations now carry an explicit
    generation through immediate and snapshot paths.
- Intentional behavior changes:
  - An older delayed unlock can no longer release a newer layout request.
  - Stale snapshot runners cancel instead of remaining alive indefinitely.
- Temporary compatibility:
  - Layout state still lives on `Miri` until Phase 4.
- Verification:
  - `swift build`: Pass
  - `swift build -c release`: Pass
  - Manual scenarios: Pass, user-reported post-change runtime pass including
    the requested rapid-input and session-recovery focus areas
  - Runtime invariants/log review: debug assertions cover active-token/activity
    agreement and snapshot layer/target/hidden/final-layout membership
  - Shadow comparison: Not applicable
- Known issues and risks:
  - Full scenario-by-scenario trace detail remains for Phase 8 stabilization.
- Decisions:
  - D-007.
- Next step:
  - Continue with Phase 2 input and session ownership.

### 2026-08-24 — Phase 1: coordinator event-routing seam

- Status: Complete
- Revision/commit: working tree
- Structural changes:
  - The coordinator core now owns application phase, a main-actor FIFO event
    queue, event sequencing, command admission, reconciliation admission and
    coalescing, and idempotent termination preparation.
  - Source-specific pending AX reconciliation state was replaced by one
    coordinator-owned reconciliation intent.
  - NSWorkspace, AX, input/hotkey, session, reconciliation timer,
    launch-settling, delayed focus-probe, termination, and menu/settings entry
    points now enter through typed coordinator events.
- Contract changes:
  - Added working `AppEvent`, `AppPhase`, `ModelChange`, `LayoutRequest`,
    `LayoutEvent`, `ReconciliationIntent`, config/persistence result event, and
    monotonic event-sequence contracts.
  - Documented phase-specific execution, deferral, coalescing, and ignore rules.
- Intentional behavior changes:
  - Reconciliation requests that overlap layout work now share one coalescing
    policy: full scan dominates targeted scans, PID targets are unioned, and
    focus adoption requests are combined.
  - Termination preparation now executes at most once even when menu,
    application-delegate, and signal paths overlap.
- Temporary compatibility:
  - `Miri` remains the shared state object and transitional coordinator name.
  - Coordinator handlers call the existing domain implementation methods; the
    state groups planned for Phases 2–6 have not moved.
  - Legacy layout completion paths use a forwarding drain method until
    `LayoutController` emits `LayoutEvent` directly.
- Verification:
  - `swift build`: Pass
  - `swift build -c release`: Pass
  - Manual scenarios: Pass, user-reported application smoke pass after the
    Phase 1 runbook; individual scenario trace detail was not retained
  - Runtime invariants/log review: Compile-time main-actor queue boundary plus
    debug assertions for main-thread execution, non-reentrancy, and bounded
    event/command queues added; live trace review not run
  - Shadow comparison: Not applicable; routing changed without duplicating
    domain algorithms
- Known issues and risks:
  - The broader scenario matrix remains for stabilization; no Phase 1 regression
    was reported in the user-run smoke pass.
  - Existing Swift 6 AppKit actor-isolation warnings in snapshot presentation
    code remain for the later actor-isolation phase.
- Decisions:
  - D-005 and D-006.
- Next step:
  - Transfer input and session event-source ownership in Phase 2.

### 2026-08-24 — Migration plan created

- Status: Not started
- Revision/commit: working tree
- Structural changes:
  - None; this change defines the target boundaries and migration phases.
- Contract changes:
  - Proposed coordinator event and model-change contracts documented.
- Intentional behavior changes:
  - None.
- Temporary compatibility:
  - The current `Miri` shared-state architecture remains unchanged.
- Verification:
  - `swift build`: Pass before this documentation change
  - `swift build -c release`: Not run
  - Manual scenarios: Not run
  - Runtime invariants/log review: Not applicable
  - Shadow comparison: Not applicable
- Known issues and risks:
  - Correctness prerequisites in Phase 0 remain unresolved.
- Decisions:
  - None.
- Next step:
  - Begin Phase 0 with layout-token and snapshot-session ownership fixes.

## Decision log

Record architecture decisions that change or clarify this plan. Use stable IDs
so progress entries can refer to them.

| ID | Date | Decision | Reason | Consequences |
| --- | --- | --- | --- | --- |
| D-001 | 2026-08-24 | Keep stateful application components serialized on the main actor | AX/AppKit objects and current event sources already rely on main-run-loop ordering | Subsystems are classes/components, not independent actors |
| D-002 | 2026-08-24 | Use typed coordinator events rather than a generic internal event bus | Preserve type safety and make cross-domain policy visible | Internal high-frequency callbacks stay within their owner |
| D-003 | 2026-08-24 | Do not require automated tests or CI for phase completion | The project currently cannot rely on a suitable automated environment | Build checks, runtime invariants, trace review, shadow comparison, and manual scenarios provide migration evidence |
| D-004 | 2026-08-24 | Preserve reference identity during logical-model extraction | Existing behavior relies on shared `ManagedWindow` and `Workspace` identity | The migration changes ownership, not the fundamental model semantics |
| D-005 | 2026-08-24 | Establish the coordinator seam inside `Miri` before renaming or moving domain state | Phase 1 is a routing change and later phases transfer ownership incrementally | Existing algorithms remain behind temporary implementation methods while external callbacks use typed events |
| D-006 | 2026-08-24 | Coalesce reconciliation at the coordinator into one bounded intent | Source-specific queues allowed competing sequencing decisions | Full scans dominate targeted scans, PID targets union, and focus adoption combines with logical OR |
| D-007 | 2026-08-24 | Treat the monotonic layout generation as an exclusive request-ownership token | Delayed completion must prove it still owns the application gate | Old unlocks are ignored; preparation, completion, cancellation, and session interruption correlate to one request |
| D-008 | 2026-08-24 | Give input and session sources typed event sinks plus narrow synchronous query closures | Event taps must return consumption synchronously while subsystem state remains private | Controllers do not retain `Miri` or mutate window/layout state; compatibility forwarding remains temporary |
| D-009 | 2026-08-24 | Reject unknown config root/rule keys while retaining the one documented legacy migration key | Settings rewrites typed documents and cannot safely preserve semantics it does not understand | Unsupported keys produce visible load/reload failure instead of being silently dropped; shipped config contains only supported keys |
| D-010 | 2026-08-24 | Make persistence timers emit due events and require coordinator-supplied immutable snapshots | Delayed callbacks must not capture and read mutable workspace or logical-Space collections | File/timer ownership is isolated while snapshot construction remains synchronized with coordinator model state |
| D-011 | 2026-08-24 | Allocate one typed token at layout submission and retain immutable deferred request input | Generation integers and delayed model recapture made ownership and stale completion ambiguous | Completion, cancellation, capture failure, and replacement correlate to the submitted token; deferred work cannot read a later mutable model accidentally |
| D-012 | 2026-08-24 | Split resize debounce, logical width mutation, and frame reapplication across `ManualResizeController`, window management, and `LayoutController` | AX resize handling previously mixed observation state, model mutation, presentation cache writes, and layout cancellation | Each part has one owner and external resize changes emit a typed layout event |
| D-013 | 2026-08-24 | Back the active workspace projection directly with the active `LogicalSpaceContext` | Cloning on every save/load created two mutable representations of one logical Space | Workspace and window reference identity is preserved while the context graph has one authoritative owner |
| D-014 | 2026-08-24 | Treat process/window cleanup as a global model operation | Active-only cleanup could leave stale membership in inactive Spaces, buffers, and transition state | Termination cleanup returns one typed result after scanning every logical context and transition store |
