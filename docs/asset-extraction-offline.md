# Reading the guest's assets straight off the disk image

**Date:** 2026-08-06 · **Status:** measured here, on this Mac, against
`~/Lab/Assets/os91-qemu/now-mirror-stage.qcow2`. No VM was booted and no
guest was running.

[mirror-assets.md](mirror-assets.md) carries the inherited knowledge of
WHAT the assets are and where they live in the System Folder; it names
the offline route as an "explicitly unverified alternative" that
upstream did not use. **This page verifies it**, because it is roughly
four orders of magnitude faster than the wire: the whole System file's
resource fork took 24 s over the wire at ~330 KB/s, and here the same
7,893,757 bytes are an ordinary file read.

Everything below is READ-ONLY on a COPY. The rule from
mirror-assets.md stands unchanged: these are Apple's bitmaps, the pack
stays private, and nothing is ever written into a guest System Folder.

## The four steps, and the two that are not obvious

```
qemu-img convert -f qcow2 -O raw <image>.qcow2 /private/tmp/probe.raw
```

`qemu-img` is a file converter, not the emulator — nothing boots, and
the source image is opened read-only. (A running VM's own image can be
converted too; prefer an idle one.)

**1. The Apple Partition Map.** Block 0 is `ER`, then 512-byte `PM`
entries. Take the `Apple_HFS` one: on these images it is entry 8, at
physical block 1544 → byte offset `0xc1000`.

**2. That partition is an HFS WRAPPER, and this is the step that stops
people.** Its volume signature at partition+1024 is `BD` (HFS
Standard), its name is `Untitled`, and it contains exactly three items —
`System`, `Finder`, and `Where_have_all_my_files_gone?`. That file name
is Apple's own joke and the clue: **an HFS+ volume is embedded inside**.
Modern macOS refuses the wrapper outright, because HFS Standard support
was removed after Mojave, which is why `hdiutil attach` answers "image
not recognized" and reads as a dead end.

The MDB gives the embedded volume's location:

| Field | Offset in MDB | Value here |
|---|---|---|
| `drAlBlkSiz` | 20 | 69632 |
| `drAlBlSt` | 28 | 24 |
| `drEmbedSigWord` | 124 | `H+` |
| `drEmbedExtent.startBlock` | 126 | 5 |

```
embedded = partition + drAlBlSt * 512 + startBlock * drAlBlkSiz
         = 0xc1000  + 12288          + 5 * 69632          = 0x119000
```

`H+` appears at `embedded + 1024`, confirming it.

**3. macOS mounts HFS+ happily — but not at an offset.** `hdiutil
attach -section` was tried and refused; carving the embedded volume out
to its own file works:

```
python3 - <<'PY'
src=open('/private/tmp/probe.raw','rb'); src.seek(0x119000)
import shutil; shutil.copyfileobj(src, open('/private/tmp/hfsplus.img','wb'), 1<<20)
PY
hdiutil attach -readonly -mountpoint /private/tmp/os9mnt /private/tmp/hfsplus.img
```

**4. Resource forks are then ordinary files.** macOS exposes them at
`<file>/..namedfork/rsrc`, so no MacBinary, no AppleDouble, no `DeRez`:

```python
import macresources
fork = open('/private/tmp/os9mnt/System Folder/System/..namedfork/rsrc','rb').read()
for r in macresources.parse_file(fork):
    ...   # r.type, r.id, r.name, r.data
```

Measured on the stage image: the System file's fork is **7,893,757
bytes / 2,162 resources**, and the type census matches
mirror-assets.md's wire-pulled figures closely enough to trust the
route — `ics#` 78, `ics8` 75, `ics4` 73, `ICN#` 57, `icl4` 52, `icl8`
52, `CURS` 40, `PICT` 42, plus `CDEF` 34 and 110 `DITL`s.

**`machfs` also reads the wrapper directly** (`machfs.Volume().read()`
over the partition bytes, 0.4 s) and is the right tool if mounting is
unavailable — but it lands you in the wrapper, showing three files, and
the embedded volume still has to be found. `machfs` and `macresources`
are both already installed on this Mac.

## The script

[`tools/extract-assets-offline`](../tools/extract-assets-offline) is the
four steps above, end to end, writing the pack the host renders from
(`mirror/host/MirrorKit/Sources/MirrorKitUI/Resources/`). It reuses the
parsers the live-pull extractor already had
(`mirror/tools/extract-assets/`) rather than growing a second set — only
the transport is different, so the two routes cannot disagree about what
an `icl8` means.

```
tools/extract-assets-offline                 # default image, default pack
tools/extract-assets-offline --reuse-work    # skip convert+carve on a rerun
tools/extract-assets-offline --theme-report  # census the theme file, stop
```

It is idempotent: each output directory is cleared before it is
rewritten, and it refuses to finish if a generic icon the renderer names
is missing rather than shipping a half pack.

