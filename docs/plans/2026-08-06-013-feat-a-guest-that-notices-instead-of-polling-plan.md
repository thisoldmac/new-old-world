---
title: A guest that notices instead of polling - Plan
type: feat
date: 2026-08-06
---

# A guest that notices instead of polling - Plan

Subordinate to [001, NOW Mirror UX Completion](2026-08-03-001-now-mirror-ux-completion-plan.md),
which owns the destination. This one is about how the guest SPENDS ITS
TIME, and it is written because a measurement on 2026-08-06 said the
current answer does not scale to the machines this product is for.

## Why this exists

**Measured, clean clone, current builds, one variable changed — which
process is frontmost. The guest's own `latencyMs`:**

| front | menubar.app | menus | items | latency |
|---|---|---|---|---|
| Finder | Finder | 8 | 82 | **116 ms** |
| New Old World | New Old World | 7 | 48 | **1116 ms** |

Ten-sample runs agree: NOW-front medians ~950 ms; Finder-front 0–16 ms.
Fewer menus, fewer items, ten times the cost. It is not the window
chain, not a foreign process, and not proportional to the work done.

Two things follow, and the second is the reason for this plan.

**The narrow finding — and it was WRONG, corrected the same day.**
This plan first said the cost was `collect_self_menubar`, the menu bar
read through the Toolbox, inferred by differencing the two conditions
above. A microsecond breakdown taken before any code changed says
otherwise: **the whole menu bar is 1.0–2.5 ms, about 0.1% of the
total.** The ~1 s is `find_controls_by_probe` — a `FindControl` grid
sweep over NOW's own window, 3,724 points across a 757×487 content
area.

**Why the differential lied, which is the transferable part.** The
inference assumed the two conditions differed only by the menu-bar
step. They also differ by WINDOW ACTIVATION, and `FindControl` answers
an inactive window immediately: ~2.7 µs per point in the background
against ~240 µs in the foreground. The same sweep, ninety times the
cost, for a reason that has nothing to do with menus. A differential is
only as good as the claim that one variable moved, and here two did.

The fix taken is this plan's own thesis in miniature, at tier 1: cache
what the sweep DISCOVERED (which controls exist, and where each was
found), re-prove it at one `FindControl` per control per pass, and
invalidate on control creation, disposal or movement. Same Toolbox
call, roughly 3,700× less often, no layout assumptions. Measured
916 ms → **0 ms** median in steady state, with the full sweep now paid
once per UI change instead of once per poll.

**The wide finding.** Every cost here comes from RE-DERIVING the
machine's state on a timer. The scene walk enumerates processes, binds
each, walks window chains, reads controls, joins semantics and mints
references — all of it, every poll, whether or not anything changed.
That is O(size of the UI) per poll against a machine whose UI is
usually identical to the last poll. It is affordable on an emulated G4
and it will never be affordable on the hardware this product exists
for: a PowerBook 1400c is far slower than the emulator, and the 180c is
not in the same universe. **Guest-side cost is therefore a correctness
question for the vintage machines, not a comfort question.**

## The steer this plan is written under

Michelle, 2026-08-06, and it widens the option space rather than
narrowing it:

> OS 9 is a great little sandbox to do whatever we want in. So in the
> future we might wind up hooking or even building a new Toolbox
> itself. Don't scope yourself too narrowly. We're doing extremely
> unreasonable things with mid-nineties technology, and that's the whole
> point. So let's be unreasonable, but let's make it smooth, polished,
> fast, and a great experience.

So "replace the mechanism" is on the table. What is NOT on the table is
shipping something that only works on an emulator.

## Goal Capsule

- **Objective:** the guest's per-poll cost becomes proportional to what
  CHANGED, not to how much interface exists. A machine sitting still
  costs a comparison; a machine being used costs the work its own
  changes imply.
- **Authority:** unchanged. `contract/asyncapi.yaml` is the wire
  meaning, `contract/peek_table.h` the in-memory meaning,
  `MirrorStateEngine` the single published state.
- **Non-goal:** a faster full walk. Making the existing O(UI) walk
  cheaper is worth doing and is a different, smaller piece of work.
  This plan is about not doing it.
