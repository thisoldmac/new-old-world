# The state of the Mirror, 2026-08-06

**What a person sitting in front of the NOW Mirror will actually
experience today — the good and the bad, in the order they will meet
them.** Written as a handoff, at the end of the 2026-08-05/06 session
that produced plans 012, 013 and 014 and about twenty branches.

This page exists because the alternative is reconstructing it from
twenty ledger entries. It is a **snapshot with a date on it**, not a
maintained index: it will go stale, and when it does the rule is the
same as everywhere else here — **[open-issues.md](open-issues.md) is
right if it and this disagree, and the code is right if it and the code
disagree.** Do not repair a claim here by editing it into agreement;
add a dated line, the way the ledger does.

**Tier, for the whole page: TESTED and EMULATOR-VERIFIED. Nothing
described here has run on a PowerBook.** Every number is from an
emulated Power Mac G4 under OS 9.1, which is faster than any hardware
this project targets.

## Read these four first

| | why |
|---|---|
| [mirror-drive-loop.md](mirror-drive-loop.md) | the rules for driving it. Read before a run, every run. |
| [open-issues.md](open-issues.md) | the ledger. Its first four entries are all from 2026-08-06. |
| [plans/…-001-now-mirror-ux-completion-plan.md](plans/2026-08-03-001-now-mirror-ux-completion-plan.md) | the destination. 011–014 are slices under it. |
| [mirror-measurement-method.md](mirror-measurement-method.md) | 23 rules for not believing a wrong number. Cheaper than re-learning any of them. |

## What got much better this session

All of it emulator-only.

- **The loop is fast now.** The host's cycle went from a 364 ms median
  to **25 ms**, and a cycle in which a Finder window opened from
  1,936 ms to **26 ms** (258 cycles, every one `outcome=ok`). The guest
  round trip went from ~115 ms to **~10 ms idle**. A scene walk with NOW
  frontmost went from ~1.1 s to **0.7–1.0 ms**. Three separate
  bottlenecks, each exposed by removing the one in front of it: the
  guest's own sleep, a `FindControl` grid sweep of NOW's own window, and
  a visibility census paid every cycle for state that changes only when
  a process starts or quits.
- **Acts bind, and stay bound.** The anchor plane's ten-second owner
  lease used to lapse two ways — a long host cycle, and the guest's own
  act wait not servicing the wire. Both are closed. An act a target
  **takes** costs **0.08–0.20 s**.
- **One act no longer makes the whole Mirror look like a twelve-second
  machine.** An act nobody takes still costs its full deadline (5.07 s,
  and it must), but **80 scene requests were answered during it, median
  65 ms**, where there used to be exactly one, at 6634 ms.
- **A dialog no longer ends the session.** With the optional NOW
  Extension resident, the machine holds a second connection that answers
  for itself; an application starved 108 s kept its session, proven by
  mutation.
- **A modal in a foreign application is a tax, not a wedge** — 20×
  (scene median 21 ms → 413 ms), and acts work straight through it.

## What a driver will hit, in the order they will hit it

### 1. Window interiors are blank or hatched — and this is the biggest one

> **SUPERSEDED, later the same day (2026-08-06).** This section was
> written before the composition arc merged into
> `claude/gworld-interior-host-render-98ddd5`. The experiment below is
> answered and outcome 1 shipped: an offscreen world's per-item drawing
> IS recoverable, worlds are hooked at birth by a `_QDExtensions`
> (`$AB1D`) patch in the target's own context, and the host re-homes the
> held ops into the window — nested worlds included. What remains true
> is the *evidence class*: all of it is emulator-only, and **the live
> host application has never been watched composing.** Read
> [render-composition.md](render-composition.md) and
> [status.md](status.md) for the current picture; the paragraph below is
> kept because it is the measurement that motivated the arc.

The OS 9 Finder composites its icon views into an **offscreen GWorld**
and `CopyBits` the finished composite into the window, so the content
plane sees one opaque rectangle instead of icons and labels. Measured on
this branch: a full repaint of a Macintosh HD icon-view window emitted
**25 ops — 10 line, 7 rect, 8 bits, and ZERO text**. The desktop is the
opposite case and mirrors correctly, which is what shows the mechanism
is sound where it applies.

Whether this is fixable semantically is **one unanswered experiment**,
and it is scoped: [gworld-probe-brief.md](gworld-probe-brief.md). Its
three outcomes are all publishable and the middle one is the likeliest.
Owned by a separate worktree as of this writing; do not start it without
checking.

### 2. 62 % of elements have no determined kind, so widgets draw wrong

190 of 308 corpus items carry `knowledge: unknown`
([mirror-element-coverage.md](mirror-element-coverage.md)). A control
whose kind is unknown cannot be drawn as the right widget — this is the
"radios drawn as push buttons" defect at its source, and it is the root
of most remaining render complaints.

**The cause is diagnosed and it is not a missing capability.** A
complete classifier already ships — `ext/src/now_semantic.c :: classify()`
reads `kControlKindTag` from inside the target process, and its
`signature != kControlKindSignatureApple` branch is an authoritative
standard-versus-custom split. It is **starved by the transport**:
`contract/peek_table.h` carries a *single* `NowPeekSemanticCell`, control
classification is the lowest-priority claimant on it, and only the front
process may spend it. Date & Time's window has 21 controls and was front
for one scene — best case it could have classified one of twenty-one.

