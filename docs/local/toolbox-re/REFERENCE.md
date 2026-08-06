# The Toolbox and GWorld, measured

**Emulator: QEMU mac99, Mac OS 9.1, 2026-08-06.** Nothing here has run
on physical hardware. Every claim carries how it was established:

- **static** — read out of a file on the guest's disk, no machine running
- **measured** — observed by a program running on the guest, this rig
- **doc** — asserted by documentation or prior art; evidence, not a
  measurement of this machine

The ledger (`ledger.json`) is the primary record; this file is the shape
a reader needs. [PLAN.md](PLAN.md) is the arc.

## 1. Getting at the corpus

**The guest filesystem mounts read-only on the host** (static). No VM,
no time limit:

```
qemu-img convert -O raw base.qcow2 disk.raw
# parse the Apple Partition Map at block 1; HFS partition here at 1544
dd if=disk.raw of=hfs.img bs=512 skip=1544 count=8387044
hdiutil attach -readonly hfs.img
```

**The Toolbox is not statically readable from the ROM** (static). On
this New World machine `System Folder:Mac OS ROM` is 2,448,470 bytes of
CHRP boot script wrapping a compressed body. The only valid PEF inside
(`0x2055c4`, arch `pwpc`, 3 sections) is a small embedded driver
importing DriverServicesLib / NameRegistryLib / PowerMgrLib. Toolbox
*code* exists decompressed only in RAM, so code-level questions belong
to the live lane. **Applications, however, are ordinary PEFs**, and
their import tables are a rich static source (`tools/pef.py`).

## 2. Structure layouts

`offsetof` from the extension's own dialect — 68K, Retro68, Universal
Interfaces 3.4 — printed by a program compiled in it, then the same
fields read off a live port (measured).

| Type | Size |
|---|---|
| `GrafPort` | 108 |
| `CGrafPort` | 108 |
| `BitMap` | 14 |
| `PixMap` | 50 |
| `GDevice` | 62 |
| `QDProcs` | 52 |
| `CQDProcs` | 80 |

**`GrafPort` and `CGrafPort` are the same size and different shapes**,
which is the whole reason a discriminator check must precede any write:

| Offset | `GrafPort` | `CGrafPort` |
|---|---|---|
| 0 | `device` | `device` |
| 2 | `portBits` (BitMap, inline) | `portPixMap` (**handle**) |
| 6 | *(inside portBits)* | `portVersion` — **the discriminator** |
| 8 | | `grafVars` |
| 12 | | `chExtra` |
| 14 | | `pnLocHFrac` |
| 16 | `portRect` | `portRect` |
| 24 | `visRgn` | `visRgn` |
| 28 | `clipRgn` | `clipRgn` |
| 104 | `grafProcs` | `grafProcs` |

`portVersion & 0xC000 == 0xC000` identifies a colour port (measured on a
live window). A fresh window's `grafProcs` is NULL (measured).

`PixMap`: `baseAddr@0`, `rowBytes@4`, `bounds@6`. `rowBytes`' high bit
(0x8000) marks "this BitMap is really a PixMap"; the low 14 bits are the
row stride.

## 3. GWorlds

- **A `GWorldPtr` IS its `CGrafPtr`** — same address, no private wrapper
  record (measured).
- **The port is a relocatable block.** `RecoverHandle` on the port
  itself returns a handle, confirming Inside Macintosh's "an
  always-locked handle in the application heap" on this machine
  (measured).
- **`useTempMem` moves only the pixels.** The port stays in the
  application heap; `baseAddr` lands outside both heaps (measured:
  `0x1f8059a4` against an app heap around `0x1ea5xxxx`). A port-hunting
  sweep of the application zone is therefore looking in the right place
  even for a temp-memory world.
- **`baseAddr` MOVES under `LockPixels`** — every flavour tested (device
  depth, 8, 32, `useTempMem`, `keepLocal`, `pixelsPurgeable`,
  `noNewDevice`). **A pixmap's `baseAddr` is not an identity.**
