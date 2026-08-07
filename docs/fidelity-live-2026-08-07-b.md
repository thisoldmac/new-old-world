# Live-frame flicker, B side — 2026-08-07

The second measurement `tools/fidelity-live.py` has ever produced.

The instrument was built for one purpose — to see flicker that a settled
capture structurally cannot — and until this page it had run **once**.
Sweep B did not run it and said so; sweep C could not, because
`mirror_read --intention snapshot` closed the connection without
replying. That transport defect is fixed
(`AgentIntegrationLocalServer.finish` encoded with `try?` and returned on
failure while its `defer` closed the socket, so **any** response over
64 KB hung up with no error frame), and this is the A/B the whole of
plan 018 is bracketed by, finally taken twice.

Compare row for row against
[the A side](fidelity-live-2026-08-07-a.md).

## WHICH RIG — read before quoting a number

| | |
|---|---|
| **Tree** | `claude/019-flicker-bc`, forked from `claude/019-integration-7` at `1a35e96f`. The only source change is the instrument's own two new assertions (below). |
| **Guest build** | `d9a78b62a414 2026-08-07T20:10:31Z`, asserted by the tool's new `--expect-build auto` against the host's `session_health` **before every one of the traces**, and recorded in each report's `rig` block. |
| **Base image** | `~/Lab/Assets/os91-qemu/now-mirror-stage.qcow2`, sha256 `c466baa9a5455c343908e12197d68e57ffc7f07c140276a90c97a5ae2a137d70` — the shared oracle, whose newest receipt is a **deferral**, so its baked resident predates the round-6 ext merge. That does not reach this run: `scripts/spin-up-ppc` clones it and stages **this checkout's** ext and app, then cold-boots so the INIT loads. |
| **Resident** | the guest's own `mirror` after the cold boot: lifecycle `active`, capabilities `511`, sourceManifest `ad1b8d35302e`, buildFingerprint `1247f064b341` — matching the local build exactly. `actselftest` → `abi-agreed`. |
| **Guest machine** | QEMU `mac99`, Mac OS 9.1. Lane block **384** (`tools/lane-ports`): anchor **15072**, wire **15073**, run dir `/private/tmp/nowvm-f384`, qmp `/private/tmp/nowvm-f384/qmp.sock`. |
| **Host app** | `scripts/build-host-app` into `/private/tmp/f384-host`, launched `--open-mirror` with **both** `NOW_PREFS_SUFFIX=f384` and `NOW_AGENT_SOCKET_SUFFIX=f384`, listening on 15073. |
| **Artifacts** | `/private/tmp/f384-live/` — `*-frames.jsonl` traces, `*-flicker.json` reports, guest screendumps, `LIMITS.md`. |

Emulator-verified at best. Nothing here touched metal.

**Also running on this Mac during these traces**, named because a shared
machine is part of a measurement's rig: `claude/019-sweep-d`'s own VM and
another session's, on their own lane blocks. Neither this lane's wire
(15073) nor its agent socket (`…now-agent-501-f384`) is reachable from
them, and the `--expect-build` assertion below is what turns that from a
belief into a check.

## Two things the instrument gained before it was pointed at anything

Both are AGENTS.md rules this tool did not implement, and each has a
failure mode that reads as a result.

**1. The artifact assertion.** `fidelity-live.py` reads the live host,
and the live host arms P3 itself — so a run against a host that never
armed reports every window stably empty and **reads as a stability
result**. Zero flicker over a dead plane and zero flicker over a live
render produce the same number. The projection already carries the
distinction and it costs one field:
`AgentIntegrationMirrorSurface.displayTotal` is `null` when the plane was
never traced for that window, `0` when traced and proven to have drawn
nothing, and `> 0` when a drain reached the artifact. `plane_evidence()`
derives all three, the run REFUSES (exit 3) without a drain unless
`--allow-no-drain` says absence is what was meant, and the decision is
written into the report beside the number. Gated by
`tools/mirror-gate-tests/test_flicker_analysis.py`, whose new cases were
**watched failing**: mutating `plane_evidence` to treat untraced as
traced turns six of them red.

**2. Which guest answered.** `--expect-build auto` reads `NOW_SRC_HASH`
out of this checkout's own products and checks it against the host's
`session_health` before the first frame. There is one agent socket per
user and this tool deliberately binds nothing, so it reads whichever host
owns that socket — possibly a neighbour's, holding a neighbour's VM. A
count taken off another build is not a weaker measurement, it is a
measurement of something else. Every run below recorded
`"buildCheck": "matched d9a78b62a414"`.

## The B-side numbers

Four traces, one boot, one guest, one build. **`missed` is quoted beside
every count on purpose: a flicker number is a floor, never a total.**

