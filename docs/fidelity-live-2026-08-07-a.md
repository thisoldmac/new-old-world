<!-- now-doc-provenance: generated reviewed=false -->

# Live-frame flicker, A side — 2026-08-07

The measurement [sweep A](fidelity-sweep-2026-08-07-a.md) said it could
not make. Sweep A scored STABILITY **3** — zero differing pixels — on
eight panels, and named its own blind spot in the same paragraph:

> this instrument renders a *settled capture*, twice. It never draws two
> consecutive live frames, so it cannot see the flicker Michelle saw.

That mattered more than a caveat: run as specified, **sweep B would have
reported "stable" whether or not slice 1 fixed anything**, which hollows
out the A/B the whole of [plan 018](plans/2026-08-06-018-feat-stable-honest-render-plan.md)
is bracketed by. This page is the A side of a measurement that can tell
the difference, taken on the unmodified tree, so slice 6 has something to
compare against.

## WHICH RIG — read before quoting a number

| | |
|---|---|
| **Tree** | `claude/018-lane-e`, forked from `claude/gworld-interior-host-render-98ddd5` at `91a5e754`. No renderer source was changed; the only new code is the instrument itself. |
| **Guest build** | `59dce8562ad4 2026-08-07T02:10:42Z`, reported by the guest's own `hello` and re-asserted through the host's `session_health` before every run. |
| **Guest machine** | QEMU `mac99`, Mac OS 9.1, staged by `scripts/spin-up-ppc` from this checkout. Run dir `/private/tmp/nowvm-lanee`, anchor **1750**, wire **5300**, qmp `/private/tmp/nowvm-lanee/qmp.sock`. |
| **Host app** | `scripts/build-host-app` into `/private/tmp/lane-e-host`, launched `NOW_PREFS_SUFFIX=lanee` with `listenPort 5300`. It was the **only** `MacOS/Host` process on the Mac, so the single-per-user agent socket was unambiguously this run's (`ps` and `lsof` both checked). |
| **Resident** | `lifecycle active`, resident 1.0, `capabilities 127`, `sourceManifest 18d732487b03…`, `buildFingerprint 0a91ea49abcd…`. |
| **Instrument** | `tools/fidelity-live.py`, gated by `tools/mirror-gate-tests/test_flicker_analysis.py`. |
| **Artifacts** | `/private/tmp/lane-e-live/` — four `*-frames.jsonl` traces (2,099 frames), four `*-flicker.json` reports, guest screendumps, `LIMITS.md`. |

Emulator-verified at best. Nothing here touched metal.

## What is being measured, and what a "flicker" is

The instrument does not photograph the window. It follows the **scene
documents the renderer draws from**, one by one, over the agent socket.

That is the sharper measurement rather than a compromise, and the reason
is a property of the renderer: `SceneRenderer.draw(in:size:)` is a pure
function of one immutable `Scene` plus four bits of mirror-local UI
state, and the live view and `RenderShot` share it — one draw path, one
set of pixels. So the sequence of documents fully determines the sequence
of frames. It also means a flicker can be *attributed*: which window,
which rectangle, which owner it flipped between.

**A flicker is a return, not a change.** `A → B → A`. A window that gains
content and keeps it is the machine doing what it was asked; a window
whose content goes and comes back is the defect. Five families are
counted separately: coverage-status flips, whole-window hatch flips,
window content dropouts, rectangle owner flips (`ink → unknown → ink`,
the signature the arc exists to fix), window presence flips.

The limits are in `LIMITS.md` beside every run and inside every JSON
report. The two that bind hardest: this reads documents rather than
pixels, so a one-pixel rect flipping counts the same as a whole window
interior (the report lists rects so a reader can judge); and frames are
read by following `snapshotID`, so every run states how many snapshots
existed and were never read — **a flicker number is a floor** when that
is non-zero.

## The A-side numbers

Four traces, one boot, one guest, one build.

| Run | Provocation | Frames | Span | Missed | **Flicker events** | Rate | Settled? |
|---|---|---:|---:|---:|---:|---:|---|
| `idle-a` | **none at all** | 682 | 71.8 s | 4 | **39** | 0.54/s | **no** |
| `finder-open-a` | open `Macintosh HD` from the desktop | 517 | 54.8 s | 3 | **34** | 0.62/s | **no** |
| `view-list-a` | Finder View ▸ as List | 449 | 47.8 s | 6 | **24** | 0.50/s | **no** |
| `reselect-a` | select that window, ×4 | 451 | 46.2 s | 1 | **25** | 0.54/s | **no** |

