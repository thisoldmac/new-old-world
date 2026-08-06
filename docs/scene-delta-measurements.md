# What scene deltas cost, measured

**Date:** 2026-08-06 · **Class:** emulator, reproduced; **not metal-verified**

Every number below is from one machine, named beside it, taken with
`tools/scene-delta-bench.py`, which asserts the guest's build fingerprint
before believing anything it is told (AGENTS.md: every QEMU guest on this
Mac sees the host as 10.0.2.2, so any session's VM can answer a listener).

```
guest build   df570d8014de 2026-08-06T08:00:09Z
machine       mac99, session-private clone of
              ~/Lab/Assets/os91-qemu/now-mirror-stage.qcow2.bak-20260806
ports         anchor 5440, wire 5441
samples       10 per condition, `before` run first so the `after` run
              cannot be credited with a quieter moment
```

The design is [scene-deltas.md](scene-deltas.md).

## The two conditions that bracket the answer

### 1 · The machine sitting still (Finder front, nothing being driven)

Three separate runs, one after another:

| run | whole documents | with deltas | of before |
|---|---:|---:|---:|
| A | 254,938 B over 10 scenes | 26,182 B | **10.3%** |
| B | 255,437 B | 26,468 B | **10.4%** |
| C (with `reveal` between polls) | 267,290 B | 27,786 B | **10.4%** |

In every run the shape is the same: **one whole document, then nine
`scene.same` answers costing zero bulk bytes each.** The 10% is entirely
the first scene; the marginal cost of a poll on an unchanged machine is
one control frame.

Round trip fell too, though not proportionally — see below.

### 2 · The machine being driven hard (front application alternating)

`--drive "Finder,New Old World"`, so the frontmost application changes
between every poll:

| | whole documents | with deltas |
|---|---:|---:|
| median bytes per scene | 26,186 B | 24,895 B |
| forms | 10 whole | 1 whole, 9 delta |
| walk median | 16 ms | 16 ms |

**A delta saves about 5% here, and that is the honest worst case.**
Changing which application is frontmost rewrites `front` on every `apps`
row and every `processes` row, rewrites `front` and `z` on every window,
and replaces the entire menu bar — because classic Mac OS draws one menu
bar and it is the front application's. Nearly every entity in the
document genuinely changed, so nearly every entity is genuinely carried.

The guest still chose the delta each time, correctly: it was smaller. A
delta that was not smaller would not have been sent.

## Walk time did not move

The thing that would make this a bad trade is a delta that halves bytes
and doubles the walk. It does not:

| condition | walk median, before | walk median, after |
|---|---:|---:|
| idle | 0 ms | 0 ms |
| driven | 16 ms | 16 ms |

The guest encodes the document either way — the span table is offsets
taken off a counter the encoder already keeps — and the added work is one
FNV-1a pass over the body regions plus a `strcmp` and an integer compare
per entity. It does not register against a walk this size.

## Round trip, and why the emulator UNDERSTATES this

| condition | trip median, before | trip median, after |
|---|---:|---:|
| idle, run A | 115 ms | 115 ms (min 11 ms) |
| idle, run B | 8 ms | 4 ms |
| idle, run C | 8 ms | 6 ms |
| driven | 26 ms | 27 ms |

Round trip did **not** fall in proportion to the bytes, and the reason
matters: on this emulator the wire is host loopback and the transfer is
dominated by the guest's cooperative event-loop latency, not by the
document's size. Run A's 115 ms median with a *zero-byte* answer is the
proof — no bytes crossed at all and the round trip was unchanged.

**This is the opposite of the usual emulator caveat, and it should be
said plainly.** Plan 013 warns that a fix tuned to emulator timings may
miss on metal because the emulator's disk is host-backed. Here the
emulator's advantage runs the other way: its *network* is loopback, so
the byte term this change removes is nearly free on it and expensive on a
PowerBook 1400c over real Ethernet, and worse again on a 180c. The idle
saving measured at 90% of bytes here should be worth **more** on the
hardware this product exists for, not less.

That is a prediction, not a measurement. It is marked as one in
[open-issues.md](open-issues.md) and it is what a metal pass would settle.

## An observation this run produced that is not about deltas

In run C the bench revealed two Finder folders alternately, expecting the
window order to change between polls. It did not: nine of ten answers
were `scene.same`, meaning the walked scene was byte-identical each time.
Either the Finder did not reorder its windows, or the walk does not see
that it did. **`scene.same` turns out to be a rather good change
detector**, and it just detected something worth a second look — recorded
in [open-issues.md](open-issues.md) rather than chased here.

## Reproducing

```sh
NOW_LAB_ROOT=/path/to/timbottu \
NOW_SPIN_BASE=$HOME/Lab/Assets/os91-qemu/now-mirror-stage.qcow2.bak-20260806 \
NOW_SPIN_RUN=/private/tmp/nowvm-delta \
NOW_ANCHOR_PORT=5440 NOW_WIRE_PORT=5441 \
  scripts/spin-up-ppc

tools/scene-delta-bench.py --port 5441 --build <fingerprint> \
  --samples 10 --front Finder
tools/scene-delta-bench.py --port 5441 --build <fingerprint> \
  --samples 10 --drive "Finder,New Old World"

tools/shutdown-guest.py /private/tmp/nowvm-delta/qmp.sock --port 5440
```
