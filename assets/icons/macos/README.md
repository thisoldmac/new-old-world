<!-- now-doc-provenance: generated reviewed=false -->

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

## The menu-bar glyphs

The status item used to be text — `● New Old World` — where a single leading
character carried the connection state. Replacing the words with a picture
would have thrown that signal away, so the state moved **onto the machine's
screen**: one shape, five fills.

| State | Screen | Replaces |
| --- | --- | --- |
| `notListening` | empty | `○` |
| `waiting` | a dot | `◌` |
| `connected` | filled | `●` |
| `connected`, quiet | half filled | `◐` |
| `failed` | filled behind a bang | `⚠` |

The menu bar now gets an 18pt icon instead of a sentence, and the state is
still readable without opening anything. `GuestStatus.statusImageName` picks
the asset; `GuestStatus.glyph` is untouched and still the fallback.

These are **template images**: shape lives in the alpha channel and RGB is
zero everywhere, so macOS paints them black on a light menu bar, white on a
dark one, and inverts them while the menu is held open. Baked-in colour would
fight the system and look wrong in half the states it can appear in. macOS
displays are 1x or 2x — there is no 3x — so each glyph ships at 18pt and 36pt.

Two things are deliberately not where you might look for them. The glyph
carries the app's identity, so the resting item has **no text at all**; if the
image cannot be loaded, `restingTitle` puts the old `● New Old World` back
rather than leaving an invisible status item. And because the text is gone,
the image sets an `accessibilityDescription` and the button a tooltip — both
the menu line — so VoiceOver still reads the state rather than just a name.

Whether every name the enum can return actually exists as an asset is checked
by `statusglyph.py`, **not** by a unit test. The catalog is compiled into the
app bundle by Xcode, so under `swift test` `NSImage(named:)` searches the test
runner's bundle and finds nothing whatever the name says — a test there would
fail for the wrong reason. The generator can see the Swift enum and the images
it writes at the same time, so that is where the two are held to agree.

## What is here

| Path | What it is |
| --- | --- |
| `appicon.py` | Draws the icon and writes the catalog, the `.icns` and the review sheet. **Source of truth.** |
| `statusglyph.py` | Draws the five menu-bar template glyphs, cross-checks them against `GuestStatus.statusImageName`, and writes `status-glyphs.png`. |
| `status-glyphs.png` | The five glyphs as the system will paint them: black on light, white on dark. |
| `source-512.png` | The original artwork. |
| `master-1024.png` | The full-size composition, as shipped to slots ≥64px. |
| `master-1024-small.png` | The simplified composition behind the 16px and 32px slots. |
| `NewOldWorld.icns` | Standalone icon for anything outside the app bundle — DMG, docs, Finder. |
| `review.png` | 16/32/64/128/256 at actual size, light and dark. |

`NewOldWorld.iconset/` is a build intermediate for `iconutil` and is
gitignored.

## Regenerating

```
python3 assets/icons/macos/appicon.py      # app icon
python3 assets/icons/macos/statusglyph.py  # menu-bar glyphs
```

Pillow + NumPy, plus `iconutil` from the system. Both rewrite the asset
catalog in place. `statusglyph.py` exits non-zero if the glyph names and
`GuestStatus.statusImageName` have drifted apart.

## How it is wired

`now-host/NewOldWorld.xcodeproj` uses a `PBXFileSystemSynchronizedRootGroup`
for `Sources/Host`, so anything placed in that folder is picked up by the
target automatically — the catalog needed no file-list surgery. The only
project change was `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon` in the two
target build configurations.

## Verified, and not

Verified: `iconutil` accepts the set, which rejects a missing slot or a file
whose pixel size disagrees with its name; `xcodebuild` builds the app; the
built bundle carries all ten renditions in `Assets.car` with
`CFBundleIconName = AppIcon` in its `Info.plist`; all five glyphs are in the
same catalog at both scales with `template=template`, which is what makes them
invert in a dark menu bar; and the host suite passes, 593 tests.

**Not verified: how any of it looks in a real Dock, Finder or menu bar.** That
wants a human glance before it is treated as final — particularly the glyphs,
which have only ever been seen as PNGs here, never in an actual menu bar.

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
