# Miri Subsystem Migration Plan

## Document status

- Plan status: Proposed
- Migration status: In progress
- Last updated: 2026-08-24
- Current phase: Phase 1 — coordinator contracts and event-routing seam
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
| `AppCoordinator` | Application phase, event sequencing, layout/reconciliation admission, active request tokens, pending commands and reconciliation intents, startup and termination orchestration | Workspace collections, AX observers, CALayers, geometry, file encoding, menu rendering |
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
| 0 | Correctness prerequisites and observability | In progress | 2026-08-24 | Reconciliation gateway and idempotent termination landed; layout/snapshot prerequisites remain |
| 1 | Coordinator contracts and event-routing seam | In progress | 2026-08-24 | Event queue and routing seam implemented; live manual trace pass remains |
| 2 | Input and session event sources | Not started | 2026-08-24 | Move event-source state and orchestration |
| 3 | Configuration, persistence, and UI boundaries | Not started | 2026-08-24 | Remove storage/UI reach-through |
| 4 | Layout and presentation ownership | Not started | 2026-08-24 | One owner for layout request lifecycle |
| 5 | Logical window and workspace ownership | Not started | 2026-08-24 | Move commands, placement, and Space state |
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
| Application phase and cross-domain pending intents | Transitional coordinator core in `Miri`; domain state remains in extensions | `AppCoordinator` | 1 | In progress |
| Event tap, hotkeys, key maps, focused interaction monitor | `Miri` | `InputController` | 2 | Not started |
| Lock/sleep/console/recovery input state | `Miri` | `SessionController` | 2 | Not started |
| Loaded config and modification tracking | `Miri`/`MiriConfig` | `ConfigStore` | 3 | Not started |
| Persistent timers, state files, restore snapshot, watcher | `Miri` | `PersistenceController` | 3 | Not started |
| Settings/status integration | UI controllers with direct `Miri` access | UI actions and immutable view state | 3 | Not started |
| Applied frames, visibility, transforms, layout lock | `Miri` | `LayoutController` | 4 | Not started |
| Snapshot session, overlay, hidden windows, animation timer | `Miri` and snapshot helper objects | `LayoutController` | 4 | Not started |
| Workspaces, active focus, floating windows, width state | `Miri` | `WorkspaceModel` | 5 | Not started |
| Logical Space contexts and buffer | `Miri` | `WindowManagement` | 5 | Not started |
| Fullscreen/minimized transition placement | `Miri` | `WindowManagement` | 5 | Not started |
| AX observers and discovered-window conversion | `Miri` | `WindowManagement`/`AXWindowMonitor` | 6 | Not started |
| Reconciliation, active rescan, launch settling | `Miri` | `WindowManagement` plus coordinator admission | 6 | Not started |

## Manual verification matrix

Use `Pass`, `Fail`, `Not run`, or `Not applicable`. A phase only needs the
scenarios affected by that phase; Phase 8 requires every applicable scenario.

| Area | Scenario | Baseline | Latest result | Notes |
| --- | --- | --- | --- | --- |
| Startup | Start with existing normal windows | Not run | Not run | |
| Startup | Start with no manageable windows | Not run | Not run | |
| Commands | Rapid left/right focus and snapshot retarget | Not run | Not run | |
| Commands | Workspace focus, previous workspace, and empty workspace | Not run | Not run | |
| Commands | Move and resize one/all columns | Not run | Not run | |
| Lifecycle | Launch app with delayed/placeholder AX windows | Not run | Not run | |
| Lifecycle | Close one window and last window without quitting app | Not run | Not run | |
| Lifecycle | Quit app with windows in active and inactive contexts | Not run | Not run | |
| Window state | Minimize and restore a managed window | Not run | Not run | |
| Window state | Enter and exit native fullscreen | Not run | Not run | |
| Native Spaces | Move a managed window between macOS Spaces | Not run | Not run | |
| Native Spaces | Switch Spaces with buffered and fullscreen windows | Not run | Not run | |
| Session | Lock and unlock, then recover by relevant interaction | Not run | Not run | |
| Session | Sleep and wake, then recover by relevant interaction | Not run | Not run | |
| Reliability | Active rescan for configured problematic app | Not run | Not run | |
| Configuration | Reload valid config | Not run | Not run | |
| Configuration | Reload malformed config and keep last known-good state | Not run | Not run | |
| Configuration | Save valid and invalid Settings drafts | Not run | Not run | |
| Persistence | Restart and restore persistent layout/Spaces | Not run | Not run | |
| Termination | Normal menu quit restores managed windows once | Not run | Not run | |
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

### 2026-08-24 — Phase 1: coordinator event-routing seam

- Status: In progress
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
  - Manual scenarios: Not run; require an interactive Accessibility-enabled
    macOS session
  - Runtime invariants/log review: Compile-time main-actor queue boundary plus
    debug assertions for main-thread execution, non-reentrancy, and bounded
    event/command queues added; live trace review not run
  - Shadow comparison: Not applicable; routing changed without duplicating
    domain algorithms
- Known issues and risks:
  - Phase 0 layout-token and snapshot-session correctness prerequisites remain
    unresolved and prevent Phase 1 from being marked complete.
  - Live event ordering and affected manual scenarios have not yet been run.
  - Existing Swift 6 AppKit actor-isolation warnings in snapshot presentation
    code remain for the later actor-isolation phase.
- Decisions:
  - D-005 and D-006.
- Next step:
  - Complete the Phase 0 layout-token prerequisites, then run the Phase 1 live
    trace and manual scenario pass before closing this phase.

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
