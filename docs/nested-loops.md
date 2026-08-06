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
| `console_model.c` — the `chat` verb's streamed turn | own pump loop (`chat_verb_wait`) | **Yes** — `now_wire_pump()` every pass; `exec.cancel` ends it via `now_wire_exec_cancelled()` | until the terminal `chat.result`, the wire's 60 s quiet deadline, or a 5-minute hard cap. The longest pump loop in the guest, deliberately: the Chat page is the interactive face, and this verb's help says the console waits |
| `act_client.c` — `act_yield`, under `now_act_submit` **and** `now_act_await_fired` | own `WaitNextEvent(0, …)` yield loop | **Yes, since 2026-08-06** — `now_wire_pump()` every pass | — (the act itself still runs to `kNowActDeadlineTicks` × 2 ≈ 10 s when a target declines; the WIRE no longer waits with it). **Row added and then changed on the same day; see below for what pumping cost** |

**The `act_client.c` row is why this table is dated and why "every" in
its heading is a claim, not a fact.** The audit above was re-run
2026-07-21, and the act plane did not exist yet. Nothing re-ran it when
that plane landed, so the guest's longest non-pumping wait spent weeks
outside an audit whose title says it is exhaustive — and it was found
not by re-auditing but by chasing a symptom from the other end. **When a
new nested loop lands, it gets a row in the same commit.**

The measured cost, 2026-08-06: an act refused `act-not-taken` after
**6.6 s**, and a `scene.request` issued in the same instant answered in
**6634 ms** — the same number twice, because it was the same wait seen
from both ends. Two phases plus overhead puts the worst case at
**11.7–12.5 s**, which is the range of the slow Mirror loops that were
being attributed to a modal. Worse, it is self-sustaining: the anchor
plane's ten-second OWNER lease is renewed by host traffic *through
`conn_service`*, which is exactly what does not run during the wait — so
a ~10 s act lapses the lease and the next act refuses `plane absent`.
That is the "refused the first time, worked the second" report.

**Fixed the same day, and the fix was not free.** `act_yield` now calls
`now_wire_pump()`. Pumping inside an armed window means serving requests
while an act is armed, which is precisely the re-entrancy
[no-hijack-criterion.md](no-hijack-criterion.md) exists to prevent — so
that document's safety argument has been **deliberately spent**, with
Michelle's approval, and its opening box says so, names the trade, and
lists what the replacement does not cover. The repair shipped as three
things, not one: `pump.h` at the call site, a one-act-at-a-time latch
(`now-guest-shared/src/now_act_inflight.h`) that refuses a nested act
with `act-busy` before it can write a field, and the decision about what
may be served mid-arm — which is *everything except another act*, stated
here rather than left implicit. A scene walk, a census, a file transfer
and a `ps` can all now run while a trap patch is live in every process
on the machine. Nothing has measured whether that is safe; it is written
down because it is new.

The measurement that motivated it is above; the measurement that it
worked is in [open-issues.md](open-issues.md). Also unresolved: **the
act ceiling is stated nowhere once.** `kNowActDeadlineTicks` is 5 s per
phase here; plan 014's host-side watchdog is 20 s and was chosen against
the *script* ceiling, with nothing naming this one. Two halves, two
numbers, neither aware of the other — the shape AGENTS.md warns about
under "state a limit once".

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
guest death timer. **`act_yield` was the exception, and it is why that
sentence needed qualifying:** it is bounded by a *deadline*, not by how
long a hand stays on a mouse, so it ran its full ~10 s whenever a
target declined, and it is reached by the host rather than by a person.
A wait no human is holding open is not human-scale, and "does not reach
the 65 s death timer" was the wrong bar anyway — the anchor lease is
**10 s**, and this wait cleared it. That is the argument that got it
pumped; the qualification stays here because the next long,
host-initiated, deadline-bounded wait to be added will need the same one
made about it. Three of them cannot be fixed rather than merely have
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
