# What Timbuktu actually did — from the patents

`corpus_impact`: none because this is a namesake/reference teardown; its
durable output is the four design lessons folded into
[QUICKDRAW-CONTENT-PLANE.md](QUICKDRAW-CONTENT-PLANE.md). No new claim about
*our* guest/hardware.

We're named for Timbuktu, so we should know what it did under the hood. It
turns out we don't need to decompile it — Farallon/Netopia **patented the whole
mechanism**, in the inventors' own detail. Two patents are the primary source:

- **[US 5,241,625](https://patents.google.com/patent/US5241625A/en)** — "Screen
  image sharing among heterogeneous computers" (the QDC/QDP architecture).
- **[US 6,038,575](https://patents.google.com/patent/US6038575A/en)** — "Method
  of sharing glyphs between computers…" (the per-glyph cache).

Cross-checked against *Inside Macintosh: Imaging with QuickDraw* (the bottleneck
procedures) and the develop "CopyBits" article. This is the primary-source
answer; a binary decompile would only confirm it (and no Ghidra is installed —
we have Retro68 `objdump` for 68k/PPC if we ever want to verify a glossed
detail, but the patents are complete enough that it isn't worth it).

## The architecture, verified

```
  source Mac                                     guest (Mac or, translated, PC)
  ┌────────────────────────────┐                 ┌────────────────────────────┐
  │ app → QuickDraw bottlenecks │  message stream │ QDP replays the same ops   │
  │   ▲ QDC intercepts via the  │ ───(network)──▶ │   onto the guest port      │
  │   │ TRAP DISPATCHER         │  1-byte opcode  │   (or GDI, translated)      │
  │   └ StdText/StdLine/StdBits │  + operands     │                            │
  └────────────────────────────┘                 └────────────────────────────┘
```

**QDC = QuickDraw Capture, QDP = QuickDraw Playback.** Exactly the
op-stream-as-data thesis we arrived at independently. The mechanism, point by
point (all quotes from US5241625):

1. **Interception = global trap patch.** *"For each trap to be intercepted, QDC
   gets the address of the original routine from the Macintosh trap dispatcher
   and substitutes the address of its own routine."* Targets are the
   **bottleneck procedures**: *"StdText, StdLine, StdBits, StdRect, StdRRect,
   StdOval, StdArc, StdPoly, and StdRgn."* Each replacement logs the call, then
   delegates to the original. (Global traps, not per-port grafProcs — see the
   deltas below.)

2. **Message format.** *"a one-byte message type in the range of 0 to 127 …
   accompanied by one or more bytes of data."* An opcode stream — essentially a
   live PICT. State first (if the port changed), then the drawing command.

3. **GrafPort state as deltas, from a synchronized numbered cache.** Both ends
   keep numbered grafPort caches; on a port change QDC compares *"port
   rectangle, bitmap bounds, visible region, clipping region, pen location, pen
   pattern and pen mode"* and *"for each item that differs, a message is
   generated."* Only deltas cross the wire.

4. **Bitmaps: move rects, not pixels, when state is synchronized.** Screen→screen
   blits become a *"MoveBits message [with] the source and destination
   rectangles … QDP simply performs the same bit operation"* — no pixels,
   because the guest screen is assumed identical. Only when QDP can't know the
   destination state does QDC *"[perform] the drawing operation and send the
   resulting bit image."*

5. **Non-QuickDraw screen changes: the "screen stash."** For framebuffer writes
   that bypass QuickDraw (games, custom blitters), QDC keeps *"a separate bit or
   pixel image which is the same size, shape and depth as the screen's frame
   buffer … continuously compares the contents of the copy with … the frame
   buffer."* A full shadow-buffer diff, polled (`CheckScreen`), optional.

6. **Fonts: map, or fall back to pixels.** Mac font numbers differ per machine;
   QDP calls a host-supplied font-mapping function. **When a font is missing on
   the destination, Timbuktu draws locally and ships the resulting *bitmap*
   instead of the text.** US6038575 refines this into a per-glyph cache:
   `SENT_ARRAY(FONT_ID, GLYPH_ID)` is one bit per glyph; an unseen glyph is
   rendered to a bitmap and sent once, then *"appended onto a cached font bitmap
   … within the destination"* — render-once, never resend.

7. **Re-entrancy guard.** The capture proc must ignore *secondary* calls: when a
   bottleneck runs the original, that original calls *other* bottlenecks. *"GDI
   Capture checks to determine if GDI Capture is being reentered … not interested
   in these secondary GDI calls … completes the function call … without doing any
   additional processing."* Top-level ops only.

## Us vs. Timbuktu — where we diverge, and why

| Dimension | Timbuktu (1990) | MirrorKit (2026) |
|---|---|---|
| Interception | **global trap patch** (whole screen, all apps) | **scoped per-port `grafProcs`** on window ports we choose |
| Output | replay-and-discard over the network | **data-first**: a queryable, diffable display list |
| Font mismatch | fall back to pixels / render-once glyph cache | **never falls back** — we extracted the real NFNT strikes (platinum-pack, IoU 1.0) |
| Non-QD writes | full shadow-buffer diff (the "stash") | bits-op geometry → **lazy `capture_region`** islands |
| Ground truth | none | **the emulator** (`capture_full` IoU + TCG trace) |
| Ref identity | numbered grafPort cache | the `ax2` window ref shared with the axtree |

The interception choice is the deep one. Timbuktu **had** to patch globally — it
mirrored the entire screen for any app plus the Finder plus non-QuickDraw
writes. We want *scoped window content*, so per-port `grafProcs` is the tighter,
safer fit (bounded blast radius, reversible per window, no system-wide trap).
The trade-off is real and worth stating: our scoped hook **misses apps that
write the framebuffer directly** (bypassing their port) — exactly the case
Timbuktu's screen-stash exists to catch. That's our documented escape hatch, not
a surprise.

## The four lessons we're taking

1. **Re-entrancy guard — the one we'd have hit.** Our `textProc` tail-calls
   `StdText`, which calls `StdBits` to blit each glyph; without a guard we'd
   capture those nested ops as phantom content. **QDPeek needs a per-context
   "in capture" flag; record only top-level bottleneck entries.** (Added to the
   hook contract in QUICKDRAW-CONTENT-PLANE.md.)

2. **Port-state deltas + a numbered cache.** Validates our "sample port state at
   capture" plan; the numbered-cache delta scheme is a ready compression if our
   rings get chatty (send a port id + only changed fields, not the full
   GrafPort each op).

3. **Scroll = move a rect, not pixels.** Screen→screen `CopyBits` (scrolling, a
   dragged region) can be recorded as a rect-move op; a diff/replay consumer
   moves the pixels it already holds instead of re-fetching. Free bandwidth for
   the common scroll case.

4. **The screen-stash is the honest floor.** For truly-bypasses-QuickDraw UI,
   the full shadow-buffer diff is the complete-but-heavy fallback beneath our
   bits-op braid. We won't build it for M0–M3, but it's the named answer to
   "what about an app that never calls QuickDraw."

And the two places we're **already ahead**, both because of the asset work:
Timbuktu fell back to pixels whenever a font was missing and built a glyph cache
to soften it — we shipped with the guest's own strikes, so semantic text replay
is immediate and total. And Timbuktu had no oracle; we validate the op stream
against the emulator's framebuffer.

## Verdict on the decompile

The patents answer "what was it doing under the hood" completely and from the
source. A teardown of the actual extension (the QD hook lives in Timbuktu's
system extension, not the app; 68k `CODE` / PPC `PEF` in the resource fork,
`objdump` via Retro68) would at most confirm the patent or reveal a shipped
tweak the patent glosses (exact trap set, stash cadence). Low value now —
parked, not pursued.
