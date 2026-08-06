# Reverse-engineering the Toolbox and GWorld

**Started 2026-08-06, overnight.** Long-horizon research, emulator and
documentation only. Nothing here touches metal.

## The goal, stated so it can be measured

> By morning we should have what we need to build our own damned Toolbox
> if we have to.

That is not "read Inside Macintosh". It is a **reimplementation-grade
reference**: every structure with byte offsets verified against live
memory rather than quoted from a header, every dispatch path traced from
call site to implementation, and the GWorld lifecycle understood well
enough to predict what an unknown application will do.

The immediate consumer is the GWorld probe
([the brief](../../gworld-probe-brief.md),
[run notes](../gworld-probe-run-notes.md)), which is blocked on exactly
this: after a night of measurement it still cannot say whether the
Finder's composite has an owning CGrafPort, and every explanation left
standing is a fact about the Toolbox nobody here knows.

## Three instruments, and what each is good for

| Instrument | Good for | Cannot |
|---|---|---|
| **Static** — ROM, System file, extracted resources, disassembly | Ground truth about code that never changes; finding the actual implementations behind trap numbers | Say what a running system chose at runtime |
| **Live** — QEMU: `memsave`/`pmemsave`, QMP, gdbstub breakpoints, register reads | Structures as they really are, allocation geography, lifetimes, who calls what and when | Reach code that never runs during observation |
| **Documentation and prior art** — Inside Macintosh, technotes, and the existing reimplementations (Executor, Basilisk II/SheepShaver, MACE, Advanced Mac Substitute) | Decades of other people's reverse engineering, and the names for things | Be trusted as fact about THIS machine — every claim gets confirmed live |

The rule that governs the third column, and it is the project's own:
**a documented claim is evidence, not a measurement.** Every structural
claim in the output carries how it was established.

## Phases

Each phase records findings into `ledger.json` through
`tools/toolbox-re-gate row`. A phase is not done because it feels done;
it is done when it has recorded evidence with provenance.

### P0 — Rig and corpus
Boot a private VM. Establish that (a) `memsave` reads can be taken in a
*known* CPU context — the flaw that invalidated the first oracle attempt
— and (b) the ROM and System file can be read out of the image
statically. Set up the note skeleton.

### P1 — Structures, verified byte by byte
`GrafPort`, `CGrafPort`, `PixMap`, `BitMap`, `GDevice`, `CQDProcs`,
`QDProcs`, `Zone`, block headers, `WindowRecord`. Offsets confirmed
against live memory in a known context, not read off a header. The
deliverable is a table where every row says how it was checked.

### P2 — GWorld: the whole surface, to reimplementation grade
The arc is named for this one. Not just "how does a GWorld work" but
**everything a reimplementation would have to provide**, because the
answer to the probe's question and the answer to "could we build this
ourselves" are the same body of knowledge.

- **Construction.** What `NewGWorld` actually builds — CGrafPort,
  PixMap, GDevice, colour table — and where each piece lands. Whether a
  `GWorldPtr` is exactly a `CGrafPtr` or carries private state beyond
  it. What `NewGWorldFromPtr` does differently.
- **The flags, each measured rather than quoted**: `useTempMem`,
  `keepLocal`, `pixelsPurgeable`, `noNewDevice`, `useDistantHdwrMem`,
  `useLocalHdwrMem`, `pixPurge`, `nativeEndianPixMap` — what each
  changes about placement and layout.
- **The pixel lifecycle**: `LockPixels` / `UnlockPixels` /
  `GetPixBaseAddr` / `AllowPurgePixels` / `NoPurgePixels` /
  `GetPixelsState` / `SetPixelsState`, and what a purged GWorld looks
  like from outside (this is a live way an offscreen port's pixels can
  vanish while the port remains).
- **Mutation and teardown**: `UpdateGWorld` (resize/depth change, and
  whether it reallocates in place), `DisposeGWorld`'s unwind order.
- **Context**: `GetGWorld` / `SetGWorld` / `CTabChanged` /
  `PixMapChanged`, and how the current device interacts with an
  offscreen port.
- **LIFETIME, which is the blocking question.** Does an application's
  offscreen port persist between repaints, or is it created, drawn into
  and destroyed inside one? This settles the transient hypothesis that
  currently explains every null result in the probe arc.

### P3 — Dispatch
The trap table, the CFM/InterfaceLib path, and which QuickDraw entry
points on this machine are native PowerPC versus 68K. Where `StdText`,
`StdBits` and friends live, and the exact route by which a port's
`grafProcs` is consulted — the mechanism the whole content plane rests
on, which the spike proved fires but did not explain.

### P4 — The Finder's composite, settled
With P1–P3 in hand, determine what the OS 9 Finder actually does to
build a window's icon view: GWorld or hand-managed PixMap, persistent or
transient, and whether any port owns those pixels at any moment.

### P5 — Icon identity
`PlotIconSuite` / `PlotIconID` / `PlotCIconHandle`: the path from a
resource ID to pixels, and where an interception could recover the
IDENTITY a bits op cannot carry. This is what makes host-side
composition possible without sending pixels.

### P6 — Synthesis
The reimplementation-grade reference, plus corpus findings for the
durable claims, plus an honest list of what remains unknown.

## Rules for this arc

- **Every claim carries provenance**: `static`, `live`, `doc`, or
  `measured` (measured = observed on this rig, with the run named).
- **A negative needs a positive control**, the lesson this project paid
  for twice tonight: before believing "X is not there", show the
  instrument finding something that IS.
- **Commit at every phase boundary**, and write findings down as they
  land rather than at the end. A session can end without warning.
- **Emulator only.** No deploys, no metal suites, no touching another
  session's VM.
- **The stop gate is not a substitute for judgement.** If the work is
  genuinely blocked, record the blocker and write the handoff — the gate
  will let the turn end once a handoff exists.

## The stop gate

`tools/toolbox-re-gate` runs on the `Stop` hook and refuses to let the
turn end while phases remain unrecorded. It is a no-op for any session
without `docs/local/toolbox-re/ledger.json`, so it costs other work
nothing, and it stands down after repeated blocks with no progress
rather than wedging the session — a gate that can never be satisfied is
worse than the drift it prevents.

    tools/toolbox-re-gate start          # open the ledger
    tools/toolbox-re-gate row P1 "..." --provenance live --evidence f.json
    tools/toolbox-re-gate status
    tools/toolbox-re-gate handoff "..."  # what a successor needs
    tools/toolbox-re-gate done           # requires every phase recorded
