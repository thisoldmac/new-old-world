---
title: The blessed-path drag — OS-owned drops in both directions
type: feat
date: 2026-08-17
artifact_contract: ce-unified-plan/v1
artifact_readiness: experiment-gated
execution: code
---

# The blessed-path drag — OS-owned drops in both directions

## Goal Capsule

Replace the imitation layer of the cross-edge file drag with the OS's own
machinery, per the AGENTS.md principle written 2026-08-17 ("THE BLESSED
PATH"): **force the code through the blessed OS path so the OS's behavior,
not ours, is what ships.** Concretely: a host→guest handoff becomes a real
Drag Manager promise drag on the guest — cursor at {x,y}, mouse down, a
`flavorTypePromiseHFS` skeleton (name, type/creator, fork sizes) — and OS 9
takes over: the Manager's own ghost with a file icon, real window tracking,
the Finder creating the destination and pulling the promise, the Finder's
own collision and progress behavior. The start must be inducible in an
emulator without a human gesture — `setState({pos, mouse_down,
attachment: promise_skeleton})` as a contract-declared verb — so the whole
lane is observable and testable around.

This plan is banked at Michelle's direction on 2026-08-16/17. It records
the evidence gathered the same night, including one decisive negative
result, and gates its first implementation slice on one cheap experiment
rather than pretending the route is proven.

## Why now, and what it deletes

Two agents answered explicit asks for *native* dialogs with styled
imitations. The product's drag lane today is real transport wearing fake
clothes:

| surface | today | class |
|---|---|---|
| Replace? on collision (both lanes) | `now_confirm` hand-built movable modal (`now-guest-ppc/src/workshop/confirm.c`) | IMITATION — named debt #1 |
| Transfer progress | app-drawn receive windoid (`receive_progress.c`; the bar control is native, the window is not) | IMITATION — named debt #2 |
| CarbonLib warning, unsigned-update confirm, processes confirm | same `confirm.c` root, 3 more call sites | IMITATION (same root) |
| Host "change the share" confirmation | hand-drawn SwiftUI sheet (`FilesModuleView.swift:175-209`) where the sibling case already uses `.confirmationDialog` | IMITATION (host) |
| Host→guest carry | app-drawn illustration of the carried file, not a `DragRef` | IMITATION |
| KW-09 alert chrome | fidelity symptom of the same `confirm.c` root | related |

Already on the blessed path (2026-08-17 sweeps, `A1-blessed-path-inventory`
reports): the guest's *outbound* drag (`continuity_dragmgr.c` — real
`NewDrag`/`AddDragItemFlavor`/`SetDragImage`/`TrackDrag`; `SetDragImage` is
the sanctioned way to supply the Manager's image), the drag
observation/registration surfaces, and — on code re-read — the host's
`NSDraggingSession`/`NSFilePromiseProvider` plumbing (eager fetch stages
privately and surfaces only through the promise). The host sweep's
"cleaner than expected" reading still owes reconciliation against attended
observation before the host is declared done.

**Kill list once the native drop works** (not before): the carry
illustration; `now_confirm` on the drag lane (it survives only for
automated/MCP puts, where nobody is dragging); the receive windoid on the
drag lane; every `rx_outcome` string that exists to narrate what the OS
would have shown.

## The wall, measured (2026-08-17)

The 2026-08-15 slice-2 result (promise machinery proven in-process; drag
never left NOW; `inwin=1`) was re-measured on the current candidate with
V15 armed (`test/hg-drag-native-track`, four controlled gestures, ledger
entry 2026-08-17):

- **Verdict: the drag still cannot leave NOW — but not for the reason
  slice 2 recorded.** Targeting is fine; **the pointer never moves.** The
  Drag Manager reads the pointer correctly; `lm`/`dm` (resident-written
  low-memory) reach the driven point, `raw` stays frozen at the press
  point, and screendumps show cursor + drag image parked there until
  `TrackDrag` returns.
- **Mechanism:** Continuity applies Cursor Device motion at task time only
  (the 1.11 safety contract, bought with six PowerBook wedges). A drag
  source's `TrackDrag` is synchronous — NOW's own task time is consumed
  for the whole drag, so the pointer pump starves. The drag source's own
  starvation is the carrier failure: the same disease as the guest→host
  mint (fixed 2026-08-17 by the post-epoch publish), in the opposite
  direction.
- The rig-defect hypothesis (NOW's fronted catch panel explaining
  `inwin=1`) was **refuted** with a drop on exposed desktop, NOW fronted:
  identical result. And "NOW hidden, Finder fronted" cannot even run for
  this direction — the synthetic button lands in the front process, so a
  background NOW never sees it. Front-ness, not hidden-ness, is the
  variable.
- **Still unanswered because no drop completed:** whether the OS 9 Finder
  shows its own copy progress for a promise pull, and what it natively
  does on a same-name promise drop. These two observations decide the
  exact fate of the fake dialogs and MUST be captured in the first slice
  that completes a drop.

## Routes past the wall

The pointer pump needs task time *while `TrackDrag` runs*. Three routes,
ordered by preference:

**Route A — ride the Drag Manager's own callbacks (preferred, unproven,
cheap to test).** The Drag Manager calls registered tracking handlers
repeatedly during a drag, at task time, in the context of the process
under the pointer — this is the exact context class in which the
resident's `dragObs` EnterHandler ran and in which the resident's
`dragBegin` MacTCP send survived a real PowerBook (2026-08-16, 10 frames,
no wedge). If the resident (or the app) registers a tracking handler for
NOW's own drag and applies the pending Cursor Device move from inside it,
the pump rides the drag's own heartbeat: task time, blessed context, fires
continuously while the button is down. **Decisive experiment (slice 0,
emulator-only, ~one session):** instrument whether tracking-handler
callbacks fire during a NOW-originated `TrackDrag` at a useful rate, apply
the Cursor Device move from one, and watch whether the pointer (and the
ghost) actually track. Everything downstream gates on this.

