# QDPeek — implementation spec (QuickDraw content plane)

`corpus_impact`: none because this is the implementation spec for the
QUICKDRAW-CONTENT-PLANE.md research brief; findings land with the milestone
closeouts (M0's is `qdpeek-m0-quickdraw-capture`).

**Status: M0-M3 DONE; M4 emulator safety gate PASSED 2026-07-19** (findings
`qdpeek-m0-quickdraw-capture` through `qdpeek-m4-metal-safety`). The M4 review
rejected main's lifecycle implementation, hardened it, and passed the exact
mac99 campaign plus rollback. Metal promotion still requires the reviewed
source to land durably and the deploy artifact to be rebuilt from that revision.

**What.** A resident producer (`QDPeek`, an INIT) that hooks QuickDraw's
per-port bottleneck procedures on *window ports*, records draw operations
into a shared-memory ring, and a toolkit-worker verb (`qdtrace`) that
controls it and drains the ring as JSON. Host side: a `display` layer in the
scene IR, replayed by the mirror through the extracted NFNT strikes.

Read QUICKDRAW-CONTENT-PLANE.md first for the mechanism and data-first
rationale, and `TIMBUKTU-QD-FINDINGS.md` for the primary-source teardown that
backs the hook contract (the re-entrancy guard, STATE deltas, BITS-never-pixels,
and the four M2+ refinements folded in below). This doc is the build contract.

## Decisions (confirmed — Michelle sign-off + M0 validation)

1. **Sibling INIT, AXPeek untouched.** `QDPeek` is its own extension with its
   own GNE filter (chained — AXPeek itself tail-chains the boot filter, the
   mechanism is proven), its own Gestalt selector (`'TBqd'`), its own shared
   block. Rationale: AXPeek is load-bearing and metal-proven; a draw-time
   hook is the riskiest resident code we've shipped and must not share a
   failure domain with the semantic plane. Carve a shared `peeklib` only
   when a third peek appears.
2. **One traced app (PSN) at a time, one global ring.** "Trace this app" is
   the bounded v1 (the mirror traces the front app; Rung-F calibration
   traces its subject). Ops are port-tagged, so per-window filtering is a
   host concern. Widening to N apps is a control-block change, not a
   redesign.
3. **One wire verb, `qdtrace`, with a `cmd` arg** (`status|start|stop|
   fetch`). One control-tools registry row, one docs/30 classification, one
   e2e-policy ripple (the HANDOFF lesson). The workshop can still render it
   as one instrument with four affordances.
4. **Counting and recording are one machinery** (`mode` field). M0 ships
   with the record path disabled but counters live — the risky part
   (install/uninstall/chaining) soaks first with near-zero payload logic.
5. **JSON fetch** (house style, endian-proof). If M1 measures the decode as
   the bottleneck, fall back to the `pull` raw channel with the same record
   layout — the ring format below is already wire-shaped for that.
6. **CGrafPort-only in v1.** OS 9.1 windows are color ports
   (`portVersion & 0xC000 == 0xC000`). A B&W GrafPort window is skipped and
   counted (`skippedPorts`) — honesty over coverage.

## Guest architecture

```
 QDPeek INIT (resident, 68K + RoutineDescriptors)
 ├── GNE filter (chained): in each app's context at event-loop time
 │     · apply pending command (install/uninstall hooks on that app's
 │       window ports, from the WindowList it already owns)
 │     · repair sweep: re-install on rebuilt ports, drop dead ones
 ├── bottleneck hooks (pascal, called at draw time in the app's context)
 │     · fixed bounded work: bump counter → (record mode) append record
 │       → tail-call the SAVED previous proc (usually the Std proc)
 └── QDShared (NewPtrSys block, Gestalt 'TBqd')
       · seqlock, counters, command block, ring

 toolkit worker (normal context)
 └── qdtrace verb: writes commands, reads counters, drains the ring,
     translates port addresses → window identities at fetch time
```

**Hook install rules** (all applied only in the traced app's own context,
GNE moment — never cross-heap):
- Only ports found on that app's WindowList; save the previous `grafProcs`
  pointer per port in a bounded INIT-private table (16 slots; overflow =
  counted, not traced).
- Hook procs are RoutineDescriptors so native Color QD calls them correctly
  (the `cis`-fix and sleepwatch NewRoutineDescriptor precedents apply; each
  bottleneck's procInfo is fixed at install time, allocated once in the
  system heap).
- Uninstall = restore the saved pointer, same context. A port that died with
  its app's heap is simply forgotten — the hook code is resident forever, so
  a stale `grafProcs` in freed memory never dangles into unmapped code, and
  the repair sweep prunes the table by WindowList membership.
- Hook body discipline = the GNE fast-path rules (docs/28 spirit): no
  allocation, no memory movement, fixed bounded work, tail-chain. A
  reentrancy/busy flag drops (and counts) ops that arrive while a record is
  being committed.

## QDShared v1 (the contract header, `qdpeek/src/qdshared.h`)

```c
#define QD_MAGIC    0x54427164UL   /* 'TBqd' — also the Gestalt selector */
#define QD_VERSION  1UL
#define QD_RING_CAP 65536UL        /* compile-time v1; reported in status */
#define QD_TEXT_MAX 64             /* inline text bytes per record        */

typedef struct {            /* worker writes, INIT applies in-context */
    volatile uint32_t cmdSeq;      /* bump after editing the fields below */
    volatile uint32_t ackSeq;      /* INIT sets = cmdSeq once applied     */
    uint32_t mode;                 /* 0=off  1=count  2=count+record      */
    uint32_t psnHi, psnLo;         /* the traced app                      */
} QDCommand;

typedef struct {
    uint32_t text, line, rect, rrect, oval, arc, poly, rgn, bits,
             comment, other;       /* committed ops by family             */
    uint32_t dropped;              /* ring full / busy-flag collisions    */
    uint32_t skippedPorts;         /* non-CGrafPort or table-overflow     */
    uint32_t installs, uninstalls, repairs, cmdApplies;
} QDCounters;

typedef struct {
    uint32_t magic, version;
    volatile uint32_t seq;         /* seqlock over counters+cursor+ring   */
    uint32_t ticks;                /* TickCount at last commit (liveness) */
    QDCommand  cmd;
    QDCounters counters;
    uint32_t ringCap;              /* == QD_RING_CAP                      */
    uint32_t writeCursor;          /* monotonic byte count; pos = c % cap */
    uint8_t  ring[QD_RING_CAP];
} QDShared;
```

**Ring records** — 2-byte aligned, never wrapped mid-record (a `WRAP` op
pads to the ring end). Common header 12 bytes:

| offset | field | notes |
|---|---|---|
| 0 | `size` u16 | whole record incl. header + pad |
| 2 | `op` u8 | family below |
| 3 | `flags` u8 | bit0 truncatedText, bit1 stateStale |
| 4 | `port` u32 | CGrafPtr — the window identity key |
| 8 | `ticks` u32 | TickCount at capture |

| op | payload |
|---|---|
| 1 TEXT | pen h,v (2×s16) · txFont u16 · txSize u16 · txFace u8 · len u8 · bytes[≤64] — longer runs truncate inline, `flags.0` set, full length still in `len`'s companion u16 when truncated |
| 2 LINE | from h,v · to h,v (4×s16) · pnSize h,v |
| 3 RECT / 4 RRECT / 5 OVAL | verb u8 (frame/paint/erase/invert/fill) · pad · rect (4×s16) · (RRECT: ovalW,ovalH u16×2) |
| 6 ARC | verb u8 · pad · rect · startAngle s16 · arcAngle s16 |
| 7 POLY / 8 RGN | verb u8 · pad · bounding box (4×s16) — not the point/region data, v1 |
| 9 BITS | srcRect · dstRect (8×s16) · mode u16 · pixDepth u8 · pad · srcRowBytes u16 — **never pixels** |
| 10 STATE | kind u8 (1 clipBBox · 2 origin · 3 fg · 4 bg · 5 pnPat hash · 6 txState) · payload ≤12 — emitted lazily when the port's shadow state differs at op time |
| 255 WRAP | pad to ring end |

**Coherence.** Classic Mac OS is cooperative — one app draws at a time, so
there is a single writer at any moment; the busy flag guards the rare
interrupt-time drawer (drop + count). The seqlock (AXShared discipline)
makes reader snapshots tear-free: the worker samples `seq`, copies
`[cursor, writeCursor)` in ≤2 segments, re-samples, retries on change.
Overrun: if `writeCursor - readerCursor > ringCap`, fetch replies
`resync:true` with the drop estimate and restarts from `writeCursor`.

## The `qdtrace` verb (toolkit build, `#ifdef TBT_MORDOR` family)

| cmd | args | reply |
|---|---|---|
| `status` | — | `{present, version, mode, psn:{hi,lo}, applied:bool (ackSeq==cmdSeq), counters{…}, cursor, ringCap}` |
| `start` | `serialHi, serialLo, mode:"count"\|"record"` | `{requested:true, cmdSeq}` — applied at the app's next GNE moment (≲ ticks); poll `status.applied` |
| `stop` | — | `{requested:true}` — uninstall + mode 0 |
| `fetch` | `cursor, maxBytes≤32768` | `{ops:[…], nextCursor, dropped, resync, ports:{"0x00ABCDEF":{psn:"hi.lo", title, occ}}}` |

Fetch decodes ring records to JSON guest-side and resolves each port
address against the traced app's WindowList (normal-context walk — the same
machinery `axtree` uses), so ops arrive keyed to window identities the host
can match to `ax2` refs. Text bytes ship MacRoman (the wire's existing
convention; the host decodes).

