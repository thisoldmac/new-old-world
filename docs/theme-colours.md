# The colours the machine draws with

The host renderer redraws windows the guest's Appearance Manager erased.
To do that it has to fill the same faces — and for most of this project's
life it filled them with **constants**, which is a defect that never
looks like one.

This page is the rule, what the machine answered when it was finally
asked, and where the line between "a theme decides this" and "Platinum's
geometry decides this" was drawn.

## The rule

> **Where the machine can be asked, ask it.** Where it cannot, a measured
> constant is acceptable **only if it is declared as measured, with what
> and when** — the value, the instrument, the machine, the date.

A guess that looks right is the defect this whole arc has been removing,
and it is worse in a colour than in a rectangle, because **nothing ever
looks broken**. A wrong rectangle is visible in one glance; a wrong
colour survives every fidelity score in this repository, because a
whole-window similarity number cannot flag a face that is uniformly the
wrong grey.

Two constants had already gone wrong this exact way:

- **`ppat` 16 on the desktop.** A shipped factory resource, tiled in
  place of the real desktop pattern, plausible for years.
- **`Platinum.dialogFace`.** Counted off one screendump, correct for the
  shipped theme, silently wrong for any other. Named as such by the lane
  that introduced it — which is the only reason it did not become a third
  `ppat` 16.

## What is on the wire

`meta.theme`, added 2026-08-07. Four `#RRGGBB` strings and the depth they
were asked at. Contract: `contract/asyncapi.yaml`, "WHAT COLOUR THE
MACHINE DRAWS WITH". Guest: `now-guest-ppc/src/scene/scene_theme.c`.
Host: `SceneTheme`, which resolves it against the fallbacks and publishes
**per-colour provenance** so a fallback can never be mistaken for an
answer.

| key | asked with |
| --- | --- |
| `dialogBackground` | `GetThemeBrushAsColor(kThemeBrushDialogBackgroundActive, …)` |
| `alertBackground` | `GetThemeBrushAsColor(kThemeBrushAlertBackgroundActive, …)` |
| `documentBackground` | `GetThemeBrushAsColor(kThemeBrushDocumentWindowBackground, …)` |
| `highlight` | `LMGetHiliteRGB` |
| `depth` | the main device's `pixelSize` — the depth the four above were asked AT |

**`depth` is not decoration.** A brush answers differently on a
256-colour screen than on millions, so a colour with no depth beside it
cannot be checked against a screendump taken later. The guest's other
callers pass a flat 32; this one asks the screen.

### Three states, not two

- **No `theme` at all** — this producer did not ask.
- **`theme` present, a key absent** — the machine was asked and would not
  name that brush.
- **A value** — the machine named it. Including `#000000`: black is a
  legal colour, and so is the one value that cannot double as "unknown".

Those are different facts and a consumer needs them apart. Before this
field they were one thing: a constant.

## Where the line is: theme, or Platinum's geometry

**On the wire:** fills the machine *makes and hands out on request*. Each
one has a Toolbox call behind it that answers the question.

**Not on the wire, and deliberately:**

- **The bevel ramp** (`Platinum.g0`–`g6` as light/shadow edges). There
  *are* bevel brushes in Appearance 1.1, but **no guest source asks for
  one**: these greys are this side's drawing of the Platinum 3D idiom,
  not a fill any guest ever made. Putting them on the wire would ship a
  guess in a wire format, which is strictly worse than a labelled
  constant.
- **`Platinum.selection`** — the menu-title fill and the derived-grid
  selection ring. A marker this side draws. There is no brush for it;
  Appearance draws menu backgrounds with `DrawThemeMenuBackground`, not
  from a brush a caller can read.
- **Insets, hairlines, `menubarHeight`, `contentTop`.** Geometry. A theme
  does not move them and no call reports them.
- **The `Inactive` brush variants.** The scene has no per-window active
  bit a renderer could key them off. A field with no consumer is a field
  nobody notices going wrong.

The test for the line: **does a Toolbox call answer it?** If not, it is
not a theme answer, whatever it looks like.

## What the machine said, against what we were guessing

Asked of a stock Mac OS 9.1 guest (QEMU mac99, 800×600, screen depth 32),
guest build `beda718861c0 2026-08-07T07:37:01Z`. Evidence out of git:
`~/Lab/Assets/now-mirror-assets/019-theme-colours-2026-08-07/`.

| colour | what we carried | the machine | guest pixels | delta |
| --- | --- | --- | --- | --- |
| `dialogBackground` | `0xDDDDDD`, counted off a screendump | `#DDDDDD` | `#DDDDDD`, 24300 of 24300 px of NOW's own window face | **none** — the count was right |
| `alertBackground` | `0xEEEEEE`, then `0xDDDDDD` by argument | `#DDDDDD` | `#DDDDDD`, 40372 of 45974 px of a real Finder alert | **none against the second**; the first was wrong by 0x11 per channel |
| `documentBackground` | `0xFFFFFF`, hardcoded | `#FFFFFF` | not sampled — no document window in the capture | none |
| `highlight` | `0xCCCCFF`, extracted from the theme FILE | **`#97A1DE`** | `#97A1DE`, 2399 of 3240 px of a selected row | **R−53 G−43 B−33** |

### The one that overturned

`highlight` was `0xCCCCFF`, read offline out of the theme file's default
scene and corroborated by two slots in that file agreeing. The running
machine disagrees with both, and its own screendump agrees with the
running machine.

The seam was already written down — `PlatinumAccentRamps.swift` said in
its own comment *"this is what the theme file SAYS, not what a running
AppearanceLib answers"* — and so was the reason nobody caught it:
`AccentRampTests` records that **no capture in the corpus carried a
selected list row**, and forcing the constant to magenta changed no pixel
anywhere. So `0xCCCCFF` had never been seen on a screen.

`PlatinumAccent.activeHighlight` keeps it, relabelled: it is a true fact
about a **file**. `Platinum.highlightFallbackRGB` is now the measured
`0x97A1DE`, and `meta.theme.highlight` beats them both.

**Still unknown:** one machine, once. The live value is the user's
Appearance highlight setting, so another install may hold something else.
That is precisely why the answer belongs on the wire and the constant is
only what stands in when nobody asked.

## What a measurement could NOT settle

**Which brush an untitled modal takes.** The Alert Manager erases an
alert with the alert brush and an ordinary modal dialog with the dialog
brush — but **both evaluate to `0xDDDDDD` under Platinum**, asked of the
machine and counted off a real alert's interior. So no capture can
distinguish them, and none will until either the theme differs or the
guest reports the WDEF variant, which IR v1 does not carry.

The renderer therefore uses the discriminator it *already* uses to decide
that a window draws `dBoxProc` chrome instead of a title bar — kind 2
with no title — and `SceneTheme.face(forWindowKind:untitled:)` says so at
the point of use. That adds no new guess, but it is **the same guess
twice**, and if it is wrong it is wrong in both places. Recorded here
rather than left as a comfortable silence.

## How to check a colour claim

1. Ask the guest for a scene and read `meta.theme` (any host, or the
   listener in `tools/local-scene-bench.py`'s shape).
2. QMP `screendump` the same guest.
3. Histogram the region, do not sample a pixel — a probe point lands
   inside whichever control the layout happens to put there. The dominant
   colour of a face is the face.
4. Report the count, not an adjective: *"40372 of 45974"*, never
   *"matches"*.
