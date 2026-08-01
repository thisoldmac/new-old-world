# Platinum asset extraction — agent brief

`corpus_impact`: none because this is a work brief; the OS 9.1 resource
inventory it cites is recorded here pending the extraction outcome, and the
extraction agent's closeout owns the finding.

**Goal.** Produce the ported Platinum **asset pack** the mirror README
contracts (README.md → "Asset-pack contract"): real Chicago/Charcoal/Geneva
glyphs, real icons, the desktop pattern, and cursors — extracted from the
canonical OS 9.1 guest image — so `MirrorKitUI` can swap out its
`mock-platinum` stand-ins. Window *chrome* stays procedural (`ui_theme.c` →
`platinum.css` → `PlatinumTheme.swift`); do **not** extract chrome bitmaps.

Everything in *Verified* below was proven live on 2026-07-16 against the
canonical `os91-runner.qcow2` image (mac99, OS 9.1). Commands are exact.

## Verified facts (2026-07-16, live guest)

- **Fonts live as FFIL suitcases in `Macintosh HD:System Folder:Fonts`**, not
  in the System file. Present: Chicago (rsrc 104,029 B), Charcoal (88,553 B),
  Geneva (142,815 B) — plus 27 others.
- **The Chicago suitcase carries BOTH formats**: `FOND` 16383 + bitmap
  `NFNT` 4502 **and a TrueType `sfnt` 4027**. (Expect the same shape in
  Geneva/Charcoal — multiple NFNTs for 9/10/12 etc.; verify per suitcase.)
