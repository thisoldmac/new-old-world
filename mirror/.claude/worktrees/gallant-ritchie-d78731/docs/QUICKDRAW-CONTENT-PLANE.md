# QuickDraw content plane — research (data-first)

`corpus_impact`: none because this is a research brief: mechanisms are cited
to Inside Macintosh, docs/46 §5.10/Rung F, and the AXPeek implementation;
the volume/perf numbers are explicitly hypotheses with an M0 measurement plan.
Findings come from the probe phases, not this document.

**Goal.** The mirror's one remaining blind plane is **window content** —
document bodies, list/table rows, canvases, custom CDEFs. Everything else
(windows, controls, menus, dialog text, desktop icons) is semantic today.
This brief designs the content plane as a **QuickDraw operation stream,
captured as data** — the Timbuktu move, done data-first: the ops are the
product, replay is just one consumer.

The IR anticipated this seam from day one — `scene.py`: *"Every source
adapter (mock, axtree poller, and eventually a QuickDraw op stream) produces
the same scene."*

## Prior art

- **Timbuktu (Farallon, 1988) — mechanism now VERIFIED from its patents**
  ([US5241625](https://patents.google.com/patent/US5241625A/en),
  [US6038575](https://patents.google.com/patent/US6038575A/en); full teardown in
  [TIMBUKTU-TEARDOWN.md](TIMBUKTU-TEARDOWN.md)). It was **QuickDraw Capture
  (QDC) → op stream → QuickDraw Playback (QDP)** — precisely this brief's thesis,
  shipped in 1990. QDC intercepted the **same bottleneck procedures** (StdText/
  StdLine/StdBits/StdRect/…) — but via a **global trap patch** (whole screen),
  where we scope to **per-port grafProcs** (chosen windows). It sent 1-byte
  opcode + operand messages (a live PICT), grafPort state as cache deltas, moved
  rects instead of pixels for screen→screen blits, diffed a full shadow
  framebuffer ("screen stash") for non-QuickDraw writes, and **fell back to
  pixels when a font was missing** — the exact gap our extracted NFNT strikes
  close. Their one implementation subtlety we'd have hit: a **re-entrancy guard**
  (bottlenecks nest — StdText calls StdBits), folded into the hook contract
  below. Our AXPeek INIT is the verified producer precedent on this OS stack.
- **QuickDraw itself records ops.** Every QD drawing routine funnels through
  its port's **bottleneck procedures** (`QDProcs`/`CQDProcs`; a NULL
  `grafProcs` means the ROM standard procs). `OpenPicture` records a PICT by
  swapping those same bottlenecks — *recording a port's ops is a
  system-sanctioned pattern with a shipped serialization (PICT opcodes)*, not
  a hack. (Inside Macintosh: Imaging with QuickDraw, ch. 3 "Customizing
  QuickDraw Operations".)
- **Repo: docs/46 Rung F** designed QD tracing as a *calibration* tool
  (discover a custom app's private schema, emulator-side). This brief
  elevates it to a **standing plane**: a live, bounded op stream feeding the
  mirror, with Rung F's calibration lane as a consumer.
- **AXPeek (docs/41)** supplies the architecture wholesale: boot INIT,
  in-context hook, fixed `NewPtrSys` system-heap block, **seqlock**
  coherence, Gestalt-published address, 10 Hz throttle discipline, honest
  staleness. QDPeek is AXPeek's sibling (or its v5).

## The hook (mechanism, IM-grounded)

**Per-port `grafProcs`, window ports only.** Install a custom
`QDProcs`/`CQDProcs` record on the ports we care about; each entry captures
its op then **tail-calls the standard proc** (nothing draws otherwise).

| Bottleneck | Fires for | Record |
|---|---|---|
| `textProc` (StdText) | DrawString/DrawText/TE redraws | **the jackpot**: byte run + pen + port's txFont/txSize/txFace/txMode |
| `lineProc` | Line/LineTo | from/to points, pen size/pattern |
| `rectProc` `rRectProc` `ovalProc` `arcProc` | Frame/Paint/Erase/Invert/Fill × shape | GrafVerb + rect (+arc angles, rrect radii) |
| `polyProc` `rgnProc` | poly/region ops | verb + bounding box (not the point list, v1) |
| `bitsProc` (StdBits) | **CopyBits** — every offscreen-composited app | src/dst rects + transfer mode + src depth/rowBytes; **never the pixels** (see below) |
| `commentProc` | picComments | kind only |
| `txMeasProc`, `getPic/putPicProc` | measurement / PICT plumbing | skip |

Plus **port-state deltas** sampled at capture time (clip bbox, origin, fg/bg,
pen pattern) — cheap to read off the GrafPort the proc is handed.

**Install point: AXPeek's in-context moment.** The GNEFilter already runs
briefly *inside each app's context* at event-loop time (not mid-draw, not
interrupt time) and already walks that app's WindowList at 10 Hz. That is
exactly the safe moment to install/repair/remove `grafProcs` on that app's
window ports — same-context, no cross-heap surgery, self-healing when an app
rebuilds a port, reversible (restore NULL) without a reboot. A window's port
pointer **is** its WindowRecord, which AXPeek already fingerprints — so every
op tags with the **same `ax2` window ref the axtree uses**. One IR, planes
compose.

**ISA/discipline.** Bottlenecks run at draw frequency in the drawing app's
context. Hook code lives resident (INIT, like AXPeek), 68K with
RoutineDescriptors for PPC callers (Mixed Mode — the GNEFilter ABI shim
proved this path). Same rules as the GNE fast path and docs/28: no
allocation, no moving memory, bounded fixed work, then tail-chain.

**Re-entrancy guard (Timbuktu's lesson).** A bottleneck's tail-call into the
standard proc *calls other bottlenecks* — `StdText` blits each glyph through
`StdBits`, shape frames call line/rect procs. Capturing those secondary ops
would fabricate phantom content. Every hook carries a **per-context "in
capture" flag**: set on entry, record only when it was clear (top-level
op), tail-chain, clear on exit. (US5241625: capture *"is not interested in
these secondary … calls … without doing any additional processing."*)

## The data (data-first IR)

**`QDShared`** — a fixed system-heap ring (AXShared pattern: magic,
version, seqlock, Gestalt `'TBqd'`), fixed-width op records, small inline
payloads (text bytes ≤ 64/op, MacRoman), per-window drop counters when the
ring overruns — honest truncation, never silent.

**Wire:** toolkit-worker verbs `qdtrace start|stop|status|fetch`, fetch
drains since a sequence cursor (ETag-style). Scoping is per window ref —
bounded by construction, "trace this window" not "tape the screen".

**IR:** `windows[].display = [op…]` — a versioned display list beside
`controls`/`text`. The scene IR is pre-freeze by design (MIRRORKIT-PLAN
decision 5); this is exactly the churn window to add it in.

**CopyBits / offscreen apps — the honest braid.** Double-buffered apps
(GWorld → one CopyBits) yield semantic ops only for the blit. The answer is
composition, not defeat: the bits-op carries the dst rect, and the existing
`capture_region` verb fetches exactly that rect's pixels **lazily, on
demand**. Text/primitives stay semantic; blits become bounded pixel islands
with known geometry. (Rung G's per-region fallback, but *driven by the op
stream* instead of guesswork.)

## Better than Timbuktu

1. **The data survives.** Timbuktu replayed and discarded; we keep a
   queryable display list — *searchable window text* (document bodies and
   list rows: the exact Rung-D/blind-spot gap), diffable frames, agent-legible.
2. **Scoped and bounded.** Per-window rings with drop counters, not
   whole-screen mirroring.
3. **Pixel-faithful replay without pixels.** Text ops carry font/size/face —
   and we now hold the guest's own NFNT strikes (platinum-pack, IoU 1.0).
   Replaying `textProc` ops through `BitmapFont` reproduces the guest's
   rendering exactly, at any scale, vector-crisp primitives around it.
4. **An oracle Timbuktu never had.** The emulator: validate the stream
   against `capture_full` diffs (the font-validation IoU method), and
   cross-check with QEMU/TCG-side tracing (docs/46 §5.10's lane) — ground
   truth for both completeness and correctness.
5. **Fail-closed honesty** end to end: overrun counts, absent-vs-empty
   display lists, staleness ticks — the house style.
6. **One ref scheme.** Ops keyed to `ax2` window refs; the semantic tree,
   icons, and content plane land in the same scene.

## Volume & perf (hypotheses → M0 measures them)

Unknowns that decide ring sizes and cadence, stated as hypotheses:
a text-heavy window redraw is O(10²) ops; SimpleText typing is a few ops per
keystroke; a GWorld app is ~1 CopyBits per frame. **M0 answers these with a
counting-only probe** — per-op-type counters in the shared block, no
payloads, near-zero risk — run against SimpleText, Finder list windows, and
GraphCalc on the live emu guest before any ring is designed.

## Safety & tiering

Installing `grafProcs` mutates live port records and runs resident code at
draw time. **Emulator-first is mandatory** (session clones, the standard
blast radius); metal is tier-gated and attended after emu soak — `cis`/
`serial_tx` history applies. The hook *code* ships resident (INIT); the
*installs* are dynamic and reversible per window (unlike AXPeek's
boot-only sampling, a wedge can be undone by uninstalling, without reboot).
Default harness builds compile the verbs out unless this lands as toolkit
surface — same artifact discipline as the rest of the below-line family.

## Phases

| Phase | Delivers | Acceptance |
|---|---|---|
| **M0** | counting-only probe (INIT + counters + `qdtrace status`) | op-rate table for 3 real apps on emu; no guest instability over a battery run |
| **M1** | text ops end-to-end (ring + fetch + IR `display`) | typed text in SimpleText readable over the wire; matches what was typed |
| **M2** | primitives + state deltas; mirror replays via BitmapFont/Canvas | replay-vs-`capture_full` IoU on a SimpleText doc ≥ threshold |
| **M3** | bits-ops + lazy `capture_region` composition | a GWorld app's window renders (semantic + pixel islands) |
| **M4** | Rung-F calibration consumer; metal gate review | docs/46 lane fed by the same stream; metal-safety review artifact |

## Open questions

- `QDProcs` vs `CQDProcs` per port type (B&W GrafPort vs CGrafPort — both
  exist on OS 9; the CQDProcs record has more entries incl. `StdPix`).
- PPC-native Color QD internals: confirm all public drawing paths honor
  `grafProcs` on 9.1 (IM says yes; verify on the emu with M0 counters).
- TextEdit redraw granularity (whole-line StdText runs vs per-char) —
  affects text-reassembly on the host.
- Ring sizing + fetch cadence vs the 0.5 s mirror poll (M0 data decides).
- Whether `picComments` carry anything worth keeping (table rules etc.).
- Metal perf ceiling (Q950/PB1400c) — bottleneck overhead per op must stay
  invisible; M0's counter probe measures the hook floor before payloads.

## Relationship to existing docs

- docs/46 §5.10 + Rung F — the calibration lane this generalizes; Rung G —
  the pixel fallback this bounds and directs.
- docs/41 / `axpeek/src/axshared.h` — the producer architecture to clone.
- docs/26 — the capture/OCR plane the braid composes with.
- MIRRORKIT-PLAN decision 5 — IR pre-freeze churn window for `display`.
- `platinum-pack` fonts — the replay fidelity story.