- **Stop conditions:** any change that cannot be defended on real
  hardware; any resident change that destabilises a foreign
  application; and the standing one — if two diagnostic boots do not
  yield, leave it disarmed and say so.

## The decisions taken before writing code

### A — the resident becomes a NOTIFIER, not a faster reader

The extension already runs below the application in three ways: six
trap patches (the act plane), per-port QuickDraw bottlenecks (the
content plane), and as of this week a Time Manager task that keeps
running while every application is starved. **It sees mutations
happen.** What it does not do is remember that it saw them.

So: maintain a shadow model in the resident, updated at the moment
something changes, and let a scene request read the model instead of
walking the machine. The common case — nothing changed — becomes a
generation compare. This is the same shape as the content plane's
existing `gLastWindowList` change-detect, generalised from one field to
the observable interface.

**Why this and not just caching in the application:** an application
cache has no way to know when a FOREIGN process changed its menus. Only
something running in that process's context at mutation time does. The
resident is the only component with that vantage, which is what makes
this architectural rather than an optimisation.

**And the vantage has a floor, now measured.** The one piece of this idea
already shipping is the content plane's arm handshake — the application
writes a request, and it is honoured only when the TARGET process next
runs the resident's jGNE pass. That is the exact shape § A proposes, so
its cost is this plan's own thesis with a number on it, and the number
was taken before any more of it was built. **~116 ms for the frontmost
application, and the handshake is never the expensive part**: the two
cases that cost seconds cost them because the target is not being
scheduled at all, which no notifier can fix. The measurement, the null
control and the decision not to build on it are in
[open-issues.md](../open-issues.md). Read it before proposing a
mechanism here — it also says which conditions were never reached.

### B — three tiers of technique, and the tier is chosen by METAL RISK

Ranked, and a slice must say which tier it is in:

1. **Do less of the same thing.** Resolve a root menu once per scene
   rather than once per menu; skip joins for planes nobody claimed;
   encode once instead of sizing then writing. No new assumptions about
   how a Macintosh is laid out — the Toolbox is still asked, just far
   less. **Metal-safe by construction.**
2. **Be told instead of asking.** Trap patches and, for our own
   process, possibly Carbon Events (below). Carries the risk of the
   patch itself, which this project already takes and has procedures
   for, but does not add new assumptions about data layout.
3. **Read structures instead of calling.** The 10x measurement makes
   this tempting. For FOREIGN processes we already do it, gated by the
   validated reader with bounds checks and the anchor oracle. For OUR
   OWN process it trades a guaranteed-correct path for a fast one, and
   the guarantee is what a support range of OS 8.6–9.2.2 across several
   ROMs actually buys. **Tier 3 needs a metal pass before it is
   trusted, and a slice may not drift into it silently.**

### C — Carbon Events are available on our floor, and may cover the SELF case

Researched 2026-08-06: the Carbon Event Manager is available on Mac OS
8.6 through 9.1 with **CarbonLib 1.1.1 or later**, and this application
already requires CarbonLib 1.6. So for NOW's own interface there may be
a supported subscription mechanism — no patching, no layout assumptions,
tier 2 with tier-1 risk.

Two cautions, both from the same sources. Feature coverage varies by
version and much of the Carbon Event Manager is HIToolbox-era, so
whether the menu and window classes actually FIRE under CarbonLib on OS
9 is a probe, not a given. And note the direction of the other
restriction: GNE filters are unsupported *in Carbon*, which is exactly
why the system-wide notifier lives in the 68K resident rather than in
the application. The two halves need different mechanisms for the same
reason they always have.

### D — the cadence stops being the design

Today the host polls and the guest answers with a whole document. Once
the guest can say "nothing changed", the interesting question moves to
the wire: a scene that is mostly identical to the last one should not
cost a full IR document. That is a contract change and belongs in its
own slice AFTER the guest can tell the difference — sending deltas the
guest computes by diffing two full walks would be all of the cost and
none of the benefit.

## The work

### 1 · A phase breakdown, because everything else is guessing

