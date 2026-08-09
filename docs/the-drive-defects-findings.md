# The drive defects — what was found, group by group

**2026-08-07/08, lane `claude/025-drive-defects`.** The plan is
[`plans/2026-08-07-026-the-drive-defects-plan.md`](plans/2026-08-07-026-the-drive-defects-plan.md);
the evidence is [`the-drive-and-the-islands.md`](the-drive-and-the-islands.md).
This is what survived checking.

**Nothing here is metal-verified.** Everything below is Tested — the suites
pass on this Mac — and no part of it has run on the PowerBook.

Two of the plan's stated mechanisms did not survive. Both are recorded at
length, because in each case the plan's reasoning was sound and its
conclusion was wrong, and the next person will otherwise re-derive it.

---

## Group B — CONFIRMED, and the fix was on the other side

The plan says the act plane has one request cell, so interaction refuses
rather than queues. The refusals are real: nine in ninety seconds while
Michelle worked a scroll bar.

**But the guest is not the half that was wrong.** `now_act_inflight.h`
argues its refusal is correct rather than poor, in as many words:

> a caller told "busy" can decide, whereas a caller made to wait cannot

That is right, and it names a duty. **The host never discharged it.**
`NOWMirrorSource.perform` routes only the plans carrying a typed
postcondition through `MirrorMutationBroker`'s one-lane FIFO. Everything
else — move, resize, select, **control clicks**, keystrokes, most menu
commands — got a bare `Task` straight to the wire, one per gesture, all
concurrent. The file says so itself:

> the acts that filled the 2026-08-04 PowerBook log were almost all of
> this kind

A scroll arrow is a control click. Every one of Michelle's clicks raced
the one before it into a cell that holds one request.

**Fixed** by `MirrorDirectActLane` (`now-host/Sources/Host/`): one direct
act on the wire at a time, in arrival order, released when the guest
answers rather than on a settlement these plans can never produce. Past
its capacity a submission is refused **host-side**, instantly, saying it
was never sent.

There were **two** doors, and serializing one would have serialized
nothing: `perform(_ interaction:)` and `perform(_ actions:label:)` each
had their own bare `Task`. Both now take the lane.

This touches no contract, no `ext/` and no `peek_table.h`. **It owes no
bake.**

### Watched to fail

Three guards, each watched against the specific mutation it names —
the chain removed, the capacity guard removed, the depth never reclaimed.
In each case the mutation **built**, the test **ran**, and the failure was
that guard's own assertion and no other's.

---

## Group B, second half — REFUTED

The plan says zero confirmations in 32 minutes means "the pressed state's
exit from *waiting* has no input", and that this is "very likely why the
pressed state never shows".

**That cannot be the cause, and the shape of the symptom says so.** A
press that entered *waiting* and never got an exit would be stuck DOWN
until `PressSession.patience` expired. Michelle reported the opposite:
the pressed state never appears at all.

The actual wall is `PressSubject.init?(_ object:)`
(`now-host/Packages/MirrorKit/Sources/MirrorKit/PressSubject.swift`), which
returns nil — **no press session is created, so there is nothing to draw
and nothing for a confirmation to settle** — for:

- **`case .window`**, outright. That is every title-bar button, which is
  exactly the case Michelle called out by name ("including title bar
  buttons").
- **Any control with a non-nil `part`.** Scroll bars, deliberately.
- **Any dialog item whose `semanticKind` is not one of `pushButton`,
  `checkBox`, `radioButton`.** Its own comment records that **62% of
  elements carry no determined kind**, and it declines rather than guess.

So the pressed state is not waiting on a confirmation. For most of what a
person clicks, it is never armed. Routing settlement back into
`PressAnswer.confirmed` — the follow-on the code already names — would
change nothing about this symptom.

**The real dependency is classification**, which is the same CDEF wall
group D's missing I-beam runs into. Fixing the pressed state means
widening press eligibility (`.window` for title-bar buttons is the cheap,
self-contained half), not plumbing confirmations.

### One genuine defect found on the way, and fixed

`LiveMirror.act(_:_:pressing:)` called `controller.perform` and only
**then** assigned `press = session`, while the completion it passes opens
with `guard var live = press`. Any driver answering synchronously found
`press` still nil and the guard returned.

NOW's driver answers synchronously for exactly one disposition — a
refusal — and `NOWMirrorSource.perform(_:answer:)` promises in its own
comment that the button then "comes back up at once with the reason
beside it". **It never did.** The refusal was dropped and the button stayed
down for the whole of `PressSession.patience` with nothing said.

Arming before sending is the fix. It **carries no dedicated guard**:
driving a SwiftUI view's private gesture path needs a harness this tree
does not have. Said plainly rather than glossed.

---

## Group C — REFUTED as stated; the wall is one layer earlier

The plan says part 129 appears zero times because "`ctlact` is a click
verb; a thumb needs press-move-release, which is the drag vehicle's
territory."

**`ctlact` accepts part 129 today.** `act_cmds.c` validates `part` in
0–255 and names 129 in its own refusal text. The guest would take it.

Part 129 is zero because **the host refuses the gesture before any verb is
chosen.** The chain, derived rather than remembered:

1. `LiveMirror.swift:546` turns a thumb drag into
   `ActionModel.thumbTracking(...)` and sends it through
   `perform(_ actions:label:)`.
2. `ActionModel.availability` classifies `.thumbTracking` alongside the
   device gestures: it needs `planes.inputDevice`, else
   `.inputDeviceUnavailable("needs a positioned input-device adapter;
   this driver has none")`.
3. NOW declares `ActionPlanes.residentActPlane`, whose comment is *"A
   guest with the resident act plane and no positional click — NOW"* and
   whose first field is **`inputDevice: false`**.
4. `perform(_ actions:label:)` checks availability before dispatching and
   returns on the refusal. **`send` is never reached**, and
   `.thumbTracking` has no case in NOW's `send` switch either.

This matches Michelle's report exactly — *"Scrollbar buttons work;
click-and-drag on the slider does not"* — because the arrows are
`.controlPart` → `ctlact`, and only the thumb takes the refused path.

**It is refused honestly and by name, not silently dropped.**

### Where the fix goes, and why it was not attempted here

The guest already has the vehicle: P7, `ext/src/now_ext_drag.c`, reached
through `now_act_drag_press` / `now_act_drag_cell` /
`now_act_drag_available`, with `NowPeekDragCell` **already in
`contract/peek_table.h`** behind `drag_format == kNowPeekDragFormatV1`.
So the cell exists and wiring it is not a layout change.

Closing C means teaching NOW to declare an input-device capability backed
by that vehicle, and giving `send` a `.thumbTracking` case that drives
press → move → release so `TrackControl`'s own loop tracks it. That is a
slice of its own, and half-building it would have left a capability
declared and unbacked — which reads as working and is worse than the
honest refusal that is there now.

---

## Group A — not this lane's

`claude/024-items-arbitration` is on it and has an unverified checkpoint
(`6892ad93`), which splits the cell: the icon box excludes the replay, the
name yields per piece through `Coverage.textCovers`. Not duplicated here.

**One thing to hand that lane:** the plan attributes the decode cost —
p99 3,152 ms, max 7,527 ms for 3 windows and 49 elements — to the missing
arbitration. Arbitration changes what is **drawn**. 7.5 s to **decode** 49
elements is a decode-side number, and the guest's own phase counters are
in microseconds. Those may well be two mechanisms wearing one symptom, and
the cost should be re-measured after the arbitration lands rather than
assumed closed by it.

---

## Groups D and E — untouched

Not reached. The plan's walls for each still stand as written; nothing
here supersedes them.
