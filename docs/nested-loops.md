# Nested event loops and wire liveness

**Status:** audit + proposal, 2026-07-20. Nothing here is implemented
yet.

## Symptom

With a modal dialog open on the guest, a host-initiated screenshot hangs
with no output, and Cancel does nothing — permanently, not just until
the dialog is dismissed.

## Root cause: three defects, stacked

The guest's wire is serviced from one place — `conn_service()`, called
each pass of `main.c`'s `WaitNextEvent` loop. **Any nested loop that
does not call it freezes the entire wire**: no pings answered, no
requests served, no transfers pumped. Classic Mac OS is full of nested
loops; the Toolbox runs its own event loop inside `ModalDialog`,
`Alert`, Navigation Services, and every mouse-tracking call.

That is defect A. Two host-side defects turn a temporary stall into a
permanent one:

**B — no request has a deadline.** `requestCapture`, `getFile`,
`listFiles`, and `runCommand` all park a completion and wait forever.
Only `stopStream` has a fallback timer.

**C — session teardown leaks pending work.** When the 75-second idle
timeout finally closes a stalled session, the close path fails console
commands and the pending capture, but `pendingFile` and
`pendingListings` are dropped without ever being called — a Files
download or listing started against a stalled guest never settles at
all, and its UI stays busy even after the guest reconnects.

> Corrected 2026-07-20 during implementation: an earlier draft of this
> document claimed the pending *capture* leaked too. It does not — the
> close path calls `deliverCapture(.failure(…))`. A capture against a
> modal guest hangs for the full 75-second idle timeout and then fails,
> which is bad but bounded; files and listings are the unbounded case.
> The fix is the same either way, and the 75-second wait with a dead
> Cancel button is the symptom that was actually reported.

**D — Cancel is unsendable before the transfer starts.**
`Session.cancelCapture()` guards on `captureBegin != nil`. A guest stuck
before it ever sends `capture.begin` has no in-flight transfer, so
cancel returns silently. Cancel currently means "abort a transfer",
where the human means "abandon my request".

## Audit: every nested loop in the guest

Re-audited 2026-07-21, after the Workshop replaced the five windows.
**There is no `ModalDialog` in the guest any more** — the Connection
dialog became a page — so the two sites that once blocked indefinitely
are gone, and Navigation Services now takes `now_pump_nav_event()`
everywhere.

| Site | Loop | Pumps the wire? | Blocks for |
|---|---|---|---|
| `fileshare.c` — `NavGetFile`, `NavChooseFolder` ×2 | Navigation Services | **Yes** — `now_pump_nav_event()` | — |
| `confirm.c` — the movable-modal question | own `WaitNextEvent` loop | **Yes** — the loop calls `conn_service()`; its `TrackControl` takes `now_pump_action()` | — |
| every module's buttons and checkboxes | `TrackControl` | **Yes** — `now_pump_action()` | — |
| `console_module.c` — scroll bar arrows/page | `TrackControl` | **Yes** — the action proc scrolls and calls `now_wire_pump()` | — |
| `console_module.c` — scroll bar **thumb** | `TrackControl(…, NULL)` | No | Drag duration |
| `connection_module.c`, `screenshots_module.c`, `cloud_module.c` — pop-ups | `TrackControl(…, (ControlActionUPP)-1L)` | No | Menu-down duration |
| `software_module.c` — splitter drag | own `StillDown` loop | **Yes** — calls `conn_service()` every pass | — |
| `connection_module.c` — text fields | `HandleControlClick` | No | Selection-drag duration |
| `files_browser_view.c`, `cloud_module.c` — the lists | `HandleControlClick` | No | Selection/sort-drag duration |
| `main.c` | `MenuSelect`, `DragWindow`, `TrackGoAway`, `GrowWindow`, `TrackBox` | No | Mouse-down / drag duration |
| `proc_actions.c` — `quit`'s confirmation wait | own `WaitNextEvent(0, …)` yield loop | **Yes** — `now_wire_pump()` every pass | ≤ `--wait N` (6 s default, 20 s ceiling) |

The `quit` row is the one deliberate stall we *added*, so it is worth
stating why it cannot be avoided and what it does and does not cost. A
`kAEQuitApplication` event sits in the target's queue until the Process
Manager schedules it, and on a cooperatively scheduled machine that only
happens while somebody else is inside `WaitNextEvent`. Confirming the
outcome — the whole point of the verb — therefore requires yielding.

The loop yields with an event mask of **0**: it dequeues nothing, so no
click or keystroke is lost (they stay queued for the main loop), and it
does not re-enter event dispatch from inside a command. What it does cost
is a redraw: the guest's own window does not repaint for the duration. It
services the connection throughout, and when the WIRE is the caller,
`now_wire_pump`'s reentrancy guard makes the pump a correct no-op because
`conn_service` is already on the stack. Bounded by construction, and well
inside the host's 75 s idle timeout — `runCommand` arms no watchdog of its
own, so that timeout is the only backstop and the 20 s ceiling exists to
stay far from it.