So the next step here is a **batched or multi-control request op and a
priority that reflects what the answer is worth**, not op replay. That
is the highest-value unstarted work on this page.

Beside it: fewer than half of dialog items are **addressable** (75 of
186; Sound is 0 of 64), so the act plane refuses them by name.

### 3. `actselftest` answers `no-such-process`, and it blocks reproduction

On a fresh clone, foreign processes report **`not-observed`** and
`actselftest` answers **`no-such-process`**. The heartbeat half of this
was found and fixed on 2026-08-06 (`now_peek_idle()` renews the writer
lease once per event-loop pass), and that fixed the flap; **the
`no-such-process` half did not change and needs its own look.**

This is not an abstract gap — it **blocked two agents on 2026-08-06**
from reproducing real reported cases, because a clone on which no
foreign process can be bound cannot be driven into a control panel or a
foreign modal. Anyone picking up an act-plane or Mirror-fidelity
question should expect to hit it first. Ledger: *"BROKEN: the anchor
plane is active and binds nothing (2026-08-05)"*, with the 2026-08-06
correction appended to it. Start at `now_ax_bind_process` in
`now-guest-ppc/src/axwalk/axprocess.c`, read against whatever `mirror`
reports as `active`.

Two related things the same entry names and does not close: the **first**
scene of a fresh connection still misses foreign processes by design
(claim-before-echo; the host's second poll covers it), and a scene's
coverage `reason` still does not distinguish `no-plane` from
`not-observed` — a wording gap that hid this defect across two sessions.

### 4. A Finder-owned modal still stops the whole machine

Different and worse than the foreign-application case above. The Finder
inside `ModalDialog` services no Apple events, so on a cooperatively
scheduled Macintosh it starves NOW too: `outcome=starved`,
`decode_ms=0`, and the anchor worker stops answering even `hello`.
Nothing on either side can dismiss it. **Anyone measuring plan 014
against a Finder-owned modal will correctly see it change nothing, and
must not conclude the fix did nothing.**

### 5. Smaller, but they will be met

- **Twelve console verbs cannot be given an argument** from the guest's
  own console — the fall-through passes `NULL` as the whole request.
- **The guest serves no Apple menu of its own**, and `OpenDeskAcc` is
  not in CarbonLib at all, so what it should serve is a design question
  rather than a to-do.
- **A backgrounded application cannot be armed for content capture at
  all** — nothing can make a process pump that is not being scheduled.
- **A repaired alert has not been watched in the Mirror window.** The
  wrong-buttons / dead-clicks / missing-text defect is fixed in both
  halves and rendered in tests; no drive has looked at it. Its stop icon
  is still a placeholder.

## The two live risks to carry in your head

- **Nothing is metal-verified.** Not one thing on this page. Two of the
  changes are worse than merely unverified, because they are the kind
  that behaves differently on real hardware rather than merely slower:
  the **Open Transport wake notifier** runs at *interrupt time*, where a
  mistake is a crash and not a slow answer; and the **act pump** serves
  wire requests inside a window where a trap patch is live in every
  process on the machine. A 1400c is also slower than an emulated G4 in
  every direction, so every number above is the optimistic one.
  `wirestat wake off` disables the notifier from either face without a
  rebuild — that is the escape hatch if a metal pass goes badly.
- **The no-hijack argument's single-cell protection was spent on
  purpose.** [no-hijack-criterion.md](no-hijack-criterion.md) §4 argued
  the act plane's single request cell was safe because two requests could
  not overlap, said in writing that the protection was *incidental*, and
  **named the act pump as one of two changes that would remove it**. The
  change was made anyway, with Michelle's explicit approval, to buy the
  latency above. What stands in its place is a one-act-at-a-time latch
  that refuses with `act-busy` — watched firing on a machine, which is
  simultaneously proof that the hazard is real and that the guard meets
  it. It covers **the act cell and nothing else**.

  **From the host, the signature if this bites is: an act that failed
  and a scene that moved anyway.** If you ever see that, go to the
  ledger entry *"LIVE RISK, deliberately taken"* first; the analysis is
  already written and does not need repeating.

## Where the work goes next

Nothing here is a schedule; it is what the evidence says is worth most.

1. **The element classifier's transport** (§ 2). Diagnosed, scoped,
   unstarted, and it is the root of most remaining render defects.
2. **`actselftest` → `no-such-process`** (§ 3). Not the biggest defect,
   but it is the one that blocks *measuring* the others.
3. **The GWorld probe** (§ 1) — an experiment before an architecture,
   and its brief is written.
4. **A metal pass**, attended and Michelle's call, with the wake and the
   act pump as its two subjects.
5. **The Cycle 18 re-score**, which plan 001 names as the first thing
   U6 should do, and which is only meaningful on a machine whose acts
   bind — so it wants 2 first.

Plans 013 and 014 are done and closed at the emulator tier; 012 is done
with its metal and 68K passes owed; plan 001 is the destination and
nothing in it is blocked.
