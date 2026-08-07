# Deriving a drawn procedure

**Date:** 2026-08-07 · **Status:** the method, proven on one case — the
Platinum tab. Read this before attempting the next piece of chrome.

Mac OS 9 draws most of its chrome at run time. The Appearance Manager is
handed parameters and produces pixels, and the parameters are the only
thing anyone can extract — [asset-extraction-offline.md](asset-extraction-offline.md)
opened `Apple platinum`'s 876 KB resource fork and found `clut`, `scen`,
`tvar`, `tthm` and not one pixel of window furniture. So for a whole
class of chrome, "extract harder" is a dead end, and the work is to
**recover the procedure and run it host-side**.

That is a different job from porting a spec, and it turns out to be a
much easier one than it sounds, because of a fact nobody had looked for:

> **The Appearance Manager leaks most of itself through the QuickDraw
> bottlenecks.** `DrawThemeTab` does not draw a tab with one opaque
> call. It paints the label box, strokes three lines across the top of
> it, and draws the title — all ordinary ops, all captured by QDPeek,
> all carrying the machine's own colours. Only the *shaped* part goes by
> a route the content plane cannot see.

So the question is never "what does Platinum look like". It is **"which
part of it already arrived, and what is the smallest thing I must add to
the part that did not"**.

## The ladder of evidence, cheapest first

Work down it and stop as soon as the answer is firm. Every conclusion
you write down says which rung it came from — that is what lets the next
person re-check it cheaply.

1. **The header.** Universal Interfaces on the CarbonLib floor
   (`$RETRO68/InterfacesAndLibraries/AppleUniversal/Interfaces/CIncludes/Appearance.h`).
   It names the constants, the states and the metric selectors. For the
   tab it gave `kThemeLargeTabHeight = 21`, `kThemeSmallTabHeight = 16`,
   `kThemeTabPaneOverlap = 3`, `kThemeLargeTabHeightMax = 24`, the seven
   `ThemeTabStyle` states and `kThemeMetricLargeTabCapsWidth`. Fifteen
   minutes, and it fixes the vocabulary for everything below.
   (Retro68's headers are CR-terminated: `tr '\r' '\n'` first, and use
   `grep -a`, or grep will decide the file is binary and say nothing at
   all — which reads exactly like "the header does not mention tabs".)
2. **The theme file, offline.** Already tooled:
   `tools/extract-assets-offline`. Answers "is there art here" and
   sometimes hands over exact colour tables.
3. **The guest's own op stream.** A capture drain
   (`sweep-*/p1/panels/*.json`) is the Appearance Manager's own drawing,
   op by op, with every `state`/`fg` colour beside it. **This is the rung
   that was being skipped**, and it is by far the highest-yield one.
4. **The guest's own pixels.** A QMP screendump of the same instant.
   Answers what the stream withheld, and is the only honest validation.
5. **Reverse-engineering AppearanceLib.** Authorised where necessary.
   It was **not** necessary for the tab; rungs 1, 3 and 4 were enough,
   and finding that out cost an afternoon rather than a week.

## How to read rung 3 — the part that is not obvious

A drain is 4,550 ops. The trick is to stop looking at the window's port.

The Appearance control panel's window port carries **eleven** ops: its
frame and nothing else. All 1,863 of its real ops are in one offscreen
world (`0x203d61b0`), because the panel composites itself and blits.
Grouping by `port` first, and reading the world with the text ops in it,
turns an unreadable pile into a legible script:

```
rect  verb 2  [-1, 10, 465, 311]     bg DDDDDD    erase the strip
rect  verb 1  [-1, 31, 465, 311]     fg EEEEEE    the pane's face
rect  verb 0  [-1, 31, 465, 311]     fg 000000    the pane's frame
line  [0,32]-[462,32]                fg CCCCCC    …and its bevel
line  [1,33]-[461,33]                fg FFFFFF
rect  verb 1  [16, 10, 65, 34]       fg EEEEEE    tab 1, FRONT (24 high)
line  [16,10]-[65,10]                fg 000000
line  [16,11]-[64,11]                fg CCCCCC
line  [16,12]-[64,12]                fg FFFFFF
text  pen [16,25]  "Themes"          fg 000000
rect  verb 1  [89, 10, 166, 31]      fg CCCCCC    tab 2 (21 high)
line  [89,10]-[166,10]               fg 000000
line  [89,11]-[165,11]               fg CCCCCC
line  [89,12]-[165,12]               fg DDDDDD
text  pen [89,25]  "Appearance"
…
```

Everything a tab drawer needs is in those fourteen lines:

