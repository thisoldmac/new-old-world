# Driving a classic Mac's cursor over the network

**This is a measurement rig, not a product.** It drives a guest
Macintosh's pointer from an interrupt, clicks at raw screen points with
no idea what is under them, and patches three Toolbox traps. Clicking a
point nobody resolved is exactly the inference a real act plane refuses
to make; every binary here is named `MEASUREMENT RIG` or `CursorRig` in
the places a person would see it, so that nothing in this tree can be
mistaken for a shipping path. It is deliberately independent of NOW's
architecture — it borrows the lab's VM tooling and nothing else.

## Production reconciliation (2026-08-09)

This research history and its documents were preserved intact, then its measured
mechanisms were folded into NOW rather than merging the spike as a second
extension. Production uses the spike's fixed-size UDP/latest-state shape,
Open Transport notifier boundary, Time Manager writer, Cursor Device Manager
placement, and task-time redraw debt. It replaces the rig's unconditional raw
control with TCP-granted nonce/epoch authority, a shared P7/P9 input owner,
acknowledged button generations, a clamped release lease, and immediate physical
guest-mouse takeover. See `docs/continuity-mode.md`.

The binaries below remain measurement rigs. They are not built, staged, or
shipped by NOW, and they cannot coexist with the NOW Extension. Preserve them as
reproducible evidence; do not install them beside the product resident.

## The question

Continuity mode: drag the pointer off the edge of a modern Mac and have
it start driving an old one. Two parts were unproven. This spike attacks
the first:

> Can the guest's cursor be driven over the network at a usable refresh
> rate and latency — **while the guest is busy doing other things**?

The bar, from Michelle: *"it doesn't have to be natively smooth, but it
does need to be quick enough to be usable and also accurate and
predictable"* — and the hard part *"isn't 'can the guest's cursor land
where it's supposed to', it's competing with coop multitasking, slow
hardware and slow nics."*

## The answer

**Position: solved.** Under every load condition, the pointer's position
is at most **one tick** (1/60 s) behind the packet's arrival, never
out of order, with no loss.

**Picture: solvable, and the spike's founding assumption about it was
wrong.** The drawn arrow does not follow the position writes at all. It
needed a second mechanism, which is now measured working under the
realistic case and honestly broken under one pathological case.

### Position, by load condition

15 seconds at 60 positions/second, seed 7, emulated Power Mac G4 under
Mac OS 9.1. Ticks are `TickCount` — 1/60 s — and are never converted.

| load | staleness p50 / p99 / max | out of order | lost | coalesced |
|---|---|---|---|---|
| idle (comparison, not the headline) | 0 / 1 / 1 | 0 | 0 | 47 |
| spin — a busy loop that yields to nothing | 0 / 1 / 1 | 0 | 0 | 23 |
| tracking — the `DragGrayRgn` shape | 1 / 1 / 1 | 0 | 0 | 10 |
| drawing — QuickDraw churn | 1 / 1 / 1 | 0 | 0 | 78 |
| polite — heavy work that still pumps | 1 / 1 / 1 | 0 | 0 | 16 |

4500 commands, **zero out of order and zero lost in every condition**.
Staleness is `apply − arrival`, both stamped on the guest.

By send rate, under the tracking load:

| positions/s | staleness max | coalesced | out of order |
|---|---|---|---|
| 15 | 1 | 0 | 0 |
| 30 | 1 | 0 | 0 |
| 60 | 1 | 78 | 0 |
| 90 | 1 | 363 | 0 |
| 120 | 1 | 721 | 0 |

Above 60/s the surplus is **coalesced, never replayed** — the writer
takes the newest and discards the rest, which is why the tail does not
degrade. Sending faster than the writer's 60 Hz cadence buys nothing.

### Picture, by load condition

| load | redraws in 15 s | picture lag max | does the arrow move? |
|---|---|---|---|
| idle | 845 (56/s) | 1 tick | yes |
| **spin — calls nothing at all** | **1** | **100 ticks** | **NO — zero pixels** |
| tracking | 889 (59/s) | 1 tick | yes |
| **drawing — QuickDraw only** | **1** | **100 ticks** | **NO** |
| polite | 883 (59/s) | 0 ticks | yes |

"Does the arrow move" is read from **outside** the guest, through QMP,
by diffing framebuffer dumps and reporting the bounding box of what
changed — because the guest's own counters cannot see pixels, and a
count alone is equally consistent with a clock ticking or a caret
blinking. `host/sprite_check.py`.

