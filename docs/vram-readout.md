# VRAM readout: measured costs and the capture-stage design they set

Measured 2026-07-19 on the PB1400c (Sonnet G3, OS 9.1, 800×600 16-bit,
framebuffer `0x60000000`, rowBytes 1600, 937 KB visible) with the guest's
`vprobe` console command — raw framebuffer reads through `GetPixBaseAddr`
on the screen's PixMap, probe loops built `-O2`, attended run. The
canonical finding row is `pb1400-vram-read-bandwidth` in the TimBotTu
corpus; this doc is the working summary for capture/stream design.

## Numbers

| Method | Full screen | MB/s | ns per bus transaction |
|---|---|---|---|
| Raw 8-bit | 416.8 ms | 2.1 | ~434 |
| Raw 16-bit | 208.3 ms | 4.3 | ~434 |
| Raw 32-bit | 104.1 ms | 8.7 | ~434 |
| Raw 32-bit unrolled ×8 | 104.1 ms | 8.7 | ~434 |
| Raw 64-bit FPU (`lfd`) | 89.7 ms | 10.1 | ~747 |
| CopyBits (native depth) | 119.4 ms | 7.6 | — |

- **The bus charges per transaction, not per byte.** Bandwidth doubles
  with each access-width doubling and unrolling changes nothing: the
  wall is the bus, never the loop.
- **`lfd` is the fastest read and the floor: ~90 ms full-screen**, but
  only 1.16× over 32-bit — the 603e's 32-bit external bus still runs
  two beats per 64-bit load (~747 ns vs ~434).
- **CopyBits was already within ~15% of the 32-bit floor.** There was
  never much on the table for whole-frame reads.
- **The framebuffer is uncached** (reread identical), so no warm-read
  strategy exists.
- **Partial reads are exactly linear**: 60 rows cost 10.3 ms measured
  vs 10.4 ms predicted. ~17 µs per row at 16-bit with `lfd`.
- **Raw reads are pixel-faithful**: 600/600 rows matched CopyBits with
  the cursor hidden. The raw path is safe to build a capture stage on.

## What this settles

Full-frame capture is transaction-bound at ~90 ms no matter how clever
the reader; streaming stays ~7–10 fps if every frame reads every pixel.
**The lever is reading fewer bytes, and linear partial cost makes that
pay exactly proportionally.** Capture cost should scale with screen
*activity*, not screen *size*.

One trap the probe exposed: raw reads only beat CopyBits at the
screen's **native** depth. CopyBits converts depth for free during the
blit; a raw capture feeding a non-native stream depth pays a RAM-side
conversion that eats the margin.

## The capture-stage design these numbers set

For delta streaming (the two halves meet here):

1. **Read raw at native depth** with `lfd`, into the same buffer the
   diff already keeps for the previous frame — reading and diffing
   become one pass over the bytes.
2. **Read predictively**: last frame's dirty rows plus a margin, plus a
   rotating sweep slice (1/Nth of the screen per frame) so a change in
   an unwatched region is caught within N frames. Typing-level activity
   becomes a ~1–2 ms read instead of 90 ms.
3. **Convert only dirty rows** to the stream depth, then encode and
   send only those — every stage now scales with activity.
4. Keyframes (stream start, palette change, manual refresh) do a full
   `lfd` read; one-shot screenshots keep CopyBits, which is fine at
   whole-frame scale and converts for free.

QuickDraw trap-patch dirty rects would perfect the dirty set, but
predictive reads plus the delta diff capture most of that value with no
resident hook — park it unless the sweep's worst case proves annoying.

`vprobe` stays in the command table: it is the regression check for any
future capture-stage change, and the first thing to run on new hardware
(the transaction cost and bus width are per-machine facts).