Example fetched op:
```json
{"op":"text","port":"0x004A3B10","ticks":88213,"pen":[12,24],
 "font":3,"size":9,"face":0,"text":"HELLO_CLAUDE.txt"}
```

**Registry mechanics (M1, the HANDOFF lesson):** one `control-tools.toml`
row (`experimental`, unreviewed → refuses unattended metal, which matches
the emu-first mandate), docs/30 matrix row (workbench first), workshop-parity
ledger + instrument row, e2e-policy membership `members_sha256` pins + the
pinned control-channel row count, `tools/control-contract render`, then the
FULL `mcp-classic/tests` battery — the four quick gates are not sufficient.

## Host side

- **IR**: `windows[].display: [DisplayOp]` (version-stamped with the scene;
  the IR is pre-freeze — this is the churn window). `DisplayOp` mirrors the
  fetched JSON; `scene.py` grows the parity normalizer as the oracle.
- **Poller**: when tracing is active, `fetch` rides the existing poll tick
  (the wire is one shared connection now — same discipline).
- **Renderer (M2)**: replay ops into the window content area — text through
  `BitmapFont` (guest font id → strike: 0/1 system→chicago-12, 3 geneva →
  geneva-N; unknown ids fall back + count), primitives as Canvas paths,
  BITS dst-rects as gray placeholders until M3 fills them via lazy
  `capture_region`.