## What was refuted

The spike began from this, carried over as known-good:

> Position and picture are separate concerns… **write position and let
> the OS draw** — it already glides the pointer while applications are
> wedged.

**The second half is false on Mac OS 9.** Writing `MTemp` / `RawMouse` /
`MouseLocation`, setting `CrsrNew ← CrsrCouple`, *and* calling
`CursorDeviceMoveTo` leaves the drawn arrow exactly where it was. The
machine agrees about where the pointer is — a tracking loop's `GetMouse`
returns the new point, and SimpleText picks an I-beam for it — and the
picture does not move. Only a QuickDraw `HideCursor`/`ShowCursor` pair
moves it.

That matters because QuickDraw needs **task time**, and the writer is an
interrupt-level Time Manager task, which never has it. So the picture is
owed at interrupt time and settled later, somewhere else.

### Where "later" has to be

A `jGNE` filter was the obvious place, and it is not enough: it only runs
when somebody calls `GetNextEvent`, and during a drag nobody does. That
is the `spin` and `drawing` rows above — 1 redraw in 15 seconds.

But a tracking loop is not silent. `DragGrayRgn`, `TrackControl` and
every hand-written drag call **`GetMouse`, `StillDown` and `Button`**,
thousands of times a second, at task time, in the tracking application's
own context. Patching those three gives the picture exactly the moment
it needs. They are chain-only trampolines — every register preserved,
the stack untouched, nothing answered — so a call behaves precisely as
it would with no extension present, and the settle work is skipped
unless a debt is owed. The writer can owe at most one picture per tick,
so a loop calling `GetMouse` ten thousand times a second pays a load, a
test and a jump on all but sixty of them. Measured: **59.3 redraws a
second under a drag**, lag p50 0 and max 1 tick.

**What is still broken, precisely:** an application that reaches *no*
event loop and calls *none* of those three traps freezes the picture
completely while its position keeps tracking. `spin` and `drawing` are
that case, constructed deliberately. A real application that is merely
slow is not — anything that drags, tracks a control, or pumps events is
covered. This is a named, bounded limitation, not a surprise waiting to
happen.

## What transfers to metal, and what does not

The guest speaks **UDP over Open Transport** on its real NIC, with an
async endpoint and a notifier. That is the same code path on a PowerBook
1400c as under QEMU — no emulator-specific transport anywhere in this
tree. But the two halves of every number transfer differently, which is
exactly why arrival and apply are recorded separately:

- **Scheduling (apply − arrival) should transfer.** It is a property of
  cooperative multitasking and the Time Manager, not of the wire. The
  1400c is slower, so the constant will move; the *shape* — one tick,
  monotonic, unaffected by load — is a property of the mechanism.
- **The wire will not.** QEMU's NIC is essentially free: 0.5 ms median
  round trip, 0 lost of 200. An Orinoco card on the 1400c measures
  200–300 KB/s. Bandwidth is not the worry — 60 positions/s is 24 bytes
  each, about 4 KB/s once UDP, IP and the radio's headers are counted,
  roughly **two per cent of that link**. What will cost is the **packet
  rate**: sixty interrupts a second and sixty trips through the Open
  Transport stack on a 117 MHz machine. That is why `sweep` exists — run
  the same rungs on metal and compare.

Nothing here has run on physical hardware. Every number on this page is
**emulator-measured**, which in this project's vocabulary is "tested",
not "metal-verified".

## Running it

```bash
scripts/check          # host-side logic, then every mutation it claims to catch
scripts/build          # the four guest binaries
scripts/spin-up        # stage onto a fresh guest, cold-boot, prove the build
```

Then:

```bash
host/rigdrive.py battery --seconds 15 --seed 7 --outdir runs
host/rigdrive.py sweep --load tracking --rates 15 30 60 90 120
host/sprite_check.py --qmp <run-dir>/qmp.sock --load tracking
host/rigdrive.py ping --count 200
```

## Operating notes

Two things bite when driving the guest, both learned here:

- **The rig's applications do not handle the quit AppleEvent**, so the
  Shutdown Manager stalls waiting for them and the machine never goes
  down. `scripts/spin-up` is unaffected because it does its cold cycle
  *before* launching them; to shut down a guest that is already running
  the rig, quit them first — `host/rigdrive.py quit` for the intake, and
  a cmd-Q through the anchor for the starver, which is frontmost.
