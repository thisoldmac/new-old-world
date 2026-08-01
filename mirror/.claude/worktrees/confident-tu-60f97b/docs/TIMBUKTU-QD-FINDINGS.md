# Timbuktu / QuickDraw — consolidated findings

`corpus_impact`: none because this consolidates the namesake research for the
QD-plane thread; the durable design lessons already live in the docs it
cross-walks, and QuickDraw-plane findings land with the QDPeek milestone
closeouts (M0's op-rate table first).

**Purpose.** One digest of everything we learned about how Timbuktu worked and
what it means for our QuickDraw content plane — for the thread building QDPeek
to fold in. Action-oriented: confirmed mechanism → durable QuickDraw reference
→ how each finding maps to the QDPeek build → the refinements the build spec
doesn't yet capture.

## Doc map (where each thing lives)

| Doc | Role |
|---|---|
| **this** | consolidated findings + spec cross-walk + open refinements |
| [TIMBUKTU-TEARDOWN.md](TIMBUKTU-TEARDOWN.md) | the full patent teardown (quotes, per-point mechanism) |
| [QUICKDRAW-CONTENT-PLANE.md](QUICKDRAW-CONTENT-PLANE.md) | the design brief (data-first rationale, hook contract, phases) |
| [QDPEEK-SPEC.md](QDPEEK-SPEC.md) | the build contract (INIT, `QDShared`, `qdtrace`, milestones) |

Primary sources: **[US 5,241,625](https://patents.google.com/patent/US5241625A/en)**
(Timbuktu screen-image-sharing = QDC/QDP), **[US 6,038,575](https://patents.google.com/patent/US6038575A/en)**
(per-glyph sharing), and *Inside Macintosh: Imaging with QuickDraw*
(bottleneck procedures). Not a decompile — the inventors' own descriptions.

## 1. What Timbuktu actually did (confirmed)

**QuickDraw Capture (QDC) → 1-byte-opcode message stream → QuickDraw Playback
(QDP).** Shipped 1990. This is our data-first thesis, 36 years early.

1. **Intercept = global trap patch.** QDC took each QuickDraw **bottleneck
   proc**'s address from the trap dispatcher and substituted its own, which
   logged then delegated. Whole-screen, all apps.
2. **Message = 1-byte opcode (0–127) + operands.** A live PICT.
3. **GrafPort state as deltas** from a **synchronized numbered cache** — on a
   port change, only the fields that differ (portRect, bitmap bounds, visRgn,
   clipRgn, pen loc/pattern/mode) are sent.
4. **Screen→screen blits = move a rect, not pixels** ("MoveBits"): send
   src+dst rects, the far side repeats the bit-move on its identical screen.
   Pixels only when the destination state can't be assumed.
5. **Non-QuickDraw framebuffer writes = the "screen stash"**: a full
   shadow-buffer kept and diffed against the real framebuffer, polled. The
   complete-but-heavy catch-all for apps that bypass QuickDraw.
6. **Fonts: map, else fall back to pixels.** Mac font numbers differ per
   machine; a host-supplied mapping function translated them. **Missing font →
   draw locally, ship the resulting bitmap instead of the text.** US6038575
   refined this to a render-once **per-glyph cache** (`SENT_ARRAY(FONT_ID,
   GLYPH_ID)`, one bit/glyph).
7. **Re-entrancy guard.** The capture proc's delegate calls *other*
   bottlenecks (StdText → StdBits per glyph); capture ignores those secondary
   calls and records **top-level ops only**.

## 2. QuickDraw reference facts (durable, IM-grounded)

The seam is **per-port bottleneck procedures** — `grafProcs` (`QDProcs` on a
B&W `GrafPort`, `CQDProcs` on a `CGrafPort`); NULL means the ROM standard
procs. `OpenPicture` records a PICT by swapping exactly these — recording a
port's ops is a **system-sanctioned pattern with a shipped serialization**.

The bottleneck set and what each op carries (the content plane's vocabulary):

| Bottleneck | Fires for | Carries |
|---|---|---|
| `StdText` | DrawString/DrawText, TE redraws | **the jackpot** — byte run + pen + port txFont/txSize/txFace/txMode |
| `StdLine` | Line/LineTo | from/to, pen size/pattern |
| `StdRect`/`StdRRect`/`StdOval`/`StdArc` | Frame/Paint/Erase/Invert/Fill × shape | GrafVerb + rect (+arc angles, rrect radii) |
| `StdPoly`/`StdRgn` | poly/region ops | verb + bounding box (not the point list, v1) |
| `StdBits` | **CopyBits** — every offscreen-composited app | src/dst rects + mode + depth/rowBytes; **never the pixels** |
| `StdComment` | picComments | kind only |
| `StdTxMeas`, `StdGetPic`/`StdPutPic` | measurement / PICT plumbing | skip |

Port-state read cheaply off the GrafPort at capture time: clip bbox, origin,
fg/bg, pen pattern (the "STATE" deltas).

**OS-9.1 specifics** (verify with M0 counters): windows are **CGrafPorts**
(`portVersion & 0xC000 == 0xC000`); confirm all public PPC Color-QD drawing
paths honor `grafProcs`. A window's port pointer **is** its WindowRecord —
so every op keys to the **same `ax2` window ref the axtree uses**. One IR.

## 3. Findings → QDPeek build (cross-walk)

Where the research backs a spec decision, and its source:

| Finding | Backs / informs (QDPEEK-SPEC) | Source |
|---|---|---|
| Bottleneck-proc interception is the seam | per-port `grafProcs` hooks on window ports | IM; US5241625 |
| **Re-entrancy: record top-level ops only** | the **busy/reentrancy flag** (install rules; QDShared `dropped`) | US5241625 (quoted) |
| GrafPort state as lazy deltas | the **STATE op** (kind 1–6, emitted when shadow differs) | US5241625 |
| Port identity keys the stream | records keyed by `CGrafPtr`, resolved to window identity at fetch | US5241625 (numbered cache) |
| Opcode + operands, PICT-like | fixed-width ring records, 2-byte aligned | US5241625; PICT |
| CopyBits carries geometry, not pixels | **BITS op** = src/dst/mode/depth, no pixels | US5241625; IM |
| Text needs font/size/face to replay | TEXT op carries txFont/txSize/txFace; replay via BitmapFont strikes | US5241625; platinum-pack |
| Draw-time hook must be minimal/bounded | GNE-fast-path discipline; smarts in worker/host | docs/28; AXPeek |
| Emu-first, tier-gated metal | `experimental`+unreviewed; M4 review gate | cis/sertx precedent |

The spec already banks all of these — this is the primary-source **why**
behind the busy flag, the STATE deltas, and BITS-never-pixels, in case a
reviewer asks.

## 4. Refinements the spec doesn't yet capture

Small, flagged for the QD thread's sign-off — mostly M3+ or optional:

1. **Scroll = MoveBits (replay by moving pixels you already hold).** The spec's
   BITS op records geometry and defers all pixel fill to M3 lazy
   `capture_region`. But a **screen→screen** blit (scrolling, a dragged region)
   is Timbuktu's MoveBits case: if both src and dst rects are on-screen, the
   replay side already has those pixels — *move the rect*, don't re-fetch. A
   cheap M3 fast-path for the common scroll, before falling back to
   `capture_region` for genuine new pixels. (Detect: src within the port's
   bounds.)

2. **Unknown-font text → pixel island, not a wrong glyph.** The spec's replay
   maps guest font ids to strikes and "unknown ids fall back + count." Timbuktu
   is instructive on what "fall back" should mean: it drew locally and shipped
   the **bitmap of the affected rect** rather than render wrong text. Our analog:
   an unknown-font TEXT op should carry (or let the host request) a
   `capture_region` of the run's bounding rect — an honest pixel island, same
   as BITS — instead of a mis-rendered strike. Keeps text honest when a strike
   is missing. (M2 refinement; near-zero for our pack, which covers the system
   faces, but the escape hatch should be pixels, not guesswork.)

3. **The screen-stash is the named floor for non-QuickDraw apps.** The spec's
   risk register mitigates "Color QD bypassing grafProcs" by cross-checking
   counters vs `capture_full` diffs — good for *detection*. Timbuktu's
   **screen-stash** (shadow-framebuffer diff) is the *coverage* answer for apps
   that write the framebuffer directly (games, custom blitters that never touch
   a port). We won't build it for M0–M3, but it's worth naming as the honest
   heavy floor beneath the bits-op braid, so "an app that never calls
   QuickDraw" has a documented answer instead of a silent blind spot.

4. **Numbered-port cache = a compression path if rings get chatty.** Records
   key by full `CGrafPtr` (u32) today — correct and identity-stable. Timbuktu's
   numbered cache (small id + only-changed fields) is the compression move if
   M0/M1 show state re-emission dominating the ring. Not needed until measured;
   noted so it's not reinvented.

## 5. Where we're already ahead of Timbuktu

Both banked, both from work already on main:

- **We never fall back to pixels for fonts.** Timbuktu's whole font-mismatch
  apparatus (mapping function, per-glyph cache, bitmap fallback) existed
  because it couldn't ship the font. We **extracted the guest's own NFNT
  strikes** (platinum-pack, sheet-vs-guest IoU 1.0) — semantic text replay is
  immediate and total. Their hardest problem is our solved one.
- **We have an oracle Timbuktu never had.** The emulator: validate the op
  stream against `capture_full` framebuffer diffs (the font-validation IoU
  method) and cross-check with QEMU/TCG-side tracing. Ground truth for both
  completeness (undercounts = drawing with no ops) and correctness.

And the design divergence that stays deliberate: Timbuktu **global-trap-patched**
for whole-screen mirroring; we **scope to per-port grafProcs** on chosen
windows — bounded blast radius, reversible per window, no system-wide trap. The
trade is real (we miss apps that bypass their port — item 3's screen-stash is
that escape hatch), and it's the right call for a *scoped content plane* rather
than a screen-sharing product.
