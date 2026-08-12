---
title: Composing interiors host-side - Plan
type: feat
date: 2026-08-06
---

<!-- now-doc-provenance: generated reviewed=false -->

# Composing interiors host-side - Plan

Subordinate to [001, NOW Mirror UX Completion](2026-08-03-001-now-mirror-ux-completion-plan.md),
which still owns the destination. Continues the GWorld probe arc, whose
brief is `docs/gworld-probe-brief.md` and whose measurements are the
corpus finding `gworld-offscreen-ports-are-hookable` and
`docs/local/toolbox-re/REFERENCE.md`. Where this plan and
[open-issues.md](../open-issues.md) disagree, the ledger is right.

## Why this exists

A window interior that the Mirror has always drawn as a hatched
rectangle is **not opaque after all**.

Measured 2026-08-06 on mac99/OS 9.1: a resident found and hooked the
Finder's *offscreen* GWorld from outside the process, and with the hook
held across a reflowing resize that port emitted 8 `text`, 24 `rect`, 11
`rgn` and 8 `bits` ops while the window port emitted only 4 opaque
blits. The text carried the real filenames at their true pens —
`'Documents'` [280,67], `'TimBotTu'` [282,131], `'TBT'` [40,195], and the
header `'10 items, 3.21 GB available'` [135,14].

`finder-window-icons-are-offscreen-blits` said this was a dead end. It
was right about the **window** port, which is all anyone had ever
hooked.

So the semantic road that pixel islands were meant to replace is open,
and this plan is about spending that — turning ops we can already
capture into an interior a person sees.

## The one thing standing in the way

**The host cannot join the two halves it receives.**

It gets ops tagged with port `0x1f472e60`, and separately a `bits` op on
window `0x00ac7af0` with a destination rect. Nothing connects them.
`NowContentBitsPayload` carries `src`, `dst`, `mode` and
`src_row_bytes` — and deliberately **no source identity**
(`contract/content_table.h`). The brief named this under "Provenance"
and parked it behind *measure first*; measuring is done.

Without that field the host has a pile of drawing operations and no idea
which rectangle of which window they belong inside. With it, a blit
becomes a **join**: re-home the source port's accumulated ops into the
window at the blit's `dst` offset.

That is the whole plan. Everything else is deferred and named at the
bottom.

## What the code already provides

Read rather than assumed, because each changes the shape of the work:

- **The ops already carry their port.** `NowContentRecHeader.port` is the
  CGrafPtr that drew, on every record. The host already receives ops
  keyed by port; it simply cannot interpret a port it has never been
  told about.
- **The resident already knows the source port**, because it hooked it:
  `gPorts[slot].offscreen` and the row's `pixmap`. But it is a HANDLE,
  and what `content_record_bits` receives is a relocated DEREF — the two
  do not compare directly, and assuming they do reproduces the defect
  that cost this arc a night. **Read A2.1 before writing that line.**
- **The block is accretive by design.** `content_table.h` has been
  appended to twice already under the prefs-record rule (v2 identity
  fields, then the probe fields), with static asserts pinning every
  offset. A record payload growing is the one thing that is *not*
  automatically safe — see slice A.
- **The host already replays ops.** Text, lines, rects, ovals and regions
  replay today; the content plane's host side is not new code. What is
  new is a second coordinate space and the transform between them.

## The slices

### A — the contract, and the payload's version problem

`contract/asyncapi.yaml` first, then `contract/content_table.h`.

Add a source-port identity to the bits payload. **This is not a free
append.** Unlike block fields, a ring record's payload is read at a
fixed width by a reader stepping records by their own `size`; a longer
`NowContentBitsPayload` written by a new resident and read by an old
host is a misparse, not a graceful degradation.

Two options, and the decision belongs in this slice rather than to
whoever types it:

1. **Widen the payload and gate on the block's `format` word.** Bump
   `kNowContentFormatV2` → `V3`; a host that reads V3 knows the payload
   is wider. Costs a format bump, which is a hard cutover for any
   resident/host pair that disagrees.
2. **Emit a separate `kNowContentOpBlitSource` record immediately before
   each bits op.** Accretive by construction — an old reader sees an
   unknown op, steps by `size`, and loses only the join it never had.
   Costs one extra record per blit.

**Recommendation: option 2.** The project's own rule is that a reader
that predates a field gates and never looks; option 2 is the record-level
form of that, and it degrades to today's behaviour exactly. Option 1's
format bump would strand every already-baked image.

Also in this slice: `docs/contract-coverage.md` in the same commit, per
AGENTS.md.

### A2 — SETTLED BEFORE IMPLEMENTATION

Three decisions taken here so the next thread does not re-derive them.
The first is a correction to this plan's own earlier wording.

**1. How the guest resolves a blit's source port — and the trap.**

An earlier draft of this plan said "the value the payload needs is in
hand at the moment `content_record_bits` runs". **That is not true as
written, and taking it at face value reproduces the defect that cost a
whole night.**