| quantity | where it came from | rung |
|---|---|---|
| tab boxes, in order | the paint rects | 3 |
| which tab is front | it is 24 high where the others are 21 | 3 + 1 |
| pane top | `31` = tab top + 21 | 3 |
| face colour per state | `EEEEEE` front, `CCCCCC` non-front | 3 |
| frame / bevel / lit colours | the three lines' own `fg` | 3 |
| titles | the text ops | 3 |
| **caps width** | **half the gap between neighbours: 24 / 2 = 12** | 3 |

The caps-width row is the one worth stealing. `kThemeMetricLargeTabCapsWidth`
is nowhere in the stream — but the gap between two label boxes is exactly
two caps, because two caps are what fills it. All five gaps on this panel
measure 24. **A metric that is not reported is often implied by the
spacing of things that are**, and an implied metric is per-machine and
per-theme for free, where a constant is neither.

## What the stream did NOT carry, and how to get it

The caps' shape. For that, rung 4 — count pixels.

Crop the guest screendump around one tab and print it as a character
grid with a colour legend (thirty lines of Python; no image library
needed for a `P6` PPM). Reading the front tab's left cap down the rows
gives the black column at each y:

```
y  104 105 106 107 108 109 110 111 112 113 114 …
x  177 176 176 176 175 175 175 174 174 174 173 …
```

One pixel left every third row, without exception — a **1-in-3 slant**,
for the bottom 17 rows, covering 7 px. The top 4 rows are a corner
covering the remaining 5. 7 + 5 = 12 = the caps width the stream implied.
**Two independent routes agreeing on 12 is the moment the derivation is
finished**, and it is worth waiting for; a single measurement of a shape
this small is very easy to get one pixel wrong.

Two things the pixels also settle, which no amount of reasoning would:

- The front tab has **no bottom edge** — the pane's black top line stops
  at its left cap and resumes after its right one. That join is what
  makes a tab look attached rather than pasted on.
- Apple's caps are **anti-aliased** (`#222222`, `#444444`, `#BBBBBB`
  down the diagonal), which classic QuickDraw does not produce. So
  `DrawThemeTab` is compositing a prepared stencil, not stroking a line.
  This is the one place the host cannot match exactly, and it is
  deliberately not chased: Core Graphics anti-aliases the same geometry
  its own way, and the shape is what matters.

## Every conclusion, and which rung it came from

Michelle authorised reverse-engineering AppearanceLib **where necessary**.
The record should therefore say where it was necessary, and the answer is
**nowhere** — the tab was fully derived without disassembling anything.
Per conclusion:

| conclusion | route | rung |
|---|---|---|
| tab heights are 21 (large) / 16 (small), overlap 3 | INFERENCE — header constants, then confirmed by the capture's own 21/24 rects | 1 + 3 |
| there are seven tab states and four directions | INFERENCE — `ThemeTabStyle` / `ThemeTabDirection` | 1 |
| a tab is a paint rect + three top lines + a title | INFERENCE — read directly out of the drain | 3 |
| the front tab is the one that overlaps the pane | INFERENCE — the only 24-high rect, matching `kThemeTabPaneOverlap` | 3 + 1 |
| face is `#EEEEEE` front / `#CCCCCC` non-front | INFERENCE — the `fg` at each paint. Not a chosen grey | 3 |
| bevel is black / `#CCCCCC` / `#FFFFFF` front, `#DDDDDD` non-front | INFERENCE — the `fg` at each of the three lines | 3 |
| pane top = tab top + non-front height | INFERENCE — the pane's own paint rect agrees at y 31 | 3 |
| **caps width is 12** | INFERENCE ×2 — half the 24-px gap between neighbours, and independently the guest's pixels | 3 **and** 4 |
| the cap is a 1-in-3 slant for 17 rows and a 4-row corner | MEASUREMENT — pixel columns off the screendump | 4 |
| the front tab interrupts the pane's frame line | MEASUREMENT — the line is absent under its caps | 4 |
| the lit edge runs top and left only | MEASUREMENT — the right slant has no highlight | 4 |
| AppearanceLib composites a stencil for the caps | INFERENCE from measurement — the diagonal carries blend values classic QuickDraw cannot produce | 4 |
| **reverse-engineering AppearanceLib** | **not needed** | 5 |

The one line worth carrying forward is the caps width: **two independent
routes agreeing is what ends a derivation.** A single measurement of a
12-pixel shape is very easy to get one pixel wrong, and one pixel is the
whole error budget.

## Implementing it: three rules

1. **Parameterise from the stream, gate on the header.** Every colour
   and every distance in `PlatinumTab` comes from the capture. The
   header's constants appear only in `DrawnTabStrip.Metrics` as an
   *acceptance test* — a run of equal-height boxes is a common shape, and
   "these are tabs" is a strong claim that wants a reason. Matching
   `kThemeLargeTabHeight` and `kThemeTabPaneOverlap` is that reason.