- **A single dropped socket is not a machine going down.** The
  down-detection here requires four *consecutive* failures. The first
  version believed the first one, announced "went down (0s)", and the
  guest was still sitting on the desktop 25 seconds later with
  everything running — which would have baked a stage image from a LIVE
  volume, precisely the dirty disk this whole path exists to avoid.

## How the rig is built to not lie

Most of the effort here went into this, because the failures that matter
are the ones that produce a plausible number.

- **Arrival and apply are separate timestamps.** "The wire was slow" and
  "we were not scheduled" have identical symptoms and different fixes.
  The picture gets a third.
- **Ticks stay ticks.** `TickCount` is a low-memory read, cheap enough
  for an interrupt-level task, where `Microseconds()` is a trap. Nothing
  converts to milliseconds; that would invent precision the clock never
  had. The known limitation, stated rather than fixed: measuring a
  ~1-tick process with a 1-tick clock aliases, so the 0/1 split in the
  good case is not the fine shape of the distribution. It resolves the
  tail, which is what this spike is about.
- **The ring counts what it drops.** A ring that overflows silently
  reports a *clean* tail precisely because it discarded the interesting
  part. Preallocated, fixed size, never grown — allocation moves memory,
  and memory moving under the writer is the jitter being measured.
- **The tail is pulled after the run.** Measuring latency over the wire
  while the measurement uses the wire is a trap this lab has already
  paid for. During a run the only traffic is the thing under test.
- **The load generator is first-class.** "While the guest is busy" is
  the condition under which the defect exists at all; a cursor rig that
  only runs against an idle Finder measures the one condition in which
  it cannot appear. Idle is a comparison row, never the headline.
- **A load must be PROVEN to have been running.** The starver only
  notices a request when its event loop next runs, so a load can start
  late — and a check whose placements fell outside the window is an idle
  measurement wearing a load's name. This caught a real false positive:
  `spin` appeared to move the arrow until the window was checked.
- **The guest proves which build it is.** Every binary carries a hash of
  its own sources; the host demands it back and refuses to measure a
  build it did not stage. A stale extension is otherwise invisible — the
  file is in the folder, Gestalt answers, the magic is right.
- **The seed is recorded.** Random motion defeats path-dependence; an
  unseeded failure cannot be replayed.
- **Every guard has been watched failing.** `scripts/check` reintroduces
  each of the eight defects the tests claim to catch and requires red.

Two of those rules earned their place during this spike rather than
before it: the redraw counter first reported `redraws 0` under three of
five loads — which reads as "the picture never updates under load", a
devastating result, and was false, because it looked only at the newest
ring entry and under load a fresh unapplied sample always sat there. And
the load-window proof caught the `spin` false positive above.

## Layout

| path | what |
|---|---|
| `contract/cursor_rig.h` | the one contract: wire, samples, table. Compiled by the INIT, the app and the host `cc`. |
| `contract/cursor_rig_logic.c` | coalescing and ring accounting — no Toolbox, so the host runs it |
| `init/` | **CursorRig**, the 68K INIT: Time Manager writer, jGNE filter, tracking-trap patches, Cursor Device Manager glue |
| `app/` | **CursorRig Intake**, PowerPC Carbon: UDP over Open Transport, async notifier |
| `starver/` | **CursorRig Starver**, the load generator |
| `restarter/` | a 68K application that calls the Shutdown Manager, so the cold cycle is clean |
| `host/` | the driver, the analysis, the stager, the sprite oracle |
| `tests/`, `scripts/check` | the guards, and the mutations they are watched against |

## What this spike did not answer

- **Part two of continuity mode is untouched**: can the guest recognise
  "the host is driving → the cursor reached the screen edge → hand
  back"? Not attempted here.
- **Nothing has run on metal.** The packet-rate sweep is the first thing
  to run on the 1400c; the picture mechanism is the second.
- **Dragging across the boundary** — carrying an item — needs the
  minimal object support the brief defers, and clicking at a raw point
  is deliberately below the line a product would hold.
- **Two residents.** CursorRig declares itself exclusive and refuses to
  install beside another (publishing its table with `refused` set, so
  the host is told *why* rather than finding a rig that is silently not
  there). Folding this into NOW means merging with that extension, not
  running beside it.