`latencyMs` is one number for the whole collect. Every conclusion in
this plan past the menu bar is inference from differencing two
conditions. Counters for enumerate / bind / windows / controls / menus /
encode turn each future question from an argument into a lookup.

**Do this first even though it is not a fix**, and expect it to
reorder the slices below. It is the cheapest thing here and the only
one that makes the rest honest. In particular it settles whether the
menu cost is Toolbox-shaped or **disk-shaped**: the Apple menu's items
are backed by the Apple Menu Items FOLDER, and if their text costs file
access then the fix is "never re-read unchanged items", not "call the
Toolbox less".

**Done when:** a scene reports where its time went, and the 2026-08-06
numbers above are reproduced with the menu phase named explicitly.

**DONE 2026-08-06** (`claude/scene-phase-timings`). `meta.phases` is on
the wire, additive and optional, eight non-overlapping phases named for
what the guest DOES, with the absence rule stated in the contract and the
breakdown's own cost published beside it. The arithmetic has a native
test; the host carries the numbers on its `NOWBASE cycle` measurement
line and deliberately NOT on the ambient status line. Full numbers,
both conditions, in `docs/open-issues.md`. Three things it settled:

- The menu cost is **Toolbox-shaped, not disk-shaped** — 107 µs with the
  Finder in front, 1.36 ms with NOW in front. The Apple menu's folder
  never showed up.
- **A focus change costs one 1.9-second scene**: the activation
  invalidates the sweep cache and the whole 3,724-point grid is re-swept
  in the foreground. The cost moved from every poll to every focus
  change. That is the target § 2 should aim at first.
- **The background sweep returns nothing.** `FindControl` refuses an
  inactive window, so with anything else in front NOW's own window walk
  spends 5–10 ms and reports ZERO controls. The mirror shows NOW's
  window empty whenever NOW is not frontmost — a correctness hole, found
  by a measurement, and it is not a performance question.

### 1a · The cost was not the work at all — it was the WAIT

**DONE 2026-08-06** (`claude/wire-latency`), and it reframes what is left
of this plan.

§ 1 made the walk cheap (3–8 ms) and the deltas arc made the idle answer
free (zero bytes), which left a round trip still costing a 115 ms median.
Neither term explained it. It was the guest's own `WaitNextEvent` sleep:
six ticks, ~111 ms measured, taken whenever no transfer was already in
flight — so a request arriving into a quiet connection sat readable on
the socket until the sleep expired.

The guest now measures that itself, which is the part worth keeping:
`wirestat` reports the interval between its own service passes and the
delay from Open Transport announcing data to the loop reading it, as
histograms. The second one — `notice` — was a 48.5 ms mean and a 103 ms
maximum, i.e. **uniform arrival into the sleep, and 100% of the missing
time.** An Open Transport notifier calling `WakeUpProcess` takes the
round trip to 10 ms idle and 15 ms mid-drive. Numbers, conditions and
what is unverified: [open-issues.md](../open-issues.md).

