# VRAM readout on the PowerBook 180c

Measured 2026-07-25 on the PB180c (33 MHz 68030 + 68882, System 7.1,
640×480 8-bit internal, framebuffer `0xFC080000`, rowBytes 640, 300 KB
visible) with `NOW-68K 0.16`'s `vprobe`, probe loops built `-O2`, run over
the wire with the screen still. Companion to
[vram-readout.md](vram-readout.md), which is the same probe on the
PB1400c — read them together, because the interesting part is where they
disagree.

Whole-frame on every row (the probe reports a `%` when it scales a pass
down to fit its budget; nothing scaled here), so these are directly
comparable to the 1400c's whole-frame figures.

## Numbers

| Method | Full screen | MB/s |
|---|---|---|
| Raw 8-bit | 484.4 ms | 0.6 |
| Raw 16-bit | 200.4 ms | 1.4 |
| Raw 32-bit | 179.3 ms | 1.6 |
| Raw 32-bit unrolled ×8 | 169.1 ms | 1.7 |
| **`movem.l` ×8 (best)** | **159.0 ms** | **1.8** |
| `fmove.d` (68882) | 201.7 ms | 1.4 |
| CopyBits (banded, native depth) | 244.9 ms | 1.1 |

Timer: `Microseconds()` resolved to 37 µs with 0 of 2000 samples
repeating, so every row above is thousands of ticks wide and the clock is
not the limit.

Reread: 179.3 ms first, 179.3 ms best — **identical**. Uncached.
Partial: 48 rows measured 24.1 ms against 17.9 ms predicted from the
full-frame rate. Fidelity: 480/480 rows matched CopyBits — **and that row
means less than it reads as; see below.**

## The fidelity row was measured in 32-bit addressing, and does not generalise

**Every number above is a rate, and a rate is the same whether or not the
address was a screen.** On 2026-07-28 the same probe on the same machine
reported `Fidelity 480/480 differ, 1st 0`, and `shotdiag` in the same
session reported `Addressing 24-bit`, `Base 0xFC080000`, `StripAddress
0x00080000`. The machine's PRAM battery is dead, so the Memory control
panel's 32-bit setting had reverted between the two sessions; in 24-bit
mode the top byte of that base is ignored and the walk was reading main
RAM. The human then switched 32-bit addressing back on and captures came
across correct immediately, which is the confirmation.

So:

- **The fidelity row above is a fact about a 32-bit session, not about
  raw reads.** Read as "raw reads are pixel-faithful *when the CPU can
  reach the framebuffer*". 24-bit addressing is the DEFAULT state of these
  machines, not an anomaly.
- **The bandwidth rows are unaffected.** Reading the wrong memory costs
  the same as reading the right memory, which is exactly why this went
  unnoticed for so long — and is the reason a number from this probe is
  only quotable beside its Addressing row (added 2026-07-28).
- **CopyBits was never affected** at all: QuickDraw resolves addressing
  itself, which is why the guest's own on-disk PICT was always correct
  while the wire capture was noise.

NOW-68K now switches to 32-bit addressing around the VRAM copy alone
(`core/screen68.c`), so the mode the machine boots in no longer changes
what a capture contains. Tested, not re-measured on metal.

## What this settles

**The width ceiling is ~16 bits, and that is the headline.** 8→16-bit
more than doubles the rate (2.42×), but 16→32-bit buys only 12% — and
12% is loop overhead, not data path. A bus that charged per transaction
would have doubled again. This one does not, which is the signature of a
framebuffer path about 16 bits wide: past that, reading wider gets you
nothing because the memory cannot deliver it faster.

**`MOVEM.L` does not burst, and the reread row says why.** Bulk reads beat
unrolled `move.l` by 6% — instruction-fetch savings, not burst cycles.
The 68030 *can* convert `MOVEM.L` into burst memory cycles, but burst
fills are cache-line fills, and this VRAM is uncached (identical reread).
Nothing to burst into. The two rows were written to be read together and
they agree.

**The FPU is a loss here**, which is the sharpest reversal from the
1400c, where `lfd` was the floor. `fmove.d` lands *slower* than plain
32-bit (201.7 vs 179.3): the 68882 is a coprocessor with per-operation
communication overhead, and it converts to extended precision on the way
in. A 64-bit read is not a 64-bit read when a coprocessor is doing it.

**CopyBits is not competitive**, unlike on the 1400c where it sat within
15% of the raw floor. Best raw beats it 1.54× (159 vs 245 ms), so a raw
capture stage has a real margin here. **Caveat:** this row is fifteen
banded `CopyBits` calls, not the 1400c's single full-frame blit, so an
unknown part of that gap is per-call overhead rather than copy cost. It
is a floor on the margin, not a measurement of it.

**Partial reads are NOT linear.** 48 rows cost 24.1 ms against 17.9 ms
predicted — 35% over. They still pay, just not proportionally: 10% of the
rows for about 15% of the time. On the 1400c partial reads were exactly
linear, and that exactness is what made predictive capture attractive
there. Here the lever still works and is simply worth less per pull.

**Raw reads are pixel-faithful WHEN THE CPU CAN REACH THE FRAMEBUFFER**
(480/480 rows, in a 32-bit-addressing session), so a raw capture stage is
safe to build on — but only one that puts the machine in 32-bit addressing
for the read itself. See the addressing section above; the same sweep
reported 480/480 *differ* three days later on the same machine, with
nothing changed but a Memory control panel setting that had reverted on
its own.

## What it means for a capture stage on this machine

**Full-frame streaming is arithmetic, not tuning.** 300 KB at 1.8 MB/s is
159 ms of *reading alone* — a ~6 fps ceiling before a single byte is
diffed, converted, encoded or sent. The 1400c reached 10.1 MB/s and still
concluded that whole-frame reads cap streaming at 7–10 fps. This machine
starts 5.6× worse.

So the 1400c's conclusion survives — **the lever is reading fewer
bytes** — but every reason behind it is different, and two of its
supporting assumptions do not hold:

1. **Read at 16-bit or wider, and stop caring past 32.** Widening beyond
   16 bits is within measurement noise of free, but it buys nothing
   either. Use `movem.l` because it is the best of them, not because it
   bursts.
2. **Budget partial reads at ~1.35× their linear share**, not at their
   linear share. A predictive reader sized on the 1400c's exact linearity
   would under-budget here by a third.
3. **A raw reader is worth building over CopyBits** — the opposite of the
   1400c finding — subject to the banding caveat above.
4. **No warm-read strategy exists**, same as the 1400c and for the same
   reason: the framebuffer is uncached.

## What this does NOT settle

- **Non-native depths.** The 1400c's trap was that CopyBits converts
  depth for free while a raw path pays a RAM-side conversion, which ate
  the margin. Not measured here. The margin above is native-depth only.
- **The `fmove.d` row is content-dependent.** It converts to extended and
  a 68882 handles denormals slowly, so it is what an FPU reader costs on
  *this screen*, not a bus figure.
- **The CopyBits banding**, as above.
- **Anything about an external monitor, another depth, or a different
  machine.** The 180c drives 8-bit external video too; none of it was
  probed.
- **The streaming stage itself**, which does not exist on this guest.
