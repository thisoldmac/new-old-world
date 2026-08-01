# The Event Manager journaling mechanism — reopening a closed question

Classic Mac OS has a built-in record/playback hook: the Event Manager can be
told to **source** its input from a journal device instead of the hardware
(playback), or to **report** each event to one (record). It is the mechanism
classic macro and remote-control utilities used to drive a Mac.

The lab excluded it from the input plane without testing it. This document
holds what we actually measure.

**Status: RESOLVED 2026-07-30 — journaling cannot drive a foreign application,
so it is not an input plane for this project.** The mechanism is alive on 9.1,
AMS's report does not hold, it sources mouse position and key state, and the
sourced position genuinely reaches inside a live `TrackControl` loop — the exact
thing `PostEvent` cannot do. And none of that helps here, because `JournalFlag`
is a **per-process** low-memory global: no application can arm journaling for
another. See "The answer" below. Everything above that heading is the
pre-measurement framing, kept as written.

## Why it was excluded, and why that is not enough

The lab's `docs/12-journaling.md` and the finding
`input-injection-postevent-not-journal` reject the journal driver on two
grounds:

1. Advanced Mac Substitute (Josh Juran) reports the driver is *"broken and
   unusable under System 7's multi-tasking"*, and we target 9.1 — further
   still.
2. Playback is a **system-wide takeover**: every application's Event Manager
   reads from the journal, the human is locked out, and a flag left armed
   means a reboot.

Reason 2 is a property of the mechanism and stands on its own. Reason 1 is
**secondhand** — the finding's evidence is `memory:timbottu-harness-state`,
tracing to AMS's report, and nobody probed 9.1 here. It closed the question
before it was asked.

Two things make that worth revisiting now:

- The alternative it selected has a ceiling nobody had measured: `PostEvent`
  actuation dies after ~9 uses per boot, and it cannot drive a control at all
  once the target enters a tracking loop ([STATUS.md](STATUS.md)).

  > **Correction, 2026-07-30 (later the same day):** both halves of that bullet
  > were wrong, and it was the motivation for reopening the question. The
  > ~9-per-boot ceiling was an artifact of an accumulating test oracle —
  > `PostEvent` measures 20/20 with independent trials, and 45 consecutive
  > keystrokes land. The "cannot drive a control" claim was a non-retrying test
  > client; `axdo` scrolls a real scrollbar. See STATUS.md. Reopening the
  > journaling question was still right — the exclusion *was* inherited rather
  > than measured — but it was not urgent for the reason stated here.
- "We inherited a claim" is not the same as "we know." The point of measuring
  is to learn what the mechanism is and is not good for — not to adopt it.

## Phase 1 — what exists on a stock OS 9.1 boot (measured 2026-07-30)

`journalprobe`, a read-only verb, on a fresh `mac99` / OS 9.1 clone:

| Field | Value | Reading |
|---|---|---|
| `journalFlag` (0x08DE) | `0` | journaling idle; nothing is recording or playing back |
| `journalRef` (0x08E8) | `0` | no journal device registered |
| `OpenDriver("\p.Journal")` | **-43** (`fnfErr`) | no `.Journal` driver in the System file |

**The -43 is not evidence of breakage.** The journal *device* was always
supplied by whoever wanted to use the mechanism — a macro utility installs
one — and Apple shipped no stock provider. A missing `.Journal` is the
expected state on any clean system, and supplying the provider is the
caller's job. What phase 1 establishes is narrower and still useful: the
mechanism is **idle and unclaimed** on our target, so an experiment cannot
collide with an incumbent.

The two low-memory addresses are `P-DOC`, taken from the Multiversal
interfaces (`toolchain/multiversal/CIncludes/Multiverse.h`, which defines
`LMGet/SetJournalFlag` at 0x08DE and `LMGet/SetJournalRef` at 0x08E8), not
from recollection. Modern Universal Interfaces carry only `JournalRef`.

## Phase 2 — the protocol, learned by listening

The journal driver's `csCode` values are in no shipped header (confirmed by
grep across both Retro68 toolchains, Universal and Multiversal). They are
published in Inside Macintosh Vol. I, and they also appear in leaked Apple
System 7.1 Toolbox source, which is `P-3P` and not something to build on.

There is a better way that needs neither: **install a journal device that
only listens.** A DRVR that logs every `csCode` and parameter block the
Event Manager sends it, armed in *record* mode, makes the system tell us its
own protocol — a `P-OBS` derivation, measured on our own machine, with no
copyright question and no dependence on a constant we could get wrong.

It also answers the real question as a side effect. If the Event Manager
never calls our driver, the mechanism is inert on 9.1 and AMS's report is
confirmed for our target — cheaply, and first-hand.

Design constraints for that experiment, before any of it is written:

- **Record, not playback.** Record observes; playback takes the machine.
  Nothing about phase 2 needs playback.
