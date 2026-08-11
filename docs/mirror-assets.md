# Extracting the guest's own Platinum assets

**Date:** 2026-07-31 · **Status:** recorded knowledge, carried from the
parked upstream project `timbottu/mirror`
(`docs/ASSET-EXTRACTION.md`, plus the asset sections of `HANDOFF.md`
and `PROTOTYPE-NOTES.md`). Nothing here was measured by NOW.

**Provenance.** Every verified item below was proven on 2026-07-16
against a QEMU `mac99` guest running Mac OS 9.1. Not on hardware.

## The constraint that comes first

**These are Apple's bitmaps.** Upstream's rule: the extracted pack stays
private, is never published, never ships as an artifact, never goes
upstream, and is never shared externally. Pulls are read-only, from an
own VM, and nothing is written into any guest System Folder.

Any NOW use of this material inherits that rule unchanged.

## Why it mattered

Timbuktu's hardest problem — a font the far side does not have —
required a whole apparatus: a font-number mapping function, a per-glyph
sent-cache, and a fall back to shipping bitmaps when a face was missing.

**Extracting the guest's own bitmap strikes deletes that entire
problem.** Text captured semantically replays through the guest's real
glyphs at the right size, and the only remaining fallback is the rare
unknown face. Upstream reports its rendered sheets matched the guest at
IoU 1.0 (mac99).

## Where the assets actually live

| Asset | Location | Verified detail |
|---|---|---|
| Fonts | `System Folder:Fonts`, as FFIL suitcases — **not in the System file** | Chicago 104,029 B, Charcoal 88,553 B, Geneva 142,815 B resource forks, plus 27 other suitcases |
| Icons, cursors, patterns | `System Folder:System` (type `zsys`, resource fork 7,893,757 B) | 52 `icl8`, 52 `icl4`, 57 `ICN#`, 75 `ics8`, 78 `ics#`, 40 `CURS`, 21 `cicn`, 25 `SICN`, 32 `ICON`, 42 `PICT`, 3 `ppat`, 5 `PAT `, 1 `PAT#` — **no `NFNT`/`FOND`** |
| The Platinum theme | `System Folder:Appearance` | holds `Desktop Pictures`, `Sound Sets`, `Theme Files` |
| Application icons | each application's own resource fork | `BNDL` / `FREF` / `icl8`, keyed by creator + type |

**The Chicago suitcase carries both formats:** a `FOND` (16383) with a
bitmap `NFNT` (4502) **and** a TrueType `sfnt` (4027). Upstream expected
the same shape in Geneva and Charcoal, with multiple `NFNT`s for 9/10/12
pt — **stated as a hypothesis, to verify per suitcase.**

## The extraction route that worked

Pull the resource fork off a **live guest over the wire** and parse it
host-side. No image mounting, no offline surgery.

| Step | Result |
|---|---|
| Pull one font suitcase's resource fork | 0.1 s |
| Pull the whole System file's resource fork | 24 s, ~330 KB/s (mac99) |
| Parse the pulled fork | stock `DeRez -useDF` reads it as a plain file — no extra tooling to enumerate or dump resources |

An **explicitly unverified alternative** upstream noted and did not use:
convert the disk image to raw, attach it read-only, and read the named
resource fork. The wire route was proven and sufficient.

**That alternative is now the route.** It was verified on 2026-08-06 and
built into `tools/extract-assets-offline`; the step upstream would have
run aground on — the Apple_HFS partition being an HFS *wrapper* modern
macOS refuses, with the real volume embedded inside — is written up in
[asset-extraction-offline.md](asset-extraction-offline.md). The two
routes were cross-checked: the generic icons come out byte-identical.

> **VERIFIED 2026-08-06, and it is far faster**: see
> [asset-extraction-offline.md](asset-extraction-offline.md). The whole
> System file's fork — 7,893,757 bytes, 2,162 resources — is an
> ordinary file read instead of 24 s at ~330 KB/s, with resource forks
> exposed by macOS at `<file>/..namedfork/rsrc`. The step that makes it
> look impossible is that the `Apple_HFS` partition is an HFS WRAPPER
> whose embedded HFS+ volume must be located through the MDB; modern
> macOS refuses the wrapper because HFS Standard support is gone. No VM
> boots, and the read-only-on-a-copy rule above is unchanged.

Two host-side parsing options were named as **hypotheses, not tried**: a
Python resource-fork package (cleaner programmatically, was not
installed) and `fondu` for converting the classic font resources to BDF.

## Format facts worth not re-deriving

- **`sfnt` → `.ttf` is a byte copy.** The resource payload *is* a
  TrueType font file. Concatenate the bytes verbatim, write `.ttf`,
  validate by loading it.