- **A disposed world's address is reused** by the very next `NewGWorld`
  of the same size (measured: `0x1ea59e00` twice running). An observer
  polling for offscreen ports cannot tell one repaint's world from the
  next by address, and a stale row pointing at a disposed world will
  come to point at a live different one.

## 4. Dispatch

- **A window port and an offscreen port dispatch identically.** Hooking
  `grafProcs` on each and drawing the same string fired the text hook
  once on both (measured, side by side in one program). The content
  plane's mechanism is not window-specific.
- **`StdText` does NOT nest through `StdBits`** on this machine. With no
  re-entrancy guard installed, a `DrawString` produced `text=1, bits=0`
  on both port kinds (measured). `ext/src/now_content.c` justifies its
  guard with "StdText blits each glyph through StdBits"; **that
  rationale does not reproduce here.**
- **A GWorld→window `CopyBits` passes the port's own dereferenced
  `portPixMap`** as its source (measured). The join the probe wants
  exists.

## 5. The Finder — ANSWERED

**The labels in a Finder icon view are recoverable as semantic text.**
Measured 2026-08-06 by hooking the Finder's offscreen port from a
resident and holding the hook across a reflowing resize:

| Port | What it emitted |
|---|---|
| window `0x00ac7af0` | 4 `bits`, 3 `rect` — the opaque composite |
| **offscreen `0x1f472e60`** | **8 `text`**, 24 `rect`, 11 `rgn`, 8 `bits` |

The text records carry the real filenames at their true pens:

    '10 items, 3.21 GB available'  pen [135,14]
    'Documents'                    pen [280,67]
    'TimBotTu'                     pen [282,131]
    'TBT'                          pen [40,195]
    'TBT-paced-dev'                pen [140,195]
    'TBT-sndbuf-dev'               pen [265,195]

This **supersedes the dead-end verdict** of the corpus finding
`finder-window-icons-are-offscreen-blits` for the OFFSCREEN port. That
finding remains exactly right about the window port — which is all
anyone had looked at.

**The method matters as much as the result**: arm, wait for the chase to
hook the offscreen port, then force a repaint **without re-arming**.
Re-arming bumps the generation and unhooks the world, which is why every
earlier attempt saw an empty offscreen port.

**Lifetime, observed.** Across three resizes the hooked row went stale
once and `lastMatch` moved `0x1f472e60` → `0x1f472ee0`: the Finder does
replace its offscreen world, consistent with importing `NewGWorld` and
`DisposeGWorld` and no `UpdateGWorld`. A hook must be re-established per
world — but a world lives long enough to be found and read.

**What is still opaque.** Icons arrive as `bits` with no identity while
their labels arrive as text, so a composite decomposes into content that
is already semantic and images that need identity from elsewhere
(`PlotIconSuite`/`IconRef` interception).

## 5a. The Finder, statically

- **It uses GWorlds** (static, from its own PEF import table): it
  imports `NewGWorld`, `DisposeGWorld`, `SetGWorld`, `GetGWorld`,
  `GetGWorldPixMap`, `GetGWorldDevice`, `LockPixels`, `UnlockPixels`,
  `CopyBits` from InterfaceLib.
- **It imports no `UpdateGWorld`.** It has no way to resize an offscreen
  world in place, so a world is created and destroyed rather than kept
  and updated.
- **Its window icon views composite offscreen and arrive as one blit**
  (measured): a 404×218 content window emits one `bits` op, `src == dst`,
  zero text, zero per-icon ops.
- **Icons go through `PlotIconSuite` / `PlotIcon` / `PlotIconRef`** with
  IconServicesLib linked (static). Icon *identity* in a composite is an
  IconSuite or IconRef — the interception surface for host-side
  composition, since a `bits` op carries geometry and never pixels.

## 5b. Which applications composite offscreen

Derived statically from PEF import tables — nothing was launched. Full
table in `app-offscreen-table.txt`.