- **System file** (`Macintosh HD:System Folder:System`, zsys, rsrc fork
  7,893,757 B) census of asset types: 52 `icl8`, 52 `icl4`, 57 `ICN#`,
  75 `ics8`, 78 `ics#`, 40 `CURS`, 21 `cicn`, 25 `SICN`, 32 `ICON`,
  42 `PICT`, 3 `ppat`, 5 `PAT `, 1 `PAT#`. No NFNT/FOND (they're in Fonts).
- **Wire pull works and is fast**: `Harness.pull_file(path, fork="rsrc")`
  MacBinary-decodes both forks host-side; Chicago pulled in 0.1 s, the whole
  System rsrc fork in 24 s (~330 KB/s, emu).
- **Stock `DeRez -useDF` parses a pulled fork saved as a plain file** — no
  extra tooling required to enumerate/dump resources:
  ```
  DeRez -useDF System.rsrc | grep "^data" | sed "s/^data '\([^']*\)'.*/\1/" | sort | uniq -c
  DeRez -useDF Chicago.rsrc -only "'NFNT'"
  ```
- `Macintosh HD:System Folder:Appearance` holds `Desktop Pictures`,
  `Sound Sets`, `Theme Files` folders (the Platinum theme file lives there).

## Extraction route (verified transport)

Pull off a **live guest** via the worker wire — no image mounting needed:

```python
import sys; sys.path.insert(0, "<repo>/mcp")
from timbottu_mcp_classic.harness import Harness
h = Harness(host="127.0.0.1", port=1400, expect_backing={"worker"})
f = h.pull_file("Macintosh HD:System Folder:Fonts:Chicago", fork="rsrc")
open("Chicago.rsrc", "wb").write(f.rsrc_fork)
```

Spin up your own VM (standard practice — never borrow another session's):

```
TIMBOTTU_QEMU=<main-worktree>/qemu/build/qemu-system-ppc \
TIMBOTTU_IMAGE=$HOME/Lab/Assets/os91-qemu/os91-runner.qcow2 \
tools/launch --headless        # anchor worker auto-starts on :1400, ~55 s
```

Pulls are read-only; `tools/stop` when done. *(Alternative, unverified: 
`qemu-img convert` to raw + `hdiutil attach -readonly` and read
`..namedfork/rsrc` — hypothesis only; the wire route is proven and enough.)*

## Parsing (host-side)

- **Resource map**: `DeRez -useDF` (verified) or the `rsrcfork` PyPI package
  (cleaner programmatic access; not yet installed here — hypothesis).
  `fondu` (brew) converts FOND/NFNT→BDF if preferred (hypothesis).
- **`sfnt` → `.ttf`**: the resource payload is a TrueType font file;
  concatenate the resource bytes verbatim, write `.ttf`, validate by loading
  (CTFont / fontTools). Two-tier plan below.
- **`NFNT`** (Inside Macintosh: Text, ch. 4): header (fontType, firstChar,
  lastChar, widMax, kernMax, nDescent, fRectWidth, fRectHeight, owTLoc,
  ascent, descent, leading, rowWords) + bitImage (rowWords×16 px wide,
  fRectHeight rows) + offset/width table. Glyph i's image sits between
  locTable[i] and locTable[i+1] columns. Missing glyphs have offset/width
  0xFFFF.
- **`icl8`/`ics8`**: 32×32 / 16×16, 8-bit indices into the **standard system
  8-bit CLUT** (the documented 6×6×6 color cube + grays ramp — generate it,
  don't extract it). Mask comes from the matching `ICN#`/`ics#` second plane.
- **`ppat`**: PixPat structure → small RGB tile (the OS 9 default desktop
  pattern candidates are the System `ppat`s and the Platinum theme file).
- **`CURS`**: 16×16 1-bit data + mask + hotspot point.

## Two fidelity tiers for fonts

1. **Tier 1 — `sfnt` TrueType** (quick win): register the extracted TTFs at
   runtime (`CTFontManagerRegisterFontsForURL`) and point
   `Platinum.systemFont/appFont` at them. Native text layout, real glyph
   shapes. *Pixel fidelity vs the guest's bitmap rendering at 9–12 pt is
   NOT guaranteed* (the guest screen uses the NFNT bitmaps) — treat as a
   visual upgrade, not ground truth.
2. **Tier 2 — NFNT sprite sheets** (gold standard): per-glyph PNG sheet +
   metrics JSON rendered exactly from the bitmap resources. Required for
   pixel-honest text (Geneva 9 lists, menu titles). Chicago 12, Charcoal 12,
   Geneva 9/10/12 minimum.

## Deliverable contract

```
prototypes/mirror/assets/platinum-pack/
  manifest.json           # version, source image id, per-asset provenance
                          #   (file path + resource type/id), extraction date
  fonts/<face>-<size>.png # glyph sheet (Tier 2)
  fonts/<face>-<size>.json# {ascent, descent, leading, glyphs: {char:
                          #   {x,y,w,h,advance}}}
  fonts/ttf/<face>.ttf    # Tier 1
  icons/<name>.png        # icl8+ICN#-mask composited RGBA, 32×32 (+ ics8 16×16)
  cursors/<name>.png      # RGBA + "hotspot" in a sidecar or manifest
  patterns/desktop.png    # the default desktop ppat tile (+ any PAT fills)
```

Plus the extractor itself (rerunnable, checked in):
`prototypes/mirror/extract-assets/` (Python; pull → parse → render → manifest).
`MirrorKitUI` consumption lands separately — deliver the pack + a short
README; the mirror side wires it in.

## Acceptance

- Re-runnable end to end against a fresh VM (one command).
- Manifest provenance complete: every PNG traces to file + type + id.
- Tier 2 metrics sanity: rendering "The quick brown fox…" from the sheet
  matches the guest — compare against a `capture` screenshot of SimpleText
  showing the same string (the capture verb is in the anchor's scope).
- `swift test` untouched (the pack is data; no MirrorKit code changes).

## Rules

- **Copyright**: these are Apple's bitmaps. The pack stays in this private
  repo for the mirror's own rendering; never publish it (no artifacts, no
  upstream, no external sharing).
- Own VM only; read-only pulls; no writes into any guest System Folder.
- Close out with `corpus_impact` — the durable claims (suitcase contents,
  System census corrections, which ppat is the default desktop) belong in a
  finding.

## Context pointers

- README.md → "Asset-pack contract" (the source contract this fulfils).
- MIRRORKIT-PLAN.md (what MirrorKitUI is; mock-platinum is the stand-in).
- `MirrorKit/Sources/MirrorKitUI/PlatinumTheme.swift` (the swap point).
- `attic/web/platinum.css` + guest `ui_theme.c` (procedural chrome — stays).
- Memory/recipes: `tools/launch` clones by default; stop via QMP quit.