The remaining non-pumping sites are all **human-scale** — seconds — so
they stall a stream and delay a heartbeat but do not reach the 65 s
guest death timer. Three of them cannot be fixed rather than merely have
not been: `MenuSelect`, `DragWindow` and `GrowWindow` take no callback
at all (`pump.h` says so), a popup CDEF needs its own action, and the
Control Manager does not call an action proc for a scroll bar's
indicator part.

## What we can and cannot fix

**Our own modals: fully fixable.** Every Toolbox nested loop has a hook
that runs during its idle time — a `ModalFilterUPP` for dialogs, a
`NavEventUPP` for Navigation Services, an `ActionUPP` for `TrackControl`.
Calling `conn_service()` from those hooks makes the wire genuinely
cooperative with the modal: pings answer, captures serve, transfers pump,
all while the dialog sits open. The settings dialog proves this works
today.

**Other applications' modals: mostly fine, not guaranteed.** Classic Mac
OS is cooperatively multitasked. A foreground app running the standard
`ModalDialog` loop calls `WaitNextEvent` internally, which yields time to
background apps — so our `conn_service()` keeps running and the wire
stays live. But an application that busy-waits instead of yielding, or a
system-modal condition, can starve every background process, and there is
**nothing we can do about that from above the line**. The guest cannot
promise liveness it does not control.

That asymmetry is the whole argument for the host-side work: guest-side
pumping fixes the cases we own, and the host must degrade gracefully for
the cases we do not.

## Proposal

### Guest — make nested loops cooperative (fixes A)

1. **One shared idle hook.** Add `now_wire_pump()` to `wire.h` — a thin,
   reentrancy-guarded wrapper over `conn_service()` — so every nested
   loop calls the same thing, and a future change to servicing has one
   home. The reentrancy guard matters: `conn_service` must not recurse
   if a pumped callback somehow re-enters.
2. **Dialogs**: give the sharing dialog (and every future
   `ModalDialog`) a filter proc built from the settings dialog's shape.
   Factor that filter into a reusable `now_modal_filter()` rather than
   copying it a third time — copies are what caused this bug.
3. **Navigation Services**: pass a `NavEventUPP` that pumps on
   `kNavCBEvent`/idle. Both `NavChooseFolder` today and `NavGetFile` in
   slice 3 need it.
4. **Tracking loops**: pass an action proc to `TrackControl` that pumps.
   `MenuSelect`, `DragWindow`, `GrowWindow`, `TrackGoAway` and
   `TrackBox` take no callback and cannot be pumped — accept them as
   bounded human-scale stalls, and note that streaming visibly pauses
   while a menu is held open.
5. **Document the rule** in `docs/architecture.md`: *any* new nested
   loop must pump, and code review should treat a bare `ModalDialog(NULL,
   …)` as a defect.

### Host — degrade gracefully (fixes B, C, D)

6. **Per-request deadlines.** Every pending request gets a timer sized to
   its work: a listing is a control round-trip (~10 s), a capture
   includes VRAM read plus transfer (~30 s plus a size-scaled
   allowance), a file pull scales with its announced size. On expiry the
   completion fires with a plain-language failure — "the classic Mac
   didn't answer; it may be showing a dialog" — which is both true and
   actionable.
7. **Fail pending work on teardown.** `failPendingCommands` becomes
   `failAllPending`, covering captures, files, and listings in one
   place. No
   completion may be dropped: a leaked completion is a permanently stuck
   UI.
8. **Cancel means abandon.** Cancel should settle the pending request
   locally whether or not a transfer ever started, and send
   `capture.cancel` / `file.cancel` only if there is a transfer to
   cancel. The human's intent is "stop waiting", and that must always be
   honorable.
9. **Say why.** A request that times out while the heartbeat is stale
   should say so, distinguishing "the guest is busy" from "the guest is
   gone" in the panel's error line.

### Ordering

C and B are the highest value per line: they turn a permanent hang into
a bounded, explained failure, and they protect against every future
guest-side stall including ones we have not found. A (guest pumping) is
what actually makes the product feel right — a dialog on the guest
should not interrupt a stream at all. D is small and removes a papercut.

## corpus_impact

A finding is warranted once implemented and verified on metal: the
durable claim is that *a classic Mac guest's wire liveness is only as
good as its nested loops*, with the general rule (every Toolbox nested
loop needs an idle hook that services the connection) and the limit
(background time depends on the foreground app yielding, so the modern
side must always carry its own deadline). That is reusable well beyond
NOW — TimBotTu's Runner/Worker have the same exposure.
