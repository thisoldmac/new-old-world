# platinum-pack — real OS 9.1 Platinum assets

The ported Platinum asset pack the mirror README contracts: real
Chicago/Charcoal/Geneva glyphs, real System icons/cursors, and the default
desktop pattern — extracted from the canonical `os91-runner.qcow2` guest (mac99,
OS 9.1) so `MirrorKitUI` can swap out its `mock-platinum` stand-ins.

**This is Apple's bitmap/font data.** It lives in this private repo for the
mirror's own rendering only. Never publish it — no artifacts, no upstream, no
external sharing (see `../ASSET-EXTRACTION.md` → Rules).

The generated files here are produced by `../extract-assets/extract.py`; re-run
that to regenerate (a rerun only writes, it never wipes this hand-authored
README or `validation/`). `manifest.json` traces every generated file to its
source (`System Folder` path + resource type + id).

## Layout

```
fonts/<face>-<size>.png    Tier-2 glyph sheet (packed printable ASCII 32-126)
fonts/<face>-<size>.json   metrics: {ascent,descent,leading,frectHeight,
                           cellHeight, glyphs:{char:{x,y,w,h,advance,left}}}
fonts/ttf/<face>.ttf       Tier-1 Apple TrueType (the suitcase 'sfnt' verbatim)
icons/<name>_<dim>.png     icl8 (32) / ics8 (16) composited with ICN#/ics# mask
cursors/<name>.png         CURS 16x16 RGBA;  cursors/hotspots.json has hotspots
patterns/desktop.png       the default desktop pattern ('ppat' 16 "Mac OS Default")
patterns/ppat_*.png        other colour PixPats;  patterns/pat_*.png the 'PAT ' fills
manifest.json              version, source image, per-asset provenance
validation/                Tier-2 acceptance evidence (see below)
```

### Fonts — two tiers

- **Tier 1 (TTF).** Each suitcase carries a TrueType `sfnt`; the resource *is* a
  `.ttf` file, copied verbatim. All three load clean through CoreText
  (`manifest.fonts.ttf[*].coretext_valid == true`). Register at runtime and
  point `Platinum.systemFont/appFont` at them. Native layout, real shapes;
  pixel fidelity at 9-12 pt is *not* guaranteed against the guest's bitmap
  rendering.
- **Tier 2 (bitmap sheets).** Rendered from the `NFNT` strikes for pixel-honest
  text. Place glyph `ch` at pen `x + left`, top `baseline - ascent`, advance by
  `advance`. Reference consumer: `../extract-assets/render_string.py`.
  - **Chicago 12** (system font) — 1 strike.
  - **Geneva 9 / 9-italic / 10 / 12 / 14 / 18 / 20 / 24** — Geneva ships 8
    strikes; all exported.
  - **Charcoal has no bitmap strike.** The suitcase is TrueType-only (`sfnt`
    only, no `NFNT`), so there is no Tier-2 Charcoal sheet. The guest itself
    renders Charcoal from the TrueType; MirrorKit should do the same (rasterise
    `ttf/Charcoal.ttf` at the target size). `manifest.fonts.notes.Charcoal`
    records this.

### Desktop pattern

`patterns/desktop.png` is `ppat` id 16, whose resource name is literally
**"Mac OS Default"** — a 128x128 8-bit tile (the classic blue-grey with the
embossed Finder-face watermark). That name self-identifies it as the OS default
desktop; the other System `ppat`s (18, 42) are small UI fills.

## Tier-2 acceptance (validated 2026-07-16, IoU 1.0)

`validation/tbtrunner-geneva10.png` stacks the live guest's Finder icon label
"TBTRunner" (top) over the same string rendered from `fonts/geneva-10` (bottom)
— pixel-identical. `../extract-assets/validate.py --port <p>` reproduces it
against a live guest and asserts IoU >= 0.95; the verified run scored **1.0**
(exact bounding box, zero shift). Note the Finder icon-label font on this guest
is **Geneva 10**, not Geneva 9.

## Consuming from MirrorKit

The pack is pure data; wiring it into `PlatinumTheme.swift` (replacing
`mock-platinum`) lands separately on the mirror side. Nothing here touches Swift.
