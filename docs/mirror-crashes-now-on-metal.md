# Mirror crashes NOW on the PowerBook, and the app switcher then kills the Finder

**Reported by Michelle, 2026-08-08, first metal session in weeks.**
Filed, not diagnosed. **No fix, no reproduction in a test, no verified
mechanism.**

## The sequence

1. Open Mirror on the PowerBook 1400c → NOW quits immediately, "error of
   type 1".
2. Relaunch NOW, open Mirror → same crash, reproducible.
3. **Click the app switcher after a crash → the Finder crashes.** It
   restarts safely.

**Step 3 is not second-crash-specific.** An earlier draft of this
document said the first crash was clean and only the second took the
Finder, and treated that asymmetry as the strongest clue. Michelle
corrected it: the Finder crash happened *both* times, in this session and
in the pre-census-fix VM sessions, and in every case it followed
**clicking the app switcher after a crash**. There is no asymmetry. The
rule is: NOW crashes, then the app switcher kills the Finder.

That correction matters because a false asymmetry sends the search
somewhere real evidence does not.

## What Michelle noticed on her own

> this is very similar to the behavior that crashed the vm before the
> census patches

Worth carrying rather than dismissing: `pccard` was also something that
walked hardware and that the emulator tolerated. Census now runs clean on
both the VM and metal, so if this is the same class it is a different
instance of it.

## Six mechanisms checked by reading, and all six already defended

Recorded so the next person does not spend the same hour. Each of these
is a plausible cause of "an app crashes and takes system state with it",
and `ext/src/now_content.c` already defends every one:

1. **Trap patches left dangling by the dead app.** They are installed by
   the resident, not the app, so NOW dying does not orphan them.
2. **`CQDProcs` record in the crashed app's heap.** It is a system-heap
   static, with a comment at `now_content.c:1300` saying it must never
   live in the patched application's heap.
3. **Unchecked allocation on the arm path.** `NewPtrSysClear` is
   null-checked and degrades to absent honestly.
4. **Ports left hooked after a crash.** True — the unhook requires the
   armed A5 context and a crashed app never runs it — but the restore
   path is guarded three ways: same context, still owns the hook, and
   never dereference a port that stopped matching its identity.
5. **Re-hooking an already-hooked port on relaunch**, making `prev` point
   at our own procs and recursing forever on the next draw. Refused: a
   non-NULL `prev` is skipped and counted (`skipped_ports`).
6. **The orphaned hook firing from the Finder's context and failing its
   slot lookup.** `content_emit_state` returns cleanly when `slot < 0`.

**This is a finding, not an absence of one.** The content plane is
written carefully against exactly this class, which means the cause is
probably somewhere else: the application side rather than the resident,
or something the emulator forgives that a 603e does not — unaligned
access and instruction-cache coherency are the classic divergences, and
QEMU is lenient about both.

The honest status is that reading did not find it, and that six negative
results by inspection are worth less than one bisect on the machine.

## The one experiment worth metal time

**Drag `NOW Extension` out of the Extensions folder, restart, open
Mirror.** Without the resident, Mirror should degrade honestly — every
plane "Available, not requested", which is what the VM shows today.

- Still crashes → the defect is in the application (`now-guest-ppc`).
- Stops crashing → the defect is in the resident (`ext/`).

One reboot splits the system in half. Everything else on this page is
worth less.

Alongside it, and cheap: take `now-logs` off the desktop before
rebooting, and if MacsBug is on that machine, a stack crawl at the crash
is worth more than the rest of this document combined.

## RESOLVED TO A HALF: the bisect ran, and the crash is in the resident

**Michelle, 2026-08-08, with the NOW Extension removed and the PowerBook
rebooted: Mirror connects and renders. It does not crash.**

So the crash is in `ext/`, not in `now-guest-ppc`. One reboot did what an
hour of reading the source could not, which is the whole argument for
running the experiment before writing the theory.

