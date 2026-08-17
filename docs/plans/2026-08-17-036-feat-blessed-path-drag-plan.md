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

## The ownership toggle (design invariant, 2026-08-17)

Michelle's framing, adopted as the model: **exactly one OS's drag
machinery is live at any moment — the one that owns the cursor — and the
edge toggles it.** Host→guest: the AppKit session ends at the cross (the
synthetic release that already ships) and the guest's `TrackDrag` begins
there. Guest→host: the Finder's `TrackDrag` ends at the cross (the press
release, already the design) and the host's
`NSDraggingSession`/`NSFilePromiseProvider` begins there. Consequences:

- The `TrackDrag`-blocks-NOW window shrinks to the guest-owned segment of
  the gesture — the watchdog/lease allowances cover that, not a whole
  human drag.
- **Abort is native.** Cross-back mid-drag: report the position somewhere
  no target accepts, then report button-up — `TrackDrag` returns
  `userCanceledErr` (-128, measured slice 0; the plan first predicted
  `dragNotAcceptedErr`), the promise is never asked, the Manager's own
  snap-back plays. No cancel channel to invent. (Mirrored on the host by
  round 2's staged/never-committed semantics.)
- There is a beat at the edge where neither drag exists, while the
  skeleton crosses the wire (~hundreds of ms). Invisible if the guest
  draws nothing until `TrackDrag` starts. Guard the failure mode: a
  skeleton that never arrives leaves the guest holding a pressed cursor
  with no drag — time that out into the same native non-drop.

## Routes past the wall

The pointer pump needs task time *while `TrackDrag` runs*. We are both
halves of the problem — the drag source and the pointer authority — so we
can cooperate with ourselves. Routes, ordered by preference:

**Route A′ — `SetDragInputProc` (primary; the Manager's own seam for
exactly this).** The drag *source* attaches an input proc to its own
`DragRef`; the Drag Manager calls it — inside `TrackDrag`, at task time,
in our context — every time it samples the mouse, and the proc supplies
position and button state. It exists precisely so a drag can be driven by
something other than the physical mouse. That is the `setState({pos,
mouse_down})` entry point as a published API, not a hack. Freshness works
because continuity positions arrive via the OT notifier at deferred-task
time, independent of NOW's blocked task time — the input proc does a
bounded read of the latest point, squarely inside the 1.11 contract.
**Slice 0 questions:** (1) does the ghost track the reported position;
(2) does the cursor sprite follow, or only the ghost (if only the ghost,
the resident's proven low-memory writes can keep the sprite in agreement,
or ghost-only is accepted); (3) does the drop resolve and target at the
reported point (`inwin`/`loc` flip to the Finder, promise asked); (4)
does abort-by-non-acceptance return `dragNotAcceptedErr` cleanly.

**Route A — tracking-handler relay (fallback).** NOW's own tracking
handler pumps while the drag is over NOW's windows; the resident's
Finder-context handler (installed and metal-proven for the `dragBegin`
send) takes over once the drag crosses onto the desktop. Two of our
components cooperating across the gap. Costlier and only needed if the
input proc is not called continuously or its samples don't steer the
drag.

**Route B — timer-context Cursor Device movement.** Would work by
construction and is the reason it is not preferred: it re-opens the
six-wedge PowerBook safety argument in full. Emulator evidence cannot
retire that risk (the wedges were metal-only). Only on the table if A′
and A both fail; requires its own safety design and Michelle's explicit
sign-off before any metal contact.

**Route C — another process's task time.** A faceless background helper
as the drag source, keeping NOW's loop free. Costs a new guest component
and its lifecycle for an architectural dodge; recorded for completeness,
pursued only if everything above dies.

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
| 0 | **DONE 2026-08-17 — GO** (`test/hg-drag-input-proc`, 16 commits, receipts `/private/tmp/now-slice0-receipts/`): the Manager sampled the input proc 12786/12786 times, ghost tracked the scripted ramp, `inwin=0` out of process, desktop drop completed the **first out-of-process promise pull**, abort clean (`userCanceledErr`, asks=0). Sprite does NOT follow (ghost-only; slice 1 decides). `SetDragInputProc` confirmed CarbonLib 1.0+. | passed |
| 1 | `continuity.hostDragBegin` carrying only the *starting* state (ordinary Continuity datagrams carry the rest — transport settled). Gates inherited from slice 0's gaps: a true Finder-**window** drop (rig geometry fixed), real byte-compare, and the **600 KB promise pull fixed** (fails today where 4 KB succeeds, under the 1 MB cap, undiagnosed). Sprite decision made deliberately (resident low-mem chase vs ghost-only). | emulator |
| 2 | ~~Observe the Finder's native collision~~ **Answered early by slice 0: the Finder shows NO dialog for a promised-drop collision — it silently fails and creates nothing.** The drag-lane replacement for `now_confirm` is therefore a fixed *send-proc policy* (uniquify or overwrite — Michelle's pick), not any dialog. Copy-progress observation still open (every completed pull was 4 KB; re-observe with a large file once the 600 KB defect falls). | policy decision + large-file observation |
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
