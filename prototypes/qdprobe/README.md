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

A third thing came out of inspecting the identity change the same way, and this
one is reassuring rather than sharpening. The gate is real in the object code,
not just in the source: `qdprobe_gne_apply` loads `arm_expiry`, branches to the
retire path when it is zero, compares with a **signed** subtract otherwise, then
compares `arm_a5` against `LMGetCurrentA5()` (an inline read of low memory
`0x904`) and only then executes `_GetPort` (`$A874`). No refusal path reaches
the Toolbox at all, and `-Os` inlined `patch_current_port` without dropping
either check. The object file's only library import is `memcpy` — the
pre-existing `QDProbePort` struct copy in `restore_ports()` — and the map shows
it linked into our own flat blob rather than dispatched, so it is as resident as
the rest of us.

## What it does

- Chains jGNE, like NOW's core, to get a moment in each process's context.
- While a **live request naming this context** stands, patches the current
  port's `rectProc` — recording the port, its previous `grafProcs`, and the
  **A5 it was patched from**.
- Counts every call through the patched proc, then tail-calls the original.
- Otherwise restores every port it patched — but **only from the same A5
  context it patched them in**. See below.

## Arming names its target

A request is three fields in the shared block, and `arm` alone is not one of
them:

| field | written by | meaning |
| --- | --- | --- |
| `arm_a5` | reader | the **only** A5 world we will patch |
| `arm_expiry` | reader | `TickCount` after which the request lapses |
| `arm` | reader (commit) / probe (to zero, on expiry) | request stands |

`arm` is the commit word: **write `arm_a5` and `arm_expiry` first, `arm` last;
to disarm, write `arm` first.** A jGNE pass can land between any two stores, and
that order is what stops a live `arm` from ever pairing with the previous
request's target.

**Arming with no target named does nothing.** The obvious reading of a bare
`arm` is "instrument everything"; the fail-closed reading is "instrument
nothing", and this is the repo's habit for good reason. A request that does not
say whose ports it wants has not asked for anything we are willing to do. Both
refusals — no target, and wrong context — are counted per pass, so a
misaddressed request is loud rather than silent.

### Why this changed

The first draft patched whichever port happened to be current while armed,
first-come, capped at 8, with no identity check at all. The cap bounded how
*many* ports; it never bounded *whose*. The sibling Portal INIT measured the
same defect shape in the actuator case (`mirror`, `d9db2c4`,
`docs/PORTAL-PLAN.md`, 2026-07-31): its `MenuSelect` patch was single-flight and
self-disarming, and with a request armed a real user press on a *different* menu
ran the armed command **18/20**. The patch that additionally required the
request to name its exact `ControlHandle` hijacked **0/20**. The general lesson,
and it is the reason this file changed:

> **A bound on time or count is not a bound on scope.** Disarming says the patch
> fires once. It says nothing about *whose* call it fires on.

### Why A5

It is what both sides can actually hold. `LMGetCurrentA5()` is a single
low-memory read from resident code in any context — no Process Manager call,
nothing that moves memory — and NOW's anchor plane already keys per-process
state the same way (`contract/peek_table.h`), so a reader that has an anchor
already has the value to write here.

Two limits, stated rather than assumed:

- **A5 names an A5 *world*, not a process**, and the value can be reused after
  an application quits. Re-arm per launch. The expiry is what bounds the window
  in which a recycled A5 could be mistaken for the target — the honest reason to
  keep a deadline even though it guards nothing about scope.
- **A background target never arms.** Our hook only runs when the target runs,
  and a suspended process does not pump its event loop. Upstream measured this
  directly: **6/6 timeouts** arming a backgrounded application (`mirror`,
  `docs/STATUS.md`). Identity-scoped arming can only ever reach a target that is
  alive and pumping. That is a real bound on what this probe can observe, not a
  bug to be fixed here.

### The expiry is secondary, and is not the guard

The dead-man's switch exists because upstream also measured that **the guest
never ages a request out** — only the host verb's exit path cleared `armed`, so
an agent that died mid-verb left a patch armed indefinitely, and a safety
property should not depend on the caller surviving. It is fail-closed (a request
with no deadline is expired on sight) and wrap-safe (signed tick difference).

It bounds a request's **duration, not its scope**. Its one real virtue is
independence: it fires in whatever process pumps next, so retiring a request
needs neither the target nor the reader to still be alive. Nothing about it
substitutes for the identity check.

### What disarm can and cannot guarantee

The asymmetry is not fixable from inside the probe, so it is stated instead:

- **Guaranteed, promptly:** we stop patching anything new. The refusals are
  decided by whoever pumps, so they take effect in every process at once, and
  the expiry path does not need the target alive.
- **Not guaranteed:** that the instrumentation is already gone. A port can only
  be restored from the context that patched it (see below), so a disarm reaches
  the target's ports only when the **target next pumps events**. A target that
  is suspended, wedged, or quit keeps its patch until it runs again — or
  forever, which is the leaked-entry case rule 3 accepts on purpose.

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
nothing reads them, and nothing writes a request either — so on a machine that
booted this today, `arm_a5` is zero and the probe refuses every pass. That is
the next rung, not an oversight, and the reader's first job is the three-field
commit order above rather than a single `arm` poke.

## Build

```
cmake -B build -DCMAKE_TOOLCHAIN_FILE=$NOW68K_TOOLCHAIN prototypes/qdprobe
cmake --build build
```

Deploy `QDProbe.bin` into `System Folder:Extensions` on a **disposable clone**
and cold-boot; INITs load at boot only, and OS 9 ignores a soft power-down.
Recovery is a shift-boot, which is in place before the install rather than after
the problem.
