<!-- now-doc-provenance: generated reviewed=false -->

# Event Manager journaling — asked, measured, closed

**Date:** 2026-07-31 · **Status:** recorded knowledge, carried from the
parked upstream project `timbottu/mirror` (`docs/JOURNALING.md`).
Nothing on this page was measured by NOW.

**Provenance.** All measurements were taken on session-private QEMU
`mac99` clones running Mac OS 9.1, in 2026-07-30 and 2026-07-31.
**Never on real hardware, and the hazard below is a reason it never
should be.**

## The answer, first

Classic Mac OS has a built-in record/playback hook: the Event Manager
can be told to **source** its input from a journal device instead of the
hardware, or to **report** each event to one. It is the mechanism the
classic macro and remote-control utilities used.

**It cannot drive a foreign application, so it is not an input plane for
this kind of project.**

Not because it is broken — it is alive and it works better than its
reputation — but because **`JournalFlag` (low memory `0x08DE`) is a
per-process global.** No application can arm journaling for another from
outside.

## What was actually measured

| Question | Answer |
|---|---|
| Is the mechanism idle and unclaimed on a stock 9.1 boot? | Yes. `JournalFlag` 0, `JournalRef` (`0x08E8`) 0, `OpenDriver("\p.Journal")` returns **-43 `fnfErr`** |
| Is -43 evidence of breakage? | **No.** Apple shipped no stock journal device; supplying one was always the caller's job. A missing `.Journal` is the expected state on a clean system |
| Does the Event Manager call an installed driver at all? | **Yes** — via `Control`, never `Status`; roughly 40+ times per tick, about 200,000 calls across runs |
| Is the widely-cited "broken and unusable under multitasking" report true on 9.1? | **No.** The driver path works |
| Does it have a per-boot ceiling like the injection path was believed to? | **No ceiling observed at all** |
| Is playback a system-wide input takeover? | **No.** Armed ~600 ticks, the guest stayed usable and the wire stayed responsive |
| Can a sourced position reach inside a live tracking loop? | **Yes** — the thing input injection demonstrably cannot do |
| Can one process arm it for another, from outside? | **No** |

The control codes, measured by listening and then confirmed against
Inside Macintosh Vol. I pp. 1-261..262: **`csCode 16` = `jPlayCtl`
(`JournalFlag` < 0), `17` = `jRecordCtl` (> 0)**.

### Which hooks fire, and which can be sourced

| Code | Fires on 9.1 | Sourceable |
|---|---|---|
| 0 `jcTickCount` | yes, dominant | yes |
| 1 `jcGetMouse` | yes | **yes** |
| 2 `jcButton` | **never** | — |
| 3 `jcGetKeys` | yes | **yes** |
| 4 `jcEvent` | **never** | — |

**The tracking-loop result, stated precisely.** With the flag negative
and the driver writing the datum, `GetMouse` **inside `TrackControl`'s
action procedure** returned the sourced local point (278,40) instead of
the real pointer at (759,539), and drove the scroll bar to value 40
instead of 100. A tracking loop *is* reachable this way.

Because `jcButton` is never journaled, the working shape would be a
hybrid: source the position through the journal, hold the button through
the low-memory `MBState` path.

### And it still does not help

A foreign process sampled `JournalFlag` **10,722,892 times** while
another process held it at −1, and read **0 every time**. With the owner
backgrounded and a foreign app frontmost polling `GetMouse` about nine
million times, all 32 logged journal calls still came from the owner.

Installing the driver at boot from an INIT **does not help** — the
driver was never the constraint.

So journaling can drive **the process that armed it, and nothing else,
from outside.** That is the precise claim the evidence supports.

## The route that was never tested

Upstream narrowed its own conclusion after review, and the narrowing is
the useful part:

> Both experiments wrote `JournalFlag` **from the owner's own process**.
> The INIT experiment varied where the *driver* was installed, not who
> set the flag — which is exactly why it changed nothing. **The untested
> route is writing `JournalFlag` while the target process is current**:
> code executing *as* the target, rather than an application arming it
> for another.

That is not speculative, because the observer INIT is already a
`GNEFilter` hook that runs in each process's context, for precisely this
class of problem. A hook that can read another process's per-process low
memory can write it.

**A second route skips journaling entirely: patch the traps.** A native
PowerPC application's `DragWindow` has been shown reaching a 68K trap
patch on this target, so a patched `GetMouse` / `StillDown` returning a
sourced position for a chosen process reaches a foreign tracking loop
directly. **That is the route the act plane took**, and it works — see
[mirror-act-plane.md](mirror-act-plane.md).

**Why the untested route stays untested.** The observer is deliberately
observe-only; that restraint is why it is safe. A hook that *writes*
into other processes' low memory is a different posture. And the failure
mode is worse: a foreign app whose `GetMouse` / `GetKeys` / `TickCount`
come from us is **wedged if our driver dies**, the deadman must now
disarm a flag it can only write when that process is current, and
falsifying a foreign process's clock takes its timing with it.

## The hazard worth inheriting

A journal device left armed **while falsifying `TickCount`** took the
guest's network stack down within seconds, and it did not recover in
120 s. **Every Open Transport timeout is counted in ticks, so
falsifying the clock destroys the channel you would recover through.**

A host-side disarm is therefore unreachable in exactly the failure it
exists for.

The thing that works is an **in-driver deadman** that zeroes the flag
itself when its log fills — verified to rescue an abandoned run with no
software of ours running. Upstream's own design constraint, *"a disarm
path that does not depend on the agent,"* was right and stronger than it
knew: it must not depend on the **host** either.

**Emulator and disposable clones only. Never real hardware.**

## The capability journaling did produce

**System-wide `TickCount` falsification from in-guest OS API, with no
per-boot ceiling.** `TickCount()` returned an injected `1000000` while
the raw ticks global read `96335`. Recorded because it is genuinely new,
not because anything needs it — and it comes with the hazard above
attached.

## The instrument lesson

The first reading of these runs was *"only the tick hook sources"* — a
wrong conclusion caused by **a two-byte error in the instrument itself.**
The journal code is a **word at `csParam + 4`** (`csParam` is
`short[11]`) and the filter compared a longword, folding in the
caller-stable junk word beside it.

One bug produced two opposite errors. **An instrument is the first
suspect.**

## Why this question was reopened at all

The original exclusion was **inherited, not measured**: it traced to a
third party's report about System 7 and a system-wide-takeover argument.
The takeover argument stands on its own; the breakage claim did not
survive being tested on the actual target.

Reopening was right for that reason. It was **not** urgent for the
reason first written down — the injection-path ceiling it was meant to
route around turned out to be an artifact of a broken test oracle, not a
property of the mechanism. See
[mirror-measurement-method.md](mirror-measurement-method.md).
