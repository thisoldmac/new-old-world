# The broad-spectrum GWorld probe

**One experiment, one question:** when a classic Mac application draws
into an *offscreen* GWorld and then blits the result into its window,
can we see the drawing that BUILT the composite — or only the blit?

Everything about the Mirror's blank window interiors turns on the
answer, so this is an experiment to run before it is an architecture to
design. **It is scoped to measure, not to ship.**

## Why this exists

The Mirror renders meaning, not pixels: the content plane (P3) hooks a
window port's QuickDraw bottlenecks and streams the drawing operations
to the host, which replays them. That works — text, lines, rects, ovals
and regions all replay today.

It fails for the windows a person cares about most, and the failure has
one shape. From the parent corpus finding
`finder-window-icons-are-offscreen-blits` (mac99, 2026-07-17, three
redraw paths tried):

> The OS 9 Finder composites its window icon views in an offscreen
> GWorld and CopyBits the finished composite into the window, so a
> window's icon positions and labels are NOT recoverable from the
> QuickDraw op stream: no per-icon plot op and no item-label text op is
> ever emitted for window contents, only one content-sized blit.

Re-measured on this branch, 2026-08-06: a full repaint of a Macintosh HD
icon-view window emitted **25 ops — 10 line, 7 rect, 8 bits, and ZERO
text**. The interior is entirely blits. The desktop is the opposite and
proves the mechanism is sound where it applies: desktop icons are
plotted straight into the screen port, so each emits its own bits op at
its true position plus a text op carrying the filename, and they mirror
correctly today.

So the icons, their labels and their layout **are** drawn with ordinary
QuickDraw calls — just into a port nobody watches. The composite arrives
as one opaque rectangle and the host draws its "Bitmap unavailable"
hatch, which is what a person sees as a blank or hatched interior.

`docs/mirror-content-plane.md` § "Pixel islands" describes the fallback:
fetch that rect's real pixels and composite them. That remains the
eventual floor and its design is complete. **The standing direction is to
get as far as possible before sending pixels**, and this probe is the
last unexplored question on that road.

## The question, stated so it can come back "no"

**Does hooking an offscreen GWorld's `grafProcs` yield the per-item
drawing — label text ops, icon plot ops, at their positions within the
GWorld?**

Three outcomes, all publishable, and the middle one is the likeliest:

1. **Yes.** Labels arrive as text ops and icons as bits ops inside the
   offscreen port. Then a blit becomes a *join*: the host re-homes the
   source port's accumulated ops into the window at the blit's
   destination offset, and window interiors become semantic — real,
   selectable, classifiable content with no pixels on the wire.
2. **Partially.** Some families come through (say text but not icons,
   because the icons are `PlotIconSuite` blitting from a resource, or
   the labels are drawn once into a cached bitmap and stamped). Then say
   exactly which families, because half a semantic interior plus pixels
   for the rest is still a large win.
3. **No.** The Finder writes the GWorld's pixmap directly, or draws
   through a path the bottlenecks do not see. Then the semantic road for
   in-window icon views is closed, the finding says so permanently, and
   pixel islands are the answer rather than a fallback.

**Any of the three is a successful probe.** Outcome 3 is worth as much
as outcome 1 — it retires a road that would otherwise be re-proposed
every few weeks. What is NOT acceptable is a report that cannot tell 2
from 3 because the instrument could not see.

## Why "broad spectrum"

Do not build this around the Finder. The Finder is the acceptance case,
not the sample: an answer from one application tells us about one
application, and the point is to learn what the *era's* applications do.

Cover a spread, and report per application, because the mix is the
finding:

- **the Finder** — icon view, list view (list views may draw directly);
- **a control panel** — Date & Time and Appearance are already known-bad
  in the Mirror, and are DITL-driven rather than icon-driven;
- **SimpleText** — known to draw text directly to the window; it is the
  **positive control**. If the probe cannot see SimpleText's text, the
  probe is broken, not the application.
- **something double-buffered** — Sherlock 2 or the Apple System
  Profiler, which likely composite for flicker-free redraw;
- **NOW itself** — its own Workshop window, where we know every drawing
  call in the source and can check the probe's output against the code.

A table of *which applications composite offscreen, and what is visible
inside when they do* is the deliverable. It sizes the remaining red far
better than any single application can.

## What exists to build on

Read these before writing code:

- `ext/src/now_content.c` — the P3 writer. It installs a custom
  `CQDProcs` on armed **window** ports (`content_install_port`),
  tail-chains each hook through a saved standard set (`gStd`), and holds
  a re-entrancy guard (`gInCapture`) so only the TOP-LEVEL bottleneck
  entry records — `StdText` blits each glyph through `StdBits`, and
  without the guard a 41-character run would record 41 nested bits ops.
  Port table is 16 entries (`kNowContentMaxPorts`).
- `contract/content_table.h` — the record format. Header carries
  `port` (the CGrafPtr, i.e. which port drew), `ticks`, `a5`, `psn`,
  `display_epoch`, `generation`. `NowContentBitsPayload` carries src and
  dst rects, mode and rowBytes — **and no source identity**, which is
  the field this work will need.
- `now-guest-ppc/src/content/qdtrace_*.c` — the drain/status/arm verbs.
  `qdtrace start` takes an exact window address plus a process, and
  there is deliberately no arm-everything.
