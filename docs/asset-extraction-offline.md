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
four steps above, end to end. By default it writes a new timestamped
`pack-*/Resources` beneath `$NOW_MIRROR_ASSET_STORE` (or
`~/Lab/Assets/now-mirror-assets`) and prints the completed destination. The
resource parsers extracted from the former live-pull route now live at
`tools/asset-pack/`; the archived orchestrator remains provenance only. Keeping
one parser implementation means the two transports cannot disagree about what
an `icl8` means.

```
tools/extract-assets-offline                 # default image, default pack
tools/extract-assets-offline --store DIR     # another external pack store
tools/extract-assets-offline --out DIR       # deliberate exact destination
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
| Font strikes (`NFNT` sheets + metrics) | 9 — Chicago 12, Geneva 9/9-italic/10/12/14/18/20/24 |
| TrueType faces (`sfnt`, carried verbatim) | 3 — Chicago, Charcoal, Geneva |
| Strikes rasterised from a `sfnt` (no `NFNT` to lift) | 16 — Charcoal 9–24, one per `hdmx` row |

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
keep drawing it;
[mirror-assets.md](mirror-assets.md) needed no correction.

**Tabs were asked about separately, and get the same answer.** The
2026-08-07 fidelity sweep found the Appearance and Energy Saver panels
rendering with no tab edges in both passes, and Appearance also losing
its "Themes"/"Appearance" tab labels — so plan 018's slice 5 re-opened
the census specifically to look for tab art. There is none: no `PICT`
in the file is a tab or a tab edge, and the only bitmaps are the fifteen
listed above. What the file carries for tabs is `tvar`/`tthm`/`scen`
and the accent `clut`s — **parameters**. `DrawThemeTab` /
`DrawThemeTabPane` draw them at run time from those, exactly as
`DrawThemeWindowFrame` draws the title bar.

So the missing tab edges are a **renderer** gap, not an extraction gap,
and there is nothing here for the extractor to grow. They belong to a
host-side tab drawing routine — which plan 018's procedural-chrome lane
then wrote, by the route the next paragraph describes rather than by
[plan 016](plans/2026-08-06-016-feat-platinum-from-the-source-plan.md)'s
"ask a running `AppearanceLib`" one. Recorded here rather
than left in a session note because the next person to see a missing
tab edge will come looking in the extractor, which is where the answer
is not.

(The blank theme *swatches* in the Appearance panel are the one part
that could have been art: they are the fourteen 177×125 `PICT`s above.
The pack carries `PICT` unconverted because macOS has no QuickDraw
picture decoder — a separate, pre-existing decision, not this gap.)
**"From the ported specification" was the wrong second half of that
sentence, and 2026-08-07 corrected it.** The Appearance Manager draws
procedurally *through the QuickDraw bottlenecks*, so most of a themed
element's parameters — its boxes, its state colours, its bevel greys,
and metrics nothing reports — are already in any capture of a window
that draws it. The host draws chrome, but the numbers come from the
guest, per capture, not from constants anyone chose. The method is
[deriving-a-drawn-procedure.md](deriving-a-drawn-procedure.md) and the
first element done that way is the tab.

What the file *does* contain that is worth having is **specification,
not art**: the 21 accent ramps are the exact eight-step colour tables the
Appearance Manager tints highlights and selections with, and lifting
those numbers is the same move as porting the seven greys. That is a
colour-table extraction, not a bitmap one. It is now in the extractor —
see the next section.

## The 21 accent ramps, as numbers

`tools/extract-assets-offline --accent-ramps` prints them; a full run
generates
[`PlatinumAccentRamps.swift`](../now-host/Packages/MirrorKit/Sources/MirrorKitUI/PlatinumAccentRamps.swift)
beside the renderer. **Source, not a pack file** — 21 names and 160 RGB
triples the renderer wants at static-init, with no bundle lookup and no
decode that could fail quietly into a fallback nobody would ever see on
screen.

**The `clut` layout was read, not guessed.** It is QuickDraw's
`ColorTable` (Inside Macintosh: Imaging With QuickDraw, "Color Table";
declared in Universal Interfaces `Quickdraw.h`):

| field | bytes | note |
|---|---|---|
| `ctSeed` | 4 | |
| `ctFlags` | 2 | 0x0000 pixmap, 0x8000 device |
| `ctSize` | 2 | number of entries **minus one** |
| `ctTable` | 8 × (ctSize+1) | `value`, then `red`/`green`/`blue` at 16 bits each |

which is `8 + 8n` bytes — and that arithmetic is the **check**, not the
comment: it predicts both the 72-byte ramps (n = 8) and the 8-byte
`Black & White` (ctSize = −1, no entries) at once, which a misread
layout could not do. Channels convert by taking the high byte, exactly
and losslessly: every value in this file is a byte doubled (`0xCCCC`,
`0xEEEE`, `0xFFFF`).

Every ramp runs light to dark and ends in black. `Black & White` is a
real ramp with no entries, and is carried as one rather than dropped.

### Which ramp is ACTIVE — as far as an image can say

The theme file names twenty-one ramps; it does not say which one a
machine uses. Two independent slots in `scen` 2000 **"Mac OS Default"**
— the shipped default scene — answer it, and they agree:

- One item holds a Pascal string that is one of the 21 clut names in
  **all fourteen scenes without exception**. For the default scene it is
  **Lavender** (`clut` 208). (Its tag decodes as `vfnt`, which cannot be
  what Apple meant it for; the slot is identified here by the invariant
  it satisfies, not by a name we would be guessing at.)
- `hcol` holds the Appearance control panel's **highlight colour name**
  and `lgsf` its literal `RGBColor`. For the default scene those are
  `"Purple"` and **0xCCCCFF** — which is Lavender's second step,
  exactly.

`scen` is a flattened **Collection**, not a struct: 16-byte header
entries (id, attributes `0x40000000`, offset, `OSType` tag) then a data
area where each item's `UInt32` size sits immediately before the bytes
its offset points at. The walk stops on the first entry whose attributes
are not `0x40000000` rather than trusting the leading word as a count —
mis-taking that word (a version) for a count is exactly how this parse
went wrong the first time.

The highlight name is **not** a ramp name (`Purple`, `Yellow`, `Gray`
are in that list and none is a ramp), so the two settings are
independent and only coincide for some themes. Gray Space's highlight is
0xCCCCCC; Bubbles' is 0x99FFFF, which is not a Bondi step at all.

There is **no `Appearance Preferences` file** anywhere in the guest's
Preferences folder, so nothing on this image has overridden the shipped
default. That is evidence, not proof: only a running AppearanceLib can
say what it resolves. `PlatinumAccent.active` is the named seam, and
plan 016 P2's `GetThemeAccentColors` applet is what replaces it.

### The difference list

Every colour the renderer draws that these numbers touch, ported value
beside measured value:

| what | ported | measured | verdict |
|---|---|---|---|
| `Platinum.selection` — menu-title fill, derived-grid ring | `0x333399` | Lavender step 4 = `0x333399` | **identical.** The port was right; only its provenance changed |
| selected list row (`SceneRenderer`, list cells) | `Platinum.g2` = `0xCCCCCC` | default scene's highlight = `0xCCCCFF` | **differs**, one blue channel. `0xCCCCCC` is a real Appearance highlight — the *Gray Space* theme's |

The first row is the more valuable one, and plan 016's stop condition is
why it is written down rather than acted on: a constant that survives
measurement unchanged is a result, and changing code to celebrate it
would be worse than leaving it alone.

Two observations recorded and **deliberately not acted on**:

- The seven greys are close to the **Silver** ramp (`g1`/`g2`/`g5`/`g6`
  match `EEEEEE`/`CCCCCC`/`555555`/`000000`; `g3` is `A6A6A6` against
  `AAAAAA`, `g4` `888888` against `777777`). Silver is an **accent**
  ramp, not the chrome grey scale — the resemblance is a family
  likeness, not a source. The chrome greys are `GetThemeBrushAsColor`'s
  answer to give, which is P2's job.
- `Black & White` being empty means a machine set to it has no accent
  ramp to index; whatever the Appearance Manager does there is not in
  this file.

### What changed on screen

**Nothing, in the nine existing captures.** Regenerating them
(`NOW_RENDER_DIR`) produced nine byte-identical PNGs, and that is not
because the change is subtle: forcing the highlight to magenta and
regenerating *also* changed nothing, so **no capture in the corpus has a
selected list row**. The new render test carries its own scene for that
reason. No guest screendump has a selected row either, so this colour is
**measured from the source, not metal-verified** — a machine has not yet
been watched drawing it.

## The fonts — and the one this image cannot give

Added 2026-08-07. Until then **the offline route extracted no fonts at
all**, which quietly broke the recovery procedure this page and
[asset-pack.md](asset-pack.md) both name: "run the extractor" rebuilt a
pack whose `fonts/` directory was empty, and `FontBook` — which asks for
`chicago-12` and `geneva-9/10/12` by name — answered nil for all of them
and fell through to a fallback face with different metrics. The pack in
the store had its strikes because the *wire* route put them there.

The strikes are **not in the System file**. Its four `NFNT`s are a
Geneva/Monaco rump; the real ones are in `System Folder:Fonts:`, each
suitcase a file with an empty data fork and everything in its resource
fork. The parser is the live route's own `fonts.py`
(`parse_fond` → association table → `parse_nfnt` → `render_strike`), so
the sheets cannot disagree between routes — and they demonstrably do
not: **all eight sheets the store's pack already carried came out of the
offline route byte-identical**, PNG and metrics JSON alike. The offline
run also produces a ninth, `geneva-9-italic` (`NFNT` 769), which the
wire pack was missing.

**Charcoal — the Mac OS 8/9 system font — has no strike to extract, and
that is a fact about the image rather than a gap in the tool.** Its
suitcase holds `FOND` 2002, one `sfnt`, `vers`, `ftag` — and the `FOND`
association table has exactly one row, `(size 0, style 0, id 9719)`,
size 0 meaning *scalable*. There is no `NFNT` anywhere on the volume for
it, the System file included, and its `sfnt` carries no embedded bitmap
tables either (no `bdat`/`bloc`, no `EBDT`/`EBLC` — the table list is
`OS/2 VDMX bsln cmap cvt fdsc feat fmtx fpgm glyf hdmx head hhea hmtx
just loca maxp mort name post prep prop umif`). Mac OS rasterises
Charcoal from TrueType at run time, with `hdmx` supplying the device
metrics.

**So the extractor rasterises it too, since 2026-08-07** — a face with no
`NFNT` is rendered from its own `sfnt` by `fonts.render_truetype_strike`
at every ppem its `hdmx` table carries device metrics for, and at no
other size. For Charcoal that is 9–24: 16 strikes, 223 glyphs each. The
advances are `hdmx`'s, not the rasteriser's, and a ppem with no `hdmx`
row raises rather than being filled in, because a strike whose widths are
a guess is worse than the substitution it replaces. The shapes are
FreeType's and OS 9's interpreter is not FreeType, so that half is
measured against the guest's own screendumps rather than claimed:
**5.86% of ink pixels disagree, against Chicago's 72.81%**, and the eight
group-box title widths the guest itself measured come out exact. The
numbers, the residual and what still substitutes are in
[charcoal-strike.md](charcoal-strike.md).

The three `sfnt`s are carried out verbatim as `fonts/ttf/<face>.ttf` (an
`sfnt` resource *is* the TrueType file image); Charcoal's is now read.

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