The six mechanisms listed above were all read out of `ext/src/now_content.c`
and all found defended. They stay listed, because "the obvious defences
are present and the crash is still in here" narrows the search rather
than ending it — whatever this is, it is not one of the six shapes that
extension code usually dies of.

### What the resident-less run shows, split honestly

With the INIT out, Michelle reports: the Workshop renders with the
correct desktop under it, only the Workshop renders, it never updates
with new content or state, and its render degrades over time.

- **Only the Workshop, no foreign interiors — EXPECTED.** The content
  plane lives in the resident. Without it there are no content records,
  so no foreign window interior can be captured. The Workshop survives
  because its structure and semantics come from the application's own
  walk, and the desktop under it is host-side.
- **Never updates — NOT expected, and a separate defect.** Structure and
  semantics do not need the resident. If nothing refreshes, that is
  app-side or host-side and would still be broken with the INIT
  installed.
- **Degrades over time — NOT expected, and a separate defect.** A render
  with no content plane should be static. Decay has no source in the
  resident's absence.

Those last two are independent of the crash and of each other. They
should not be filed under "the resident is missing", because removing the
resident is exactly the condition that proves they are not its fault.

### The charter violation this exposes

[docs/resident-components.md](resident-components.md) states that a
resident component is always optional and **the product degrades honestly
without it**.

It does not. With the resident absent, the Mirror shows a frozen and
decaying picture and says nothing. The honest behaviour is to name the
state: no content plane, structure only. This is the provenance ladder's
own rule — an unmarked stale image is the failure the ladder exists to
prevent — applied to the case where the whole plane is gone rather than
one window's ink.

That is arguably worth more than the crash fix. A crash is loud. This is
the quiet hatch.

## The next bisect, and it needs no rebuild

The resident arms planes by a **lease union**: `arm_request` is the union
of what each owner has claimed (`peek.c :: publish_claims_to`). Every
owner claims a different set, and each is reachable from the **guest's
own console** — so the plane that crashes can be found on the machine,
with no host, no cross-compile and no deploy.

| on the guest | owner | caps claimed |
|---|---|---|
| open the Processes module | Processes | anchors |
| `observe` | Observe | anchors + tree (P1/P2) |
| `qdtrace start` | Content | **content (P3)** |
| `actselftest` | Act | anchors + act (P4) |
| `transitions` | Events | events (P5) |

Procedure: reinstall the INIT, reboot, and walk the ladder **without
opening the host Mirror at all**. Whichever verb takes the machine down
names the plane.

P3 is the standing suspect — it is the only plane whose machinery
(trap patches, CQDProcs, GWorld hooks) executes inside foreign processes
at draw time, and it is the one the six defended mechanisms were read
out of.

**A null result is equally useful.** If every verb is survivable and the
Mirror still crashes, the fault is in the host's *combination* of planes
rather than any single one, and `wire.c:2016` — where the host's
requested set becomes `now_peek_release(optional & ~requested)` followed
by `now_peek_claim(requested)` — is where to look next.

Note the shape of that pair: a release of everything optional that was
not requested, then a claim. Two writes to the lease set per scene
request, and the plane goes through a transition on every one.

## MEASURED, 2026-08-08 ~06:16, driving the live PowerBook over the agent socket

The host agent socket was read while Michelle opened the Mirror. Identity
confirmed first: `Powerbook 1400c`, `guest-3`, listening port 5250 — metal,
not the emulator. A liveness tail sampled `session_health` every 3s.

### The full sequence, in order

1. **Before the Mirror opens:** cycles are `walk: structure`, `windows: 1`,
   `elements: 67`. 10 of 24 `ok`, 14 `failed`.
2. **The Mirror opens:** the walk changes to `walk: full`, `windows: 5`.
3. **Every full walk fails.** All 24 held cycles read
   `(full, failed, 5)` with `requestMs: 0, totalMs: 0, decodeMs: 0` — the
   request was **never sent**. Not a slow guest; a host that did not ask.
