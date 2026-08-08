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