| Application | GWorlds? | Notes |
|---|---|---|
| Finder | **yes** | + `PlotIconSuite`/`PlotIconRef`; no `UpdateGWorld` |
| Sherlock 2 | **yes** | also imports `SetStdCProcs` — installs its own bottlenecks |
| Graphing Calculator | **yes** | the ONLY one importing `UpdateGWorld`; also `SetStdCProcs` |
| Appearance cdev | **yes** | no own bottlenecks, so hookable |
| Network Browser | no | no `NewGWorld`, no `CopyBits` |
| Dock | no | `PlotIconRef` only |
| Date & Time cdev | no | `PlotIconSuite` only |
| Energy Saver, AppleTalk cdevs | no | draw straight to their windows |

Two patterns worth more than the table:

- **Create-and-destroy is the era's norm.** Only Graphing Calculator can
  resize an offscreen world in place; everyone else must dispose and
  recreate, so any hook on such a world has to be re-established. The
  Finder is not unusual here.
- **Some applications are unhookable by this plane, by design.** Sherlock 2
  and Graphing Calculator install their own `grafProcs` via
  `SetStdCProcs`, and the content plane refuses a port whose `grafProcs`
  is already non-NULL rather than chain onto procs it knows nothing
  about. That refusal is now a measured limitation.
- **The applications that do NOT composite are already fully visible** to
  a plain window-port hook — their content needs no chase at all.

## 6. Memory: the two facts that invalidate naive tooling

**`MemTop` is not the top of addressable memory** (measured).
`LMGetMemTop` reads `0x00e225f0` — about 14.8 MB — and the SYSTEM zone
lies below it (`0x2834`–`0x00d0b9f0`). An APPLICATION zone sits at
`0x1e93e4d4`–`0x1e97be90`, around 512 MB. MemTop bounds the low/system
region only.

Anything that uses MemTop as a RAM ceiling therefore rejects every
application-heap pointer in existence. This is not hypothetical: a
range check added to this project's probe to stop it crashing the
Finder did exactly that, and silently disabled the instrument through
three subsequent fixes that each looked correct in isolation. **Bound
reads by the zones** (`ApplicationZone()`, `SystemZone()`) — they are
mapped by construction and are the memory you are walking anyway.

**`LockPixels` relocates the PixMap record, not merely its pixels**
(measured). The control reported its own pixmap deref at `0x1e957660`,
inside its app zone; the blit it makes under `LockPixels` reports
`0x1ea53eee`, above `bkLim` and outside that zone. Consequences:

- a source pointer taken from a blit is a snapshot of a moved block;
- `RecoverHandle` on it fails, because that searches the *current* zone
  and the record is no longer in one;
- `baseAddr` taken at draw time will not equal `baseAddr` read later.

**What survives relocation is shape** — the pixmap's `bounds` and
`rowBytes`, and the owning port's `portRect` agreeing with them.

## 7. The rule this arc paid the most for

**A dereferenced handle is a snapshot, not an identity.**

Resident code that observes at draw time and acts at the next
event-loop pass must carry **handles** across that gap. A `PixMap`
record is relocatable; the pointer a blit hands you may have moved by
the time you use it, and a late `RecoverHandle` on a moved pointer
cannot recover it.

This was not deduced. A purpose-built control
(`tools/guest-gworld/src/loop.c`) holds one GWorld for its whole life
and blits it into its own window on a cadence. The chase sighted that
blit **869 times at exactly the right rect**, chased it, and found
nothing — with the target guaranteed alive. That is what proved the
instrument wrong rather than the application.

## 8. What is still open

- Whether the fix (recovering the handle at sight time) makes the
  control pass. **Until it does, no null from any application is
  evidence about that application.**
- Whether the Finder's composite survives its repaint at all — the
  transient hypothesis. The static evidence (no `UpdateGWorld`) points
  at create-and-destroy, but it has not been observed.
- Whether a 68K trap patch on a QuickDraw call is seen by a native
  PowerPC caller. The spike proves 68K-installed `grafProcs` fire for a
  68K program; it does not establish what happens when the *caller* is
  native.
- The route from an `IconSuite`/`IconRef` to a resource ID that a host
  could compose from.
