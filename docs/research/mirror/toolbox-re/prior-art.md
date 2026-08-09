# Prior art: GWorlds, QuickDraw bottlenecks, and dispatch

**Provenance of this whole file: `doc` — evidence, not measurement.**
Nothing here was observed on the rig. It is the documented and prior-art
half of the [investigation plan](investigation-plan.md); the live lane confirms or refutes it. Where a
claim is strong enough that a contradiction on the machine would be
surprising, it still gets confirmed — this project has been bitten by
code that looked obviously correct and had never run.

Two claims below carry a stronger label, **`static (this Mac)`**: they were
produced here by compiling against the real Universal Interfaces 3.4
headers with the project's own Retro68 toolchains and reading the object
code. That is still not the running OS 9.1 machine, but it is not a
quotation either — it is what our own guests actually emit.

Every claim is marked:

- **Confidence** High / Medium / Low.
- **ASSERTS** (a source states it) vs **DEMONSTRATES** (a source shows
  code, a figure, or a measurement that establishes it).

### Contents

Sections keep the brief's numbering but are ordered by dependency, since
everything refers back to the layouts.

| § | | |
|---|---|---|
| **4** | [Structure layouts](#4-structure-layouts) | offsets for every record, derived twice |
| **4a** | [The trap and selector map](#4a-the-trap-and-selector-map) | every A-trap and `_QDExtensions` selector |
| **3** | [Native PPC vs the 68K trap table](#3-native-powerpc-quickdraw-versus-the-68k-trap-table) | what a resident extension can intercept |
| **1** | [GWorld internals](#1-gworld-internals) | construction, flags, lifecycle, teardown |
| **2** | [The bottleneck mechanism](#2-the-bottleneck-mechanism) | `grafProcs` dispatch, `StdText`, icons |
| **5** | [Prior reimplementations](#5-prior-reimplementations) | Executor, MACE, AMS, SheepShaver |
| — | [Corrections to the plan](#corrections-to-the-investigation-plan-that-fell-out-of-this-sweep) | four things that do not exist as named |
| — | [**Questions for the live lane**](#questions-for-the-live-lane) | the deliverable's other half |
| — | [Coverage](#coverage-and-what-this-file-does-not-cover) | what is thin, and what rests on what |

**If you read three things**: the `CopyBits` destination test (§2), the
`StdText` answer (§2), and the CarbonLib hole (§3).

---

## 4. Structure layouts

Taken first because everything else refers to it, and because it is the
part this file can nail down hardest.

### How these offsets were produced

`static (this Mac)` — **DEMONSTRATES**, **High**.

A generated translation unit of `offsetof`/`sizeof` expressions was
compiled against
`Retro68-build/toolchain/universal/CIncludes` (Apple **Universal
Interfaces 3.4**, © 1985–2001) and the resulting constant table read out
of the object file. It was compiled **twice** — once with
`powerpc-apple-macos-gcc` and once with `m68k-apple-macos-gcc` from
`Retro68-build-68k` — and the two tables are **byte-for-byte identical**.
So there is no packing drift between our two guests for any structure
below. (`QDOffscreen.h` sets `#pragma options align=mac68k` /
`pack(2)`; the numbers are consistent with 2-byte alignment and no tail
padding throughout.)

These are the offsets **our toolchain believes**. They are not yet the
offsets the OS 9.1 ROM uses. P1 exists to close exactly that gap.

### Sizes

| Type | Size (dec) | Size (hex) |
|---|---|---|
| `Point` | 4 | 0x04 |
| `RGBColor` | 6 | 0x06 |
| `Rect` | 8 | 0x08 |
| `Pattern` | 8 | 0x08 |
| `ColorSpec` | 8 | 0x08 |
| `BitMap` | 14 | 0x0E |
| `ColorTable` (header + 1 entry) | 16 | 0x10 |
| `GrafVars` | 26 | 0x1A |
| `PixPat` | 28 | 0x1C |
| `PixMap` | 50 | 0x32 |
| `QDProcs` | 52 | 0x34 |
| `Zone` | 54 | 0x36 |
| `GDevice` | 62 | 0x3E |
| `CQDProcs` | 80 | 0x50 |
| `GrafPort` | **108** | 0x6C |
| `CGrafPort` | **108** | 0x6C |

### `BitMap` (14 bytes)

| Off | Field | Type |
|---|---|---|
| 0 | `baseAddr` | `Ptr` |
| 4 | `rowBytes` | `short` |
| 6 | `bounds` | `Rect` |

### `PixMap` (50 bytes)

| Off | Field | Type |
|---|---|---|
| 0 | `baseAddr` | `Ptr` |
| 4 | `rowBytes` | `short` |
| 6 | `bounds` | `Rect` |
| 14 | `pmVersion` | `short` |
| 16 | `packType` | `short` |
| 18 | `packSize` | `long` |
| 22 | `hRes` | `Fixed` |
| 26 | `vRes` | `Fixed` |
| 30 | `pixelType` | `short` |
| 32 | `pixelSize` | `short` |
| 34 | `cmpCount` | `short` |
| 36 | `cmpSize` | `short` |
| 38 | `planeBytes` (classic) / `pixelFormat` (QT3+) | `long` / `OSType` |
| 42 | `pmTable` | `CTabHandle` |
| 46 | `pmReserved` (classic) / `pmExt` (QT3+) | `long` / `void*` |

**Watch this one.** `Quickdraw.h` UI 3.4 has *two* `PixMap`
definitions selected by `OLDPIXMAPSTRUCT`, which is 1 only when
`TARGET_OS_MAC && TARGET_API_MAC_OS8`. The header's own note says
QuickTime 3.0 renamed `pmReserved`→`pmExt` (a `Handle` to extra info)
and `planeBytes`→`pixelFormat`. **The size and every offset are
identical either way** (4-byte fields both times), so this is a naming
and *meaning* difference, not a layout one — but a probe that reads
offset 38 must know which of the two it is looking at, and on a live OS
9.1 machine with QuickTime installed it is plausibly `pixelFormat`.
`Confidence High` (header), **DEMONSTRATES**.
Source: local UI 3.4 `Quickdraw.h` lines 1639–1729.

For the record, the offsets above were produced with the toolchain
default `TARGET_API_MAC_OS8=1`, hence **`OLDPIXMAPSTRUCT=1` — the classic
`planeBytes`/`pmReserved` names**, which is the correct shape for an OS
8/9 target and the shape our own guest compiles. The QuickTime-3 variant
occupies the same bytes.

`GETPIXMAPPIXELFORMAT(pm)` in the same header is
`pixelFormat != 0 ? pixelFormat : pixelSize` — i.e. even Apple's own
macro treats a zero `pixelFormat` as "fall back to reading depth from
`pixelSize`". Useful defensive read for the probe.

### `GrafPort` (108 bytes) vs `CGrafPort` (108 bytes)

Side by side, because the correspondence is the whole trick:

| Off | `GrafPort` | `CGrafPort` |
|---|---|---|
| 0 | `device` (short) | `device` (short) |
| 2 | `portBits` (BitMap, 14 bytes) → `.baseAddr` | `portPixMap` (**PixMapHandle**) |
| 6 | ↳ `portBits.rowBytes` (short) | **`portVersion` (short)** |
| 8 | ↳ `portBits.bounds` (Rect) | `grafVars` (Handle) |
| 12 | ↳ | `chExtra` (short) |
| 14 | ↳ | `pnLocHFrac` (short) |
| 16 | `portRect` (Rect) | `portRect` (Rect) |
| 24 | `visRgn` (RgnHandle) | `visRgn` (RgnHandle) |
| 28 | `clipRgn` (RgnHandle) | `clipRgn` (RgnHandle) |
| 32 | `bkPat` (Pattern, 8) | `bkPixPat` (PixPatHandle) |
| 36 | ↳ | `rgbFgColor` (RGBColor, 6) |
| 40 | `fillPat` (Pattern, 8) | ↳ |
| 42 | ↳ | `rgbBkColor` (RGBColor, 6) |
| 48 | `pnLoc` (Point) | `pnLoc` (Point) |
| 52 | `pnSize` (Point) | `pnSize` (Point) |
| 56 | `pnMode` (short) | `pnMode` (short) |
| 58 | `pnPat` (Pattern, 8) | `pnPixPat` (PixPatHandle) |
| 62 | ↳ | `fillPixPat` (PixPatHandle) |
| 66 | `pnVis` (short) | `pnVis` (short) |
| 68 | `txFont` (short) | `txFont` (short) |
| 70 | `txFace` (StyleField, 16 bits, low 8 used) | same |
| 72 | `txMode` (short) | `txMode` (short) |
| 74 | `txSize` (short) | `txSize` (short) |
| 76 | `spExtra` (Fixed) | `spExtra` (Fixed) |
| 80 | `fgColor` (long) | `fgColor` (long) |
| 84 | `bkColor` (long) | `bkColor` (long) |
| 88 | `colrBit` (short) | `colrBit` (short) |
| 90 | `patStretch` (short) | `patStretch` (short) |
| 92 | `picSave` (Handle) | `picSave` (Handle) |
| 96 | `rgnSave` (Handle) | `rgnSave` (Handle) |
| 100 | `polySave` (Handle) | `polySave` (Handle) |
| 104 | `grafProcs` (**QDProcsPtr**) | `grafProcs` (**CQDProcsPtr**) |

Everything from **offset 16 (`portRect`) onward is at the same offset in
both**, and the two records are the same size. The divergence is
confined to offsets 2–15.

### The `portVersion` discriminator

`doc` — **DEMONSTRATES** (Inside Macintosh states it as the mechanism
QuickDraw itself uses), **Confidence High**.

At **offset 6**:

- In a `GrafPort` that word is `portBits.rowBytes`, whose **high 2 bits
  are always clear** (`rowBytes` is bounded well below 0x4000).
- In a `CGrafPort` that word is `portVersion`, whose **high 2 bits are
  always set**. The remaining bits hold the Color QuickDraw version that
  created the structure.

Inside Macintosh: "QuickDraw uses these bits to distinguish `CGrafPort`
records from `GrafPort` records".

Source: *Inside Macintosh: Imaging With QuickDraw*, "About Color
QuickDraw" —
<https://dev.os9.ca/techpubs/mac/QuickDraw/QuickDraw-198.html>
(mirror: <https://preterhuman.net/macstuff/insidemac/QuickDraw/QuickDraw-198.html>;
PDF: <https://developer.apple.com/library/archive/documentation/mac/pdf/Imaging_With_QuickDraw/Color_QuickDraw.pdf>)

The same page confirms the offset-2 substitution in as many words: a
`GrafPort` has a complete 14-byte `BitMap` in `portBits`; a `CGrafPort`
replaces its front with the 4-byte `portPixMap` handle.

**Practical test for the probe** (`test the word at port+6, mask
0xC000`): `== 0xC000` ⇒ colour port. This is the check to use when
sweeping a heap for candidate ports, and it is cheap. Note it is a
*necessary* not *sufficient* condition — arbitrary heap bytes will hit
it roughly 1 time in 4, which is very likely part of why the zone sweep
in the probe arc produced candidates it could not confirm.

### `GDevice` (62 bytes)

| Off | Field | Type |
|---|---|---|
| 0 | `gdRefNum` | short |
| 2 | `gdID` | short |
| 4 | `gdType` | short |
| 6 | `gdITable` | ITabHandle |
| 10 | `gdResPref` | short |
| 12 | `gdSearchProc` | SProcHndl |
| 16 | `gdCompProc` | CProcHndl |
| 20 | `gdFlags` | short |
| 22 | `gdPMap` | **PixMapHandle** |
| 26 | `gdRefCon` | long |
| 30 | `gdNextGD` | GDHandle |
| 34 | `gdRect` | Rect |
| 42 | `gdMode` | long |
| 46 | `gdCCBytes` | short |
| 48 | `gdCCDepth` | short |
| 50 | `gdCCXData` | Handle |
| 54 | `gdCCXMask` | Handle |
| 58 | `gdReserved` (classic) / `gdExt` (QT3+) | long / Handle |

Same `OLDGDEVICESTRUCT` two-definition situation as `PixMap`: identical
layout, `gdReserved` renamed to `gdExt` holding "QuickTime 3.0 private
info". A classic `gdReserved` is documented as **must be 0**; if the
live lane finds it non-zero on an OS 9.1 GDevice, that is QuickTime's
extension handle, not corruption.

### `QDProcs` (52 bytes) and `CQDProcs` (80 bytes)

All fields are 4-byte procedure pointers (UPPs on CFM). The first
thirteen are **identical in order and offset** between the two:

| Off | Field | in `QDProcs` | in `CQDProcs` |
|---|---|---|---|
| 0 | `textProc` | ✓ | ✓ |
| 4 | `lineProc` | ✓ | ✓ |
| 8 | `rectProc` | ✓ | ✓ |
| 12 | `rRectProc` | ✓ | ✓ |
| 16 | `ovalProc` | ✓ | ✓ |
| 20 | `arcProc` | ✓ | ✓ |
| 24 | `polyProc` | ✓ | ✓ |
| 28 | `rgnProc` | ✓ | ✓ |
| 32 | **`bitsProc`** | ✓ | ✓ |
| 36 | `commentProc` | ✓ | ✓ |
| 40 | `txMeasProc` | ✓ | ✓ |
| 44 | `getPicProc` | ✓ | ✓ |
| 48 | `putPicProc` | ✓ | ✓ |
| 52 | `opcodeProc` | — | ✓ |
| 56 | `newProc1` | — | ✓ — **this is the `StdPix` bottleneck** |
| 60 | `glyphsProc` | — | ✓ (was `newProc2`; Unicode text drawing) |
| 64 | `printerStatusProc` | — | ✓ (was `newProc3`) |
| 68 | `newProc4` | — | ✓ |
| 72 | `newProc5` | — | ✓ |
| 76 | `newProc6` | — | ✓ |

Three of those are load-bearing and are worth calling out, because they
are named as reserved in older documentation and were quietly given
meanings later — the header's own comments are the record:

- **`newProc1` at offset 56 is `StdPix`**, the bottleneck for
  *compressed/imaged* pixel data (`ImageCompression.h`). Anything drawn
  through QuickTime's image decompression path can arrive here rather
  than at `bitsProc`. A bottleneck recorder that hooks only `bitsProc`
  has a blind spot with exactly this shape.
- **`glyphsProc` at offset 60** is used in Unicode text drawing.
- **`printerStatusProc` at offset 64** carries status between printing
  code and system imaging code.

`Confidence High` (header comments), **ASSERTS** for the semantics,
**DEMONSTRATES** for the offsets.
Source: local UI 3.4 `Quickdraw.h` lines 1861–1882.

### `Zone` (54 bytes)

`doc` + `static (this Mac)` — **DEMONSTRATES**, **Confidence High**.
Offsets from the compile; field meanings from *Inside Macintosh: Memory*
chapter 2, "Organization of Memory". The assembly-language summary in
that chapter lists the same offsets, and they agree.

| Off | Field | Meaning |
|---|---|---|
| 0 | `bkLim` (Ptr) | byte following the last usable byte in the zone |
| 4 | `purgePtr` (Ptr) | internal |
| 8 | `hFstFree` (Ptr) | head of the free master-pointer list |
| 12 | `zcbFree` (long) | free bytes remaining (what `FreeMem` reports) |
| 16 | `gzProc` (GrowZoneUPP) | grow-zone proc — **note below** |
| 20 | `moreMast` (short) | master pointers allocated at a time (32 system / 64 application by default) |
| 22 | `flags` (short) | internal |
| 24 | `cntRel` (short) | reserved |
| 26 | `maxRel` (short) | reserved |
| 28 | `cntNRel` (short) | reserved |
| 30 | `heapType` (SInt8) | was `maxNRel`; now flags (e.g. `k32BitHeap`) |
| 31 | `unused` (SInt8) | |
| 32 | `cntEmpty` (short) | reserved |
| 34 | `cntHandles` (short) | reserved |
| 36 | `minCBFree` (long) | reserved |
| 40 | `purgeProc` (PurgeUPP) | purge-warning proc, or NIL |
| 44 | `sparePtr` (Ptr) | internal |
| 48 | `allocPtr` (Ptr) | internal |
| 52 | `heapData` (short) | dummy — the first 2 bytes of the **first block header** in the zone |

Two things here matter to a heap sweep:

- **`heapData` at offset 52 is where a zone walk starts.**
  `&zone->heapData` is the address of the first usable byte; walk to
  `zone->bkLim`. Inside Macintosh spells this out.
- **`gzProc` is documented as not being yours.** IM: "in current
  versions of system software, this field does not contain a pointer to
  the grow-zone function that your application defines" — the system
  installs its own and chains. Worth knowing before reading it as an
  identity signal.
- The **structure of a heap zone is the same in 24-bit and 32-bit
  addressing modes**; only the meaning of some reserved/internal fields
  differs. Block headers are *not* the same — see below.

Zone pointers come from low memory: `SysZone` at **0x02A6**,
`ApplZone` at **0x02AA** (the header's inline glue for `SystemZone()` /
`ApplicationZone()` is literally `MOVE.L $02A6,-(SP)` /
`MOVE.L $02AA,-(SP)`). `static (this Mac)`, **DEMONSTRATES**,
**Confidence High**.

### Memory Manager block headers

`doc` — **DEMONSTRATES** (Inside Macintosh figures 2-1 and 2-2 plus
prose), **Confidence High** — with one **documented internal
contradiction**, flagged below.

Source: *Inside Macintosh: Memory*, chapter 2, "Block Headers", pp.
2-22–2-24 —
<https://developer.apple.com/library/archive/documentation/mac/pdf/Memory/Memory_Manager.pdf>
(HTML mirror index: <https://dev.os9.ca/techpubs/mac/Memory/Memory-202.html>)

All pointers and handles reference the **logical contents**, i.e. the
byte *after* the header. So a candidate pointer found in a heap sweep is
`blockStart + headerSize`.

**24-bit zone — 8-byte header:**

| Off | Field |
|---|---|
| 0 | tag byte |
| 1..3 | physical size of block (24 bits) |
| 4..7 | relative handle (relocatable) / address of block's zone (nonrelocatable) / undefined (free) |

Tag byte bits: **6–7 = block type**, 4–5 reserved, **0–3 = size
correction**.
Block type: `00` free, `01` nonrelocatable, `10` relocatable.
`physicalSize = logicalSize + sizeCorrection + 8`.

**32-bit zone — 12-byte header:**

| Off | Field |
|---|---|
| 0 | tag byte (bits 6–7 = block type; bits 0–5 reserved) |
| 1 | master pointer flag bits (only if relocatable; else undefined) |
| 2 | reserved |
| 3 | size correction |
| 4..7 | physical size of block |
| 8..11 | relative handle / address of block's zone |

Master-pointer flag byte: bit 7 locked, bit 6 purgeable, bit 5 contains
resource data.
`physicalSize = logicalSize + sizeCorrection + 12`.

Assembly summary constants (same chapter): `tyBkFree EQU 0`,
`tyBkNRel EQU 1`, `tyBkRel EQU 2`. Master-pointer high-byte flags:
`lock EQU 7`, `purge EQU 6`, `resource EQU 5`.

> **⚠ The document contradicts itself on one value.** In the body text
> for the 32-bit header: "the high-order 2 bits determine whether a block
> is free (binary 00), relocatable (binary **10**), or nonrelocatable
> (binary 01)". But **Figure 2-2's own legend** for the same field reads
> "00: Free block / 01: Nonrelocatable block / **11**: Relocatable
> block". The 24-bit figure (2-1) says `10`, and the assembly constant
> `tyBkRel EQU 2` says `10`. Three sources to one, so `10` is very
> likely right and the figure legend is a typo — **but a heap walker
> that hard-codes `== 0b10` and a machine that really uses `0b11` fail
> silently, skipping every relocatable block.** The live lane should
> read the tag byte of a known relocatable block and settle it.
> **Confidence Medium** that it is `10`; the disagreement is the finding.

Other block facts that bear on a sweep:

- **Minimum block size is 12 bytes**, free or allocated. A free
  fragment smaller than that is absorbed into the preceding allocation
  rather than returned to free storage.
- Allocation is in **even** byte counts; on 68020/030/040 blocks are
  padded to **4-byte** boundaries. (So a `CGrafPort` of 108 bytes needs
  no padding, but the surrounding arithmetic still uses the size
  correction.)
- Inside Macintosh explicitly warns that the "organization and size of
  heap zones and block headers is subject to change" — Apple's own
  hedge, and the reason P1 measures rather than quotes.

### What is *not* in Universal Interfaces 3.4

`static (this Mac)` — **DEMONSTRATES** (searched the whole `CIncludes`
tree), **Confidence High**.

the investigation plan's flag list names **`nativeEndianPixMap`** and this brief also
asked about **`createPalette`**. **Neither identifier exists anywhere in
UI 3.4's headers.** `QDOffscreen.h`'s only related remark is the
pointer "to allocate non-mac-rgb GWorlds use `QTNewGWorld`
(`ImageCompression.h`)". These are later Carbon / Mac OS X-era
additions. Treat them as **not available on an OS 9.1 InterfaceLib**
until the live lane says otherwise — a probe that passes such a bit
would be passing an undefined flag.

---

## 4a. The trap and selector map

`static (this Mac)` — **DEMONSTRATES**, **Confidence High**. Extracted
from the `ONEWORDINLINE`/`FOURWORDINLINE` glue in UI 3.4 headers, which
is the literal 68K instruction sequence Apple shipped for each call.

This is the 68K-side ground truth for what a trap patch could grab.

### Offscreen graphics: `_QDExtensions` = **$AB1D**, selector in D0

The encoding is `MOVE.L #(paramBytes<<16 | selector), D0` then `$AB1D`.

| Selector | Call | Param bytes |
|---|---|---|
| 0x0000 | `NewGWorld` | 0x16 (22) |
| 0x0001 | `LockPixels` | 0x04 |
| 0x0002 | `UnlockPixels` | 0x04 |
| 0x0003 | `UpdateGWorld` | 0x16 (22) |
| 0x0004 | `DisposeGWorld` | 0x04 |
| 0x0005 | `GetGWorld` | 0x08 |
| 0x0006 | `SetGWorld` | 0x08 |
| 0x0007 | `CTabChanged` | 0x04 |
| 0x0008 | `PixPatChanged` | 0x04 |
| 0x0009 | `PortChanged` | 0x04 |
| 0x000A | `GDeviceChanged` | 0x04 |
| 0x000B | `AllowPurgePixels` | 0x04 |
| 0x000C | `NoPurgePixels` | 0x04 |
| 0x000D | `GetPixelsState` | 0x04 |
| 0x000E | `SetPixelsState` | 0x08 |
| 0x000F | `GetPixBaseAddr` | 0x04 |
| 0x0010 | `NewScreenBuffer` | 0x0E |
| 0x0011 | `DisposeScreenBuffer` | 0x04 |
| 0x0012 | `GetGWorldDevice` | 0x04 |
| 0x0013 | `QDDone` | 0x04 |
| 0x0014 | `OffscreenVersion` | (`MOVEQ #$14,D0`) |
| 0x0015 | `NewTempScreenBuffer` | 0x0E |
| 0x0016 | `PixMap32Bit` | 0x04 |
| 0x0017 | `GetGWorldPixMap` | 0x04 |
| 0x0018 | `GetPixRowBytes` | 0x04 |

Note there is **no `PixMapChanged` selector** — the investigation plan names it; the
header's call is **`PixPatChanged`** (0x0008), alongside `CTabChanged`,
`PortChanged` and `GDeviceChanged`. Worth correcting before a probe goes
looking for it.

### QuickDraw drawing traps (single-word A-traps)

| Trap | Call |
|---|---|
| $A8EC | **`CopyBits`** |
| $A817 | `CopyMask` |
| $AA51 | `CopyDeepMask` |
| $A8EA | `SetStdProcs` |
| $AA4E | `SetStdCProcs` |
| $A882 | `StdText` |
| $A890 | `StdLine` |
| $A8A0 | `StdRect` |
| $A8AF | `StdRRect` |
| $A8B6 | `StdOval` |
| $A8BD | `StdArc` |
| $A8C5 | `StdPoly` |
| $A8D1 | `StdRgn` |
| $A8EB | **`StdBits`** |
| $A8ED | `StdTxMeas` |
| $A8EE | `StdGetPic` |
| $A8F0 | `StdPutPic` |
| $A8F1 | `StdComment` |
| $A8F6 | `DrawPicture` |
| $A8EF | `ScrollRect` |
| $A838 | `CalcMask` |
| $A839 | `SeedFill` |
| $AA00 | `OpenCPort` |
| $AA01 | `InitCPort` |
| $AA02 | `CloseCPort` |
| $A86F | `OpenPort` |
| $A86D | `InitPort` |
| $A87D | `ClosePort` |
| $A874 | `GetPort` |
| $AA2D | `SetDeviceAttribute` |
| $AA2E | `InitGDevice` |
| $AA2F | `NewGDevice` |
| $AA31 | `SetGDevice` |
| $AA32 | `GetGDevice` |
| $AA40 | `QDError` |

Every one of the ten standard bottleneck procs has its **own A-trap**.
That is a second, independent interception surface alongside a port's
`grafProcs` pointer, and it is worth being explicit that they are not
the same surface: patching `$A8EB` catches calls that *reach* `StdBits`;
installing a `bitsProc` catches calls dispatched *through a particular
port*.

### Icon drawing: `_IconDispatch` = **$ABC9**, selector in D0 high word

The encoding here is `MOVE.W #(paramWords<<8 | selector), D0` then
`$ABC9`.

| Selector | Call |
|---|---|
| 0x01 | `GetIconSuite` |
| 0x02 | `DisposeIconSuite` |
| **0x03** | **`PlotIconSuite`** |
| 0x04 | `MakeIconCache` |
| 0x05 | `PlotIconMethod` |
| 0x06 | `LoadIconCache` |
| 0x07 | `NewIconSuite` |
| 0x08 | `AddIconToSuite` |
| 0x09 | `GetIconFromSuite` |
| 0x0A | `ForEachIconDo` |
| **0x00** | **`PlotIconID`** (`MOVE.W #$0500,D0`) |
| 0x1D | `PlotIconHandle` |
| 0x1E | `PlotSICNHandle` |
| 0x1F | `PlotCIconHandle` |
| 0x13/0x14/0x15 | `IconIDToRgn` / `IconSuiteToRgn` / `IconMethodToRgn` |

Older, non-dispatched icon traps: **`PlotIcon` = $A94B**,
**`PlotCIcon` = $AA1F**, `GetCIcon` = $AA1E, `DisposeCIcon` = $AA25,
`GetIcon` = $A9BB.

Icon **Services** (the `IconRef` API, System 8.5+) is a *different*
trap: **`_IconServicesDispatch` = $AA75**, with `PlotIconRef` at
selector **0x000E**. So there are **three** generations of icon plotting
with three different interception points — `$A94B`/`$AA1F`,
`$ABC9`, and `$AA75`. A recorder that hooks only one generation will
miss whichever the Finder actually uses. This bears directly on P5.

---

## 3. Native PowerPC QuickDraw versus the 68K trap table

This is the section that decides whether a resident 68K extension can
intercept anything a modern app draws. The definitive part is below;
see also the researched material further down.

### What our own guests emit — the crux, established here

`static (this Mac)` — **DEMONSTRATES**, **Confidence High**.

The same source file (calling `NewGWorld`, `GetGWorldPixMap`,
`LockPixels`, `CopyBits`, `SetStdCProcs`, `DisposeGWorld`) was compiled
with both toolchains and disassembled.

**68K guest (`m68k-apple-macos-gcc`)** — the calls compile to **raw
inline A-traps**, with **zero undefined symbols**:

```
203c 0016 0000   movel #$00160000,%d0
ab1d             _QDExtensions          ; NewGWorld
...
a8ec             _CopyBits
aa4e             _SetStdCProcs
203c 0004 0004
ab1d             _QDExtensions          ; DisposeGWorld
```

**PPC guest (`powerpc-apple-macos-gcc`)** — the same calls compile to
**CFM cross-fragment calls**, and the object file's undefined symbols
are exactly:

```
U .CopyBits   U .DisposeGWorld   U .GetGWorldPixMap
U .LockPixels U .NewGWorld       U .SetStdCProcs
```

Each `bl` is followed by the `nop` TOC-restore slot that marks an
inter-fragment call. **There is not one A-trap instruction anywhere in
the PPC object.**

So the shape of the answer is settled even before we know what
InterfaceLib does internally:

> A native PPC application **never executes the QuickDraw A-trap
> itself**. It calls an InterfaceLib export. Whether a 68K trap patch
> sees that call depends **entirely on whether InterfaceLib's
> implementation of that export goes on to execute the trap** — which is
> a property of the OS, not of the application, and is exactly what the
> live lane must measure.

This also means the two guests sit on **opposite sides** of the
question: NOW-68K's own drawing is patchable by definition; the Carbon
PPC guest's is not, unless InterfaceLib routes through the trap.

The corresponding **`grafProcs` surface is unaffected by any of this** —
a `bitsProc` installed in a port is consulted by whatever code
implements the drawing, native or emulated. That is consistent with what
the probe arc already measured live (`docs/open-issues.md`: offscreen
drawing *does* consult `grafProcs`), and it is the reason the content
plane rests on bottlenecks rather than on trap patches.

---

### QuickDraw *is* native PowerPC — and that does not take it off the trap table

`doc` — **DEMONSTRATES** (Apple primary, verbatim), **Confidence High**.

The intuitive assumption ("QuickDraw stayed 68K, so trap patches work") is
**wrong on the first clause and accidentally right on the second**.

> "QuickDraw is one of the system software services that has been ported
> to native PowerPC code."
> — *Inside Macintosh: PowerPC System Software*, Ch. 1, p. 1-59

QuickDraw has been native PPC since **System 7.1.2 (1994)**, the first
Power Macs. But native does **not** mean off-trap. For a natively
implemented routine, the trap dispatch table entry holds **a pointer to a
routine descriptor**, whose first field is an executable 68K instruction
that invokes the Mixed Mode Manager. The table was deliberately kept so
that existing trap-patching extensions kept working.

Source: <https://developer.apple.com/library/archive/documentation/mac/pdf/PPC_System_Software/Intro_to_PowerPC.pdf>
(mirror: <https://dev.os9.ca/techpubs/mac/PPCSoftware/PPCSoftware-18.html>)

### The InterfaceLib export is trap glue

`doc` — **DEMONSTRATES**, **Confidence High**.

> "When a native application calls a system software routine, the
> Operating System executes some glue code in an import library of
> executable code. The glue code inspects the trap dispatch table for the
> address of the called routine. If the called routine exists only as
> 680x0 code, the Mixed Mode Manager switches modes and calls the 680x0
> routine."
> — *ibid.*, p. ~1-15

Apple publishes the worked shape of that glue (Listing 2-1, Mixed Mode
Manager chapter): `NGetTrapAddress(_TextWidth, ToolTrap)` followed by
`CallUniversalProc(...)`. TN1127 "In Search of Missing Links" teaches
developers to hand-write the identical pattern for APIs InterfaceLib
omits — i.e. it reconstructs InterfaceLib's own idiom.
<https://developer.apple.com/library/archive/technotes/tn/tn1127.html>

**So the InterfaceLib stub reads the trap table at call time**, which
means a patch installed there is picked up.

The strongest corroboration is that Apple warns about the *cost* of
exactly this path:

> "if you patch the PowerPC code with 680x0 code, the Mixed Mode Manager
> needs to intervene to switch the execution environments both when
> entering and when exiting your patch code. This switching results in a
> considerable overhead (approximately 15 microseconds on a 60 MHz
> PowerPC processor per round-trip mode switch...)"
> — *ibid.*, p. 1-66

That sentence is only coherent if a native PPC caller's call does run
through a 68K patch in the trap table.

### The two documented escapes

**1. Split traps.** `doc` — **DEMONSTRATES**, **Confidence High**.

> "the system software includes a small number of split traps, system
> software routines that are implemented with 680x0 code (usually in ROM)
> and as PowerPC code in an import library. Because the PowerPC code is
> contained directly in the import library, you cannot patch the PowerPC
> portion of a split trap... For example, a number of very small utility
> routines like **AddPt** and **SetRect** are implemented as split traps."
> — *ibid.*, p. 1-67

Both named examples are QuickDraw calls. Apple's stated selection
criterion ("very small utility routines") argues `CopyBits` is *not* one —
it is large and an obvious patch target — **but no authoritative list of
split traps was found.** Open item.

**2. Selector-based traps cannot carry PPC or fat patches at all** — only
68K patches. In the 68K world you patch one selector and chain the rest;
in the PPC world you cannot, and you cannot know how many selectors
exist. Core drawing calls like `CopyBits` are single-word traps, but
**everything in `_QDExtensions` ($AB1D) and `_IconDispatch` ($ABC9) is
selector-dispatched** — which is precisely the GWorld and icon surface
this arc cares about.

### ⚠ The CarbonLib hole — and it is ours

`static (this Mac)` + `doc` — **Confidence Medium**, and this is the
single most consequential unknown in the file.

Every primary source above is 1994–95, describing **InterfaceLib**.
Nothing found establishes what **CarbonLib** does under Mac OS 9.1.
Carbon was designed as a source-compatible layer that also runs on Mac OS
X, **where no trap table exists at all** — so there is a real risk that
CarbonLib implements or forwards natively and never consults the trap
table.

This is not hypothetical for us. Checking the guest's own build:

- `now-guest-ppc/CMakeLists.txt:263` does
  `target_link_libraries(now-guest-ppc PRIVATE "${NOW_CARBONLIB_341}")`.
- The toolchain compiles it with `TARGET_API_MAC_OS8=1` and
  `TARGET_API_MAC_CARBON=0` (classic headers, `OLDPIXMAPSTRUCT=1`), the
  Retro68 "retrocarbon" hybrid.
- **Both** `libInterfaceLib.a` **and** `libCarbonLib.a` in the toolchain
  export `.CopyBits`, `.NewGWorld` and `.StdBits`:

```
universal/libppc/libInterfaceLib.a:  T .CopyBits  T .NewGWorld  T .StdBits
universal/libppc/libCarbonLib.a:     T .CopyBits  T .NewGWorld  T .StdBits
```

So **which fragment our guest's QuickDraw imports actually resolve
against depends on link order**, and the explicit `libCarbonLib.a` is
added as a `PRIVATE` link library alongside the spec's default
`-lInterfaceLib`. This is answerable **statically, today**, by dumping
the import table of the built PEF and reading which fragment each
QuickDraw symbol names. It should be, because the answer changes what a
resident trap patch can see.

---

## 1. GWorld internals

`doc` — sourced primarily from *Inside Macintosh: Imaging With QuickDraw*,
Ch. 6 "Offscreen Graphics Worlds" —
<https://developer.apple.com/library/archive/documentation/mac/pdf/Imaging_With_QuickDraw/Offscreen_Graphics_Worlds.pdf>
(mirrors: <https://dev.os9.ca/techpubs/mac/QuickDraw/QuickDraw-311.html>,
<https://dev.os9.ca/techpubs/mac/QuickDraw/QuickDraw-331.html>)

> **Method warning worth carrying forward.** The researcher on this
> section reported that two automated page-summaries returned
> **fabricated "verbatim quotes"** from the Apple PDF, and were discarded
> in favour of reading the rendered pages. Treat any second-hand
> paraphrase of Inside Macintosh — including summaries produced by
> tooling — as suspect until checked against the page.

### What `NewGWorld` constructs

```c
pascal QDErr NewGWorld(GWorldPtr *offscreenGWorld, short pixelDepth,
                       const Rect *boundsRect, CTabHandle cTable,
                       GDHandle aGDevice, GWorldFlags flags);
```

It builds (**ASSERTS**, **High**, IM pp. 6-5, 6-18–6-20):

- an offscreen **graphics port** — a `CGrafPort` (on basic-QD machines, a
  `GrafPort` extension);
- an offscreen **`PixMap`**, reached as a `PixMapHandle`;
- **either a new offscreen `GDevice` or a link to an existing one**;
- a **copy** of the supplied `ColorTable` — "NewGWorld makes a copy of the
  record and stores its handle in the offscreen PixMap record" (p. 6-20).
  The caller's table is not retained;
- the **base address handle** for the pixel image, via `NewScreenBuffer`
  (or `NewTempScreenBuffer` when `useTempMem` is set).

The initialization sequence is stated explicitly (p. 6-19):

1. **calls `OpenCPort`** to initialize the port;
2. sets the port's **`visRgn` to a rectangular region coincident with its
   boundary rectangle**;
3. **generates an inverse table with `MakeITable`** — *unless* a screen's
   `GDevice` already has the same colour table, in which case it reuses
   that inverse table.

Pixel image size: `rowBytes * (bounds.bottom - bounds.top)` (p. 6-19).

Parameters:

- **`pixelDepth`** — 1/2/4/8/16/32. **`0` means "default"**: use the depth,
  colour table *and* `GDevice` of the deepest screen intersecting
  `boundsRect`, which is then interpreted in **global** coordinates. `0`
  therefore also suppresses creating a new `GDevice`, and **overrides
  `noNewDevice`**. Bad depth → `cDepthErr` (−157).
- **`boundsRect`** — becomes the PixMap's `bounds`, the port's `portRect`,
  the port's `visRgn`, *and* the `gdRect` if a `GDevice` is created. (The
  probe arc has already measured `portRect == bounds` live — consistent.)
- **`cTable`** — copied. `NIL` = default for the depth. **Ignored when
  `pixelDepth == 0`.**
- **`aGDevice`** — "used only when you specify the `noNewDevice` flag".
  IM: "Generally, your application should never create GDevice records
  for offscreen graphics worlds."
- **`flags`** — `NewGWorld` consumes only
  `pixPurge | noNewDevice | useTempMem | keepLocal` (p. 6-18).

Result codes: `noErr`, `paramErr` (−50), `cDepthErr` (−157),
`cNoMemErr` (−152).

### Is a `GWorldPtr` exactly a `CGrafPtr`? — **No.**

**The type is `CGrafPtr`; the object is bigger and carries private
trailing state.** **ASSERTS**, **Confidence High** for the existence of
the private state, **Low** for its layout.

> "An offscreen graphics world is defined by **a private data structure**
> that, in Color QuickDraw, contains a `CGrafPort` record and its handles
> to associated `PixMap` and `ColorTable` records. The offscreen graphics
> world also contains a reference to a `GDevice` record **and other state
> information**. On computers lacking Color QuickDraw, `GWorldPtr` points
> to an **extension of the `GrafPort` record**."
> — IM p. 6-3, immediately above `TYPE GWorldPtr = CGrafPtr;`

p. 6-12 repeats it and gives the reason: "kept private to allow for
future extensions." Apple *develop* #1 (Jan 1990), Guillermo Ortiz,
"Braving Offscreen Worlds", says the same in developer register: think of
the GWorld structure as **an extension to the CGrafPort structure**,
usable interchangeably with a `CGrafPtr` in most cases.
<http://preserve.mactech.com/articles/develop/issue_01/offscreen_worlds.html>

**Reimplementation reading**: "extension of the record" most naturally
means the private fields are **appended to the port in the same
non-relocatable block** — `NewPtr(sizeof(CGrafPort) + private)`.
**Medium, INFERRED from an assertion.** No source publishes the trailer's
offsets, size, or a signature field for real Mac OS.

This matters directly to the probe: **a heap sweep looking for blocks of
exactly `sizeof(CGrafPort)` = 108 bytes would miss every GWorld** if the
trailer shares the block. Sweeping for "block ≥ 108 with a valid
`portVersion` at +6" is the safer shape.

Apple's prohibitions, which are also hints about the mechanism
(**ASSERTS**, **High**):

- p. 6-9: "**You cannot dereference the `GWorldPtr` data structure to get
  to the pixel map.** The `baseAddr` field of the `PixMap` record for an
  offscreen graphics world contains a handle instead of a pointer... You
  must use the `GetPixBaseAddr` function."
- p. 6-31: "do not dereference the `GWorldPtr` record" — use
  `GetGWorldPixMap`.
- p. 6-38: "Your application should never directly access the `baseAddr`
  field."

**Source disagreement.** develop #1 (1990, Apple DTS) writes
`fDrawingPort^.portPixMap` directly; IM (1994) forbids it. IM wins for a
9.1 target — but the older idiom is why real 9.x software still does it,
so a reimplementation **must keep `portPixMap` valid and equal to what
`GetGWorldPixMap` returns**. `GetGWorldPixMap` did not exist before
System 7 (IM p. 6-32), which is why the idiom existed at all.

### How does the system recognise a `CGrafPtr` as a GWorld?

**This is the highest-value unknown in the whole GWorld section**, because
both `SetGWorld` and `GetGWorldDevice` branch on it at runtime.

- **Executor's answer is Executor's own.** It stamps
  `CPORT_VERSION(port) |= GW_FLAG_BIT` with `GW_FLAG_BIT == 1`, so
  `GWorld_p(port)` is `CGrafPort_p(port) && (portVersion & 1)`, where
  `CGrafPort_p` tests `((char*)port)[6] & 0xC0) == 0xC0` — the same
  offset-6 discriminator documented above. i.e. Executor uses
  `portVersion == 0xC001` to mean GWorld.
  **DEMONSTRATES for Executor; establishes nothing about Apple.**
- **No source confirms real Mac OS uses `portVersion` bit 0**, or a
  `gdRefNum` sentinel, or `grafVars`, or a side table.

**Confidence Low** on the real mechanism. Flagged for the live lane —
this is cheap to measure (allocate a GWorld, read the word at +6).

### Flag values

From `QDOffscreen.h`. **Note the version split** — the table below is the
**Mac OS X 10.5 SDK** header; the columns marked ✗ are **absent from
Universal Interfaces 3.4** (verified locally, see §4).

| Constant | Bit | Value | In UI 3.4? |
|---|---|---|---|
| `pixPurge` | 0 | 0x00000001 | ✓ |
| `noNewDevice` | 1 | 0x00000002 | ✓ |
| `useTempMem` | 2 | 0x00000004 | ✓ |
| `keepLocal` | 3 | 0x00000008 | ✓ |
| `useDistantHdwrMem` | 4 | 0x00000010 | ✓ |
| `useLocalHdwrMem` | 5 | 0x00000020 | ✓ |
| `pixelsPurgeable` | 6 | 0x00000040 | ✓ |
| `pixelsLocked` | 7 | 0x00000080 | ✓ |
| `kNativeEndianPixMap` | 8 | 0x00000100 | **✗** |
| `kAllocDirectDrawSurface` | 14 | 0x00004000 | ✓ |
| `mapPix` | 16 | 0x00010000 | ✓ |
| `newDepth` | 17 | 0x00020000 | ✓ |
| `alignPix` | 18 | 0x00040000 | ✓ |
| `newRowBytes` | 19 | 0x00080000 | ✓ |
| `reallocPix` | 20 | 0x00100000 | ✓ |
| `clipPix` | 28 | 0x10000000 | ✓ |
| `stretchPix` | 29 | 0x20000000 | ✓ |
| `ditherPix` | 30 | 0x40000000 | ✓ |
| `gwFlagErr` | 31 | 0x80000000 | ✓ |

**Two independent lines of evidence now agree that `nativeEndianPixMap`
is not available on OS 9.1**: it is absent from UI 3.4 (the CarbonLib-era
header set, verified by search here), and the 10.5 header's own note says
only `noNewDeviceBit` and `nativeEndianPixMapBit` survive on Mac OS X —
framing it as an OS X-relevant flag. **`createPalette` does not exist as
a `GWorldFlags` constant anywhere**; two independent searches found
nothing. Treat both as unavailable.

**Source disagreement, and it favours the header.** IM (1994) lists bits
4, 5 and 8–15 as `gWorldFlag4`…`gWorldFlag15`, **"Reserved"** (pp.
6-13/6-14, 6-40/6-41). Bits 4/5 and 14 were assigned later. Apple's
"New_NewGWorld" sample dates the hardware-memory flags to **Mac OS 9+**,
on iBooks, slot-loading iMacs and AGP G4s: `useLocalHdwrMem` = VRAM,
`useDistantHdwrMem` = AGP memory, default = system memory. **Medium,
ASSERTS** (sample introduction text only).
<https://developer.apple.com/library/archive/samplecode/New_NewGWorld/Introduction/Intro.html>

### Where each allocation lands

**The key structural fact: `pixPurge`, `useTempMem`, `keepLocal` and the
hardware-memory flags govern the *pixel image base address only*** — not
the port, PixMap, ColorTable or GDevice. **ASSERTS**, **High**.

The routine split is the evidence: `NewScreenBuffer` "create[s] an
offscreen PixMap record and allocate[s] memory for the base address of
its pixel image"; `NewTempScreenBuffer` "performs the same functions...
except that it creates the base address for the offscreen pixel image in
temporary memory. When an application passes it the `useTempMem` flag,
`NewGWorld` uses `NewTempScreenBuffer` instead of `NewScreenBuffer`."

This **corroborates a live measurement already in hand** — the probe arc
recorded that `useTempMem` moves only the pixels
(`docs/open-issues.md`). Documentation and machine agree.

- **Default (flags = 0)**: unpurgeable base address, **in your
  application heap**; creates a new `GDevice` (or uses an existing one if
  `pixelDepth == 0`); allows graphics accelerators to cache the image.
  (IM pp. 6-7, 6-18.)
- **`pixPurge`**: pixel image in a **purgeable** block. You must
  `LockPixels` and check for `TRUE` before every use; on `FALSE`,
  `UpdateGWorld` to reallocate and then **reconstruct the contents** —
  "Never draw to or copy from an offscreen pixel image that has been
  purged without reallocating its memory and then reconstructing it."
- **`noNewDevice`**: uses the `GDevice` in `aGDevice` and its depth and
  colour table. `pixelDepth == 0` **overrides this**. "NewGWorld keeps a
  reference to the GDevice record... and `SetGWorld` uses that record to
  set the current graphics device."
- **`useTempMem`**: base address in **temporary memory** (Process
  Manager / MultiFinder unallocated space via `TempNewHandle` — **Medium,
  INFERRED**; IM Ch. 6 only says "temporary memory"). Apple's own
  warning: "You generally should not use this flag. You should use
  temporary memory only for fleeting purposes and only with
  `AllowPurgePixels`... so that other applications can launch."
- **`keepLocal`**: pixel image in Macintosh main memory where it **cannot
  be cached to a graphics accelerator**. On `UpdateGWorld` it also *pulls
  back* an already-cached image (p. 6-25).
- **`pixelsLocked` / `pixelsPurgeable`** are **not** `NewGWorld` inputs in
  IM — they are the `GetPixelsState`/`SetPixelsState` pair. (Executor
  tolerantly honours `pixelsLocked` at `NewGWorld` by calling
  `LockPixels` at the end; undocumented.)

### The pixel lifecycle — the load-bearing internal fact

**ASSERTS**, **High** (IM pp. 6-9, 6-32, 6-33, 6-38):

> "The `baseAddr` field of the `PixMap` record for an offscreen graphics
> world **contains a handle instead of a pointer**... `LockPixels`
> **dereferences the PixMap handle into a pointer**. When you use
> `UnlockPixels`... **the handle is recovered**."

So `PixMap.baseAddr` (offset 0) means **two different things** depending
on lock state. Any probe reading `baseAddr` out of a swept port must know
which. This is very likely relevant to the probe arc's chase failures.

- `LockPixels` returns `TRUE` if not purged / not purgeable; `FALSE` if
  purged, and then "you can perform no drawing to or copying from the
  pixel map".
- "You don't need to call `UnlockPixels` if `LockPixels` returns
  `FALSE`... However, calling `UnlockPixels` on purged memory does no
  harm."
- `AllowPurgePixels`: "**Only unlocked memory blocks can be made
  purgeable.**" `NewGWorld`'s default is unpurgeable.
- `SetPixelsState` **unlocks before making purgeable** — explicitly:
  "Because only an unlocked memory block can be purged, `SetPixelsState`
  calls `UnlockPixels` and `AllowPurgePixels`... if the state parameter
  specifies `pixelsPurgeable`." Executor does purge-then-lock, the
  opposite order — **a genuine divergence; IM wins.**
- `GetPixBaseAddr` returns **`NIL` if the buffer has been purged**, and
  "Any QuickDraw routines that your application uses after calling
  `GetPixBaseAddr` may change the base address" — re-fetch after anything
  that can move memory.
- `PixMap32Bit` reports whether 32-bit addressing mode is needed to touch
  the image.

**What happens if you draw with pixels unlocked?** Apple never states the
failure mode. Mechanically, `baseAddr` holds a handle, so a blitter that
trusts it writes through a master-pointer address as though it were a
pixel address. **High confidence on the mechanism, Medium that real 9.1
QuickDraw does not internally lock as a safety net** — no Apple statement
either way. Open item.

Executor implements **nested locks** (`pixel_lock_count`); Apple
documents no counting. Treat lock nesting as an implementation choice.

### `UpdateGWorld`

```c
GWorldFlags UpdateGWorld(GWorldPtr *offscreenGWorld, short pixelDepth,
                         const Rect *boundsRect, CTabHandle cTable,
                         GDHandle aGDevice, GWorldFlags flags);
```

Accepts `keepLocal | clipPix | stretchPix | ditherPix`. Apple: "you
should pass either `clipPix` or `stretchPix` to ensure that the pixel map
is updated to reflect the new color table." A non-`NIL` `aGDevice` makes
`pixelDepth` and `cTable` ignored.

Returns `gwFlagErr` **alone** on failure ("the offscreen graphics world
is left unchanged"; use `QDError`). On success, a combination of
`mapPix`, `newDepth`, `alignPix`, `newRowBytes`, `reallocPix`, `clipPix`,
`stretchPix`, `ditherPix`.

The documented algorithm (pp. 6-25/6-26) — this is the reimplementation
spec, **ASSERTS**, **High**:

1. new/different colour table → map pixel values to the new table;
2. different `pixelDepth` → translate pixel values to the new depth;
3. `boundsRect` **different but same size** → realign the pixel image to
   the screen, for `CopyBits` performance;
4. smaller + `clipPix` → clip along **bottom and right** edges;
5. bigger + `clipPix` → **bottom and right edges undefined**;
6. smaller + `stretchPix` → reduce to new size;
7. bigger + `stretchPix` → stretch to new size;
8. if the Memory Manager purged the base address → "**reallocates the
   memory, but the pixel image is lost. You must reconstruct it.**"

develop #1 adds the reading that `flags == 0` means "I know what I am
doing — don't update the pixels for me."

### `DisposeGWorld`

> "disposes of all the memory allocated for the offscreen graphics
> world... including its **pixel map, color table, pixel image, and
> GDevice record (if one was created)**."
> "If this offscreen graphics world was the current device, the current
> device is reset to the device stored in the global variable
> `MainDevice`."
> — IM pp. 6-26/6-27

**Apple states *what* is unwound, never the *order*.** The only ordering
given is the `MainDevice` restoration. **Order is an open item.**

Executor's order (**DEMONSTRATES**, one implementation, not Apple's):
reset `thePort` to `WMgrPort` if it was the GWorld → dispose the
pixel-image handle (recovering it via `RecoverHandle` first if pixels are
locked, because `baseAddr` then holds a dereferenced pointer) →
`DisposeGDevice` **only if this GWorld allocated it** → `ClosePort` →
`DisposePtr` the port → free the side record. Note Executor resets the
*port*; Apple resets the *device*.

Related and worth copying: for `QTNewGWorldFromPtr`-created worlds, "its
pixel data is not disposed as QuickTime does not know how the pixel data
was originally allocated" (Apple Q&A QA1007) — a good reason for the
private record to carry an **"owns the buffer"** bit.
<https://leopard-adc.pepas.com/qa/qa2001/qa1007.html>

### Handle or pointer?

- **The port is a pointer, not a handle.** `GWorldPtr = CGrafPtr`, every
  API takes it by value, IM never mentions locking a GWorld, and Executor
  allocates it with `NewPtr`. **High.**
- **The PixMap is a handle** (`PixMapHandle`), obtained via
  `GetGWorldPixMap`. On a basic-QD machine it is a **1-bit** pixel map,
  legal for the offscreen routines but not to be handed to Color
  QuickDraw routines (pp. 6-8, 6-31).
- **The pixel image is a handle in `PixMap.baseAddr` while unlocked, a
  raw pointer while locked.**
- Everything except the pixel image is documented only ever as living in
  the **application heap**. Every routine in the chapter carries the
  warning "may move or purge memory blocks in the application heap; your
  application should not call this at interrupt time." **High for the
  pixel image, Medium for port/PixMap/GDevice** — Apple asserts the
  default but never says the other structures are immune to `useTempMem`;
  the `NewScreenBuffer`/`NewTempScreenBuffer` split is what makes the
  immunity reading strong. The probe arc's live measurement (port in the
  application zone) agrees.

### `GetGWorld` / `SetGWorld`

`GetGWorld(&port, &gdh)` replaces `GetPort` **and** `GetGDevice`
together. The `port` out-parameter "can return values of type `GrafPtr`,
`CGrafPtr`, or `GWorldPtr`".

`SetGWorld(port, gdh)` — "**unless you set the current graphics port to be
an offscreen graphics world** — sets the current device to that specified
by `gdh`." And: "If you pass a pointer to an offscreen graphics world in
the `port` parameter, set this parameter to `NIL`, because `SetGWorld`
ignores this parameter and sets the current device to the device attached
to the offscreen graphics world."

IM p. 6-8 mandates: "Instead of using `GetPort` and `SetPort` for saving
and restoring offscreen graphics worlds, you must use `GetGWorld` and
`SetGWorld`."

`GetGWorldDevice` is the second observable place the discrimination
happens: "If you point to a `GrafPort` or `CGrafPort` record in the
`offscreenGWorld` parameter, `GetGWorldDevice` returns the current
device."

The trap/selector table from IM p. 6-46 **matches the one derived from
the headers in §4a exactly**, in every selector and parameter-byte count
— two independent derivations agreeing.

Executor also records a black-box observation worth reproducing: if
Executor allocates the GDevice, the GDevice's baseAddr is the graphics
world's locked handle; if the caller passes the GDevice in, the pixmap
gets its own handle. **DEMONSTRATES** (ARDI's testing of real Mac OS).

---

## 2. The bottleneck mechanism

The richest section after §5, and the one where the documentation is most
misleading — not wrong, but silent in exactly the places that matter.
Most of what follows is from Apple's **1984 QuickDraw source** (the
legitimate Computer History Museum release), which is decisive about the
historical mechanism and **is not proof about 9.1**.

### The records and the standard routines

`QDProcs` is 13 pointers / 52 bytes; `CQDProcs` is 20 / 80 (offsets in
§4). Each field has a standard routine, and **each standard routine has
its own A-trap** — a second interception surface alongside the vector:

| # | Off | Field | Standard routine | Trap |
|---|---|---|---|---|
| 1 | 0 | `textProc` | `StdText` | `$A882` |
| 2 | 4 | `lineProc` | `StdLine` | `$A890` |
| 3 | 8 | `rectProc` | `StdRect` | `$A8A0` |
| 4 | 12 | `rRectProc` | `StdRRect` | `$A8AF` |
| 5 | 16 | `ovalProc` | `StdOval` | `$A8B6` |
| 6 | 20 | `arcProc` | `StdArc` | `$A8BD` |
| 7 | 24 | `polyProc` | `StdPoly` | `$A8C5` |
| 8 | 28 | `rgnProc` | `StdRgn` | `$A8D1` |
| 9 | **32** | **`bitsProc`** | **`StdBits`** | **`$A8EB`** |
| 10 | 36 | `commentProc` | `StdComment` | `$A8F1` |
| 11 | 40 | `txMeasProc` | `StdTxMeas` | `$A8ED` |
| 12 | 44 | `getPicProc` | `StdGetPic` | `$A8EE` |
| 13 | 48 | `putPicProc` | `StdPutPic` | `$A8F0` |

Signatures worth having in one place:

```c
void  StdText   (short count, const void *textBuf, Point numer, Point denom);
void  StdLine   (Point newPt);
void  StdRect   (GrafVerb verb, const Rect *r);
void  StdRRect  (GrafVerb verb, const Rect *r, short ovalWidth, short ovalHeight);
void  StdOval   (GrafVerb verb, const Rect *r);
void  StdArc    (GrafVerb verb, const Rect *r, short startAngle, short arcAngle);
void  StdPoly   (GrafVerb verb, PolyHandle poly);
void  StdRgn    (GrafVerb verb, RgnHandle rgn);
void  StdBits   (const BitMap *srcBits, const Rect *srcRect, const Rect *dstRect,
                 short mode, RgnHandle maskRgn);
void  StdComment(short kind, short dataSize, Handle dataHandle);
short StdTxMeas (short byteCount, const void *textAddr, Point *numer, Point *denom,
                 FontInfo *info);
void  StdGetPic (void *dataPtr, short byteCount);
void  StdPutPic (const void *dataPtr, short byteCount);
```

`GrafVerb = (frame, paint, erase, invert, fill)`.

**Note `StdBits` has no `dstBits` parameter** — it always draws into
`thePort->portBits`. That single fact drives most of what follows,
including why `CopyMask` structurally cannot go through it.

Doc trap: IM spells it **`StdTxtMeas`** in one place and **`StdTxMeas`**
in another; the exported symbol is **`StdTxMeas`**.

**IM and the shipping header disagree about `CQDProcs` fields 15–17, and
the header wins.** IM (1994) documents `newProc1`…`newProc6` as
"Reserved for future use"; Universal Interfaces names three of them:
`newProc1` = **the `StdPix` bottleneck**, `glyphsProc` (was `newProc2`,
Unicode text), `printerStatusProc` (was `newProc3`). **Any
reimplementation working from IM alone gets three fields wrong.**
<https://dev.os9.ca/techpubs/mac/QuickDraw/QuickDraw-209.html>

`glyphsProc` takes an **opaque byte stream** (`OSStatus (*)(void
*dataStream, ByteCount size)`) — no port, rect, mode or bitmap. It is a
data-handoff hook, not a rasterizer bottleneck, and arrives with
QuickDrawText 8.5. What the stream contains and who calls it is
**undocumented anywhere found**.

### Which high-level calls funnel where

Apple states the shape rule once and it generalises: "the `FrameOval`,
`PaintOval`, `EraseOval`, `InvertOval`, and `FillOval` procedures all call
the low-level procedure `StdOval`."
<https://dev.os9.ca/techpubs/mac/QuickDraw/QuickDraw-178.html>

So Frame/Paint/Erase/Invert/Fill × {Rect, RoundRect, Oval, Arc, Poly,
Rgn} → one proc per shape, operation carried in `GrafVerb`. **`FillX`
additionally stashes the pattern in `fillPat`/`fillPixPat` first**,
because the low-level proc reads it from the port, not from a parameter.

The canonical dispatcher, from Apple's `Text.a` — this is the shape of
*every* bottleneck call, and worth reading once:

```
CallText  MOVE.L  GRAFGLOBALS(A5),A0
          MOVE.L  THEPORT(A0),A0
          MOVE.L  GRAFPROCS(A0),D0     ;IS GRAFPROCS NIL ?
          LEA     STDTEXT,A0
          BEQ.S   USESTD               ;YES, USE STD PROC
          MOVE.L  D0,A0
          MOVE.L  TEXTPROC(A0),A0      ;NO, GET PROC PTR
USESTD    JMP     (A0)                 ;GO TO IT
```
<https://raw.githubusercontent.com/jrk/QuickDraw/master/Text.a> —
**DEMONSTRATES**, **Confidence High** (for 1984).

### ★ The dispatch table — what actually reaches `bitsProc`

**This is the correction that matters most, and three implementations
agree on it.**

| Caller | Reaches `bitsProc`? |
|---|---|
| `CopyBits`, dst **is** thePort's map | **Yes** |
| `CopyBits`, **any other** dst | **No** — direct `StretchBits` |
| `CopyMask` | **No** — never reads `grafProcs` |
| `CopyDeepMask` | **No** — same path |
| `ScrollRect`, basic QD | **No** (`RgnBlt`) |
| `ScrollRect`, **Color** QD | **Yes**, via an internal `_COPYBITS` |
| `DrawPicture` bits opcodes | **Yes** |
| `StdPix` (compressed PICT) | **Yes**, after decompression |
| `PlotCIcon` | **No** (shares `CopyMask`'s body) |
| `PlotIconSuite` &co. | **Conditional — see below** |
| **Text** (`StdText`) | **No** |

Apple's own comments in `Bitmaps.a` state the `CopyBits` condition
outright — and call `bitsProc` "the capture proc":

```
;  TEST IF DST IS TO THEPORT, (IF SO WE CLIP)
SRCOK   ... CMP.L BASEADDR(A1),D0        ;IS DST BASEADDR SAME ?
        BNE.S NOTPORT
        ... CMP.L BOUNDS(A1),D0          ;IS BOUNDS TOPLEFT SAME ?
        BEQ.S TOPORT                     ;YES, ITS PROBABLY TO THEPORT
;  DST IS DEFINITELY NOT TO THEPORT, SO WE CAN'T USE THE CAPTURE PROC.
NOTPORT ... JSR STRETCHBITS
;  DST IS PROBABLY TO THEPORT, SO WE USE THE CAPTURE PROC.
TOPORT  ... MOVE.L GRAFPROCS(A3),D0 ; ... MOVE.L BITSPROC(A0),A0
USESTD      JSR (A0)
```
<https://raw.githubusercontent.com/jrk/QuickDraw/master/Bitmaps.a> —
**DEMONSTRATES**, **High** (1984), **Medium** for 9.1.

Two Color-QD wrinkles worth reproducing:

- If `dst.baseAddr == ScrnBase` **and** the port's baseAddr == `RomBase`,
  it also takes `TOPORT` — comment: "IF BASEADDR = ROMBASE THEN GO
  THROUGH GRAFPROC TO MAKE PRINTING WORK".
- If the source is a PixMap, the port is an old `GrafPort`, and
  `bitsProc != JStdBits`, `CopyBits` first depth-converts the source to a
  temporary **1-bit BitMap** and calls the custom proc with *that*. So
  **a custom `bitsProc` on a basic GrafPort never sees a PixMap.**

**Independent documentary corroboration for the `CopyMask` row**: "Calls
to `CopyMask` are not recorded in pictures and do not print" (same for
`CopyDeepMask`). Picture recording lives *inside* `StdBits`, so "not
recorded" is exactly the signature of never reaching it. The full
non-recording list is `CopyMask`, `CopyDeepMask`, `SeedFill`,
`SeedCFill`, `CalcMask`, `CalcCMask`.
<https://dev.os9.ca/techpubs/mac/QuickDraw/QuickDraw-167.html>

**Correction to a widely-cited secondary source**: MacTech's *Fast Blit
Strategies* says "`StdBits()` ... is the low-level blit function that
`CopyBits()` ultimately vectors to." True **only** for the `TOPORT` case.

### `SetStdProcs` / `SetStdCProcs`, and what NIL really means

Both fill every field with the standard routines; you then overwrite the
ones you want and assign the whole record. **The table is replaced
wholesale** — MacTech: "the entire jump table ... can and indeed must be
replaced at once":

```c
CQDProcs qdNewProcs;                       /* MUST outlive the port */
SetStdCProcs(&qdNewProcs);
qdNewProcs.bitsProc = NewQDBitsUPP(CustomBlit);
SetPortGrafProcs(port, &qdNewProcs);       /* Carbon accessor */
```

A stack-local `CQDProcs` is the classic crash. And on a colour port you
must use `SetStdCProcs` — the records are 52 vs 80 bytes, and a
`QDProcs` installed in a `CGrafPort` gets read past its end.

**Does NIL short-circuit? Yes — and so does "standard".** Two mechanisms,
both worth building in:

1. **NIL → direct internal call, no vector** (the `BEQ.S USESTD / JMP
   (A0)` above). This is *why calling `StdBits` from inside your own
   `bitsProc` does not recurse* — the standard routine is a separate
   entry point, not a re-entry into the dispatcher.
2. **`SetStdProcs` copies live trap-table entries, and the dispatcher
   compares against them.** From `GrafAsm.a`:
   ```
   SetStdProcs PROC EXPORT
           MOVE.L  JStdText,(A1)+   ;copy piece of trap table
           ...
           MOVE.L  JStdBits,(A1)+   ;copy piece of trap table
   ```
   and `CopyBits` tests the installed `bitsProc` **against `JStdBits`** to
   decide whether it was *really* replaced. Executor reproduces the same
   semantic in portable C (`qHooks.cpp`):
   ```c
   if ((gp = thePort->grafProcs) && (pp = gp->bitsProc) != &StdBits)
       pp(...);          /* custom */
   else
       C_StdBits(...);   /* internal, no vector */
   ```

   **Two consequences.** A `SetStdCProcs` record with nothing changed
   costs nothing at runtime. And **a patch on the `$A8EB` `StdBits` trap
   is picked up by both the NIL path and unmodified `QDProcs` records** —
   which answers the "does NULL grafProcs short-circuit the trap"
   question in the useful direction: the `JStd*` trap-table indirection
   is still consulted.

**Carbon note, directly relevant to our guest.** Under
`OPAQUE_TOOLBOX_STRUCTS` you cannot write `port->grafProcs`; use
`GetPortGrafProcs` / `SetPortGrafProcs` (CarbonLib 1.0+,
CarbonAccessors.o 1.0+). All the `Std*` routines are likewise "CarbonLib
1.0 and later", so the mechanism is nominally present at our CarbonLib
1.6 floor. `CGrafPort` is opaque but **`CQDProcs` is not**, so the record
is still ours to fill.

### Offscreen GWorld versus window port

**The dispatch is identical.** The test in `CopyBits` is against
`thePort`, whatever that currently is; `SetGWorld` makes the GWorld's
`CGrafPort` current. **There is no on-screen/off-screen branch anywhere
in the dispatcher.** **DEMONSTRATES**, **High**.

So the earlier framing is precise: it is not that offscreen ports
dispatch differently — it is that **`CopyBits` dispatches on destination
identity**, and an offscreen destination usually is not the current port.
That remains the leading explanation for the probe's null chases.

**A new GWorld's `grafProcs` is NIL**, confirmed three ways: `NewGWorld`
builds its port with `_OpenCPort`; `OpenCPort`'s documented initial-value
table ends `grafProcs CQDProcsPtr NIL`; and the ROM's port-init literally
does `CLR.L (A1)+ ; grafProcs := Nil`. Matches the arc's live
measurement.
<https://dev.os9.ca/techpubs/mac/QuickDraw/QuickDraw-213.html>

**`UpdateGWorld` preserves it**: `move.l grafProcs(a3),grafProcs(a4)`,
copying *the pointer*, not the structure. So hooks survive an
`UpdateGWorld` — but the record must stay valid.

Two GWorld gotchas that matter more than the dispatch question:

- Without `keepLocal`, `NewGWorld` **allows accelerators to cache the
  offscreen pixel image** — the pixels may not be in main memory.
  Technote QD16: "GC QuickDraw is alerted by the call to
  `_GetPixBaseAddr` that the application is getting ready to directly
  change the pixels. This is the reason why it is so important that
  applications call `_GetPixBaseAddr` every time they are about to
  manipulate a GWorld pixel map directly." **If you plan to read a
  GWorld's bits, use `keepLocal` or always re-fetch via
  `GetPixBaseAddr`.**
- `CopyBits` "assumes that the destination pixel map uses the same color
  table as the color table for the current `GDevice` record" — **the
  current GDevice participates in colour translation even when the
  destination is offscreen.**

### ★ Does `StdText` blit glyphs through `bitsProc`? — **No.**

**The lore is wrong, and this is now settled from legitimate Apple
source.** **DEMONSTRATES**, **Confidence High** (1984), **Medium** for
9.1.

Text drawing branches into a **separate module** — Apple's QuickDraw
Character Generator, `DrawText.a` — which images glyphs directly into the
pixmap derived from `thePort->portBits`, or, for styled/scaled runs,
calls the private `_StretchBits` trap. **It never reads `grafProcs` and
never calls `StdBits`.**

- `Text.a`: `StdText` does `JSR DrText`. The file contains **zero**
  references to `StdBits`, `BITSPROC`, `CallBits` or `StretchBits`.
- `DrawText.a`: **zero** references to `StdBits`, `BITSPROC`,
  `GRAFPROCS` or `CallBits`. What it *does* contain is direct pixmap
  arithmetic —
  ```
  MULU  PORTBITS+ROWBYTES(A3),D0     ;MULT BY ROWBYTES
  ADD.L PORTBITS+BASEADDR(A3),D0     ;ADD START OF DST BITMAP
  ```
  — and, for the styled path, `JSR StretchBits`.

<https://raw.githubusercontent.com/jrk/QuickDraw/master/DrawText.a>

**Where the lore comes from**: text and `CopyBits` *do* converge — both
bottom out on `_StretchBits`. But **only `CopyBits` passes through the
`grafProcs` vector on the way.** "Each glyph is blitted" is true;
"blitted via the `bitsProc` bottleneck" is false.

**This independently confirms the inference from the arc's own
measurements** — the spike recorded `text 1 ... bits 1`, not one bits op
per character.

Downstream cases:

- **TrueType, non-antialiased (System 7 → 9.x)**: same answer. The
  scaler returns a glyph bitmap; the same character generator images it.
  Fractional widths change positioning and measurement only, not the
  imaging route. **High.**
- **Font smoothing (8.5+)**: TN1149 says the scaler emits 4-bit gray
  coverage and "QuickDrawText's blitter then looks to it that these gray
  levels blend nicely" — and, decisively, "there is no `CopyBits`
  transfer mode that knows how to blend the gray fringe pixels into the
  destination, while keeping the 'black' source pixels intact." If
  antialiased glyphs went through `StdBits`, that sentence would
  contradict itself. **Medium, ASSERTS + inference.**
  <https://developer.apple.com/library/archive/technotes/tn/tn1149.html>
- **ATSUI / MLTE (Unicode)**: bypasses *every* bottleneck on screen.
  Apple Q&A QD 64 answers a printer-driver author who replaced all
  bottlenecks and saw nothing for `ATSUDrawText`: "ATSUI and MLTE rely on
  a low level flag to indicate whether or not to use the `StdPix`
  QuickDraw bottleneck. If you are currently printing then they use the
  bottleneck." (low-memory `0x948`; Apple marks poking it "Not
  Recommended".) **High, ASSERTS.**
  <https://developer.apple.com/library/archive/qa/qd/qd64.html>

**If the goal is capturing text, hook `textProc`** (and `txMeasProc`
alongside it so pen tracking stays consistent). That is the documented,
supported route and it hands you the actual bytes plus scaling — far
better than glyph bitmaps.

Reimplementations all agree on the load-bearing point and differ in the
details: **Executor** composites a run into a 1-bit stylemap then calls
`StdBits` **once per run**; **AMS** calls `StdBits` **once per glyph** —
but both call the *function*, not `grafProcs->bitsProc`. Apple does
neither.

### What `StdBits` itself does

Apple documents an ordered five-stage pipeline (IM: Color QuickDraw,
Fig. 4-12): **1.** convert depth → **2.** stretch/shrink → **3.**
colorize using the *current port's* `rgbFgColor`/`rgbBkColor` → **4.**
clip to `visRgn ∩ clipRgn ∩ maskRgn` → **5.** transfer in the source
mode.

The ROM body matches, and adds the detail that matters:
**picture recording happens *inside* `StdBits`** (`_CHECKPIC` at the
top), then `_BitsToPix`, then "CALL HEAVY-DUTY LOOP TO DRAW TO ALL
DEVICES" → `_BitsDevLoop`.

**Two consequences for anyone hooking it**: (a) a custom `bitsProc` that
does **not** chain to `StdBits` silently breaks PICT recording of
`CopyBits`; (b) `StdBits` dispatches *further*, to a **device loop** that
walks the `GDevice` list so a copy spanning two monitors is drawn
per-device at each device's depth — so **one `CopyBits` can produce
several blits**, which is a real hazard for anything counting ops.

**Transfer modes.** Boolean `srcCopy=0 … notSrcBic=7`; `ditherCopy = 64`;
`hilite = 50`. Colour arithmetic: `blend=32, addPin=33, addOver=34,
subPin=35, transparent=36, addMax=37, subOver=38, adMin=39`. Mind the
asymmetric naming — it is `addMax` and `adMin`, and `addMax=37` sits
*before* `subOver=38`. Each has a documented 1-bit-destination fallback
(`blend→srcCopy`, `addPin→srcBic`, `addOver→srcXor`, `subPin→srcOr`,
`addMax→srcBic`, `subOver→srcXor`, `adMin→srcOr`).
<https://dev.os9.ca/techpubs/mac/QuickDraw/QuickDraw-166.html>

**Colorization is not a two-colour swap.** "Color QuickDraw first
multiplies the relative intensity of each red, green, and blue component
of the source pixel by the corresponding value of the foreground
color... then... the background color... adds the results." And the
warning every implementer needs: **"`CopyBits` applies the foreground and
background colors of the current graphics port... even if the source
image is a bitmap"** — set `RGBForeColor` black / `RGBBackColor` white
before a faithful copy. `srcXor`/`notSrcXor` are documented **undefined**
for a coloured destination.

**Dithering is not purely opt-in**: "`CopyBits` always dithers images
when shrinking them between pixel maps on direct devices." And error
diffusion is **not translation-invariant** — "a clipped dithering
operation does not provide pixel-for-pixel equivalence to the same
unclipped dithering operation", because it restarts at the clipped
region's upper-left. **That will bite any damage-rect-based redraw
scheme**, which is exactly what the content plane is.

**Stack bound**: roughly **five times** the source pixel map's
`rowBytes`. Failure surfaces as `QDError() == -143`.

**`srcBits` coercion**: the **high two** bits of `portVersion` are set
(`0b11`), sharing the position of `portBits.rowBytes`. `rowBytes < 0`
detects pixmap-ness, but `0xC000` is the real marker — and for a coerced
`CGrafPort`, the "BitMap" `baseAddr` is a **`PixMapHandle`**, not pixels.

### Acceleration lives *under* the bottlenecks

**There is no `gdProcs`.** The `GDevice` record has no drawing-procs
vector (see §4). `gdSearchProc` / `gdCompProc` are **Color Manager**
hooks used during colour matching, and they do participate in
`CopyBits`: QD16 notes QuickDraw "calls a SearchProc whenever the source
and destination have different depths and when two indexed pixel maps
have different color tables".

Apple's own words about its only QuickDraw accelerator (develop 3, the
8•24 GC card):

> "The software for the 8\*24 GC card takes effect at the level
> **immediately under the standard (bottleneck) procedures**... If an
> application completely replaces the standard bottleneck procedures, it
> is effectively turning acceleration off."

**High, ASSERTS, Apple-authored.** Practical rule: **always chain to the
standard proc**, or you disable hardware acceleration for that port.

(The other acceleration seam, `NQDMisc(6, …)` with `ACCL_BITBLT`, is
described in §5 from SheepShaver's implementation.)

### ★ `PlotIconSuite` &co. — the answer is conditional, and the condition is `grafProcs` itself

**This is the most useful single finding for P5.**

Apple's Icon Utilities checks, on entry to every `Plot*` call:

```c
//  useCopyMask is true if the icon does not need to go through bottlenecks
theBlock.useCopyMask = !((curPort->grafProcs) || (curPort->picSave));
```

and then, in `Render()`:

```c
if (HaveCQD() && theBlock->useCopyMask && masksSameSize)
    CopyMask(&dataMap, &maskMap, dstMap, ...);      /* bypasses bitsProc */
else {
    CopyBits(&maskMap, dstMap, ..., srcBic, NULL);  /* through bitsProc */
    CopyBits(&dataMap, dstMap, ..., srcOr,  NULL);  /* through bitsProc */
}
```

Apple's own release note (7/1/92) states the intent: "I now use presence
of user-defined bottlenecks or a non-zero `picSave` value in the current
port to decide whether or not to use `CopyMask` to render the icons."

**Confidence High** that this is the 7.x-era Toolbox; **Medium** for 9.1.
Source is the leaked ROM tree — flagged, and the live experiment is
trivial.

**So: if you hook `bitsProc` on the destination port, `PlotIconSuite` /
`PlotIconID` / `PlotIconHandle` / `PlotSICNHandle` / `PlotCIconHandle` /
`PlotIconMethod` deliberately switch to the two-`CopyBits` path and you
WILL see them** — as a `srcBic` mask blit followed by a `srcOr` image
blit, **one pair per intersecting `GDevice`** (the whole thing runs under
`DeviceLoop`).

**This explains the arc's own measurement.** The spike saw
`PlotIconSuite` emit a blit into the offscreen port *because the port was
hooked* — the hook is what caused the bottlenecked path to be taken. That
is a self-fulfilling observation, and a very convenient one: the icon
family is visible **precisely when you are looking**. It also means the
Finder's unhooked icon drawing takes the `CopyMask` path and is
**invisible to any passive observer**.

**`PlotCIcon` is the exception.** It is a QuickDraw routine, not an Icon
Utilities one, has no such check, and always bypasses — documented
outright: "The `PlotCIcon` procedure uses the QuickDraw procedure
`CopyMask` and doesn't send any of its drawing commands through QuickDraw
bottleneck routines. Therefore, calls to `PlotCIcon` are not recorded as
pictures."
<https://dev.os9.ca/techpubs/mac/MoreToolbox/MoreToolbox-284.html>
`PlotIcon` is plain `CopyBits`/`srcCopy`, hence always bottlenecked.

**Published docs say nothing about the other seven routines** — a grep of
the whole Icon Utilities chapter for
`CopyMask|CopyDeepMask|CopyBits|bottleneck|grafProcs|picture` returns two
hits, both about `PlotCIcon`/`PlotIcon`. Anyone claiming "the docs say
`PlotIconSuite` uses `CopyMask`" is wrong.

**Transforms are not a separate engine**: alignment is arithmetic on the
destination rect; transforms composite into a 32×32 stack buffer
(`DoOutline`, `ApplyPattern` with 50%/25% gray) and hand the result to
the same `CopyMask`-or-`CopyBits` choice; label colours swap the source
CLUT. The only non-blit drawing in the path is `RGBForeColor` and clip
manipulation.

**`PlotIconRef` / Icon Services (8.5+): unknown.** The source tree
predates it. The strongest hint is Apple's warning that "the introduction
of deep masks means that you cannot simply draw over an icon and assume
the previous icon will be erased" — which demonstrates a
read-modify-write blend, whose primitive is `CopyDeepMask`, itself on the
not-recorded/not-printed list. **But no source confirms `PlotIconRef`
uses it, and none says whether Icon Services applies the same
`grafProcs`/`picSave` fallback.**

**Executor disagrees with real QuickDraw here** and must not be used as a
model: it uses `CopyMask` unconditionally, never checks `grafProcs`, and
implements neither alignment nor transforms.

### Further disagreements between sources

1. **`CopyMask` scaling — IM contradicts itself within one chapter.**
   p. 3-30: "`CopyMask` does not allow scaling or resizing." The
   `CopyMask` reference page (3-115): "for differently sized rectangles,
   `CopyMask` scales the source image to fit the destination." MACE
   reports resolving this in favour of "no scaling" for the Classic era;
   the ROM's `CMDevLoop` is shared with `StdBits`' device loop, which
   *suggests the opposite*. **Unresolved.**
2. **AMS always routes `CopyBits` through `bitsProc`** (swapping in a
   scratch port for foreign destinations) where Apple routes
   conditionally. A deliberate simplification — but it means **AMS is not
   a behavioural oracle** for this.
3. `portVersion` marker is the high **two** bits, not "the high bit";
   `rowBytes < 0` works as a test but `0x8000` alone is not a valid
   marker.

### Remaining gaps in this section

- **Is any of this still true on 9.1 / CarbonLib 1.6?** All source
  evidence is 1984 or ~1994. `QDciPatchROM.a` in the same tree explicitly
  re-synchronises `StdBits`, `DevLoop` and `ScrollRect`, and 8.x/9.x
  shipped further QuickDraw updates in the System file.
- **Does the Icon Utilities `useCopyMask` gate still exist in 9.1?** A
  1992 change; Icon Utilities was reworked for 8.0/8.5. The single most
  load-bearing uncertainty in the icon story.
- `glyphsProc` semantics — stream format, caller, conditions.
- The 8.5+ antialiased text path: TN1149 implies strongly, proves
  nothing.
- `PlotIconRef` / alpha icons: primitive used, and whether the
  `grafProcs` fallback applies.
- Does `ScrollRect` on 9.1 still go via `CopyBits`?
- Whether `_StretchBits` is patchable as a single chokepoint catching
  **both** text and `CopyBits`. It is the one place the two paths
  genuinely converge — but it is a private trap, and patching it under
  CarbonLib is likely a dead end.
- The MacTech archive (`preserve.mactech.com`) serves an **expired TLS
  certificate** and the fetch tooling upgrades HTTP to HTTPS, so several
  articles were reachable only in part. Worth retrieving by another route
  (browser, `curl -k`, archive.org).
---

## 5. Prior reimplementations

The richest seam, as expected — and it changed the shape of the answer.

### The map

| Project | URL | Licence | Nature |
|---|---|---|---|
| **Executor** (ARDI) | [ctm/executor](https://github.com/ctm/executor), [autc04/executor](https://github.com/autc04/executor) | **MIT** core (©1986–2004 ARDI, ©2018–19 Wolfgang Thaller); bundled `cxmon` is GPL-2.0+, which binds the built product | From-scratch C++ reimplementation of the whole Toolbox. **The best legally-clean GWorld reference.** |
| **MACE** | [mace.home.blog](https://mace.home.blog/) (`mace.software` redirects) | **Closed source, no repo** | 68K CPU emulation + Toolbox reimplemented natively in C, no ROM. Dev diary is the artifact. |
| **Advanced Mac Substitute** | [jjuran/metamage_1](https://github.com/jjuran/metamage_1), under `68k/` (`jjuran/advanced-mac-substitute` is 404) | **AGPL-3.0-or-later** | From-scratch 68K Toolbox. **1-bit QuickDraw only — no PixMap, GDevice or GWorld at all.** |
| **Basilisk II / SheepShaver** | [kanjitalk755/macemu](https://github.com/kanjitalk755/macemu) (active), [cebix/macemu](https://github.com/cebix/macemu) (dormant) | **GPL-2.0-or-later** | Run the real ROM. Do **not** reimplement QuickDraw. Interesting only at the seams. |
| **Mini vMac** | [minivmac/minivmac](https://github.com/minivmac/minivmac) | GPL-2.0-only | Hardware-level Mac Plus. No API layer at all. |
| **Apple QuickDraw 1.x (1984)** | [CHM release](https://computerhistory.org/blog/macpaint-and-quickdraw-source-code/), browsable at [jrk/QuickDraw](https://github.com/jrk/QuickDraw) | ©1984 Apple, **non-commercial use only** — not open source | 37 files, 17,101 lines of 68000 asm. Pre-Color QuickDraw. |

> **A note on the "SuperMario" tree.** The research surfaced
> `elliotnunn/supermario`, a **leaked** Apple System 7.1 source tree whose
> `QuickDraw/` directory contains `GWorld.a`, `GDevice.a`, `CQD.a`,
> `BitBlt.a`, `DeviceLoop.a`. It is not a licensed release and not a
> reimplementation — it is categorically different from Executor, AMS and
> the CHM release. Two findings below are attributed to it because it is
> where they were found, and they are **exactly the kind of claim the
> live lane should confirm independently** so nothing rests on it.
> Reference only; do not copy from it into this codebase.

There is **no file called `QuickDraw.a`** in the CHM release — the
assembly is split across `BitBlt.a`, `RgnBlt.a`, `Regions.a`,
`Bitmaps.a`, `Rects.a`, `Text.a`, `Pictures.a`, `GrafTypes.a`,
`GrafAsm.a` and others.

### ★ CopyBits bypasses the bottleneck when the destination is not the current port

**This is the most consequential finding in the file for the probe arc.**

Apple's 1984 `Bitmaps.a :: CopyBits` — **DEMONSTRATES** (shipping
source), **Confidence High** for 1984, **Medium** that it still holds at
9.1:

Under a comment reading "TEST IF DST IS TO THEPORT, (IF SO WE CLIP)",
`CopyBits` bails out if `thePort` is NIL or odd-addressed, then compares
`PORTBITS+BASEADDR` against the destination's `baseAddr` **and**
`PORTBOUNDS` against its bounds. **Only if both match** does it call
`StdBits`/`bitsProc` — under a comment reading "ITS PROBABLY TO
THEPORT". Otherwise it calls `StretchBits` **directly**, passing
`wideOpen` for both the clip and vis regions.

Three consequences Inside Macintosh never states:

1. **`CopyBits` into an offscreen bitmap bypasses the bottleneck
   entirely.** A `bitsProc` installed on the *destination* GWorld's port
   will not see it.
2. **It also bypasses clipping** — no `clipRgn`, no `visRgn`, only
   `maskRgn`.
3. Identification is by **`baseAddr` + `bounds` equality**, so two
   BitMaps sharing both get conflated. A real aliasing hazard.

**Executor independently agrees** (`src/quickdraw/qBit.cpp`): it computes
`dst_is_theport_p` by `memcmp` against `thePort->portBits` and only then
calls `CALLBITS`; otherwise it calls its standard blitter directly, and
*warns* that the combination cannot be honoured —
"thePort bitsProc patched out!"

**AMS disagrees** (`68k/modules/ams-qd/CopyBits.cc`): it keeps a scratch
GrafPort, points `thePort` at it via `SetPortBits(dstBits)`, and **still
dispatches** — but through the *original* port's bottleneck
(`GRAFPROC_BITS(*saved_port)`). **DEMONSTRATES.**

So Apple and Executor **bypass**; AMS **routes through**. Two of three,
including Apple's own source, say bypass.

**Why this matters here, precisely.** It is fully consistent with what
the probe arc measured live — that offscreen drawing *does* consult
`grafProcs` — because the spike's applet made the GWorld **the current
port** and drew into it. The uncovered case is the other one: an
application whose current port is the **window** doing `CopyBits` into a
GWorld, or between two GWorlds. **That path would emit nothing to a
`bitsProc`**, and it is a strong candidate explanation for the chase's
7-sightings-0-candidates result. This is the single hypothesis most worth
testing next.

### The `grafProcs` NULL test is all-or-nothing (and three projects disagree)

**Confidence High**, **DEMONSTRATES**.

Apple's idiom, repeated inline at every call site (e.g.
`Rects.a :: CallRect`), tests **NIL-or-not on the whole `grafProcs`
pointer**. There is **no per-field NULL check**. The consequence is the
reason `SetStdProcs` exists at all: once you install a `QDProcs` record
you must fill **every** field, because a NULL member will be *called*.

- **AMS** instead treats a NULL *member* as "use standard"
  (`GRAFPROCS` macro in `GrafProcs.hh`), and its `SetStdProcs_patch`
  **zeroes** the record rather than filling it.
- **Executor** takes a third position: it compares each proc against the
  address of its own `Std*` function and counts it as custom only if
  different (`qHooks.cpp`).

For our purposes the Apple rule is the one that governs: **hook by
calling `SetStdCProcs` first, then overwrite the fields you want.**
Leaving a field NULL is a crash, not a fallback.

### A GWorld's PixMap is deliberately misaligned from its portRect

From `GWorld.a` (SuperMario tree) — **Confidence Medium** (single,
unlicensed source; flagged for live confirmation), **DEMONSTRATES** if
genuine:

- **`rowBytes` is not the obvious formula.** It is
  `(((width * pixelSize + 31 + 31) / 32) * 4)` — **31 spare bits
  allocated on purpose**, commented as leg room "if we want to realign
  the pixmap in `UpdateGWorld`". A 1993 change additionally rounds
  `rowBytes` up to a **16-byte boundary** "to help digitizer grabs".
- **The PixMap bounds are not the portRect.** When `pixelDepth == 0`,
  `horizOffset = boundsRect.left − device gdRect.left` reduced **modulo
  32 bits**, and `pixmapBounds.left` is pulled left by that many pixels
  — a **bit-phase alignment** so offscreen→screen blits are word-aligned.
  Stated reason: "to optimize CopyBits between offscreen and screen".

If true, then **a probe that assumes `pixmapBounds == portRect` or
computes expected `rowBytes` naively will be wrong on real hardware and
right on most reimplementations.** Note the probe arc has already
measured `portRect == bounds` live — which *appears to contradict this*,
but the misalignment above is conditioned on `pixelDepth == 0` and a
non-zero `boundsRect.left`, and the spike allocated at a (0,0) origin.
**This is a direct, cheap live experiment**: allocate with
`pixelDepth == 0` and `boundsRect.left != 0` and compare.

**Discriminator value**: Executor uses plain `((width*depth + 31)/32)*4`
with no slop and no 16-byte rounding, so **`rowBytes` alone fingerprints
real QuickDraw versus Executor**.

### `pmVersion` is the type tag on `baseAddr`

From `GWorld.a` — **Confidence Medium** (same caveat):

| `pmVersion` | meaning of `baseAddr` |
|---|---|
| `PixMapVers2` | **a Handle** |
| `PixMapVers1` | 32-bit pointer |
| `PixMapVers0` | clean 24-bit pointer |
| `PixMapVers4` | 32-bit pointer |

`LockPixels` dereferences the handle, strips it, writes it back into
`baseAddr` and **rewrites `pmVersion` 2→1**. `UnlockPixels` reverses it.
A second consecutive `LockPixels` is a **no-op**. `LockPixels` returns
false iff the master pointer came back 0.

The bare handle-vs-pointer fact **is** documented (IWQD ch. 6). What is
undocumented is **the `pmVersion` tagging and the 2→1 rewrite** — and
that is enormously useful to a probe, because it means
**`PixMap.pmVersion` (offset 14) tells you how to read `baseAddr`
(offset 0) without having to know the lock state out of band.** Top of
the list for live confirmation.

Note also this is a **behavioural divergence** from Executor, which
implements a lock **reference count** (`pixel_lock_count`) where Apple
treats a redundant lock as a no-op.

### The CopyBits fast path — two projects converged independently

**Confidence High**, **DEMONSTRATES** (both read).

Real `CopyBits` **skips building a colour-translation table** when source
and destination share depth **and colour-table seed** and no colorization
is in effect — indices pass through verbatim. MACE found this via Prince
of Persia, which does colour animation entirely through `pmAnimated`
CLUT entries plus `PmForeColor`: colour-matching "helpfully" instead of
passing indices through **destroys the animation**.

Executor reaches the same rule independently (`qStdBits.cpp`) — but
against a different reference: it compares the *source* seed against the
**current GDevice's** table, recording the assumption "we assume the
destination has the same color table as the current graphics device",
where MACE compares src against dst. A divergence worth knowing.

Downstream trap MACE found: `ReserveEntry` must **reseed** the GDevice
colour table when *clearing* a reservation. Since seed equality gates the
fast path, a missed reseed produces stale-optimisation artifacts far from
the call site.

### Executor's `rowBytes` tag is a 4-way discriminator, not a 1-bit flag

`src/quickdraw/qStdBits.cpp :: canonicalize_bogo_map`. IM documents "bit
15 set = PixMap". Executor decodes the **top two bits**:

| bits 15:14 | meaning |
|---|---|
| `00` | real 1-bit BitMap — **except** if `baseAddr` equals the current GDevice's baseAddr, in which case treat as the screen at the device's depth/rowBytes/ctab |
| `01` | never seen — `gui_abort()` |
| `10` | pointer to a PixMap (the documented case) |
| `11` | "CGrafPtr spew" — see below |

For `11`, the **low bit of `rowBytes`** discriminates further:

- **set** → the pointer is `&port->portBits` of a CGrafPort; the real
  port begins **2 bytes earlier**, `(CGrafPtr)((char*)bogo_map - 2)`.
  This is exactly the `offsetof(GrafPort, portBits) ==
  offsetof(CGrafPort, portPixMap)` identity in §4's table, which is what
  makes `GetPortBitMapForCopyBits` work.
- **clear** → the "BitMap*" points directly at a `PixMapHandle`.

**Also in that same function, and directly relevant**: for case `10`,
Executor looks up whether the pixmap belongs to a GWorld (by `baseAddr`)
and if so **locks the pixels for the duration of the blit**, writing the
dereferenced pointer into the caller's own struct and restoring
afterwards. So Executor's `CopyBits` transparently tolerates being handed
an **unlocked** GWorld's pixmap. Whether real 9.1 QuickDraw does the same
is the open "does it internally lock as a safety net" question from §1 —
and Executor is evidence that at least one implementer thought real
QuickDraw did.

### Executor's black-box findings against a real Mac

All from `src/quickdraw/`, ©1986–1998 ARDI. **DEMONSTRATES-by-testing** —
these are ARDI's observations of genuine Mac OS, which makes them the
closest thing in this file to a measurement.

- **GDevice ownership under `noNewDevice`**: "tests show that if we
  allocate the gdevice, then the gdevice's baseAddr is the graphics
  world's locked handle. but if the user passes the gdevice in, the
  pixmap is allocated its own handle". Nowhere in IM.
- **Bounds normalisation when depth is 0**: IM says depth 0 selects the
  deepest intersecting device; it does *not* say bounds are normalised to
  a (0,0) origin. Executor does so, carrying the honest comment "unclear
  if this is correct, but it is what NewGWorld() does".
- **`gdMode` is `0x80 | log2(bpp)`** — so 8bpp reads as **0x83**, not 8.
  "determined experimentally". A probe reading `gdMode` as a depth will
  be wrong.
- **`GetGWorldPixMap()` gets called with a non-GWorld port** by real
  software ("ultima (and others)"); Executor falls back to the port's
  pixmap rather than failing.
- **`PortChanged`** — "not implemented; worked around for hypercard".
- `srcRect` can alias `thePort->portRect` ("like it is in SimuVent"), so
  it must be copied before the port is munged.
- **An undocumented low-memory global at `0xD66`** holds a Handle to a
  system-heap block listing **all GrafPorts in the system** — a two-byte
  count followed by that many pointers, maintained by
  `Open[C]Port`/`Close[C]Port`, walked by the Display Manager on
  reconfiguration. **ASSERTED** by Executor's comment; Executor
  implements a substitute rather than the real structure, so it does not
  demonstrate it.
  **If this is real on 9.1 it is a far better instrument than a heap
  sweep** — an enumerable list of every port in the system, which is
  precisely what the probe's zone scan is trying to reconstruct by brute
  force. **Highest-value single item for the live lane to check.**
- `GetPenState` on a CGrafPort sets bit `0x8000` of `pnMode` to signal
  that `pnPat` holds a `PixPatHandle` — with the caveat "it's not clear
  what the Mac does here."

**Methodology worth stealing.** Executor's test suite is **dual-target**:
the same gtest sources compile either against Executor (`-DEXECUTOR`) or
against the real Toolbox headers, gated at runtime by
`Gestalt(gestaltQuickdrawFeatures, gestaltHasDeepGWorlds)`
(`tests/compat.h`, `tests/quickdraw.cpp`). The same assertions run on
real Mac OS and on the reimplementation. That is differential testing
against the oracle, and it is directly applicable to this arc — it is the
shape our own `scripts/test-native` manifest could grow toward.

### Screen-vs-offscreen is detected by `baseAddr` comparison — everywhere

Four independent projects converged on the same trick, none documenting
it as a technique. **Confidence High**, **DEMONSTRATES**.

- **Executor**: `active_screen_addr_p(bitmap)` ≡
  `bitmap->baseAddr == PIXMAP_BASEADDR(GD_PMAP(LM(MainDevice)))`.
- **SheepShaver**: `NQD_set_dirty_area` marks damage only when the dest
  baseAddr equals `screen_base` — blits into a GWorld are ignored.
- **Apple's `GetPixBaseAddr`**: walks `DEVICELIST` comparing baseAddr to
  decide whether to strip.
- **Apple's 1984 CopyBits**: compares baseAddr + bounds to decide whether
  the destination "is probably thePort".

The shared hazard is shared too: identification by `baseAddr` conflates
any two maps that happen to share one.

### SheepShaver's native QuickDraw acceleration — a second interception plane

`SheepShaver/src/gfxaccel.cpp`, `src/include/video_defs.h`.
**DEMONSTRATES**, **Confidence High**.

SheepShaver finds **`NQDMisc`** by symbol name in InterfaceLib and calls
`NQDMisc(6, &hook_info)` to install hooks (`ACCL_BITBLT`,
`ACCL_FILLRECT`, …), wrapping its native routines in transition vectors.
Selector 6 and the hook struct are **not** in Inside Macintosh.

This is a **third interception surface**, distinct from both trap patches
and `grafProcs`: the native QuickDraw acceleration plane, below the trap,
and the one the OS itself uses for accelerated drawing.

Worth knowing about it:

- **The parameter block is ~70% unknown.** `struct accl_params` names
  ~0x178 bytes; the code reads past its own struct with bare magic
  offsets (`p+0x018`, `0x128`, `0x130`, `0x15c`, `0x284`) that gate
  correctness for reasons nobody established, and a comment records the
  real block extends to at least **0x4f8**. An honest artifact of reverse
  engineering, and a good example of "these fields must be zero and we
  don't know why".
- **Acceleration conditions** (undocumented): src and dst depth equal and
  **≥ 8** — so 1/2/4bpp is never accelerated; `rowBytes` same sign;
  transfer mode `srcCopy` only. **`rowBytes` can legitimately be
  negative**, meaning bottom-up row order.
- **The best architectural idea in the tree**: `NQD_set_dirty_area()`
  runs at the **top of every hook, before the accelerate/decline
  decision** — including `NQD_unknown_hook`, which always declines. So
  the acceleration hook is worth installing **even if you accelerate
  nothing**, because it converts a damage *guess* into an exact rectangle
  handed over by QuickDraw itself. That is a strikingly good fit for what
  the content plane wants.

Also from that tree: **a palette change is damage with no write** —
"We have to redraw everything because the interpretation of pixel values
changed" (`video_sdl2.cpp`). IM never frames a CLUT change as
frame-buffer damage. And Basilisk II performs **pixel-format conversion
inside the CPU emulator's store path** (`src/uae_cpu/memory.cpp`), which
has no analogue in IM because IM assumes the frame buffer is dumb memory.

Neither Basilisk II nor SheepShaver reimplements QuickDraw — a full tree
listing contains **no** file matching `gworld` or `offscreen`. They are
prior art about the *seams*, not about GWorlds. **DEMONSTRATES (by
absence).**

### MACE's compatibility corpus

Closed source, so all **ASSERTS** — but almost every item is tied to a
named application that was demonstrably fixed, which is stronger than
prose usually is. **Confidence High** that the diary says it,
**Medium** that each generalises.

- **`UpdateGWorld` must re-derive the offscreen CLUT from the current
  GDevice.** A GWorld created with depth 0 / no explicit CLUT
  **snapshots the GDevice's CLUT at creation time**; the app's later
  `UpdateGWorld` is the only thing that resyncs it. Marathon's backbuffer
  inherited the intro palette and rendered plausible-but-wrong colours
  **with no error**. MACE still has not implemented `UpdateGWorld`'s
  **existing-pixel-data conversion** — some apps expect the pixels
  already in the buffer to be converted, not just the table swapped.
- **Each GWorld needs its own GDevice with its own CLUT *and its own
  inverse table*.** You cannot share the screen's ITab. (Note this
  interacts with IM's documented `MakeITable` reuse optimisation in §1 —
  IM says the ITab *is* shared when colour tables match. Not necessarily
  a contradiction, but worth resolving.)
- **`StdBits` must silently ignore negative transfer sizes.** Escape
  Velocity reads a fifth element of a four-element array and feeds
  garbage rects to `CopyBits`; real QuickDraw **no-ops rather than
  crashing**. Tolerance of garbage is a compatibility requirement.
- **`ScreenRow` holds the rowBytes of an imaginary 1-bit screen**, not
  the current mode — 640×480 at 8bpp gives **80**, not 640. Apple's own
  behaviour here was "quite erratic" across 7.1/7.5.
- **`StretchBits` is a separate trap and cannot be stubbed to
  `StdBits`** — and bitmap fonts get scaled through it, so scaled text
  quality depends on the blitter.
- **Direct-colour (16/32bpp) destinations invert pattern black/white**
  relative to indexed modes; byteswap bugs invisible at ≤8bpp surface at
  16.
- **Real apps patch QuickDraw traps wholesale.** After Dark and CloseView
  redirect all drawing to a secondary buffer via trap patches — so a
  native-C Toolbox implementation must preserve 68K register conventions
  exactly, because patchers observe them. *Independent corroboration that
  QuickDraw trap patching worked in practice on this platform.*
- Sierra AGI games test `screenBits.baseAddr` against `$F0000000` to
  decide colour vs mono.

Diary index: <https://mace.home.blog/news/>

### AMS and Mini vMac — scope-limited but two good facts

**AMS has no GWorlds** — zero hits for `NewGWorld`/`GWorldPtr`/
`LockPixels` under `68k/`; `PixMap` appears only in PICT decoding. It is
a strong source on bottlenecks and regions and **no source at all** on
GWorld.

- **`GetPixel` does not see the cursor on a real Mac.** *Missile*
  hit-tests warheads with `GetPixel`; Juran's comment records "Testing on
  a real Mac reveals that it doesn't match the cursor." AMS checks
  `CrsrRect` and samples the `CrsrSave` buffer instead. **Real-hardware
  verified**, and directly relevant to anything probing the framebuffer.
- **`UnpackBits` behaviour on the `0x80` metadata byte is undocumented
  and varies across Mac OS versions** — AMS refuses to guess and bails.
- AMS's `null_QDProcs` entries are **trap words with the autoPop bit
  set** (`_StdBits 0xA8EB | 0x0400`), not code pointers — so "calling the
  UPP" executes a 2-byte auto-popping trap. A neat trick worth knowing if
  you ever need a bottleneck table that costs nothing.
- AMS reconstructs QuickDraw's **private globals at negative offsets from
  `thePort`** (`InitGraf.cc`) in an order that **matches Apple's 1984
  `GrafTypes.a` exactly** (`wideOpen`/`wideMaster`/`wideData`,
  `rgnBuf`/`rgnIndex`/`rgnMax`, `thePoly`/`polyMax`, `patAlign`,
  `fontPtr`, `playPic`/`playIndex`). That independent convergence is the
  strongest single validation in the corpus.

**Mini vMac** does not trap QuickDraw at all — it emulates a Mac Plus at
hardware level. Change detection is a **full-frame diff** against a
`screencomparebuff` in `ScreenFindChanges()` (`src/COMOSGLU.h`), which
word-scans for first/last difference to get a vertical band, narrows
horizontally, and **adaptively scans less of the screen per tick when
falling behind**. A dirty rect one pixel wide and under 32 tall is
assumed to be a blinking caret.

---

## Corrections to the investigation plan that fell out of this sweep

Small, but they would each have sent someone looking for something that
does not exist:

- **`PixMapChanged` is not a call.** The `_QDExtensions` family has
  `CTabChanged`, `PixPatChanged`, `PortChanged`, `GDeviceChanged`. PLAN
  names `PixMapChanged`.
- **`nativeEndianPixMap` does not exist on this target.** Absent from
  Universal Interfaces 3.4 entirely; it is an OS X-era flag.
- **`createPalette` is not a `GWorldFlags` constant** anywhere; two
  independent searches came up empty. If it matters, its real origin
  needs identifying (probably Palette Manager or a wrapper library).
- **QuickDraw is native PowerPC and has been since 1994.** P3 is phrased
  as "which QuickDraw entry points are native PowerPC versus 68K"; the
  more useful question is *which are reachable through the trap table*,
  since native code still dispatches through it via routine descriptors.

---

## Questions for the live lane

Ordered by what they unblock, not by section. Each is something only the
machine — or, for a couple, a static read of a built binary — can answer.

### Tier 1 — these unblock the probe arc

1. **Does `CopyBits` skip `bitsProc` when the destination is not the
   current port?** §5's strongest finding, from Apple's own 1984 source
   and independently from Executor. If true, an application drawing into
   a GWorld from a window port emits **nothing** to a hooked `bitsProc` —
   a complete explanation for 7 sightings / 0 candidates.
   *Experiment*: hook a GWorld's `bitsProc`, then `CopyBits` into it (a)
   with the GWorld as current port and (b) with a window as current
   port. Count ops.

2. **Is there really a low-memory global at `0xD66` holding a Handle to a
   system-heap list of every GrafPort?** (count word, then that many
   pointers, maintained by `Open[C]Port`/`Close[C]Port`.) Recorded in
   Executor's comments as what the real Mac does; Executor implements a
   substitute, so it is asserted, not demonstrated. **If real it replaces
   the heap sweep entirely** — an enumerable port list is exactly what
   the chase is reconstructing by brute force, and it would retire the
   class of wild-pointer crash that already took down the Finder.

3. **How does the system recognise a `CGrafPtr` as a GWorld?** Executor
   uses `portVersion & 1` (i.e. `0xC001`); no source confirms Apple does.
   `SetGWorld` and `GetGWorldDevice` both branch on it, so a mechanism
   exists. *Experiment*: allocate a GWorld and a plain colour window,
   read the word at port+6 in each, diff.

4. **What does `PixMap.pmVersion` (offset 14) read as, locked vs
   unlocked?** The SuperMario evidence says `PixMapVers2` means
   `baseAddr` holds a **Handle**, and `LockPixels` rewrites it **2→1**.
   If that holds, a probe can tell how to interpret `baseAddr` from the
   PixMap alone, with no out-of-band lock state. Cheap, high value.

5. **~~Does `StdText` blit each glyph through `bitsProc`?~~ Answered:
   no** — from Apple's own 1984 `Text.a`/`DrawText.a`, which contain zero
   references to `StdBits` or `GRAFPROCS`, and corroborated by the arc's
   own `text 1 / bits 1` spike. Text has its own character generator and
   converges with `CopyBits` only at the private `_StretchBits`.
   **Remaining live question**: confirm it still holds at 9.1 with font
   smoothing on (draw a 20-character string into a hooked port; expect
   **0** bits ops), and **stop depending on that re-entrancy** — hook
   `textProc` instead.

6. **Does the Icon Utilities `useCopyMask` gate still exist in 9.1?**
   Apple's 7.x Toolbox chooses `CopyMask` (bypassing `bitsProc`) unless
   the port has `grafProcs` **or** `picSave` set, in which case it
   deliberately renders as two `CopyBits` (`srcBic` mask, then `srcOr`
   image) per intersecting GDevice. **If it survives, the icon family is
   visible precisely when you are looking — and the Finder's own unhooked
   icon drawing is invisible to any passive observer.** That is a
   sharper, more actionable statement than "does PlotIconSuite go through
   StdBits", and it reframes P5.
   Also still open: **which of the three icon generations the 9.1 Finder
   uses** — `$A94B`/`$AA1F`, `_IconDispatch` `$ABC9`, or
   `_IconServicesDispatch` `$AA75` — since `PlotIconRef`/Icon Services
   postdates every source consulted.

### Tier 2 — these decide what a resident 68K extension can do

7. **★ Does our PPC guest's `CopyBits` resolve against InterfaceLib or
   CarbonLib?** *Answerable statically today*: build the guest and dump
   the PEF import table, reading which fragment each QuickDraw symbol
   names. Both `libInterfaceLib.a` and `libCarbonLib.a` export
   `.CopyBits`, `.NewGWorld` and `.StdBits`, and the CMake adds
   `libCarbonLib.a` as a PRIVATE link library alongside the spec default,
   so link order decides it. No build artifact currently exists in the
   tree.

8. **Does a 68K trap patch on `$A8EC` see a native PPC caller's
   `CopyBits`?** Documentation says the InterfaceLib stub reads the trap
   table, so yes — but every primary source is from 1994 / System 7.1.2
   and **none covers CarbonLib**, which was designed to also run on Mac
   OS X where no trap table exists. *Experiment (one boot, three
   counters)*: install a `$A8EC` head patch that bumps a counter, then
   drive drawing from (a) a 68K app, (b) a native PPC non-Carbon app,
   (c) our Carbon guest. One pass distinguishes every failure mode here.

9. **Is `CopyBits` a split trap?** Split traps keep their PPC
   implementation inside the import library and **cannot be patched**.
   Apple's stated criterion is "very small utility routines" (`AddPt`,
   `SetRect`), which argues no — but no authoritative list was found.

10. **Does QuickDraw's own internal drawing re-enter through the
    `_CopyBits` trap, or call an internal entry point?** A distinct
    failure mode from 8 and 9, and one that would produce *partial*
    coverage — the most confusing kind.

### Tier 3 — reimplementation-grade structure, for P1/P2

11. **Confirm the §4 offsets against live memory.** They are what our
    toolchain believes from Universal Interfaces 3.4, and they agree
    across both compilers — but they have not been read out of a running
    OS 9.1 port. Especially `portVersion` at +6, `portPixMap` at +2,
    `grafProcs` at +104, and that `sizeof(CGrafPort)` really is 108.

12. **Which block-type encoding does the 32-bit heap use for a
    relocatable block — `0b10` or `0b11`?** *Inside Macintosh
    contradicts itself*: the body text and the assembly constant
    (`tyBkRel EQU 2`) say `10`; Figure 2-2's own legend says `11`. A heap
    walker hard-coding the wrong one silently skips every relocatable
    block. Read the tag byte of a known handle.

13. **Is the GWorld's private state a trailer on the port's own block, or
    a separate allocation?** Apple says only "a private data structure"
    and "an extension of the GrafPort record". This decides whether a
    sweep should look for blocks of exactly 108 bytes (it should not) or
    ≥ 108.

14. **Does `NewGWorld` really misalign the PixMap from the portRect?**
    The SuperMario evidence says `rowBytes` carries 31 spare bits plus
    16-byte rounding, and `pixmapBounds.left` is pulled left by
    `(boundsRect.left − gdRect.left) mod 32` **when `pixelDepth == 0`**.
    The arc measured `portRect == bounds`, but at a (0,0) origin, which
    would not trigger it. *Experiment*: allocate with `pixelDepth == 0`
    and `boundsRect.left != 0`, then compare `portRect` to
    `(**portPixMap).bounds`, and actual `rowBytes` to the naive formula.
    Also fingerprints real QuickDraw against every reimplementation.

15. **What is `DisposeGWorld`'s unwind order?** Apple states what is
    freed, never in what sequence; only the `MainDevice` restoration is
    documented.

16. **Does 9.1 QuickDraw internally lock pixels as a safety net, or does
    drawing with pixels unlocked corrupt memory?** No Apple statement
    either way. Executor locks transparently inside `CopyBits`, which
    suggests its authors believed real QuickDraw did.

17. **~~Does a NULL `grafProcs` short-circuit the `Std*` trap?~~ Largely
    answered**: NIL branches to the standard routine directly (no vector,
    which is why chaining to `StdBits` from your own `bitsProc` does not
    recurse) — **but `SetStdProcs` copies live `JStd*` trap-table
    entries**, so a patch on `$A8EB` is still consulted by both the NIL
    path and unmodified `QDProcs` records. Worth one confirmation at 9.1,
    since it is the difference between a trap patch catching all drawing
    and catching none.

17b. **Does one `CopyBits` produce more than one `bitsProc` call?**
    `StdBits` dispatches to a **device loop** across the `GDevice` list,
    so a copy spanning two monitors is drawn per-device. Anything
    counting ops needs to know this before it reads a count as a
    behaviour.

18. **Is `gdReserved`/`gdExt` (GDevice +58) non-zero on this machine?**
    Documented as "must be 0" classically, reused by QuickTime 3. Tells
    you which header variant the live system matches — as does whether
    `PixMap` +38 behaves as `planeBytes` or `pixelFormat`.

19. **Does `useTempMem` ever move anything but the pixel image?** The arc
    measured that it moves only the pixels and the documentation agrees
    via the `NewScreenBuffer`/`NewTempScreenBuffer` split. Worth one
    confirmation that port, PixMap and GDevice stay in the application
    heap under every flag combination.

### Not a machine question, but blocking

20. **Retrieve the two MacTech / *develop* articles.**
    `preserve.mactech.com` serves an **expired TLS certificate**, and the
    fetch tooling upgrades HTTP to HTTPS, so that whole archive was
    unreachable for this sweep — including "Fast Blit Strategies"
    (MacTech Vol. 15.06) and Othmer's "QuickDraw's CopyBits Procedure"
    (*develop*), both directly on-topic for §2. A browser, `curl -k`, or
    archive.org should get them, and they are the most likely single
    source for the `StdText` answer.

---

## Coverage and what this file does not cover

- **The one experiment that converts most of §2 from documented to
  metal-verified.** Install a counting `bitsProc` and run the table:

  ```c
  CQDProcs procs; SetStdCProcs(&procs);
  procs.bitsProc = NewQDBitsUPP(CountingBits);  /* log, then chain to StdBits */
  SetPortGrafProcs(port, &procs);               /* procs must outlive the port */
  ```

  | Call | Expected `bitsProc` calls |
  |---|---|
  | `DrawString` | **0** |
  | `CopyBits` **into** that port | 1 (per GDevice) |
  | `CopyBits` into a different bitmap while that port is current | **0** |
  | `CopyMask` | **0** |
  | `PlotIconSuite`, native size, `atNone`/`ttNone` | **2** per GDevice |
  | `PlotCIcon` | **0** |
  | `ScrollRect` on a colour port | 1 |
  | `DrawPicture` of a PICT with a bitmap | 1 per bits opcode |

- **Findings resting on an unlicensed source** (the leaked System 7.1
  tree): the GWorld PixMap misalignment, the `pmVersion` tagging, and the
  Icon Utilities `useCopyMask` gate. All three are written up as
  **Medium** confidence with live experiments attached, and nothing else
  in the file depends on them. The `CopyBits` destination test and the
  `StdText` answer, by contrast, come from the **legitimate 1984 CHM
  release** and stand on their own.
- **Nothing here is a measurement.** Where this file agrees with
  something the probe arc already measured — `grafProcs` consulted
  offscreen, `useTempMem` moving only pixels, `portRect == bounds`,
  `grafProcs` NULL at allocation, port in the application zone — the
  agreement is noted as corroboration, and the measurement is the
  authority, not this file.