| Run | Provocation | Frames | **Missed** | Flicker | coverage | **rectOwner** | hatch / dropout / presence | Settled? | Drain? |
|---|---|---:|---:|---:|---:|---:|---:|---|---|
| `idle-b` | **none at all**, 90 s | 951 | **5** | 51 | 51 | **0** | 0 / 0 / 0 | no | yes |
| `finder-open-b` | `finderOpen` `Macintosh HD` | 514 | **4** | 25 | 25 | **0** | 0 / 0 / 0 | no | yes |
| `view-list-b` | Finder View ▸ as List | 515 | **4** | 67 | 27 | **40** | 0 / 0 / 0 | no | yes |
| `reselect-b` | `select` ×4 — **every one refused** | 854 | **17** | 45 | 45 | **0** | 0 / 0 / 0 | no | yes |

`reselect-b` is honestly a second idle trace and is labelled as one:
`select` answered `refused — "that window is already front"` on all four
passes, so nothing was provoked. It is kept rather than dropped because
an unprovoked trace is still the purest form of the measurement, and its
17 missed snapshots are the largest in the set.

Every run carried a drain in **every frame**: 2 windows traced, both with
ops, `maxDisplayTotal` 235 in icon view and 845 in list view.

### First: the number the arc was waiting for

**`ink → unknown → ink` is ZERO in all four traces.** The signature the
provenance-ladder work was aimed at does not occur, live, on a tree that
carries the ladder, `displayEpoch` coherent pairs, the content plane's
renewal carry-forward, `contentPlane`/`controlsState`
not-attempted-vs-empty, `Platinum.contentTop` 22→20, and a render path
that no longer depends on `ImageRenderer.cgImage`'s backing store. The
A side's zero is re-earned rather than assumed.

### Second: 40 rect owner flips that are a DIFFERENT defect

`view-list-b` scores 40 where the A side scored 0, and quoting that
number without its breakdown would be exactly the mistake the A side
warned against. None of the 40 is the ink signature. All 20 flipping
rectangles are the Finder's **icon-grid boxes** (32×44), and every event
is `semantic → absent → semantic` or its mirror.

     -8.06s   displayTotal=235   itemTotal=13   roster=ICON boxes (32x44)
     +1.81s   displayTotal=235   itemTotal=23   roster=ICON boxes    <- count switched, geometry did not
     +6.86s   displayTotal=235   itemTotal=23   roster=list rows     <- geometry switched
     +7.48s   displayTotal=235   itemTotal=23   roster=ICON boxes    <- the BOUNCE, 0.83 s, nothing asked for it
     +8.31s   displayTotal=235   itemTotal=23   roster=list rows
     +8.41s   displayTotal=845   itemTotal=23   roster=list rows     <- the CONTENT PLANE finally follows

**Two separate things are visible in that timeline, and only one of them
is a defect.**

The lag is not, or not obviously: `displayTotal` holds at the icon view's
235 ops until **+8.41 s** because the Finder had not yet repainted the
window, and the content plane can only carry what the guest drew. What it
means is that for **8.4 seconds** the window's drawn content was the icon
view's while the item roster already claimed 23 list items — the semantic
layer and the QuickDraw layer disagreeing about which view the window is
in, with the renderer compositing both. On this emulator that is slow
enough to watch.

**The bounce is.** At +7.48 s the roster went list → icon → list with
`itemTotal` and the rect count both unchanged at 23 and 21, and nothing
asked it to. The count holding still is what makes it a **swap** rather
than an addition: the list rows were absent from the same frames the icon
boxes were in. In the render that is roughly a second of Finder items
drawn at the wrong positions — Michelle's complaint #1, "content draws
over, under, or absent across redraws", caught in a trace for the first
time with the window, the rectangles and the instant all named.

**The hypothesis is stated as one.** `Scene.Window.items` is the Finder's
own live `position of` through `FinderItems`; a cached roster re-attached
one cycle late would produce exactly this shape. Nobody has looked yet.

**Regression, or a bounce the A side missed?** Undecided, and the honest
answer is that this trace cannot say: `view-list-a` missed 6 snapshots
and every count in this family is a floor. Deciding it is one command on
a pre-ladder tree.

### Third: the A-side findings that reproduce unchanged

- **Every coverage event is one oscillation, still.** `process-visibility`
  flips `stale ↔ partial` with a median return of **3.396 s** (A side:
  3.28 s) — the same ~0.3 Hz square wave, running with nothing asked of
  the machine, accounting for all 51 events in `idle-b` and all 45 in
  `reselect-b`.
- **The render never settles**, at a five-second threshold, in any of the
  four runs — including the two where nothing was provoked.
- **`baseComplete` was `false` in every frame of every trace.** That is
  now three independent sittings (sweep A, live A, live B) with no
  recovery observed, through a Finder window opening and a view switch,
  with `sceneGeneration` reaching 11.