2. **Draw only the difference.** The label box, its bevel and its title
   already arrived and are already on the canvas. `PlatinumTab.draw`
   clips the label box OUT and paints only the caps and the join. This is
   `DrawnCellGrid`'s rule from
   [render-composition.md](render-composition.md) and it is what keeps a
   derived element from erasing the evidence for itself.
3. **Fill, do not stroke.** Stacking three fills — frame, lit edge, face —
   at insets 0/1/2 gives crisp 1-pixel edges. Stroking at integer
   coordinates does not, and finding out why fixed a defect much larger
   than the tab (below).

## The measurement, honestly

`PlatinumTabTests.testAgainstTheGuestsOwnPixels`, opt-in via
`NOW_TAB_REFERENCE_DIR` (the references are Apple's pixels and stay in
the private asset store: `sweep-2026-08-07-a/p1/panels`). Headless
throughout — QMP screendumps against `RenderShot`; nothing drives a
desktop.

Both tabbed panels in the corpus, every tab, by position and state.
Region per panel: the row of tabs plus the pane's frame and its two
bevel rows.

| region | pixels | exact | p50 | p95 | max |
|---|---|---|---|---|---|
| **appearance** / whole strip | 11,600 | 75.9 % | 0 | 204 | 255 |
| appearance / chrome only | 4,150 | 65.3 % | 0 | 184 | 255 |
| **energy-saver** / whole strip | 11,250 | 77.6 % | 0 | 204 | 255 |
| energy-saver / chrome only | 3,200 | 68.5 % | 0 | 178 | 255 |

Per tab — only the two caps, which is the part this drawer invented,
with the label box excluded. `flat` excludes a two-column band around
the machine's own outline, which is where its anti-aliasing runs:

| tab | caps: exact / p95 | caps **flat**: exact / p95 / **max** |
|---|---|---|
| leftmost, **front** (both panels) | 55.5 % / 187 | 73.1 % / 34 / **34** |
| middle, non-front (×6 across both) | 63.3 % / 183 | 86.1–86.4 % / 34 / **34** |
| rightmost, non-front (both panels) | 63.3 % / 183 | 86.4 % / 34 / **34** |

Read those rows carefully, because they say something a single
percentage cannot:

- **Off the diagonal, nothing is ever wrong by more than 34.** That is
  one Platinum grey step — `#DDDDDD` against `#FFFFFF`. Every flat-region
  disagreement is the one-pixel inner highlight landing a row or a column
  from where the machine puts it. There is no region where the drawer is
  wrong about WHAT colour goes there, only about exactly which pixel.
- **On the diagonal it is anti-aliasing, and that is by construction.**
  Apple composites a prepared stencil; Core Graphics blends its own. This
  is the residual that will not close without baking Apple's stencil, and
  it is judged not worth it at 1× — see the 016 amendment.
- **Every non-front tab measures identically, on both panels.** Not a
  bug in the harness: a cap's pixels depend only on the cap's shape and
  the face colour either side, so there are genuinely two patterns and
  the corpus contains many copies of each. It is also the strongest thing
  in the table — the error is position-independent and panel-independent,
  so nothing here is fitted to one tab.
- **Inside the label boxes it is the FONT, not the tab.** The pack has no
  Charcoal strike, so titles render in Chicago, which is wider — that is
  the whole gap between the "whole strip" and "chrome only" rows, and it
  is also exactly the "Notificatio" / "Advanced Setting" clipping sweep A
  reported on Energy Saver. It is a pack gap; it is not this.

**Where it still fails, stated plainly:**

1. The anti-aliased diagonal, above — 2 columns wide, both caps, every
   tab.
1b. **The corner's topmost row is two columns wide of the machine's**, and
   only that row; every row below it is within one. Two attempts to close
   it — moving the quad's control point beside its end point, and letting
   the flat top run a pixel past the label box — each fixed the top row and
   took the worst flat-region residual from **34 to 165**, so both were
   reverted. The measurement is the reason they are not in the tree, and
   the reason this line exists instead.
2. The inner highlight, by up to one pixel, worth one grey step.
3. **`Shape.cornerHeight` is not pinned by any gate**, and deliberately
   not. `cornerWidth` is — widening it 5 → 7 fails the geometry assertion
   naming it. Raising `cornerHeight` 4 → 6 changes no pixel the machine can
   distinguish, because with the control point fixed the quad passes within
   a pixel of the same columns either way. The two constants are not
   independent; only `cornerWidth` carries the curve. A gate for the other
   would be asserting a number nothing on screen depends on, which is its
   own kind of lie.
4. **States nobody has measured, because no capture contains one.**
   Every control panel and application in sweep A was scanned for the
   tab signature and exactly two have tabs, both with their window
   ACTIVE and FRONT. So there is no capture of an inactive tab strip
   (`kThemeTabFrontInactive` / `kThemeTabNonFrontInactive`), a pressed
   tab, an unavailable one, or a **small** (`kThemeSmallTabHeight` = 16)
   tab anywhere in the corpus. `DrawnTabStrip` accepts 16-high tabs and
   the drawer is written for them, and **neither has ever been seen**.
   That is the honest state: the seven `ThemeTabStyle` states are two
   measured and five unmeasured.
