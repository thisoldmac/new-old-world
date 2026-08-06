# The QuickDraw content plane, as Mirror left it

**Date:** 2026-07-31 · **Status:** recorded knowledge, carried from the
parked upstream project `timbottu/mirror`. Nothing on this page was
measured by NOW.

> **NOW has since measured this, and the central open question came back
> YES (2026-08-06).** This page records what *upstream* knew on
> 2026-07-31 and is still the best account of the bottleneck mechanism,
> the op vocabulary and the island design — but read two of its
> conclusions as overtaken:
>
> - Where it treats an offscreen composite as unreplayable and **pixel
>   islands as the answer** for window interiors, that is no longer the
>   floor. Hooking an offscreen GWorld's `grafProcs` yields the per-item
>   drawing, and a `blitsrc` record joins those ops back into the window
>   at the blit's destination. Worlds that live and die inside a single
>   event pass — which the sighting route cannot reach — are hooked at
>   creation by a `_QDExtensions` trap patch. Islands remain a genuine
>   fallback rather than the plan.
> - The op vocabulary has grown by three records and a status object
>   since; [contract-coverage.md](contract-coverage.md) expands them.
>
> The evidence is [gworld-probe-brief.md](gworld-probe-brief.md) and
> [toolbox-and-gworld.md](toolbox-and-gworld.md); the composition rule
> is [render-composition.md](render-composition.md). All emulator, no
> metal.

Source documents, now superseded by this one:
`mirror/docs/QUICKDRAW-CONTENT-PLANE.md` (the design brief),
`QDPEEK-SPEC.md` (the build contract), `TIMBUKTU-QD-FINDINGS.md` and
`TIMBUKTU-TEARDOWN.md` (the prior-art teardown).

## Read this first

**The content plane is not an open question.** Upstream designed it,
built it to M3, and passed an emulator safety gate on it. A NOW thread
that starts with *"can we read what an app draws?"* is re-deriving
answered work — that has already happened once, and this page exists to
stop it happening again.

The one question a from-scratch spike went and re-asked, and the answer
it already had:

> **Can PowerPC QuickDraw call a 68K bottleneck procedure?**
> **Yes, and it needs no `RoutineDescriptor`** — `NewQDxxxUPP` alone
> works. Measured upstream at QDPeek M0 on the mac99 emulator; the
> `RoutineDescriptor` risk row is marked RETIRED in `QDPEEK-SPEC.md`.

That is the opposite direction from what the spike braced for.

## How the provenance works on this page

Upstream's measurements are **evidence about a mechanism**, not NOW
measurements. A number here means "the mechanism behaved this way on
upstream's machine"; it does not become a NOW result by being written
down here, and it does not transfer to a machine it was never taken on.

**Every number on this page was taken on a session-private QEMU `mac99`
clone of `os91-runner.qcow2` running Mac OS 9.1**, unless the row says
otherwise. No PowerBook 1400c and no other metal appears anywhere in
upstream's QuickDraw work — `QDPEEK-SPEC.md` states metal promotion was
still blocked when the project parked.

## The mechanism

QuickDraw funnels every drawing routine through its port's **bottleneck
procedures** (`grafProcs` — `QDProcs` on a B&W `GrafPort`, `CQDProcs`
on a `CGrafPort`; `NULL` means the ROM standard procs). `OpenPicture`
records a PICT by swapping exactly those. Recording a port's operations
is therefore a system-sanctioned pattern with a shipped serialisation,
not a hack. (Inside Macintosh: Imaging with QuickDraw, ch. 3.)

Upstream installs a custom procs record **per port, on window ports
only**; each entry captures its op and tail-calls the saved previous
proc, so nothing stops drawing.

| Bottleneck | Fires for | Records |
|---|---|---|
| `textProc` (`StdText`) | `DrawString` / `DrawText`, TE redraws | byte run + pen + port `txFont`/`txSize`/`txFace`/`txMode` |
| `lineProc` | `Line` / `LineTo` | from/to points, pen size + pattern |
| `rectProc` `rRectProc` `ovalProc` `arcProc` | Frame/Paint/Erase/Invert/Fill × shape | `GrafVerb` + rect (+ arc angles, rrect radii) |
| `polyProc` `rgnProc` | poly / region ops | verb + bounding box (not the point list, v1) |
| `bitsProc` (`StdBits`) | `CopyBits` — every offscreen-compositing app | src/dst rects, transfer mode, src depth/rowBytes — **never the pixels** |
| `commentProc` | picComments | kind only |
| `txMeasProc`, `getPic`/`putPicProc` | measurement / PICT plumbing | skipped |

**Where the hook is installed.** Upstream reuses the AXPeek pattern: a
`GNEFilter` INIT runs briefly *inside each application's context* at
event-loop time, which is the safe moment to install, repair or remove
`grafProcs` on that app's window ports. Same context, no cross-heap
surgery, self-healing when an app rebuilds a port, and reversible by
restoring `NULL` without a reboot.

**A window's port pointer is its `WindowRecord`**, so every captured op
keys to the same window reference the semantic tree uses. One IR, two
planes.