4. **Four acts dispatch**, in this order:

   | act | outcome |
   |---|---|
   | move New Old World | dispatched (546 ms) |
   | move New Old World | dispatched (245 ms) |
   | click the close box of New Old World | **confirmed** (via the broker) |
   | click `"after-dark-2x-1993.sit"` | dispatched (539 ms) |

   Note the asymmetry: the close box went through `MirrorMutationBroker`
   and came back **confirmed**; the desktop-file click took the direct
   lane and only ever reached **dispatched**.
5. **The guest is lost.** The tail fired `GUEST LOST`. It returned at
   `connectedAt 06:16:45` with `framesReceived` reset to 4.
6. **Michelle, at the machine:** *"guest app crashed finder then wedged
   itself after finder restarted. needed to force quit and restart guest
   app."*

### What that adds

- **The failure is host-side, and it is total.** 24 of 24 full walks were
  never sent. Structure walks worked. Whatever refuses to send, it began
  when the walk went full.
- **The wedge is a THIRD event, not the crash.** NOW crashes → the Finder
  crashes → the Finder restarts → *then* NOW wedges and needs a force
  quit. A wedge after a Finder restart is a different failure from the
  crash that preceded it, and the two should not be filed as one.
- **`idleMs` stays 758–804 throughout**, structure or full. The ~780 ms
  poll cadence is unchanged by any of this.

### The one thing blocking the diagnosis

`outcome: "failed"` is not a real outcome. The host's own vocabulary
(`NOWMirrorSource.swift:552-597`) is `no-reply`, `wrong-mac`, `starved`,
`refusedByGuest`, `ok`. Twenty-four cycles failed and the surface will not
say which. `claude/026-cycle-outcome-reason` exists to fix exactly that,
and it is now the critical path: **re-run this read after it lands and the
answer is one word.**

### Retraction

Two claims made during this session were wrong and are withdrawn:

- That `connectedAt` moving and `framesReceived` dropping showed a host
  defect in guest-record handling. **It was reconnects.** A new connection
  resets the frame counter; that is correct. Samples taken across separate
  commands were compared in the wrong order.
- That two of four earlier guest logs "dying immediately after the files
  refusal" was a lead. The refusal appears in nearly every session and one
  survives it by twelve minutes.

Both were true observations promoted to causes because they sat near the
thing being looked for. Recorded because the pattern recurred three times
in one night, twice after saying the lesson had been learned.

## The sequence, corrected again — and the confound in it

Michelle, after the measured run above:

> the earlier initial failure was an exception type 1 from now, where it
> initially crashed cleanly, then crashed finder following the reproduced
> crash and upon clicking app switcher.

So, precisely:

1. **Crash #1** — exception **type 1** from NOW. **Clean**: NOW died and
   nothing else did.
2. **Crash #2** — the same crash, reproduced.
3. **Click the app switcher** → **the Finder crashes.**

### Two readings, and nobody has separated them

- **Cumulative:** the first crash leaves something behind, and it takes a
  second one before the app switcher finds it.
- **Unconditional:** *any* crash leaves it, and the app switcher would
  have killed the Finder after the first one too — nobody clicked it
  then.

**The experiment that separates them costs one click.** After the next
single clean crash, click the app switcher immediately, before
reproducing anything.

- Finder dies → unconditional. One crash is enough; the app switcher is
  the trigger, and the "second crash" in this record is a coincidence of
  what got clicked when.
- Finder survives → cumulative, and the crash leaves residue that
  accumulates. That is a much narrower search: something not cleaned up
  on the first death that a second death compounds.

### A note on this document's own history

This asymmetry was flagged as "the strongest clue in the report", then
**retracted** on the strength of Michelle's note that the Finder crash
happened "in both cases … when clicking app switcher after the crash".
That was read as *both crashes*; she meant *both sessions* — the
pre-census VM one and tonight's metal one.

So the retraction was the error, not the original observation. Worth
keeping visible: three times tonight a true observation was promoted to a
cause, and once a real signal was discarded by over-correcting for
exactly that. Neither direction is safe by default. The fix is the same
in both: name the experiment that would tell the two apart, and run it
before writing either one down as settled.