- `docs/mirror-content-plane.md` — the plane's design, the bottleneck
  table, and the pixel-island design that this probe is trying to defer.
- `ext/src/now_ext_act.c` — the act plane's per-process trap patches,
  the existing pattern for patching a trap on an armed pass only.

## The two hard parts, named in advance

**Discovery.** A GWorld is not on the window list, so nothing today can
find one. The straightforward route is to patch `NewGWorld` (and
`NewGWorldFromPtr`) in the armed process, hook the port it returns, and
release the hook in `DisposeGWorld`. That is resident work with INIT
discipline — load the `classic-mac-init-platform` skill, and note this
week's paid lesson: **a callback's ABI is not a formality**. The Time
Manager task hung a cold boot because a register-based callback
(`uppTimerProcInfo 0x0000B802`, record in A1) was written as a plain C
function; the fix is an assembly shim (`ext/src/now_liveness_tm.S`,
sibling of `now_ext_gne.S`). Check the ABI of anything you patch before
you write the C.

An alternative worth costing first, because it may need no trap patch at
all: on a blit, the source `PixMap` is reachable from the arguments the
`StdBits` hook already receives. If the source can be resolved to a port
at blit time and hooked *then*, the first composite is missed but every
later one is captured — cheaper and far less invasive than patching
allocation. **Cost both before choosing.**

**Provenance.** Ops recorded from a GWorld are keyed by that GWorld's
port, and today's bits payload does not say which port a blit's pixels
came from. Without that the host cannot join "ops drawn into G" to "blit
from G into window W". A source-port identity field on the bits payload
is an accretive contract addition (`content_table.h` is compiled by both
sides with static asserts pinning layout — a behaviour change starts at
the contract, per AGENTS.md).

Both are only worth doing if the probe answers 1 or 2. **Measure first.**

## How to run it, and the traps that will waste your day

Build and spin your own clone — never borrow another session's:

```bash
scripts/build-guests
NOW_SPIN_BASE=~/Lab/Assets/os91-qemu/now-mirror-stage.qcow2 \
  NOW_SPIN_RUN=/private/tmp/nowvm-gw NOW_WIRE_PORT=5311 scripts/spin-up-ppc
```

- **`now-mirror-stage.qcow2` is the oracle**, freshly baked 2026-08-06
  with the current extension (sha256 `62be7be4…`, `qemu-img check`
  clean, guest-clean shutdown). Do not clone `os91-runner.qcow2`.
- **`NOW_SPIN_RUN` must be a short path.** A worktree path exceeds the
  104-byte UNIX socket cap and QEMU dies with nothing in the output.
- **Pick a free wire port.** 5277, 5301 and 5303 were in use on
  2026-08-06; several VMs run on this Mac at once.
- **Assert which guest answered.** Every guest sees the host as the same
  gateway, so any session's VM can answer your listener. Check the build
  fingerprint and capability word before believing a reply.
- **Stop a VM with `tools/shutdown-guest.py`**, never QMP `quit` (a
  power cut — the next boot spends minutes in Disk First Aid) and never
  by port (`lsof` matches QEMU itself, killing the machine).
- **Launch staged applets from `Macintosh HD:TimBotTu:now-dev`.** A
  launch from the Desktop Folder resets the anchor worker's connection.
- **Arming needs a moment.** The scene claims the planes and the
  resident echoes on its next pass, so the FIRST scene of a fresh
  connection can miss foreign processes. Poll twice.
- **Read the drain correctly.** `qdtrace drain` returns ops under
  `qdtrace.ops`, and the scene's menus live under `menubar.menus`, not
  at top level. Two probes this week reported "nothing there" when the
  data was there under another key — check the emitter in the C before
  concluding absence. (`probe-oracles-were-blind` is the standing
  lesson.)

## What the report must contain

- **The op mix per application**, before and after hooking offscreen
  ports: totals by family (text, bits, line, rect, rgn), and for the
  interesting ones the actual records — a label's text and pen position
  is the money shot.
- **The positive control's result.** If SimpleText's text was not
  visible, everything else in the report is void.
- **Which outcome (1, 2 or 3) each application landed in**, and the
  evidence for that verdict rather than the verdict alone.
- **What it cost**: ring pressure, dropped ops, port-table pressure
  (16 slots, and a compositing app may hold several GWorlds), and
  whether any application misbehaved with hooks installed.
- **Anything that made the machine unhappy**, in full. A resident that
  destabilises an application is a stop condition, not a footnote.

Write the durable half as a corpus finding in the parent's
`data/findings/` — this is exactly the kind of claim that outlives the
repository, and `finder-window-icons-are-offscreen-blits` is its sibling
and possibly its supersession. Update `docs/mirror-knowledge.md`'s row
for "Can the QuickDraw stream tell us where Finder window icons are?",
which currently reads **No — dead end**; this probe either confirms that
permanently or reopens it.

## Scope discipline

This is a **probe**. It is allowed to be ugly, it is allowed to be a
throwaway branch, and it must not ship armed: an experimental resident
that hooks arbitrary offscreen ports is not a thing to leave installed
on any image anyone needs. If the answer is yes, the real implementation
is a separate, designed piece of work with a contract change and its own
tests.

Time-box the discovery mechanism. If patching `NewGWorld` fights back
for more than two or three diagnostic boots, fall back to resolving the
source port at blit time — it answers the same question with less
machinery, and the question is what matters.