### The re-entrancy guard — the mechanism's one non-obvious rule

A bottleneck's tail-call into the standard proc **calls other
bottlenecks**: `StdText` blits each glyph through `StdBits`, shape
frames call the line and rect procs. Capturing those secondary calls
fabricates phantom content.

The fix is a per-context "in capture" flag: set on entry, record only
when it was already clear (a top-level op), tail-chain, clear on exit.
Timbuktu's patent describes doing the same thing in 1990.

Upstream measured the guard airtight at M0: typing 40 characters
produced **text = 41, bits = 0** on mac99.

**This is not the same as the ring busy-flag**, and upstream warns
against conflating them. The re-entrancy guard *passes nested calls
through* — nested ops are intentional noise, not lost data. The busy
flag *drops* a record it cannot commit and bumps a `dropped` counter.
One is correctness; the other is honesty about loss.

## What was built, and how far it got

| Milestone | Ships | Upstream state |
|---|---|---|
| M0 | INIT (chaining, command block, install/uninstall/repair, counters), `qdtrace status/start/stop`, count mode | **DONE** — mac99: boots clean, install/uninstall 5/5, Mixed Mode works with `NewQDxxxUPP` alone, re-entrancy guard airtight, 100× start/stop stable |
| M1 | record mode: ring + TEXT records + `fetch` | not reached |
| M2 | primitives + STATE deltas; host replay via bitmap strikes | not reached |
| M3 | BITS ops + lazy `capture_region` composition; MoveBits scroll fast-path | **host half DONE** — mac99, 2026-07-17 |
| M4 | calibration consumer + metal-safety review artifact | **emulator gate PASSED** mac99, 2026-07-19; metal still blocked |

M4's pass is worth reading precisely: the review **rejected** the
then-current lifecycle implementation, hardened it, and then passed the
campaign plus a rollback (remove the INIT from Extensions). It is a
gate that failed something before it passed.

## The shared-memory contract

Upstream's `qdshared.h`, reproduced because the shape is the durable
part — a NOW port would restate it, not copy it.

| Constant | Value | Meaning |
|---|---|---|
| `QD_MAGIC` | `0x54427164` (`'TBqd'`) | also the Gestalt selector |
| `QD_VERSION` | `1` | |
| `QD_RING_CAP` | `65536` | compile-time; reported in `status` |
| `QD_TEXT_MAX` | `64` | inline text bytes per record |

Ring records are 2-byte aligned and never wrapped mid-record (op `255
WRAP` pads to the ring end). Common header, 12 bytes:

| Offset | Field | Notes |
|---|---|---|
| 0 | `size` u16 | whole record including header + pad |
| 2 | `op` u8 | family |
| 3 | `flags` u8 | bit0 `truncatedText`, bit1 `stateStale` |
| 4 | `port` u32 | `CGrafPtr` — the window identity key |
| 8 | `ticks` u32 | `TickCount` at capture |

Op families: `1 TEXT`, `2 LINE`, `3 RECT`, `4 RRECT`, `5 OVAL`,
`6 ARC`, `7 POLY`, `8 RGN`, `9 BITS`, `10 STATE`, `255 WRAP`.

**Coherence.** Classic Mac OS is cooperative, so one app draws at a
time and there is a single writer at any moment; the busy flag guards
the rare interrupt-time drawer. A seqlock makes reader snapshots
tear-free — sample `seq`, copy `[cursor, writeCursor)` in at most two
segments, re-sample, retry on change. On overrun the fetch replies
`resync: true` with a drop estimate and restarts from `writeCursor`.

Two design decisions that carried their reasons:

- **CGrafPort only in v1.** OS 9.1 windows are colour ports
  (`portVersion & 0xC000 == 0xC000`). A B&W `GrafPort` window is skipped
  *and counted* (`skippedPorts`) — honesty over coverage.
- **Sibling INIT, the observer untouched.** The QuickDraw hook is the
  riskiest resident code upstream shipped, and it was deliberately given
  its own extension, its own Gestalt selector and its own shared block so
  it could not share a failure domain with the load-bearing semantic
  plane.

## The finding that decided how folder windows render

**The Finder composites its window icon views in an offscreen GWorld
and blits the finished composite into the window.** A 12-icon window
emits *zero* per-icon operations and *zero* labels — one content-sized
blit with `src == dst`. Confirmed three ways on mac99: an update, a
reflowing resize, and a fresh window open, all blits.

The desktop is the opposite. Desktop icons are plotted straight to the
screen port: a 32×32 `bits` op at the true `dst`, plus a label `text`
op at its pen. **That asymmetry is why desktop icons were readable
semantically and window icons never were.**

Consequence upstream recorded as a hard rule: an app that composites
offscreen cannot be replayed from the op stream at all, so the op
stream's job for that app is to say *when* and *where* it repainted,
and pixels fill the rest.

## Pixel islands — the braid, not the defeat

When a window's content cannot be replayed semantically, upstream
fetches **exactly that rect's pixels** and composites them into the
otherwise-semantic window. The chrome stays semantic; only the interior
is bytes. When an island is set, it *is* the content — the renderer
skips op replay and control drawing, because the island already shows
the real ones.