## Second loss, same session — and it breaks the law stated above

A second guest loss was caught by the same tail. The numbers differ from
the first in ways that matter:

| | first loss | second loss |
|---|---|---|
| full walks `ok` | 0 | **3** (windows 6) |
| cycles actually sent (`requestMs > 0`) | 0 | **7** |
| full walks `failed` | 24 | 21 |
| last act before the loss | click `"after-dark-2x-1993.sit"` | **move New Old World** |

**"24 of 24 full walks were never sent" is withdrawn as a property.** It
was true of a single 24-cycle window and was written up as if it were a
law of the full walk. The Mirror *does* complete full walks on metal —
three of them, returning six windows — and it does send more cycles than
it completes: seven sent, three ok, so four were sent and failed. Those
are three distinct populations and the earlier reading collapsed them
into one.

**No single act is the trigger.** The first loss ended on a desktop-file
click and the second on a window move. Any account that leans on the
`.sit` click is fitting one sample.

What survives from both runs:

- The overwhelming majority of full-walk cycles produce nothing —
  17 of 24 never sent even in the better run.
- `idleMs` holds 758–804 regardless.
- The reason is still `"failed"`, still not in the host's vocabulary, and
  now it is hiding **two** different things: cycles that were never sent
  and cycles that were sent and failed. Those cannot share a label.
  `claude/026-cycle-outcome-reason` matters more, not less.

## The escalation ladder, now seen twice

Michelle, third loss of the session:

> just crashed finder on the pb and completely wedged this time.
> consistent with the earlier run which wedged the system when i tried
> repro the finder crash. did not click desktop this time

Two independent runs have produced the same monotone escalation:

| attempt | result |
|---|---|
| crash NOW | **clean** — NOW dies, nothing else |
| crash NOW again, then click the app switcher | **the Finder dies**, restarts |
| try to reproduce the Finder crash | **the whole machine wedges** |

### What this rules out, and what it favours

- **The desktop click is out.** Ruled out by her own control: she did not
  click the desktop this time and got the same result. Two runs also
  ended on different final acts (a `.sit` click, a window move). Any
  account resting on a particular act is fitting one sample.
- **A single bad code path does not do this.** One faulty branch produces
  the same failure every time it is taken. A failure that gets *worse*
  with repetition — clean, then a neighbour dies, then the machine stops
  — is the signature of **residue that accumulates across crashes**.

That is the **cumulative** branch of the discriminator recorded above,
and it now has two independent runs behind it rather than one reading of
one log. It is still not proof: nobody has clicked the app switcher after
a single clean crash, which remains the one click that would settle it.

### Where a cumulative account would look first

Stated as a place to look, **not** as a mechanism — it was read out of the
source earlier and deliberately not promoted:

The content plane's port unhook can only run **from the armed
application's own context** (`now_content.c`, the restore is guarded on
`gPorts[i].a5 != a5`). A crashed application never runs it. So each death
leaves rows whose `a5` names a process that no longer exists, and those
rows are never reclaimable — their owner cannot return. A later run gets
fewer slots, and `content_install_port` refuses a port whose `grafProcs`
is already non-NULL, counting it in `skipped_ports`.

**The resident already counts what would prove or kill this.**
`NowContentBlock.counters` carries `installs`, `uninstalls` and
`skipped_ports`, and `hooked_ports` carries the live total. If hooking
leaks across crashes, `installs` minus `uninstalls` grows with each one
and `skipped_ports` climbs on every subsequent run.

**Read those three counters after each crash in a series.** That is a
measurement, not an argument, and it does not need a rebuild — it needs
the numbers surfaced somewhere a person can see them, which is precisely
what `claude/026-mirror-logging` is for.

### Host-side at the wedge

24 of 24 `(full, failed, 6)`, **0 sent**. The guest is gone. The
sent-versus-never-sent split varies run to run (7 sent in the second
loss, 0 in the first and third) — so that ratio is a symptom of how far
things had already degraded, not a constant.