**The two routes were checked against each other, not just assumed to
agree.** The five generic icons the wire route committed —
`folder`, `document`, `application`, `disk`, `system-folder` — came out
of the offline route **byte-identical**, CLUT tail fix included.

Measured on `now-mirror-stage.qcow2`, 2026-08-06:

| | count |
|---|---|
| System-file icons (`icl8`+`ics8`, masked) | 127, plus 10 named generics (5 × two sizes) |
| Cursors (`CURS` + hotspots) | 40 |
| Patterns (`ppat` / `PAT `) | 3 + 5 |
| Pictures (`PICT`) | 42, carried unconverted |
| Per-app icons by `(creator, type)` | **914**, 185 creators, from 186 bundles |

The app-icon number is where mounting pays. Over the wire each
application's fork was a separate pull; here every app on the volume is
a filesystem walk, so the sweep reaches Extensions, Apple Menu Items and
Control Strip Modules as cheaply as the Applications folder, and both
icon sizes come out of each bundle. The pack went from 186 app icons to
914.

**`PICT` is carried, not converted.** QuickDraw picture decoding was
removed from macOS and nothing here draws these 42 images, so writing a
PICT interpreter to convert them would be a large job for art no
consumer wants. They are written as real `.pict` files with their frame
size in the manifest; claiming a PNG we cannot produce would be worse.

## What is in the theme file — opened, not assumed

`System Folder:Appearance:Theme Files:Apple platinum` has an **876,024
byte resource fork**. Opened on 2026-08-06:

| type | count | what it is |
|---|---|---|
| `clut` | 21 | the named accent ramps — `Azul`, `Bondi`, `Copper`, `Crimson`, `Emerald`, `French Blue`, `Gold`, `Ivy`, `Lavender`, `Pistachio`, `Magenta`, `Nutmeg`, `Poppy`, `Plum`, `Rose`, `Sapphire`, `Silver`, `Teal`, `Turquoise`, `Sunny`, plus `Black & White`. **8 entries each** (72 B); `Black & White` is empty (8 B). |
| `PICT` | 15 | fourteen at **177×125** — one per named scene — and one at **389×74**. Appearance control-panel preview thumbnails and its banner. |
| `scen` | 14 | the named themes as settings blobs (`Mac OS Default`, `Bubbles`, `Convergence`, `Golden Poppy`, `Mono Blue`, `Rio Azul`, `Sunny`, `Roswell`, `Lollipop` 1–5, `Gray Space`), 578 B–66 KB. Not images. |
| `icl8` `icl4` `ICN#` `ics8` `ics4` `ics#` `BNDL` `FREF` | 1 each | the theme file's **own Finder icon**. |
| `TMPL` `CNTL` `DITL` `DLOG` `dftb` `dlgx` `tvar` `tthm` `ftag` `vers` | 1–2 each | the file's own dialog, template and version (`1.1.4`, `Mac OS 9.1`). |

`Ensemble Themes` beside it is the same shape with no chrome either: 15
`PICT`, 15 `scen`, 2 `vers`, 1 `ftag`.

**The finding is confirmed, with evidence: there are no chrome
bitmaps.** Not a title bar, not a scroll arrow, not a button — nothing
in the file is window furniture. The only 32×32 icon in it is the
document icon the Finder shows for the theme file itself. The Appearance
Manager draws Platinum chrome procedurally, and the host renderer must
keep drawing it from the ported specification;
[mirror-assets.md](mirror-assets.md) needed no correction.

What the file *does* contain that is worth having is **specification,
not art**: the 21 accent ramps are the exact eight-step colour tables the
Appearance Manager tints highlights and selections with, and lifting
those numbers is the same move as porting the seven greys. That is a
colour-table extraction, not a bitmap one, and it is not in this
extractor yet.

## The honest split for a host-side asset pack

- **Extractable, real bitmaps**: icons (`icl8`/`ics8` + `ICN#`/`ics#`
  masks), cursors (`CURS`), patterns (`ppat`, `PAT `), pictures
  (`PICT`), and the font strikes (`NFNT`/`sfnt`, in the Fonts folder's
  suitcases rather than the System file).
- **Extractable as numbers**: the theme file's 21 accent `clut`s.
- **Not extractable, must stay drawn**: Platinum chrome. The theme file
  was opened and does not contradict this.

## What the extracted small icons changed on screen

`ics8` is not `icl8` shrunk — it is a separate, hand-tuned drawing — so
the renderer picks by the size of the box it is filling. Regenerating
every capture (`NOW_RENDER_DIR`) moved the menu-bar app slot in all nine
and the Finder list rows in three; the icon-view cells are 32×32 and
correctly did not move. Downsampled 32s had been rendering visibly soft
against a machine that draws them crisp.

Still generic, and deliberately: **which** icon belongs to which Finder
item. Icons arrive as bits with no identity, and nothing in this pack
changes that.