**What this says about §§ 3–5.** It is a tier-2 change by § B's ranking —
be told instead of asking — and it is the same thesis as § A applied to
the WIRE rather than to the machine's interface, one layer lower than
this plan was looking. It also lands the argument § A's own measurement
could not: **being told works and is cheap**, when the thing doing the
telling is already running (Open Transport's notifier) rather than
waiting to be scheduled (a foreign process's event loop). That is the
distinction the arm-handshake measurement was really about, and it is
worth carrying into any § 3 design: a notifier is only as good as the
context it runs in.

**And it does NOT strengthen the case for a shadow model.** The remaining
guest-side cost in the steady state is a 3–8 ms walk against a 10 ms
round trip on an emulated G4. § 5's "what would make this wrong" still
stands unamended: that case rests entirely on the vintage-hardware
multiplier, and nobody has taken a reading from a 1400c.

### 2 · Tier-1 wins, taken on evidence

Whatever § 1 names. The candidates already visible: the per-menu root
rescan, the two-pass encode, and joins for unclaimed planes. Each is
independently defensible and none needs a metal argument.

**Taken, 2026-08-06: the control sweep, removed rather than tuned.** § 1
named a focus change costing one 1.9-second scene and a background sweep
returning zero controls, and they turned out to be ONE defect —
`FindControl` refuses an inactive window, so backgrounded NOW cached
nothing and paid the whole 3,724-point grid in the foreground the moment
a person clicked in. The fix is tier 1 in the strictest sense: the same
Toolbox calls, ~3,700 fewer of them, and no new assumption about how a
Macintosh is laid out — because the application does not have to
DISCOVER controls it made itself. `control_kind.c`'s table, which existed
to report a `role`, became the scene's list of what exists, with the
whole lifecycle (adopt / dispose / dispose-window / dispose-dialog)
closed around it and source-gated. Measured 886,398 µs → 713 µs on the
focus-change scene, and NOW's own window stopped mirroring as empty
whenever something else was in front. Nothing is cached, so nothing can
be stale; see docs/open-issues.md for the numbers and what is not done.

### 3 · The change generation — the smallest useful notifier

One word in the shared table that the resident bumps when the
observable interface changes, and one the application compares against.
Nothing else. If the number has not moved, the scene is served from
what the application already has.

Start with the WINDOW LIST, because the content plane already proves
that particular detection works, and because a window list change is
the coarsest signal that is still useful. Menus second, since that is
where the measured cost is.

**The trap to design against:** a stale model is worse than a slow one.
Michelle hit a defect the same day where NOW's menu bar rendered EMPTY
until she cycled applications — freshness is already sensitive here,
and a cache that misses an invalidation reproduces exactly that class of
bug with a longer half-life. Every generation bump must be provable
from the mutation that caused it.

### 4 · The shadow model

Only once § 3 has held for a while. The model is what turns a scene
from a walk into a read; it is also the thing that can be wrong in ways
a walk cannot, so it earns its place after the cheap signal has proven
the invalidation is sound.

### 5 · The wire follows the guest

**DONE 2026-08-06**, and the contract did go first. `scene.begin` gained
`digest` / `delta` / `baseline` / `wholeBytes`, and `scene.same` is the
no-change answer — a control frame with no transfer, sent only in reply
to a request that quoted `since`. The baseline is named by the **digest
of what the consumer actually holds** rather than by a sequence number,
so a host that has drifted repairs itself on the next round trip instead
of diverging quietly. Idle wire bytes fell to ~10% of what they were
over ten polls. See [scene-deltas.md](../scene-deltas.md) and the ledger
entry *"a scene can now answer 'the same', or send only what moved"*.
Emulator only.

Deltas, or a "no change since generation N" answer that costs a control
frame instead of a document. Contract first, per the house rule.

## Picking this up cold

**Written 2026-08-06 during the durability pass, at the end of the
session that measured this plan's results.** If this and the code
disagree, the code is right; if this and
[open-issues.md](../open-issues.md) disagree, the ledger is right.

**Done, all of it emulator-only on a mac99 G4:**

| § | what landed | how it is known |
|---|---|---|
| 1 | `meta.phases` — eight non-overlapping phases in MICROSECONDS, permanent and additive, publishing its own cost | replaced `latencyMs`, which was `TickCount`-quantised at ~16.6 ms and could not resolve any phase of the walk |
| 1a | the OT notifier + `WakeUpProcess` wake | round trip 86 ms → 10 ms idle, 15 ms mid-drive, **keeping** the long idle sleep |
| 2 | the control sweep removed rather than tuned — the app reads the registry of controls it made | 886,398 µs → 713 µs on the focus-change scene; steady state 3.2–4.9 ms → 0.7–1.0 ms |
| 5 | scene deltas by digest, and `scene.same` | ~90% fewer idle wire bytes |

A correctness fix rode along with § 2 and is worth as much as the speed:
**`FindControl` refuses an inactive window**, so a backgrounded window
reported ZERO controls — a false absence nobody had ever observed
because "the background window has no controls" is not a surprising
sentence. Foreign windows now retract the control plane instead. **That
retraction path is built and has not been watched run.**

**Not started: §§ 3 and 4.** § 3's own text argues against starting it
before a 1400c reading exists; that reading still does not exist.

**The wake owes a metal pass, and this plan's rules do not say so.** By
§ B's ranking the wake is a tier-2 change, and `## Verification` below
scopes metal to *tier-3* changes — so read literally, the plan excuses
the one change in it most likely to behave differently on hardware. It
is an Open Transport notifier running at interrupt time, where a mistake
is a crash rather than a slow answer, and it also keeps the notifier
installed after the dial, which it did not before. Failure modes are
graceful by construction and `wirestat wake off` restores the shipped
behaviour from either face without a rebuild — but none of that is a
substitute for watching it. **Treat the wake as owing metal regardless
of its tier**; the rule is amended in `## Verification`.

**Nothing in this plan is metal-verified.**

## What would make this wrong

- **A model that can be stale without saying so.** The product's whole
  claim is a faithful mirror. A fast wrong answer is worse than a slow
  right one, and this plan's entire risk is concentrated here.
- **Taking tier 3 quietly.** Replacing a Toolbox call with a struct
  read because it benchmarked well, without saying that the support
  range now rests on a layout assumption.
- **Optimising the emulator.** Every number in this plan is from mac99.
  The emulator is FASTER than the target hardware in at least one way
  that matters — its disk is host-backed — so a fix tuned to emulator
  timings may miss on metal, and a cost that looks small here may
  dominate there.
- **Treating one measured instance as the problem.** The menu bar was
  this plan's first candidate and it was refuted within hours — the
  cost was a control sweep, found only because § 1 was done before any
  fix. That is the plan working, and it is also the warning: the next
  instance will not be where anyone expects either. If § 1's breakdown
  shows the same SHAPE elsewhere — full re-derivation per poll of
  something that rarely changes — slices 3–5 are right; if the control
  sweep turns out to be the only one, they are premature and should be
  re-argued rather than executed.

  **ANSWERED 2026-08-06, and it is a qualified yes.** The shape is
  everywhere: in the steady state NOTHING the guest does is proportional
  to what changed. `enumerate` re-derives the process list every poll
  (~1 ms, identical in both conditions), `menubar` re-reads a bar that
  rarely changes, `windows` re-walks chains, `encode` rebuilds a document
  mostly identical to the last. The control sweep was the loudest, not
  the only one. **But** with it fixed a whole walk is 3.0–8.5 ms on an
  emulated G4, so the case for 3–5 no longer rests on anything measured
  HERE — it rests entirely on the vintage-hardware multiplier, which is
  the one number nobody in this plan has. Make that argument with a
  reading from a 1400c before building a shadow model for it; the two
  costs § 1 DID find (the 1.9 s focus change, and a background sweep that
  returns nothing at all) are § 2-shaped and are worth more, sooner.

  **Corrected 2026-08-06, later the same day: that last clause is spent,
  and it should not be read as remaining work.** Both costs were fixed
  BY § 2, as one defect — the focus-change scene measured
  886,398 µs → 713 µs, and the background sweep became a retraction of
  the control plane rather than a false empty. See the table under
  *Picking this up cold*. The sentence was written before § 2 landed and
  survived the edit that recorded it; what stands is only the first
  half — **§§ 3–5 want a 1400c reading before anyone builds them**, and
  the real next work is not in this plan at all (see
  [mirror-state-of-play-2026-08-06.md](../mirror-state-of-play-2026-08-06.md)).

## Verification

- **Native** (`scripts/test-native`, and in its manifest or it is not
  real): the generation/invalidation logic, which is pure and testable
  without a Macintosh.
- **Emulator**: every latency claim, reproduced as the paired-condition
  measurement above rather than as a single number.
- **Metal**: any tier-3 change, and at least one confirmation that the
  wins hold on a PowerBook — the emulator's disk advantage means a
  win measured here is not automatically a win there. **Attended, and
  Michelle's call.**

  **Amended 2026-08-06: and the wake, which is tier 2.** Ranking by how
  deep a change reaches into the guest's model was the right axis for
  everything else in this plan and the wrong one for this: the wake runs
  at INTERRUPT time and changes when the notifier is installed, so its
  failure mode is a crash on a machine nobody has tested rather than a
  number that does not improve. Tier is a proxy for risk, and where the
  proxy and the risk disagree, the risk wins. **The wake owes a metal
  pass.**
