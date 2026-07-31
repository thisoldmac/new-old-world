# The host app icon

The macOS application icon for **New Old World** — the compact Mac on a
charcoal tile. Added 2026-07-31.

This is the icon the Xcode target actually builds. `appicon.py` writes the
asset catalog straight into `now-host/Sources/Host/Assets.xcassets`, so
regenerating is the whole update.

## Why there is a backdrop at all

Since Big Sur, a macOS app icon is a rounded square on a 1024 canvas: the body
is 824×824 centred, and the 100px margin is what the system uses for the drop
shadow and hover growth. macOS 26 and later mask the icon to that shape
themselves. Free-form art — which is what the original compact Mac is — either
gets clipped or reads as foreign beside every other icon in the Dock, so the
machine sits on a tile.

**Charcoal** was chosen against blue, platinum and cream by rendering all four
and comparing at 32px. It is the only one where the beige case still reads at
that size; on platinum and cream the case tone is the backdrop tone and the
machine dissolves into a blob. Blue was the runner-up and is a defensible
alternative — the trade is that the backdrop and the Finder face on the screen
are then the same hue, which costs the screen some separation as it shrinks.

## Small sizes are drawn differently

Below 32px the detail loses the argument: the machine's own cast shadow
becomes a grey smear and the case stops separating from the tile. Apple's
guidance is to simplify rather than shrink, so the 16px and 32px slots come
from a second composition — the machine at 88% of the body instead of 76%, and
no cast shadow — plus a light unsharp pass to recover the edges the downscale
softens. `master-1024.png` and `master-1024-small.png` are the two.

Downscaling is done with **premultiplied alpha**. Resizing straight RGBA lets
the colour of fully transparent pixels bleed into the edge; because those
pixels carry black here, the first cut had a dark fringe around the tile.

## The source is the quality ceiling

The artwork is 512×512 and there is no vector or layered original, so it is
upscaled about 1.5× into the safe area. It holds up because the source is a
clean render rather than a photograph, but a larger or layered original would
lift the 256px and 512px slots noticeably. If one turns up, drop it in as
`source-512.png`'s replacement and re-run.

## What is here

| Path | What it is |
| --- | --- |
| `appicon.py` | Draws the icon and writes the catalog, the `.icns` and the review sheet. **Source of truth.** |
| `source-512.png` | The original artwork. |
| `master-1024.png` | The full-size composition, as shipped to slots ≥64px. |
| `master-1024-small.png` | The simplified composition behind the 16px and 32px slots. |
| `NewOldWorld.icns` | Standalone icon for anything outside the app bundle — DMG, docs, Finder. |
| `review.png` | 16/32/64/128/256 at actual size, light and dark. |

`NewOldWorld.iconset/` is a build intermediate for `iconutil` and is
gitignored.

## Regenerating

```
python3 assets/icons/macos/appicon.py
```

Pillow + NumPy, plus `iconutil` from the system. It rewrites the asset catalog
in place.

## How it is wired

`now-host/NewOldWorld.xcodeproj` uses a `PBXFileSystemSynchronizedRootGroup`
for `Sources/Host`, so anything placed in that folder is picked up by the
target automatically — the catalog needed no file-list surgery. The only
project change was `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon` in the two
target build configurations.

## Verified, and not

Verified: `iconutil` accepts the set, which rejects a missing slot or a file
whose pixel size disagrees with its name; `xcodebuild` builds the app; and the
built bundle carries all ten renditions in `Assets.car` with
`CFBundleIconName = AppIcon` in its `Info.plist`.

**Not verified: how it looks in a real Dock and Finder.** That wants a human
glance before it is treated as final.

## Not done: the macOS 26+ layered icon

macOS 26 introduced Icon Composer and the layered `.icon` format, with
light/dark/clear/tinted variants and the Liquid Glass treatment. This pack is
a conventional asset catalog, which every macOS version from the 13.0
deployment target upward renders correctly — but on 26 and later the system is
compositing a flat image rather than a layered one.

Doing it properly means authoring layers in Icon Composer, which is a GUI tool.
It also wants a decision about how the compact Mac should separate into
background and foreground layers. Worth doing; it is a design session, not a
regeneration.