5. Tab direction. `DrawThemeTab` takes `kThemeTabNorth/South/East/West`;
   everything here is North, and nothing refuses the others — they would
   simply be drawn as North and be wrong. A capture of one has never been
   seen either.

**Verification level: emulator-verified against a stored capture.** The
screendumps are a real Mac OS 9.1 guest under QEMU, taken in fidelity
sweep A on 2026-08-07. Nothing here has been on the PowerBook, and no
running guest was contacted for this work at all — the sweep's artifacts
were sufficient, which is itself worth knowing.

## Where it sits in the renderer, and why not where you would expect

Plan 018's provenance ladder (`ProvenanceLadder`, `claude/018-lane-a`)
has four rungs: ink from the current epoch, a semantic row that owns its
display, **asset-pack art addressed by identity**, and the marked
unknown. The obvious place for a tab drawer is rung 3, and it is the
wrong one:

- Rung 3 is for a rectangle a SEMANTIC row named and did not draw, filled
  from the asset pack. There is no tab art in the pack — that is this
  whole page — and Appearance publishes `controls = 0`, so nothing names
  the tabs at all.
- The caps are not a placeholder for missing content. They are
  **reconstructed ink**, derived from the same drawing that carried the
  label boxes. That is rung 1's category, and `DrawnCellGrid` is already
  there: a derivation that runs beside the replay and feeds it, rather
  than an arbitration path competing for a rectangle.

So `DrawnTabStrip` + `PlatinumTab` is a **rung-1 producer**, and it adds
no precedence rule: it never claims a rectangle another plane claims, it
clips the label box out so it cannot paint over the guest's own bevel or
title, and where it cannot identify a strip it draws **nothing**.

**That last point is why `UnknownVisual` does not appear here**, and the
reason is a rule rather than an oversight. `UnknownVisual` marks a
rectangle nobody could reach. A tab strip's rectangle IS reached — the
replay drew the label boxes, the bevel and the titles into it — so
hatching it would break render-composition's rule 4 (*a placeholder never
paints over content another plane already drew*). The honest fallback for
"this might not be a tab strip" is silence, and
`DrawnTabStrip.derive` returns nothing on every doubt: unequal gaps, an
odd gap, a height no Appearance metric names, two tabs claiming to be
front, a missing three-line bevel. The pixels then stay exactly as the
replay left them, which is what they were before this work existed.

## The bigger thing this found

The pane's own frame line rendered at `#D9D9D9` where the machine draws
`#000000`, and its two bevel rows at `#EEEEEE`/`#F7F7F7` against
`#CCCCCC`/`#FFFFFF`. That is not a tab defect. **QuickDraw's 1×1 pen inks
the pixel whose top-left corner is `(h,v)`; Core Graphics strokes a line
CENTRED on the coordinate.** Every 1-pixel frame, bevel and separator the
replay has ever drawn came out as two rows at half coverage.

The fix is a half-pixel translation (`DisplayReplay.pixelCentre`) and an
inset on the frame verb. It moved the tab strip's exact-pixel score from
55.6 % to 69.5 % on its own, before the caps were touched.

The lesson is the one this repository keeps paying for in a new costume:
**a whole-image similarity number cannot find a systematic one-pixel
error.** It had been there for the life of the renderer, in every
capture, and what found it was cropping thirty rows and printing them as
characters.

## Doing the next one

The order that worked, and the time each part took:

1. Read the header for the element's constants and states. (15 min)
2. Find the element in a drain — **group by port first**, and go to the
   port that has the text in it. Print the ops in stream order with the
   `fg` colour resolved beside each. (30 min)
3. Write down what arrived and what did not. If everything arrived, you
   are done and the defect is in the renderer, not the data — check that
   before concluding anything is missing (render-composition.md's own
   hard-won note).
4. For what did not arrive, crop the guest screendump to that element and
   print it as characters. Look for a repeating period; Platinum's shapes
   are built from small integer slopes and will confess quickly.
5. **Cross-check the shape against something the stream implied.** If two
   routes do not agree, you have measured one of them wrong.
6. Derive in the renderer-free core, draw in `MirrorKitUI`, clip out
   whatever the replay already drew.
7. Gate the GEOMETRY, report the percentage. Watch the gate fail by
   moving the geometry one pixel.

Candidates in rough order of how much of themselves they leak: group
boxes and separators (probably entirely in the stream already — check
before writing anything), placards, list headers, disclosure triangles,
scroll-bar arrows (likely the least — a genuine shape, and the first
case that may actually want plan 016's guest-side bake).