`content_record_bits` receives `src_bits`: a *dereferenced* PixMap
pointer, and `LockPixels` relocates the record, so that pointer differs
from where the record lived a moment earlier. A hooked row stores
`gPorts[i].pixmap = (NowPeekU32)cand->portPixMap` — the **handle**.
Comparing the two directly compares a handle against a deref and never
matches.

The correct algorithm, and it is cheap (16 rows maximum):

    for each row i with gPorts[i].offscreen and gPorts[i].a5 == armed:
        if *(PixMapHandle)gPorts[i].pixmap == (PixMap *)src_bits:
            this blit's source is gPorts[i].port

Both sides are read **at the same instant**, so relocation cannot
separate them. Do not stash a deref at hook time and compare later; do
not call `RecoverHandle` on `src_bits` (it searches the current zone and
the locked record is not in one). See
`gworld-offscreen-ports-are-hookable`.

**CORRECTED 2026-08-06, by the control run.** The same-instant compare
above is necessary but NOT sufficient: the record the bits bottleneck
receives is a **copy** of the source PixMap, not the GWorld's own —
`loop.c`'s blit of `*pix` arrived at odd address `0x1eb6aaae` while the
live deref sat elsewhere — so pointer identity never fired and zero
`blitsrc` records crossed the wire against a hooked, drawing GWorld.
The working resolve keeps identity as the cheap first test and falls
back to **shape** via `now_content_probe_pixmap_match` (the same route
the chase itself was forced onto), with the row's port and pixmap
geometry read through the deref at the same instant. Two routes naming
different rows refuse, like any other ambiguity.

**2. Emit the source record in probe mode only, for now.**

`content_record_bits` runs in Record mode too, so the naive change
touches the *shipping* content plane, not just the experiment. Gate the
new record on `kNowContentModeProbe` until the join is proven end to
end. Two reasons: the shipping path should not grow a record whose
consumer does not exist yet, and every `ext/` change is gated by
`tools/ext-bake-gate`, so a resident change that is not yet worth baking
into the shared oracle is a change worth deferring in writing rather
than baking. Widen to Record mode in a later, deliberate commit.

**3. The host side lands in `NOWMirrorContentPlane.swift`.**

`now-host/Sources/Host/NOWMirrorContentPlane.swift` (420 lines) is where
a drain is applied; it already keys on "WindowRecord/GrafPort address —
the exact key both planes report", already routes records by
`record.portAddress`, and already lets MirrorKit replay text and
primitives while CopyBits stays unsupported. The join belongs there, not
in a new component.

### B — the guest fills it in

`ext/src/now_content.c`. When `content_record_bits` runs and the source
pixmap resolves to a port this plane hooked, emit the source record with
that port. When it does not resolve — an unhooked source, a hand-built
PixMap — emit nothing extra, so the absence is the existing behaviour
rather than a zero pretending to be an answer.

Native tests for the decision (which port, or none) in
`now_content_logic.c` where a host `cc` can run them, added to
`scripts/test-native`'s manifest. Watch each fail by mutation.

### C — the host joins and re-homes

The host's content-plane replay gains a second space: ops whose port is
a known offscreen source are held, and on a blit from that source they
are drawn into the window translated by `dst.topLeft - src.topLeft`,
clipped to `dst`.

Three behaviours to get right, all of them measured facts rather than
guesses:

- **A world is replaced, not updated.** Across three resizes the hooked
  row went stale once and `lastMatch` moved `0x1f472e60` → `0x1f472ee0`.
  The Finder imports `NewGWorld` and `DisposeGWorld` and **no**
  `UpdateGWorld`, and the static table says that is the era's norm rather
  than a Finder quirk. So the host must handle a source port's ops
  ending and a new port's beginning mid-session, without drawing a stale
  composite over a fresh one.
- **A disposed world's address is reused** by the very next `NewGWorld`
  of the same size (measured: `0x1ea59e00` twice running). Port address
  alone is therefore **not** a durable key for the host either; pair it
  with the record header's `generation`.
- **Ops precede their blit.** The drawing that builds a composite
  happens before the blit that reveals it, so the host is accumulating
  into a buffer it cannot place until the blit arrives. That is fine and
  is the design — but it means a source's ops must be retained, bounded,
  and dropped when its world goes.

### D0 — discovery, promoted from "deferred" (and why that was wrong)

**This was deferred item 2. It is a slice, and the deferral was a
mistake with a specific cause**: it assumed discovery is a one-off
setup cost — arm once, scan once, hook the world. True in a probe.

But this arc measured that **a world is replaced, not updated**, and
that only 1 of 9 surveyed OS 9 binaries imports `UpdateGWorld`. Under
continuous composition the Finder therefore destroys and recreates its
offscreen world as it repaints, so discovery runs *again* every time —
and what runs is an unbounded two-heap scan, at draw time, inside the
Finder. The probe's risk profile does not transfer to continuous use,
and the plan carried it across without noticing.