**Route B — timer-context Cursor Device movement.** Would work by
construction and is the reason it is not preferred: it re-opens the
six-wedge PowerBook safety argument in full. Emulator evidence cannot
retire that risk (the wedges were metal-only). Only on the table if Route
A's callbacks don't fire or fire too slowly; requires its own safety
design and Michelle's explicit sign-off before any metal contact.

**Route C — another process's task time.** A faceless background helper
as the drag source, keeping NOW's loop free. Costs a new guest component
and its lifecycle for an architectural dodge; recorded for completeness,
pursued only if A and B both die.

## The inducible entry point

Contract-declared verb (name to settle at declaration time):

    continuity.hostDragBegin {
      pos: {x, y},
      item: { name, type, creator, dataSize, rsrcSize },
      dragSeq / gesture id
    }

- Guest app builds the `DragRef` + promise flavor + send proc, positions
  the pointer, asserts the button, calls `TrackDrag` (with the Route-A
  pump registered). The send proc pulls bytes over the existing file lane
  — the half slice 2 already proved byte-identical.
- Callable from the probe with arbitrary state: press-free induction,
  observe in the emulator, test around it. Extends
  `tools/continuity-resident-drag-probe.py` (which gained `--cross` on
  2026-08-17); receipts must be written OUTSIDE `$NOW_SPIN_RUN`
  (`lane-ports reclaim` deletes the run dir — burned once).
- The edge handoff then becomes: host drag ends at the crossing (the
  synthetic-release staging that already ships), skeleton crosses,
  `hostDragBegin` fires, the host's physical release becomes the guest
  button-up becomes a real OS 9 drop.

## Known allowances the native drag needs

- `TrackDrag` blocks the app: the ack-silence watchdogs and the resident's
  lease need a declared "native drag in flight" allowance, or a slow human
  drag kills its own session (the 30 s lease vs. a leisurely drag).
- The send proc's synchronous wire pull during the drop is proven; the
  wire is otherwise silent for the drag's duration — liveness monitors on
  both sides must know that is healthy, not wedged.
- Multi-item and folders stay refused by name (`folder-not-yet`) exactly
  as today until this lane is native for a single file.

## Slices

| # | slice | gate |
|---|---|---|
| 0 | Route-A experiment: do tracking callbacks give the pump task time inside `TrackDrag`? | emulator; go/no-go for everything below |
| 1 | `continuity.hostDragBegin` contract + guest verb + probe induction | emulator: induced drag tracks, drops in a Finder window, promise pulls byte-identical |
| 2 | Observe the Finder's native collision + progress on a real promise drop (same-name-twice, screendumps) | decides the kill list's exact scope |
| 3 | Wire the edge handoff to it; delete carry illustration + drag-lane windoid/confirm per slice-2 findings | emulator round + attended metal round |
| 4 | Host reconciliation: `ChangeConfirmation` → `.confirmationDialog`; verify attended that the host lane's native claims hold on hardware | attended |
| 5 | Metal: the Route-A pump in the Finder-context class is the same class that survived 2026-08-16, but pointer *writes* from that context are new — attended PowerBook gate before anything ships | Michelle |

## What this plan deliberately does not decide

- Route B's safety design (only sketched if Route A fails).
- The Finder's native collision semantics (observed, not assumed — slice 2).
- Whether the 68K guest ever gets this lane (console-driven today; out of
  scope).
- The API arc Michelle mentioned (2026-08-16): the surfaces that survive
  this teardown are the ones an API should expose; that scoping happens
  after slice 3 lands.