- **Emulator only, session clone.** A flag left armed is a reboot, and a
  reboot of a real machine is not ours to spend.
- **A disarm path that does not depend on the agent.** The agent can wedge —
  that is measured, not hypothetical — so recovery must not require it to
  answer. On the emulator the floor is that the clone is disposable.
- **Typed emulator-only until proven otherwise**, per the plan's rule
  against load-bearing emulator-only mechanisms.

## Phase 2 + 3 — done, 2026-07-30. The question is answered.

Both phases ran in the **lab**, not here (see "Where this lives" below). Full
write-up and reproduction: `timbottu/prototypes/journal/README.md`; the corpus row
is the lab finding `journaling-alive-tick-only-os91`.

The listener was built as designed: a hand-written 68K `.Journal` DRVR that logs
every entry point, csCode and parameter block into its own resource, carried in a
PowerPC app's resource fork, armed for a bounded dwell on a session-private
`mac99` / OS 9.1 clone.

**Headline: the mechanism is alive, and AMS's report does not hold on 9.1.**

| Question this doc asked | Answer |
|---|---|
| Does the Event Manager call our driver at all? | **Yes** — via `Control` (never `Status`), ~40+ times per tick, ~200 000 calls across runs |
| Is AMS confirmed for our target? | **No.** The driver path works. `csCode 16` = `jPlayCtl` (`JournalFlag`<0), `17` = `jRecordCtl` (>0) — measured, then confirmed against Inside Macintosh Vol. I pp. 1-261..262 |
| Does it have the `PostEvent` ~9-per-boot ceiling? | **No ceiling observed at all.** That is the one clear win over `PostEvent` |
| Is playback a system-wide input takeover? | **No.** Armed ~600 ticks, the guest stayed usable and the wire stayed responsive |
| **Does playback reach inside `TrackControl`?** | **Unresolved — do not plan on it.** See below |

**The part that matters for MirrorKit, stated conservatively.** The hypothesis in
this document was that journaling could reach where `PostEvent` cannot, because
the Event Manager sources `GetNextEvent`/`Button`/`GetMouse`/`GetKeys` from the
journal device. On 9.1 those hooks are effectively gone: of ~200 000 calls,
essentially all were `jcTickCount`. `jcEvent` appeared at about **1 call in
10 500**, and `jcGetMouse` / `jcButton` / `jcGetKeys` **never fired** — with those
routines called explicitly inside the armed window precisely so that absence would
mean absence. A synthetic `keyDown` written into a `jcEvent` playback buffer was
verified in place and **never observed emerging from `GetNextEvent`**.

So journaling on 9.1 can source the **clock**, not the **input**. It does not
solve `axdo`; the tracking-loop problem stands, and the act plane's shape
described in [STATUS.md](STATUS.md) is unchanged. What journaling adds to the
toolbox is a genuinely new capability — **system-wide `TickCount` falsification
from in-guest OS API, with no per-boot ceiling** (`TickCount()` returned our
injected `1000000` while the raw `Ticks` global read `96335`).

**And a hazard worth inheriting.** It is not lockout. A journal device left armed
while falsifying `TickCount` took the guest's network stack down within seconds
and it did not recover in 120 s — every Open Transport timeout is counted in
ticks, so falsifying the clock destroys the channel you would recover through.
A host-side disarm is therefore unreachable in exactly the failure it exists for.
The thing that works is an **in-driver deadman** that zeroes `JournalFlag` itself
when its log fills — verified to rescue an abandoned run with no software of ours
running. This document's design constraint "a disarm path that does not depend on
the agent" was right, and stronger than it knew: it must not depend on the *host*
either.

## Where this lives, and why not here

The lab's doctrine (`AGENTS.md`) is that a child inherits the lab's **findings and
culture, never runtime code**. So there is deliberately no shared journaling
library, and this is not a case for one:

- **Shared:** the protocol, the measurements, and the hazard — as the lab finding
  `journaling-alive-tick-only-os91` and `timbottu/docs/12-journaling.md`. That is
  what this document points at, and it is the whole reason the doctrine allows
  mirror to depend on the parent's corpus.
- **Not shared:** the driver. The reference `DRVR` and its instrument app live in
  the lab (`timbottu/prototypes/journal/`), where the wrong claim was recorded and
  where the correction belongs. If mirror ever wants a journal device it writes
  its own from the documented protocol — which is now a table, not an
  archaeology project.

Given the result, mirror should **not** implement one *yet* — but the reason has
changed. The capability it was wanted for (reaching a tracking loop) is no longer
absent, it is unproven: `GetMouse` sourcing works, and whether a tracking loop
follows is the open question. If that comes back positive it is directly relevant
to `axdo`, and mirror would then write its own device from the documented protocol
— which is now a table, not an archaeology project.