### Three findings, in order of what they cost

**1. The render never settles — including when nothing is asked of it.**
Not one of the four runs reached a quiet state, at a five-second
threshold, in up to 72 seconds. The idle run is the sharp one: with **no
provocation whatsoever**, the scene document changed 42 times and cycled
through 4 distinct states. `msToSettle` is reported `null` rather than
the run length in all four, because "settled at 47 s" and "never settled
in 47 s" are opposite results.

**2. Every one of the 122 events is the same oscillation.** All four runs
break down identically: `coverageStatusFlips` = the total,
`windowHatchFlips` = `windowContentDropouts` = `rectOwnerFlips` =
`windowPresenceFlips` = **0**. The oscillating claim is
`process-visibility`, flipping `stale ↔ partial` with a median return
time of **3.28 s** — a ~0.3 Hz square wave that runs indefinitely,
undisturbed by whether anything was provoked. The near-constant rate
across four very different runs (0.50–0.62/s) is the signature of a clock
rather than of work.

**3. `baseComplete` was `false` in all 2,099 frames.** Sweep A saw this
in ten minutes of snapshots and could not say whether it ever recovered.
It does not, across four independent traces, through a Finder window
opening and a view switch, with `sceneGeneration` reaching 5 and
`contentGeneration` 6.

### And the finding that is an absence

**No window-level flicker was observed on this tree.** Zero hatch flips,
zero content dropouts, zero rectangle owner flips, across a Finder window
opening and a view switch. The `Macintosh HD` window's content moved
`(5 display ops, 13 items, 13 owner rects)` → `(7, 23, 21)` at the view
switch and **stayed** — a one-way change, which the instrument is
explicitly built not to count and which its gate proves it does not.

This does not refute Michelle's complaint #1. It bounds it. Whatever she
saw was either (a) below this instrument's sampling — 1 to 6 snapshots
per run existed and were never read, so **every number here is a floor**;
(b) inside the drawing of a rectangle whose *document* did not change,
which is a renderer-side effect this cannot see at all; or (c) the
`process-visibility` oscillation reaching pixels by a path not yet traced.
(c) is the cheapest to test and slice 1 is the lane that can test it.

## What slice 6's sweep B should run

1. **`tools/fidelity-live.py --idle` first, before any provocation.** It
   is the purest form of the measurement and it is one command. If the B
   side still reports "never settled" with nothing asked of it, slice 1
   did not close the thing it was aimed at, whatever the still frames say.
2. **The same three provocations, same VM shape**: `finderOpen` on
   `Macintosh HD`, Finder View ▸ as List (`--menu 259 --item 3`), and a
   repeated `select`. Compare the table above row for row.
3. **Quote the breakdown, never the total.** The A side's total is one
   oscillation counted many times. A B side whose total falls because the
   `process-visibility` clock slowed, while a window content dropout
   appeared, would be a regression reported as an improvement.
4. **Report `missed` beside every number.** A run with more misses can
   report fewer events for no reason connected to the render.
5. **Run `fidelity-sweep.py` with hygiene on** (it is now the default).
   Sweep A voided Date & Time's whole row to a leftover modal; that
   cannot silently happen again, and a target that cannot be cleaned is
   now named on its own row and on the next one.

## Two rig facts worth keeping

- **Opening the Mirror does not need accessibility scripting.** Sweep A
  drove macOS accessibility to press the "Open Mirror" button and
  recorded it as a hard floor for a headless agent. It is only half a
  floor: the app already takes **`--open-mirror`** on argv
  (`MirrorLaunchOptions.swift`), and every run on this page used it. What
  remains genuinely missing is opening the Mirror in a host that is
  *already running* — there is no agent verb, no menu item and no
  preference, and `mirror_read` answers `now-mirror-snapshot-unavailable`
  until a human clicks. A run that launches its own host does not need
  that; an agent handed a running one does. Adding the verb is a
  17-place edit across the protocol, registry, docs and six tests, so it
  is written down here rather than done in passing.
- **The three views CAN be one instant now.** Sweep A's were three phases
  on one boot because the sweep tool and the host app both bind the wire
  port. `fidelity-live.py` binds nothing — it reads the agent socket
  while the host holds the wire, and QMP is a third independent channel —
  so with `--qmp` the agent surface, the host render and the guest's own
  pixels are simultaneous, and each screendump's frame index is recorded.
  What still cannot join is `fidelity-sweep.py`'s qdtrace capture, which
  needs the wire the host is holding. That limitation is now written into
  every artifact rather than into a report a reader may not have.