- **`NFNT` layout** (Inside Macintosh: Text, ch. 4): a header —
  `fontType, firstChar, lastChar, widMax, kernMax, nDescent, fRectWidth,
  fRectHeight, owTLoc, ascent, descent, leading, rowWords` — then the bit
  image (`rowWords × 16` px wide, `fRectHeight` rows), then the
  offset/width table. **Glyph *i*'s image sits between `locTable[i]` and
  `locTable[i+1]` columns. Missing glyphs have offset and width
  `0xFFFF`.**
- **`icl8` / `ics8`** are 32×32 / 16×16 8-bit indices into the standard
  system CLUT — the documented 6×6×6 colour cube plus a grey ramp.
  **Generate the CLUT; do not extract it.** The mask comes from the
  matching `ICN#` / `ics#` **second plane**. Upstream hit and fixed a
  tail off-by-one in its generated CLUT that darkened one end of the
  ramp.
- **`CURS`** is 16×16 1-bit data plus mask plus a hotspot point.
- **`ppat`** is a PixPat structure resolving to a small RGB tile.

## Two font fidelity tiers

| Tier | What | Upstream's judgement |
|---|---|---|
| 1 | Register the extracted TrueType faces at runtime and point the theme's system/application font at them | a **visual upgrade, not ground truth** — the guest screen renders from the bitmap strikes, so pixel fidelity at 9–12 pt is explicitly not guaranteed |
| 2 | Per-glyph sprite sheets plus a metrics file rendered exactly from the bitmap resources | **required for pixel-honest text** — the tier the renders were made with |

Minimum set for tier 2: Chicago 12, Charcoal 12, Geneva 9 / 10 / 12.
Charcoal is the one with no `NFNT` to lift on this image at all — it is
rasterised from its own `sfnt` with `hdmx` advances instead
([charcoal-strike.md](charcoal-strike.md)).

## Platinum chrome is not an asset

**Window frames, title bars, scroll bars and buttons are drawn
procedurally by the Appearance Manager.** There are no chrome bitmaps to
extract.

**Checked, 2026-08-06.** This was inherited belief until the theme file
itself was opened offline. `Apple platinum` holds 21 accent `clut`s, 15
preview `PICT`s, 14 `scen` settings blobs and its own Finder icon —
**no window furniture of any kind**. The evidence table is in
[asset-extraction-offline.md](asset-extraction-offline.md); nothing here
needed correcting. Upstream ported the *specification* — the seven grey levels its
own theme code uses — and kept the host renderer in sync with that,
rather than trying to lift images.

> **TRUE, but the conclusion drawn from it was too weak (2026-08-06).**
> "No bitmaps" was read as "reimplement from a ported spec", and there
> is a third option the API surface makes obvious once looked at: the
> Appearance Manager ANSWERS. `GetThemeMetric` over ~40 selectors,
> `GetThemeBrushAsColor`, `GetThemeTextColor`, `GetThemeAccentColors`,
> `GetThemeWindowRegion`, `GetThemeScrollBarTrackRect`, `GetThemeFont`
> — the machine will state its own metrics, colours and geometry — and
> thirty-odd `DrawTheme*` entry points will draw any element into an
> offscreen GWorld once, as a bakeable asset. So chrome can be measured
> from the source rather than guessed at, without shipping pixels at
> runtime. Plan
> [016](plans/2026-08-06-016-feat-platinum-from-the-source-plan.md).

Every window frame in [mirror-renders.md](mirror-renders.md) is drawn,
not extracted.

## The icon gaps upstream did not close

- **Control panels are type `APPC`, not `cdev`.**
- **The hard-disk icon has no file** — it lives in ROM and Icon Services,
  so it is drawn procedurally.
- Third-party items and items with an unset creator fall back to generic
  bitmaps by kind.
- **True per-application icons via the Desktop database were not
  possible as built.** The call is not in the Retro68 headers and would
  require declaring the Desktop Manager traps. The resource-fork route
  covers the ordinary set; the database would additionally catch custom
  alias icons, which today collide on a single generic glyph.

## The verification method

Render a known string from the extracted sheet and compare it against a
capture of the guest showing the same string. That is where the IoU
number comes from, and it is the method that would have to be re-run for
any face NOW extracts itself.

## Where the pack lives now (2026-08-06)

**Not in this repository.** The extracted pack is a runtime dependency
of proper rendering, resolved by `MirrorKitUI/AssetPack.swift` and
regenerated by `tools/extract-assets-offline`; the renderer degrades to
procedural stand-ins without it and says so, loudly, rather than
drawing generic art as though it were the guest's.

That is the same rule as the constraint at the top of this page, made
operational: [asset-pack.md](asset-pack.md) is the resolution order,
the regeneration procedure, what the gates do with and without a pack,
and what the decision deliberately left open.
