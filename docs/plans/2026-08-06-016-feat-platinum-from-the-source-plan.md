---
title: Platinum from the source - Plan
type: feat
date: 2026-08-06
---

# Platinum from the source — Plan

Sibling of [015](2026-08-06-015-feat-live-composition-plan.md), which
makes interiors compose; this makes the CHROME around them faithful.
Depends on nothing in 015 and can run beside it. Subordinate to
[001](2026-08-03-001-now-mirror-ux-completion-plan.md).

## Why this exists

The host draws window frames, title bars, scroll bars and buttons from a
**ported specification** — upstream's reading of Platinum, seven grey
levels and a set of bevel rules. That was the only option available:
[mirror-assets.md](../mirror-assets.md) established there are no chrome
BITMAPS to extract, because the Appearance Manager draws chrome
procedurally, and today's content-plane work agrees (themed controls
arrive as CopyBits out of worlds AppearanceLib composes at draw time).

From that, the arc concluded chrome must be reimplemented from a spec.
**That conclusion was too weak, and this plan is the correction.** The
Appearance Manager does not only draw — it ANSWERS. Read out of
`Appearance.h` on the CarbonLib floor this project already targets:

- **Metrics**: `GetThemeMetric` over ~40 selectors —
  `kThemeMetricScrollBarWidth`, `CheckBoxWidth/Height`,
  `DisclosureTriangleWidth`, `EditTextFrameOutset`, `FocusRectOutset`,
  `HSliderHeight`, `BestListHeaderHeight`, and the rest.
- **Colour**: `GetThemeBrushAsColor`, `GetThemeTextColor`,
  `GetThemeAccentColors` — the machine's own RGB values, per brush, per
  state, rather than seven greys we chose.
- **Geometry**: `GetThemeWindowRegion`, `GetThemeScrollBarTrackRect`,
  `GetThemeTrackBounds`, `GetThemeTrackThumbRgn`,
  `GetThemeButtonContentBounds` — where every part of a control
  actually is, which is also what a click needs.
- **Type**: `GetThemeFont`, `GetThemeTextDimensions`.

And thirty-odd `DrawTheme*` entry points covering the entire vocabulary:
`WindowFrame`, `TitleBarWidget`, `ScrollBarArrows`, `Track`, `Button`,
`MenuBackground`, `MenuBarBackground`, `MenuItem`, `TabPane`,
`PrimaryGroup`, `EditTextFrame`, `ListBoxFrame`, `Placard`,
`GenericWell`, `FocusRect`, `StandaloneGrowBox`, `Separator`.

So the machine can be **asked** what Platinum is, and can be asked to
**draw** it. Neither is guessing, and neither ships pixels at runtime.

## The two halves, and why both

### The specification half — ask, and store the answers

A guest-side query pass walks every metric selector, every theme brush
and text colour, and the font specs, and reports them. The host stores
that as a small theme file and draws from THOSE numbers instead of
ported constants. Nothing here is a bitmap, nothing is large, and it is
exact per machine and per theme.

This alone fixes the class of error the renderer cannot currently even
detect: a scroll bar 15 px wide where the guest's is 16, a dialog grey
one step off, a checkbox drawn at the wrong size. Today those are
invisible to every test we have, because no test knows the true value.

### The art half — have the guest draw each element ONCE

For elements whose shape is genuinely pictorial (scroll arrows, the grow
box, title-bar widgets, popup arrows, the disclosure triangle), a
guest-side baker calls the matching `DrawTheme*` into an offscreen
GWorld, at each state (normal / pressed / disabled / active / inactive),
and hands back the pixels **once**, as an asset.

This is not the pixel path the project refuses. The rule that matters is
that a running mirror does not ship a framebuffer; a one-time asset bake
is the same category as the extracted icons and font strikes already in
the pack, and it inherits their constraint: **Apple's bitmaps, private,
never published, never shipped as an artifact.**

Where an element is a flat bevel the spec already describes, prefer the
spec — the bake is for shapes, not for rectangles.

## The vehicle

A rig applet in `tools/`, in the pattern of `guest-gworld`'s three: it
runs on the guest, writes a result file, the rig pulls it back. Not a
resident, not a wire verb — this is a one-shot extraction whose output
is checked in (privately) and used at build time.

**The offline route makes half of it free**: the theme file
`System Folder:Appearance:Theme Files:Apple platinum` is readable
directly off the image today
([asset-extraction-offline.md](../asset-extraction-offline.md)), and
whatever IS in it should be read before writing any guest code — an
extractor already running may have answered this.

The applet is needed for what only a running Appearance Manager can
say: the resolved metrics and colours for the theme actually in force,
and the drawn art.

## Slices

- **P1 — read the theme file offline.** What does `Apple platinum`
  contain? Answer it from the image; it may make part of the applet
  unnecessary. Record in asset-extraction-offline.md either way.
- **P2 — the query applet.** Every `GetThemeMetric` selector, every
  brush and text colour, `GetThemeFont`, written to a file the rig
  pulls. Compare each answer against the host's current ported constant
  and REPORT THE DIFFERENCES — that list is the value of this slice, and
  it is the first time the renderer's constants can be wrong out loud.
- **P3 — the host theme source.** Replace ported constants with the
  measured file, one element at a time, each with a render comparison
  against a guest screendump. `PlatinumTheme.swift` is where they live.
- **P4 — the art bake**, only for elements that are shapes rather than
  bevels, at every state, with the private-asset rule inherited.
- **P5 — the fidelity gate.** Once metrics come from the machine, a test
  can assert the render's scroll bar is the machine's width. Today
  nothing can. This is the slice that stops fidelity being a matter of
  opinion for the parts that are measurable — the parts that are not
  (does it LOOK right) stay Michelle's call, as they are now.

## What this does not do

- It does not make the renderer call the Appearance Manager live. The
  host draws; the guest is asked once, offline or at bake time.
- It does not touch composition (015's territory) or icon identity.
- It is emulator-scoped until someone runs it on the PowerBook, where
  the theme may legitimately differ — which is itself a reason the
  numbers should be read rather than hardcoded.

## Stop condition

If the measured metrics turn out to match the ported constants
everywhere, say so plainly and stop after P2: the spec was right, the
work is done, and the finding is worth more than the code would have
been.