**A trap patch is also the better mechanism, not merely the safer one.**
Patching `NewGWorld` / `DisposeGWorld` in the armed process hands us the
port *at creation*, which is precisely the world-replacement signal
slice C would otherwise have to infer from ops going stale. One
mechanism answers two questions.

**Measure this before building it.** The Finder imports `NewGWorld` from
CarbonLib as a **CFM** call, and native PowerPC callers do not dispatch
through the 68K trap table. The act plane's `MenuSelect` patch does
reach the PPC Finder, so some glue honours patches — but whether
`NewGWorld` does is unknown and decides whether this approach exists at
all. One boot answers it: patch the trap, open a Finder window, see
whether the patch fires. **Do that before writing the resident**, and if
it does not fire, say so and fall back to the scan with a bounded
re-discovery budget rather than building on a mechanism that cannot see
the caller.

Resident discipline applies (`classic-mac-init-platform`), including
this project's paid lesson that a callback's ABI is not a formality —
a register-based callback written as a plain C function hung a cold
boot, and the cure was an assembly shim.

### D — the payoff, on screen

One Finder icon-view window, rendered host-side with **real labels at
real positions**, no pixels on the wire. Icons will be hatched
rectangles at correct positions — see deferred item 1 — and that is the
honest first result rather than a reason to delay.

## Stop conditions

- **If the join proves ambiguous** — more than one plausible source for a
  blit, or sources that cannot be told apart across a world replacement —
  stop and say so. A wrong join draws one window's content inside
  another, which is worse than a hatch.
- **If holding a source's ops is unbounded**, stop. The ring already
  overran in one settle on a composite-heavy application
  (`lostBytes 835410`); the host side must not repeat that shape.
- **This does not make the probe shippable** and must not be read as
  doing so — see deferred item 2.

## Deferred, and named

These are all real and none of them are in the slices above.

1. **Icon identity.** Icons arrive as `bits` with no identity while
   labels arrive as text. Full composition needs the resource ID, via
   `PlotIconSuite` / `PlotIconID` / `IconRef` interception, composed
   against the guest's own extracted icon assets
   (`docs/mirror-assets.md`). **Complication measured by the
   documentation lane**: Icon Utilities uses `CopyMask` — invisible to
   `grafProcs` — *unless* the port has `grafProcs` or `picSave` set, in
   which case it renders as two `CopyBits`. So the observer changes the
   observed, and the experiment must be designed around that rather than
   into it.

2. ~~A shippable discovery mechanism.~~ **PROMOTED to slice D0** — see
   above. Deferring it was wrong: world replacement makes discovery a hot
   path rather than a setup cost, and a `NewGWorld` patch also supplies
   the replacement signal slice C needs. The join still goes first,
   because it is cheap and de-risks the coordinate model; it is no longer
   the only thing in this plan.

3. **The spread is thin.** Finder icon view is measured. Finder *list*
   view, a control panel, and a double-buffered application are not. A
   static table already says which OS 9 applications can composite at all
   (`docs/local/toolbox-re/app-offscreen-table.txt`): Finder, Sherlock 2,
   Graphing Calculator and Appearance do; Network Browser, Dock, Date &
   Time, Energy Saver and AppleTalk do not and are therefore already
   fully visible to a plain window-port hook. **Rig note**: the scene
   walk stops returning foreign windows with addresses over a long
   session, so run a fresh VM per phase.

4. **Ring pressure and drain cadence.** A composite-heavy application
   overran the 64 KiB ring inside one settle. Either the drain keeps up,
   the arm is short, or the ring grows — undecided, and it bites the
   moment composition runs continuously rather than in a probe.

5. **The re-entrancy guard's justification is wrong.**
   `ext/src/now_content.c` says it exists because "StdText blits each
   glyph through StdBits". Measured here with no guard installed:
   `text=1, bits=0` on both a window and an offscreen port, and the
   documentation lane says text goes through a separate character
   generator that never reads `grafProcs`. The guard may still be
   protecting something — but the stated reason is not it, and a comment
   that explains a mechanism incorrectly is worse than none. Re-argue or
   remove.

6. **`CopyBits` only consults `bitsProc` when the destination is the
   current port** (prior art, Apple's released 1984 source, corroborated
   by Executor). Our blits satisfy it. Anything that later blits to a
   non-current port would be invisible, and nothing checks that today.

7. **Port-table pressure.** `kNowContentMaxPorts` is 16 and a
   compositing application may hold several worlds; `skipped_ports`
   counts the overflow honestly but the number has never been pushed.

8. **None of this has touched metal.** Every measurement is mac99 under
   QEMU. The PowerBook has seen none of it.

9. **Stranded on `main`, and not this plan's to land**: the host's args
   are typed `[String: String]`, so every numeric argument crosses as a
   string and the guest reads 0 — **every act replies `dispatched` while
   pressing part 0 at (0,0)**. Also the `key` verb's envelope-shadowing
   bug. Both are fixed on `claude/ext-commit-gate`, 368 commits ahead.
   The shared checkout is parked on `claude/mirror-subproject` rather
   than main. All three want a decision that is the human's.
