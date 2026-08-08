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
