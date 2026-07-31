# QD Probe — a throwaway INIT, not a NOW component

**Date:** 2026-07-31 · **Status:** built, ladder not run · **Disposition:** delete
when its questions are answered

This is the P3 spike from [resident-components.md](../../docs/resident-components.md)
and M2 of [plan 007](../../docs/plans/2026-07-31-007-feat-now-mirror-integration-plan.md).
It is **deliberately not part of NOW**, and the charter is why:

> *P3 — content: QuickDraw bottleneck hooks, the full Timbuktu move. The riskiest
> class we would ever ship; dark until the mirror needs interiors better than
> pixel fill, armed per-port, separate failure domain in everything but the file.*

The charter's instruction for a plane like this is to develop it as a **throwaway
INIT under an honest name** on a QEMU clone, and fold it into the NOW Extension
only after its ladder passes. So this ships nothing, is installed by hand, and
carries its own identity end to end:

| | QD Probe | NOW Extension |
| --- | --- | --- |
| file | `QD Probe` | `NOW Extension` |
| creator | `QDpr` | `NOWx` |
| Gestalt | `'QDpr'` | `'NWex'` |
| lifetime | delete it | ships |

Nothing here is named to look like NOW, and it does not read, write, or
require NOW's table. If both are installed they do not know about each other.
That is the "separate failure domain" clause taken literally: a crash in this
file cannot be a crash in the shipping one, because they are not the same file
and share no state.

## The one question M0 exists to answer

**Can a 68K INIT's drawing bottleneck be called safely by a PowerPC
application's QuickDraw?**

Everything else about P3 — the ring buffer, the op vocabulary, per-op cost, the
scene IR — is downstream of that yes or no, and none of it is worth writing
until it is answered. The reason to doubt it: a bottleneck proc installed in a
`CGrafPort` is called by whatever code is drawing. Under CarbonLib on a
PowerPC machine that caller is native PowerPC, and reaching 68K code from
native code goes through Mixed Mode, which needs a routine descriptor rather
than a bare pointer. This project has already paid for that lesson once — the
`cis` verb froze a PowerBook 1400c hard enough to need a physical reboot, and
the fix was an `M68K` routine descriptor plus an `RTS` thunk.

NOW's existing jGNE filter is **not** evidence either way. The Event Manager
calls it as bare 68K code, which is exactly why `now_ext.c` can hand it a raw
pointer while handing Gestalt a real `NewSelectorFunctionUPP` — that file's own
comment draws the distinction. QuickDraw's bottlenecks are the second case, not
the first.

So M0 patches **one** bottleneck (`rectProc`), counts calls, and stops. If the
count is nonzero after something draws a rectangle, the mechanism is reachable.
If the machine hangs, that is the answer too, and it is why this runs on a
disposable clone first.

### What the build already sharpened

Two things came out of reading the object file rather than trusting a clean
compile — and it compiled clean on the first attempt with both of these in it.

**`NewQDRectUPP` is a plain cast on this toolchain, not a routine descriptor.**
Confirmed by the absence of any `NewRoutineDescriptor` reference in
`qdprobe.c.obj`. That cuts both ways. Nothing allocates when we install, so the
charter's "no allocation on the hot path" holds by construction. But it means we
are installing a **bare 68K pointer** exactly where the Mixed Mode doubt lives,
and the toolchain will not build a descriptor for us on this target. So the
question is now specific: *does a native PowerPC caller reach a bare 68K
bottleneck pointer?* If the ladder comes back no, the next thing to try is a
hand-built `M68K` routine descriptor plus an `RTS` thunk — the shape that
unfroze the `cis` verb on the 1400c.

**Resident code has no QuickDraw globals**, and the first draft read `qd.thePort`
anyway. `qd` is an application's A5-based struct that `InitGraf` fills in; an
INIT never calls `InitGraf`, so that read returns whatever was in our own
relocated BSS at boot. It *linked* — the object file carried a live reference to
`qd` — which is why this was worth checking instead of taking the clean build as
a result. It uses `GetPort()` now, which asks the Toolbox in the current context
and is correct from anywhere.

## What it does

- Chains jGNE, like NOW's core, to get a moment in each process's context.
- While `arm` is nonzero, patches the current port's `rectProc` — recording the
  port, its previous `grafProcs`, and the **A5 it was patched from**.
- Counts every call through the patched proc, then tail-calls the original.
- While `arm` is zero, restores every port it patched — but **only from the
  same A5 context it patched them in**. See below.

## The dangerous part, stated plainly

A patched port can be disposed by its application without telling us, and a
patched *application* can quit while armed. Either leaves a pointer to freed
memory that QuickDraw may still call. Three rules hold the line, and the ladder
is what tests them rather than this paragraph:

1. **Our `CQDProcs` blocks live in the system heap**, never in the patched
   app's. An app heap goes away when the app does; ours must not.
2. **Restore only in the patching context.** Each entry records the A5 it was
   made under, and a restore is attempted only when `LMGetCurrentA5()` matches.
   Reaching into a quit application's freed heap to "clean up" is the crash this
   avoids.
3. **Verify before restoring.** The port's `grafProcs` must still point at our
   block. If something else patched over us, or the memory was reused, we leave
   it alone and count it — unwinding a chain we are no longer on top of is how
   this class of extension corrupts a machine.

Rule 3 has a consequence worth being honest about: **an app that quits while
armed leaks its entry.** That is deliberate. A leaked slot costs a table row; a
wrong restore costs the machine.

## The ladder

Per the charter, in order, saying which rung a claim sits on:

| rung | state |
| --- | --- |
| compiles | done |
| links | done |
| packages (`QDProbe.bin`) | done |
| loads at boot | **not run** |
| callbacks run (the count moves) | **not run — the actual question** |
| survives boot / shift-disable / removal | **not run** |
| per-op cost measured | not run |
| PowerBook 1400c, attended | not run — emulator first, and not without asking |

There is no reader yet: the counters are published through Gestalt `'QDpr'` and
nothing reads them. That is the next rung, not an oversight.

## Build

```
cmake -B build -DCMAKE_TOOLCHAIN_FILE=$NOW68K_TOOLCHAIN prototypes/qdprobe
cmake --build build
```

Deploy `QDProbe.bin` into `System Folder:Extensions` on a **disposable clone**
and cold-boot; INITs load at boot only, and OS 9 ignores a soft power-down.
Recovery is a shift-boot, which is in place before the install rather than after
the problem.
