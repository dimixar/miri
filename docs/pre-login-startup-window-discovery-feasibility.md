# Pre-Login Startup Window Discovery Feasibility

## Feasibility assessment

**Yes—this is feasible, and macOS exposes a surprisingly direct signal for it.**

The key API is:

```swift
CGSessionCopyCurrentDictionary()
```

and, specifically:

```swift
kCGSessionLoginDoneKey
```

Apple describes that key as:

> “A CFBoolean value indicating whether the login operation has been done.”

This is a public CoreGraphics API available far earlier than Miri’s macOS 13 deployment target.

- [CGSessionCopyCurrentDictionary](https://developer.apple.com/documentation/coregraphics/cgsessioncopycurrentdictionary/)
- [kCGSessionLoginDoneKey](https://developer.apple.com/documentation/coregraphics/kcgsessionlogindonekey)

The SDK header also exposes two Darwin notification names:

```c
com.apple.coregraphics.GUIConsoleSessionChanged
com.apple.coregraphics.GUISessionUserChanged
```

These can signal that the session dictionary should be checked again.

## The most useful distinction

At process launch, inspect the current WindowServer session:

| Situation | `kCGSessionLoginDoneKey` |
|---|---:|
| Process launched before initial GUI login completes | `false`, or possibly unavailable during a transition |
| Normal launch after the user has logged in | `true` |
| Screen subsequently locked | Normally remains `true` |
| System sleeps and wakes | Remains `true` |
| Normal unlock after login | Remains `true` |

That gives Miri the distinction you need:

> Was the login operation already complete when this particular Miri process started?

This is much more suitable than `IOConsoleLocked`, because a lock state by itself does not distinguish the initial login screen from a later screen lock.

A process-lifetime value such as this would represent the distinction:

```text
launchedBeforeInitialLoginCompleted =
    CG session LoginDone was explicitly false at startup
```

Once login completes, that startup condition is retired permanently. A later lock or sleep in the same Miri process must continue to use the existing conservative recovery path.

---

# What Miri currently does

Miri currently samples two values in `Sources/Miri/System/MiriSessionState.swift`:

1. `IOConsoleLocked`
2. `kCGSessionOnConsoleKey`

Its session availability is:

```swift
isWorkspaceSessionActive
    && !isScreenLocked
    && !isSystemSleeping
```

It does **not** currently inspect `kCGSessionLoginDoneKey`.

If the session appears unavailable during startup, Miri sets:

```swift
isAwaitingSessionRecoveryInteraction = true
```

That causes the initial scan in `Miri.start()` to be skipped:

```swift
if isLayoutTrackingAllowed {
    rescanWindows(adoptFocused: true)
}
```

When the session subsequently becomes available, Miri waits for interaction with a relevant managed window before resuming.

That design is good for an ordinary lock/unlock cycle because Miri already has a valid window model and wants to avoid reacting to the lock/login UI. It is problematic on initial startup because Miri has no model yet.

## The startup deadlock

A recovery interaction currently qualifies only if it targets:

- An already managed window, or
- A window belonging to a PID whose launch Miri observed while waiting

At pre-login startup:

- `allWindows()` is empty because the initial scan was skipped.
- Some resume applications may already have launched before Miri registered its `NSWorkspace` observer.
- Those applications therefore might not be in `pendingSessionRecoveryLaunchedPIDs`.
- Interaction with their windows cannot release the recovery guard.
- The regular reconciliation timer is also not running while tracking is blocked.

Consequently, Miri can remain waiting indefinitely, even after the actual desktop becomes usable.

There is a second, less severe path: if the current checks incorrectly make the pre-login session look available, Miri may perform one empty initial scan. It will then rely on application notifications, AX notifications, or the default 60-second safety rescan. Login-resumed applications that were already running but had no AX windows during that first scan can be missed for a significant period.

So the issue you are seeing is consistent with the current architecture.

---

# Recommended detection strategy

## Primary signal: `kCGSessionLoginDoneKey`

At startup, read the whole session dictionary and distinguish three outcomes:

```text
loginDone == false → definitely pre-login bootstrap
loginDone == true  → normal logged-in startup
dictionary/key missing → unknown; handle conservatively
```

Do not infer `false` merely because the dictionary or key is missing. Apple documents that `CGSessionCopyCurrentDictionary()` may return `nil` when the process is not running in a Quartz GUI session or WindowServer is unavailable.

A missing value during startup could represent a transient initialization issue rather than definitive pre-login state.

## Supporting signals

Before doing any window discovery or placement, continue requiring:

- `kCGSessionOnConsoleKey == true`
- `IOConsoleLocked != true`
- Not sleeping
- No transient system/login window
- `kCGSessionLoginDoneKey == true`

`kCGSessionLoginDoneKey` identifies the initial-login condition. The other signals make sure Miri does not act during an unstable transition.

## How to notice login completion

There are two reasonable approaches.

### 1. Short polling timer

Check `CGSessionCopyCurrentDictionary()` every 0.5–1 second while startup bootstrap mode is active.

This is simple, bounded, and cheap. Polling one small session dictionary for a few seconds at login is negligible compared with scanning every application’s Accessibility tree.

### 2. Darwin notifications plus polling fallback

The public CoreGraphics header defines:

```text
com.apple.coregraphics.GUISessionUserChanged
com.apple.coregraphics.GUIConsoleSessionChanged
```

Miri could register for these through the Darwin notify APIs and re-read the session dictionary when either fires.

Notifications should be treated as **“state may have changed”**, not as authoritative proof that login is complete. Re-read `kCGSessionLoginDoneKey` afterward.

A small polling fallback is still advisable because registration can race with a state transition and session notification behavior should be validated on all supported macOS versions.

---

# Evaluation of the active-scan idea

The general idea is good, but this stopping condition is too weak:

> Stop startup scanning as soon as any window is detected.

The first detectable window does not mean login restoration is finished.

macOS resume can produce a sequence like:

1. Finder/Desktop becomes available.
2. One lightweight application exposes its window.
3. Other processes launch.
4. Some applications become regular apps before exposing AX windows.
5. Electron or other complex apps expose placeholder windows.
6. Restored documents and secondary windows appear several seconds later.

If Miri stops on the first window, it can still miss most resumed windows.

It may also detect a window that is:

- Ignored by a rule
- A transient system window
- A placeholder
- Minimized
- Native fullscreen
- Not AX-manageable
- Owned by an application whose other windows are still loading

## Better lifecycle

Use two startup phases:

```text
waitingForLogin → settlingDesktop → normalOperation
```

### Phase 1: waiting for login

This phase exists only when `kCGSessionLoginDoneKey` was false at process launch.

While in this phase:

- Do not perform ordinary layout mutation.
- Do not accept input as proof that the desktop is ready.
- Do not run snapshot animations.
- Recheck login/session state periodically.
- Continue observing app launch and termination events if possible.
- Do not start the normal reconciliation or active-rescan timers yet.

Transition when all live checks say:

```text
loginDone
onConsole
not locked
not sleeping
no transient login/system UI
```

### Phase 2: settling the desktop

Once login is complete, scan frequently for a bounded period.

A reasonable starting policy would be:

- Poll every 0.5–1 second.
- Require a short minimum grace period, perhaps 3–5 seconds.
- Continue until the discovered window/application set is unchanged for two or three consecutive polls.
- Use a hard timeout, perhaps 20–35 seconds.

The hard timeout is important because one application with broken Accessibility behavior must not block Miri indefinitely.

After the timeout or stability condition, perform the authoritative layout reconciliation and enter normal event-driven operation.

### Phase 3: normal operation

Startup mode is permanently retired for this process.

From then on:

- Application launch and AX notifications handle normal changes.
- The long reconciliation timer remains a safety net.
- Later lock/unlock and sleep/wake cycles use the existing managed-interaction recovery guard.
- Startup polling is never rearmed.

That final property ensures this behavior happens only for initial login and does not weaken Miri’s existing lock/sleep safety.

---

# Important persistence concern

There is a significant issue beyond simply discovering windows.

Miri’s persistent layout restoration is partly one-shot. If an early startup scan sees only one or two restored applications, it may consume the saved layout using that partial window set. Windows that appear later may then be inserted as new windows instead of being restored to their saved workspaces and columns.

In particular:

- `needsPersistentLayoutRestore` is cleared once at least one persistent placement succeeds.
- `needsPersistentLogicalSpaceRestore` is cleared on its first restore attempt.
- A partial matching logical-Space context can be reconstructed without windows that have not appeared yet.

Therefore, repeatedly running the current mutating `rescanWindows()` immediately after the first detectable window is not ideal.

## Better approach

During the settling phase, there should ideally be a distinction between:

1. **Probe discovery**
   - Enumerate running applications and AX windows.
   - Measure whether the set is stabilizing.
   - Do not consume persistent restoration state.
   - Do not move windows yet.

2. **Authoritative initial reconciliation**
   - Run once the desktop is reasonably settled.
   - Apply persistent logical-Space and layout state.
   - Project the windows.
   - Mark the initial model established.

A simpler implementation could do repeated normal rescans, but it would be less reliable for preserving saved ordering across a full restart.

---

# Persistence writes must also be delayed

There is an additional startup risk in the current implementation.

Even when the initial scan is skipped:

- The logical-Space autosave timer is still scheduled.
- Shutdown writes persistent layout and logical-Space state.
- An empty layout causes `layout.json` to be removed.
- A default empty logical context can overwrite useful logical-Space persistence.

If Miri starts before login, waits for a long time, and then terminates or autosaves before establishing a real model, it can damage the state that should have been restored.

A robust startup mode should therefore have a process-lifetime condition such as:

```text
hasEstablishedInitialWindowModel
```

Until that becomes true:

- Do not delete or rewrite `layout.json`.
- Do not overwrite `logical-spaces.json`.
- Do not consume the persistent restore snapshots.
- If Miri exits, leave the previous state files untouched.

This is important to the overall feasibility of the feature; active scanning alone does not protect persistent UX.

---

# Existing application-launch retries help, but are insufficient

Miri already has good per-PID retry behavior for applications whose launch it observes. For a new regular application with no known windows, it retries reconciliation at approximately:

```text
0.12, 0.45, 1, 2.5, 5, 10, 20, and 35 seconds
```

That is helpful for resume applications that launch after Miri begins observing `NSWorkspace`.

It does not fully solve startup because:

- Some applications can already exist before observers are installed.
- A launch notification can be missed.
- An app may be listed as running while `AXWindows` is unavailable.
- An app may not send reliable `AXCreated` notifications.
- Normal safety reconciliation does not start when layout tracking is blocked.

The startup scanner fills exactly this gap. Once the initial model is established, the existing event-driven mechanisms can take over.

---

# Signals that are less useful

## `IOConsoleLocked`

Miri already uses this. It can tell you that the console is locked, but not whether that lock is:

- Initial login after boot
- A later manual screen lock
- A transition around wake

It should remain a safety check, not the startup classifier.

## `kCGSessionOnConsoleKey`

This tells you whether the session is on the console. It does not mean that GUI login has finished. A pre-login session can still be associated with the console.

Again, keep it as an eligibility check, but do not use it as the decisive signal.

## `NSWorkspace.sessionDidBecomeActiveNotification`

Apple describes this as a notification posted after a user session switches in. It is useful for Fast User Switching and session activity, but does not directly communicate “initial login restoration is complete.”

It can trigger a state recheck, but `kCGSessionLoginDoneKey` should be the truth source.

- [NSWorkspace sessionDidBecomeActiveNotification](https://developer.apple.com/documentation/appkit/nsworkspace/sessiondidbecomeactivenotification)

## Boot-time heuristics

Comparing process start time with system boot time could indicate that Miri started shortly after boot, but it is unnecessary and brittle:

- Users can log in quickly or slowly.
- Miri can crash and be restarted shortly after boot.
- Fast User Switching is unrelated to boot.
- Logout/login does not reboot the machine.

`kCGSessionLoginDoneKey` expresses the relevant state directly.

## Checking for `loginwindow`

The `loginwindow` process continues to exist after login and manages the GUI session. Its presence is not a usable login-completion signal.

## Secure input

Secure keyboard input may be active at a login screen, but it can also be active in password fields during normal desktop operation. It is not an initial-login discriminator.

## Launch-item metadata

ServiceManagement and AppKit can tell you about registration or launch circumstances, but not reliably whether the GUI login operation has completed. The session dictionary is the appropriate API.

---

# Handling an unknown login state

The main ambiguity is when `CGSessionCopyCurrentDictionary()` returns `nil` or lacks `kCGSessionLoginDoneKey`.

I would recommend this policy:

1. If the key is explicitly `false`, enter definite pre-login startup mode.
2. If explicitly `true`, use normal startup, perhaps with a short generic login-item settling scan.
3. If unavailable:
   - Retry for a few seconds.
   - Do not treat the desktop as ready while lock or console state is also unknown.
   - Use a bounded timeout so Miri cannot remain disabled permanently.
   - Log the complete available session state in debug mode.

Because the key is public and present in the current macOS SDK, an absent key should be considered an exceptional or transitional condition, not the normal path.

---

# Permissions

## Accessibility

Accessibility permission remains mandatory.

If Miri already has permission, launching before login should not remove that authorization. However, if permission has never been granted, the current startup behavior exits immediately after requesting it:

```swift
guard requestAccessibilityPermission() else {
    exit(1)
}
```

A permission prompt cannot provide useful pre-login UX. Initial installation still needs to be launched and authorized after login at least once.

## Input Monitoring

Startup polling would be an improvement because it does not require a recovery input event to release the initial guard. That reduces dependence on Input Monitoring permission for this particular startup path.

Input Monitoring may still be required for the configured event-tap shortcut backend and ordinary session recovery.

## Screen Recording

Not required for discovery. It remains relevant only to snapshot capture and animation.

---

# Suggested state model

At an architectural level, this can remain small:

```text
StartupBootstrapState
├── normal
├── waitingForLogin
├── settling
└── completed
```

Or equivalently:

```text
hasEstablishedInitialWindowModel: Bool
launchedBeforeLoginCompleted: Bool
startupScanTimer: Timer?
startupScanDeadline: Date?
```

The important invariants are:

1. `launchedBeforeLoginCompleted` is determined once at process startup.
2. Startup scanning can occur only while the initial model has never been established.
3. Once completed, startup mode can never be reentered by lock or sleep.
4. All startup scan callbacks still recheck current lock, console, and sleep state.
5. Persistent state is not written or consumed before the initial model is established.
6. A generation/token invalidates delayed callbacks if session availability changes during bootstrap.

---

# Testing that would be necessary

This behavior depends on the exact macOS login timeline, so testing it on actual reboot/login cycles is important.

## Primary scenarios

1. **Cold reboot with “reopen windows” enabled**
   - Miri starts before password entry.
   - Several applications are restored.
   - Verify `LoginDone` transitions from false to true.
   - Verify all restored windows eventually enter the layout.

2. **Cold reboot without restored applications**
   - Miri must eventually complete startup even if no manageable windows appear.
   - This is why “first window found” cannot be the only completion condition.

3. **Normal manual launch after login**
   - Startup-specific waiting should not introduce a long delay.
   - Existing windows should be adopted immediately or after only a very short settling period.

4. **Launch as login item after a fast login**
   - `LoginDone` may already be true by the time Miri starts.
   - It should still handle applications whose AX windows appear slightly later.

5. **Lock and unlock after startup completes**
   - Startup scanner must not restart.
   - Existing managed-interaction recovery must remain in effect.

6. **Sleep and wake**
   - Same requirement: no startup scan reactivation.

7. **Lock or sleep during startup settling**
   - Polling must pause.
   - No window movement or persistence writes should occur.
   - Bootstrap should continue only once the session is safely available again.

8. **Fast User Switching**
   - Verify that session changes do not accidentally rearm the initial bootstrap after completion.

9. **App with slow/broken Accessibility**
   - Confirm the hard deadline prevents permanent startup blocking.

10. **Miri quits before login finishes**
    - Existing persistent layout files must remain untouched.

## Diagnostic logging

For initial validation, log the session dictionary’s documented fields at each transition:

```text
LoginDone
OnConsole
UserID
UserName
IOConsoleLocked
workspace session active
sleeping
startup bootstrap state
number of regular apps
number of discovered manageable windows
number of AX-unreadable app PIDs
```

Avoid logging anything sensitive beyond the ordinary username already supplied by the session dictionary.

---

# Overall conclusion

**High feasibility.** The fundamental discriminator already exists as a public macOS API: `kCGSessionLoginDoneKey`.

The proposed startup polling is directionally correct, but the robust version should:

1. Check `LoginDone` at process launch.
2. Enter startup-only bootstrap mode only when it is explicitly false.
3. Wait until login, console, lock, and sleep signals all indicate readiness.
4. Poll discovery for a short bounded settling period.
5. Avoid stopping after only the first window.
6. Perform one authoritative persistence-consuming reconciliation after the window set stabilizes.
7. Prevent persistence writes until that initial model exists.
8. Permanently retire startup mode afterward.
9. Keep the current interaction-gated recovery unchanged for later locks and sleeps.

No private API is necessary for the main detection mechanism, and the change fits naturally into Miri’s existing session-state and window-reconciliation architecture.