- **Fixtures**: captured fetch payloads → golden scenes, the established
  oracle loop; M2 adds a replay-vs-`capture_full` IoU gate (the font pack's
  validation method).

## Deployment & dev loop

Same recipe as AXPeek: `QDPeek.bin` (Retro68 68K INIT) → `push_stream` into
`System Folder:Extensions` → cold reboot → toolkit worker serves `qdtrace`.
INIT changes need a reboot, verb changes don't — so **keep the INIT minimal
and stable** (hooks + ring only); every decodable/queryable smart lives in
the worker or the host. Bake QDPeek into the next canonical image rev
alongside AXPeek once M1 passes.

## Milestones

| # | Ships | Acceptance |
|---|---|---|
| **M0 ✅ DONE** | INIT (chain, command block, install/uninstall/repair, counters), `qdtrace status/start/stop`, count mode only | **PASSED live (mac99, finding `qdpeek-m0-quickdraw-capture`)**: boots clean; install/uninstall functionally proven 5/5; Mixed Mode works with `NewQDxxxUPP` alone (no RoutineDescriptors); re-entrancy guard airtight (type 40 → text=41, bits=0); op-rate table gathered; 100× start/stop stable |
| **M1** | record mode: ring + TEXT records + `fetch`; registry/docs/30/parity/e2e mechanics | typed text in SimpleText readable over the wire, byte-exact vs what was typed; overrun path exercised (tiny test ring) and honest |
| **M2** | primitives + STATE deltas; host IR `display` + mirror replay via BitmapFont; **unknown-font TEXT → pixel island** (refinement 2) | replay-vs-`capture_full` IoU ≥ 0.9 on a SimpleText document window; a forced unknown-font run replays as a pixel island, not a wrong glyph; fixtures + oracle parity green |
| **M3 ✅ HOST HALF DONE** | BITS ops + lazy `capture_region` composition; **MoveBits scroll fast-path** (refinement 1) | **PASSED live (mac99, 2026-07-17)**: the Finder — *the* GWorld app, it composites icon views offscreen and blits them (finding `finder-window-icons-are-offscreen-blits`) — renders as semantic chrome + a pixel island: all 12 icons at true positions, in colour, matching a QMP screendump. `WireClient.pull` (W1 pager + CRC-32) / `captureRegion` (auto-tiled to the guest's resident buffer; a full window is `too_large` otherwise) / PackBits + gray8·mono1·rgb555be→RGBA8 / `Scene.Window.island`. Fetch-on-change measured at **1 fetch per 4 polls** (4.5s vs 3.8s baseline); a full 426×358 island is ~947 ms @ depth 16. MoveBits is real and shipped: a live page-down emits `src[4,4,418,147]→dst[4,-29,418,114]` (same size, up 33px) among two GWorld composites and three 16×16 arrows — `newestMove()` picks it and rejects the decoys (6 unit tests on the real op stream, 32 green). **Bounds:** the fast-path's live engagement rides the `--window` poll loop (a headless multi-poll can't prove it: each `--snapshot` is a fresh process/cache, and the single-client rule forbids scrolling from a second connection); bytes-per-frame is instrumented (`islandBytesFetched`) but not yet profiled per frame |
| **M4 🟡 EMU PASS** | Rung-F consumer (calibration lane reads the same stream); metal-safety review artifact for the tier gate | **PASSED mac99 2026-07-19:** `tools/qdpeek-m4-review` reconstructed the exact marker from a lossless state/text/rect stream; stale-window stop, exited/live retarget, 20 cycles, throttled repair, and remove-from-Extensions rollback passed. Review: `qdpeek-m4-metal-safety`. **Metal remains blocked until the reviewed source is durable and the final artifact is rebuilt from it.** |

Effort shape: M0 was the hard one and **is done** (the Mixed Mode + install
state machine risk is retired — see the finding). M1 is ring plumbing; M2 is
mostly host Swift.

## Refinements folded from the Timbuktu teardown

Cross-walk: `TIMBUKTU-QD-FINDINGS.md` (the sibling thread's primary-source
digest). M0 already banked the re-entrancy guard from it (§7 of the teardown);
these four are M2+ and stay flagged until their milestone:

1. **MoveBits scroll fast-path (M3).** A screen→screen blit whose src rect is
   within the port's on-screen bounds is Timbuktu's *MoveBits*: the replay side
   already holds those pixels, so *move the rendered region* instead of a
   `capture_region` re-fetch. Cheap common-case (scrolling, dragged content)
   before the pixel-island fallback. The BITS record already carries src+dst;
   the host detects src-on-screen and moves.
2. **Unknown-font TEXT → pixel island, not a wrong glyph (M2).** When a TEXT
   op's font id has no bundled strike, do NOT render a substitute strike —
   request a `capture_region` of the run's bounding rect and show an honest
   pixel island (the same braid as BITS). Near-zero for our pack (it covers the
   system faces), but the escape hatch must be pixels, never guesswork. Timbuktu
   did exactly this (draw locally, ship the bitmap) because it lacked the font;
   we have the strikes, so this is only the rare-font tail.
3. **The screen-stash is the named floor for non-QuickDraw apps (not built
   M0–M3).** An app that writes the framebuffer directly (a game, a custom
   blitter that never touches a port) emits no bottleneck ops — our scoped
   per-port hook misses it by design. Timbuktu's answer was a full
   shadow-framebuffer diff ("screen stash"). We won't build it, but it is the
   documented honest floor beneath the bits-op braid, so "an app that never
   calls QuickDraw" has a named answer, not a silent blind spot. Detection
   today = M0's counter-vs-`capture_full` cross-check (drawing with no ops).
4. **Numbered-port cache = a compression path if rings get chatty (measure
   first).** Records key by full `CGrafPtr` (u32) — identity-stable and correct.
   If M1/M2 measurements show port-state re-emission dominating the ring,
   Timbuktu's numbered cache (small id + only-changed fields) is the compression
   move. Not needed until measured; noted so it isn't reinvented.

Two ways we stay ahead of Timbuktu, both already banked: we **never fall back
to pixels for fonts** in the common case (extracted NFNT strikes, IoU 1.0 —
their hardest problem is our solved one), and we have an **emulator oracle**
(`capture_full` IoU + TCG cross-check) they never had.

## Risk register

Two distinct guards, often conflated — keep them separate:
- **Re-entrancy guard** (`gInCapture`, M0, DONE): a bottleneck's std proc calls
  *other* bottlenecks (StdText → StdBits per glyph); the flag records only the
  top-level entry and passes nested calls through. NOT a drop — nested ops are
  intentional noise, not lost data. Proven airtight (text=41 / bits=0).
- **Ring busy-flag** (M1): if a record can't be committed because the ring is
  full or a reader/writer overlap collides, drop it and bump `dropped`. This is
  the honesty counter; it only exists once record mode writes the ring.

| Risk | Mitigation |
|---|---|
| ~~Mixed Mode: PPC Color QD calling 68K hooks~~ | **RETIRED (M0)**: `NewQDxxxUPP` alone works; no RoutineDescriptors needed |
| ~~INIT unsafe at boot / install destabilizes~~ | **RETIRED (M0)**: boots clean, install on a live port survives, 100× stable |
| Hook overhead visible at draw time | fixed bounded body; M0 op rates are modest (keystroke ~5 ops); record mode adds one bounded memcpy |
| Port dies / app quits with hooks installed | resident hook code never dangles; repair sweep prunes by WindowList membership; restore only live ports (M0-exercised) |
| Ring full / reader-writer overlap (M1) | ring busy-flag: drop + count `dropped`; seqlock + retry (AXShared-proven), reader never blocks the writer |
| An app bypasses its port (writes the framebuffer directly) | scoped per-port hooks miss it BY DESIGN; detection = counter-vs-`capture_full` cross-check; the named floor is the screen-stash (refinement 3), unbuilt |
| A wedge on metal | emu-first mandatory; M4 hardens owner-context lifecycle and passes mac99 + rollback, but metal stays attended and exact-revision/hash gated (cis/sertx precedent) |
| INIT bugs need reboots to iterate | INIT stays minimal; smarts live worker/host-side; emu clones make reboot cycles cheap |

## Sign-off — resolved

All four confirmed by Michelle + validated by M0:

- D1 sibling INIT — **confirmed** (Michelle: "keep them isolated for now, merge
  later if we want"); M0 proves it boots and runs independently.
- D2 one-PSN scope for v1 — **confirmed**; M0 traced a single PSN cleanly.
- D3 single `qdtrace` verb with `cmd` — **confirmed** (one registry ripple).
- Ring 64 KiB / text cap 64 B — **kept**; M0 op rates are modest (keystroke
  ~5 ops), so 64 KiB is generously sized. Revisit only if M1 record-mode
  measurements say otherwise (then refinement 4's numbered-port cache).