**Still open, named rather than guessed:** whether a real tracking loop follows a
sourced `GetMouse` position; and whether journaling serves only the *front*
process — a background polling app produced no journal calls at all while the front
app's were journaled normally, observed once. That second one decides whether a
specific application can be targeted, which is exactly what an act plane needs.
(`0x9080` is resolved: it was never a journal code, just the adjacent word.)

## The answer, 2026-07-30 — and it is a no, for a reason worth keeping

Lab finding `journaling-sourceable-hooks-os91` (which supersedes the earlier
tick-only one). Three of the five hooks fire and are **sourceable**:

| code | fires on 9.1 | sourceable |
|---|---|---|
| 0 `jcTickCount` | yes, dominant | yes |
| 1 `jcGetMouse` | yes | **yes** |
| 2 `jcButton` | **never** | — |
| 3 `jcGetKeys` | yes | **yes** |
| 4 `jcEvent` | **never** | — |

**The hypothesis this document opened with was correct.** With `JournalFlag`
negative and the driver writing the datum, `GetMouse` inside `TrackControl`'s
action proc returned the sourced local `(278,40)` instead of the real pointer
`(759,539)`, and drove the scroll bar to value 40 instead of 100. A tracking loop
*is* reachable — which is precisely what `PostEvent` cannot do. The working shape
is a hybrid, because `jcButton` is not journaled at all: source the position
through the journal, hold the button through the existing low-memory `MBState`
path.

**And it is unusable for us anyway.** `JournalFlag` (0x08DE) is a **per-process**
low-memory global. A foreign process sampled it 10 722 892 times while another
process held it at `-1`, and read `0` every time. With the owner backgrounded and
a foreign app frontmost polling `GetMouse` ~9 million times, all 32 logged journal
calls still came from the owner and the foreign app never saw a sourced value.
Installing the driver at boot from an INIT does not help — the driver was never
the constraint.

So journaling can drive **the process that armed it**, and nothing else — *from
outside*. That is the precise claim the evidence supports.

> **Narrowed 2026-07-31 (Michelle: "can't we hook into other processes?").** I
> first wrote this as "the route is closed", and that is stronger than what was
> measured. Both experiments wrote `JournalFlag` **from the owner's own process**;
> the INIT experiment varied where the *driver* was installed, not who set the
> flag, which is exactly why it changed nothing. The untested route is writing
> `JournalFlag` **while the target process is current** — code executing *as* the
> target rather than an application arming it for another.
>
> That is not speculative here: **AXPeek is already a `GNEFilter` INIT that runs
> in each process's context**, for precisely this problem — per-process low-memory
> roots (`CurrentA5`, `WindowList`, `MenuList`) are invisible from outside, so the
> hook goes to them. A hook that can *read* another process's per-process low-mem
> can write `JournalFlag`/`JournalRef` there.
>
> A second route skips journaling: **patch the traps**. The lab has already shown
> a native PPC app's `DragWindow` reaching a 68K trap patch on this target, so a
> patched `GetMouse`/`StillDown` returning a sourced position for a chosen PSN
> reaches a foreign tracking loop directly.
>
> **What makes this a decision rather than a task.** AXPeek is deliberately
> observe-only — it never actuates and never dereferences a foreign tree, and that
> restraint is why it is safe. A hook that *writes* into other processes' low
> memory is a different posture and belongs below the line. And the failure mode
> is worse than ours: a foreign app whose `GetMouse`/`GetKeys`/`TickCount` come
> from us is wedged if our driver dies, the deadman must now disarm a flag it can
> only write when that process is current, and falsifying a foreign process's
> clock takes its timing with it. Emulator only, and a real safety review before
> anything else.

Two things worth carrying regardless:

- The earlier "only the tick hook sources" reading was wrong because of a
  **two-byte error in their own instrument** — the journal code is a WORD at
  `csParam+4` (`csParam` is `short[11]`) and the filter compared a longword,
  folding in the caller-stable junk word `csParam[3]`. One bug produced two
  opposite errors. A good reminder that an instrument is the first suspect.
- The hazard, which now sits on the lab's metal safety line: a journal device
  left armed while falsifying `TickCount` takes Open Transport down with it,
  because OT counts its timeouts in ticks — so the over-the-wire disarm is
  unreachable in exactly the failure it exists for. The only reliable net is an
  in-driver deadman. Emulator and disposable clones only; never metal.

**What this leaves for shortcut-less menu items.** The remaining honest route is
per-item geometry *from the guest* — the Menu Manager knows each item's height,
and a verb could report item rects instead of the host assuming uniform 16 px
rows. That is a guest-side change, not a journaling one.

## What this is not

Not a replacement for `PostEvent`. That path is metal-proven for `type`,
`click`, and modified keys, and it contends with the human rather than
locking them out. The question here is what journaling can do that
`PostEvent` demonstrably cannot — reach inside a tracking loop — and at what
cost.