| Property | Upstream's design |
|---|---|
| Trigger | a content-sized blit in the op stream means the guest repainted |
| Cache key | includes the rect, so a move or resize re-fetches |
| Scroll | a **MoveBits** blit (same size, displaced, src inside the content) moves the pixels already held and re-fetches only the exposed band |
| Stale geometry | attached anyway — unscaled, anchored at the content origin, clipped by the renderer |
| Never captured | a window that has never been focused since launch has no interior to hold |

The stale-geometry rule carried its reasoning, and it is the kind of
decision worth not re-litigating: a resize changes how much is visible,
not the pixels the guest drew. Clipping is truthful on shrink and merely
incomplete on grow, whereas **scaling invents pixels** (1-bit Platinum
resamples to mush) and dropping regresses to blank.

**Why interiors are held rather than polled:** under cooperative
multitasking an application's pixels only change while it is drawing,
which means while it is frontmost. So capture on launch, on raise, and
while focused — then hold. Only the front window re-captures; background
windows attach pixels already held.

### Measured island cost (mac99, upstream)

| Measurement | Value |
|---|---|
| Full-window island, 426×358, depth 16 | ~947 ms |
| Full-window fetch, quoted generally | ~1 s |
| Fetch-on-change rate, live `--window` loop | 1 fetch per 4 polls (4.5 s vs 3.8 s baseline) |
| Semantic planes alone, per poll | ~2 ms |
| A 613×538 front-window capture inside the poll | ~150 ms per poll |
| A 402×220 capture plus 2 polls | 0.23 s total |
| 6 polls, front window unchanged | 0.6 s — one capture, five reuses |

Capture cost scales with area. Upstream noted that its own poller's
"~1 s per full-window capture" comment was pessimistic for this bench.

**MoveBits is real, not theoretical.** A live page-down emitted
`src[4,4,418,147] → dst[4,-29,418,114]` — same size, up 33 px — among
two GWorld composites and three 16×16 arrows, and the detector picked
it while rejecting the decoys.

## Prior art: Timbuktu

Upstream verified Timbuktu's mechanism from the inventors' own patents
— **US 5,241,625** (screen-image sharing) and **US 6,038,575**
(per-glyph sharing) — not from a decompile. Shipped 1990, it was
**QuickDraw Capture → 1-byte-opcode op stream → QuickDraw Playback**:
the same data-first thesis, 36 years earlier.

| Timbuktu | Upstream's version |
|---|---|
| Global trap patch on the bottleneck procs — whole screen, all apps | per-port `grafProcs` on chosen windows — bounded blast radius, reversible per window, no system-wide patch |
| 1-byte opcode + operands (a live PICT) | fixed-width ring records, 2-byte aligned |
| GrafPort state as deltas from a synchronised numbered cache | the `STATE` op, emitted lazily when the port's shadow state differs |
| Screen→screen blits move a rect, not pixels ("MoveBits") | same, as the M3 scroll fast-path |
| Non-QuickDraw framebuffer writes: a full shadow-buffer diff ("screen stash") | **not built** — named as the honest floor, see below |
| Missing font → draw locally, ship the bitmap | not needed: the guest's own bitmap strikes were extracted |

**The blind spot upstream named rather than hid.** An app that writes
the framebuffer directly — a game, a custom blitter that never touches
a port — emits no bottleneck ops, and a scoped per-port hook misses it
*by design*. Timbuktu's answer was the screen stash. Upstream did not
build one, but named it as the floor so that "an app that never calls
QuickDraw" has a documented answer instead of a silent gap. Detection
today is a counter-versus-full-capture cross-check: drawing with no ops.

## Refinements upstream flagged but did not build

All four are hypotheses with a stated trigger, not pending work:

1. **MoveBits fast-path** — built at M3 (above).
2. **Unknown-font TEXT → a pixel island, never a substitute glyph.**
   If a text op's font id has no bundled strike, request pixels for the
   run's bounding rect rather than rendering the wrong strike. Near-zero
   for upstream's font pack, but the escape hatch must be pixels, not
   guesswork.
3. **The screen stash** — the named floor, deliberately unbuilt.
4. **A numbered-port cache** — records key by the full `CGrafPtr`, which
   is identity-stable and correct. If measurements ever show port-state
   re-emission dominating the ring, Timbuktu's numbered cache is the
   compression move. *Measure first;* noted so it is not reinvented.

## What is genuinely open

- **Metal.** Nothing in this plane has run on real hardware. The M4
  review passed on mac99 and explicitly left metal blocked.
- **A fixture for the content plane.** Upstream froze the display-op
  layer in its scene contract on the strength of design and live use, not
  captured evidence, and recorded the gap rather than closing it.
- **List and column Finder views.** Neither the op stream nor the item
  model addresses them; nothing detects the view type.
- **`picComments`** — whether they carry anything worth keeping.
- **TextEdit redraw granularity** — whole-line runs versus per-character
  — which decides how the host reassembles text.
