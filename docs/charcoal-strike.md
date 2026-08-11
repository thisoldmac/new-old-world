<!-- now-doc-provenance: generated reviewed=false -->

# Charcoal: rasterising the system font the guest has no bitmaps for

**Date:** 2026-08-07 · **Status:** implemented; measured against the
guest's own pixels, not metal-verified.

Font id 0 in the display stream means "the system font", and on Mac OS
8.5 and later that is **Charcoal**. The pack had none, so `DisplayReplay`
answered **Chicago** — System 7's system font, and a few percent wider
per glyph. Every menu, window title, push button and group-box label in
the mirror was drawn in the wrong face.

It read as two unrelated chrome defects, and neither was one:

| symptom | what it really was |
|---|---|
| Date & Time's "Use a Network Time Server" rendered as **"Use a Network Time Serve"** | the guest clipped the run to 170 px, which is its width in Charcoal. Chicago wants 177, so the final `r` fell outside |
| group-box frames **"stroked through their own labels"** | the CDEF erases a band out of the frame it has just drawn and puts the title in it. Chicago overran the band and met the frame line where it resumes |

One substitution, two symptoms, and no renderer change would have been
honest about either.

## Why there was nothing to extract

Charcoal ships **no bitmap strike anywhere on the guest**:

- its `FOND` association table is a single size-0 (scalable) row;
- there is no `NFNT` in its suitcase or in the System file;
- its `sfnt` carries no `bdat`/`bloc` and no `EBDT`/`EBLC`.

Mac OS rasterises it from the TrueType outlines at run time. So the
extractor now does the same, and the `sfnt` it was already carrying out
verbatim as `fonts/ttf/Charcoal.ttf` is the input.

## The two halves, kept apart

**Widths come from `hdmx`.** That is Apple's own Horizontal Device
Metrics table: one record per ppem, one unsigned byte per glyph, the
number the Font Manager advances the pen by on that machine at that
size. A rasteriser's idea of the advance is different arithmetic over the
same outline and is allowed to disagree; where it does, `hdmx` wins.

**Shapes come from FreeType**, in monochrome, through Pillow. OS 9's
TrueType interpreter is not FreeType and the difference is measured
below rather than assumed away.

**A ppem with no `hdmx` row is refused**, not filled in from the
rasteriser (`fonts.NoDeviceMetrics`). Charcoal's table covers **9
through 24**, which is every size the corpus has ever seen the system
font drawn at, so 16 strikes of 223 glyphs are produced and no size
outside that range is answerable. A request outside it still rounds
through `FontBook.nearest`, which errs small and says which strike it
gave — the same documented substitution as before, rather than a strike
whose advances are a guess.

Vertical metrics come from `hhea` scaled by ppem/unitsPerEm, and that
choice is **checkable rather than assumed**: at 12 ppem it yields ascent
12, descent 3, leading 1 — and Chicago and Geneva, which both ship a
hand-drawn 12-point `NFNT`, say exactly 12/3/1 in their own headers.
Where a rasterised glyph reaches past that box the box grows to hold it,
and the metrics record that it did (`grewToFitInk`, true at 9, 10, 13,
17 and 21).

Two smaller decisions, both paid for by a near miss:

- **Charcoal carries eight `(1,0)` `cmap` subtables**, one per localised
  Mac script. The Roman one is picked by format 6's own `language == 0`.
  Taking the first would have filed high glyphs under the wrong byte for
  some faces, and a wrong glyph is worse than a missing one — the same
  lesson `render_strike` already learned about MacRoman keying.
- **The `hmtx` left side bearing was tried and rejected on evidence.**
  Deriving each glyph's bearing from the font's own scaled `hmtx` — the
  obvious parallel to taking the advance from `hdmx` — moved 89 of 223
  glyphs and made the measured disagreement against the guest **worse**,
  11.32% against 5.86%. FreeType's grid-fitted bearing is kept.

## The widths are exact, and the guest is the one saying so

Before it draws a group-box title the CDEF erases a band out of the frame
and clips to it, so **the band's width is that machine's own statement of
how wide that string is**. Eight such bands sit in the committed
captures. No VM, no screendump, no judgement:

| title | guest's band | Charcoal (`hdmx`) | Chicago |
|---|---|---|---|
| Current Date | 80 | **80** | 84 |
| Current Time | 81 | **81** | 84 |
| Time Zone | 64 | **64** | 66 |
| Desktop | 51 | **51** | 53 |
| Menu Blinking | 89 | **89** | 92 |
| Insertion Point Blinking | 148 | **148** | 155 |
| Documents | 71 | **71** | 72 |
| Check Disk | 66 | **66** | 70 |

Eight of eight exact. Chicago overruns every one, by +1 to +7 px,
monotonically with length — the signature of a per-glyph advance
difference rather than a layout bug. `Use a Network Time Server` is the
ninth case and the clipped one: 168 px in Charcoal inside the 170 px the
guest allowed, against Chicago's 177.

`testAGroupTitleIsExactlyAsWideAsTheBandTheGuestErasedForIt` and
`testNoSystemFontRunOverrunsTheClipTheGuestSetForIt` are those two rules
as gates. The second is generalised over all thirteen sweep captures
rather than named on one string, and putting the substitution back
reports **far more** than the sweep ever found: Appearance's "Fonts" and
"Desktop", Sound's "Input", "Output" and "Mute", and every clock digit
Date & Time redraws.

## The shapes are close, and here is how close

Rasterisation is the half that cannot be exact, so it is measured
against the guest's own framebuffer — `sweep-2026-08-07-a/p2/panels/*.ppm`,
three panels, fourteen runs the machine actually drew.

Each run is **located by matching its own ink** before differencing. That
control is load-bearing: the app's synthesised tab scene sits about one
pixel left of the machine (chrome included — energy-saver's tab strip
starts at guest x 206 and ours at 204), and a fixed-offset region delta
is dominated by that shift rather than by the face. Measured that way the
tab strip's label boxes move only 1.2 points between the two faces, which
is why `PlatinumTabTests`' `labels-only` number is not a face
discriminator and says so in its own comment.

Disagreeing pixels as a fraction of the run's ink:

| run | Charcoal | Chicago |
|---|---|---|
| Notification | **1.1%** | 79.6% |
| Mouse | **1.3%** | 35.6% |
| Help | **1.7%** | 17.9% |
| Sleep Setup | **1.9%** | 70.7% |
| Schedule | **1.9%** | 8.5% |
| Set Time Zone | **2.4%** | 71.9% |
| The time zone must be set to determine the correct | **2.5%** | 91.0% |
| zone: | **2.7%** | 10.5% |
| Date & Time | **2.7%** | 63.6% |
| Cancel | **2.8%** | 26.9% |
| time. Select the closest city in your current time | **7.5%** | 92.1% |
| Show Details | **13.0%** | 76.1% |
| Advanced Settings | **13.1%** | 75.5% |
| Energy Saver | **19.2%** | 73.7% |

**Pooled: 5.86% of ink pixels disagree, against Chicago's 72.81%.**
Per-string p50 2.6% / p95 13.1% against p50 71.3% / p95 91.0%.

**What the residual is, glyph by glyph.** Aligning each glyph separately
rather than the whole run: 170 of 175 glyph placements are exact, with 0
to 2 pixels of shape difference each — FreeType and Apple's interpreter
hinting the same outline slightly differently. The other five are `A`,
`v`, `w` and `y`, all glyphs whose left side bearing is negative, which
FreeType places one pixel further left than the machine does. The rows
above 12% are the runs that start with one: a whole-run match then has to
compromise between the glyph that wants +1 and the rest that do not, and
that compromise is what the percentage prices. It is a real
disagreement — the renderer draws a run from one pen — but it is one
pixel on four glyphs, not a wrong face.

`FREETYPE_PROPERTIES=truetype:interpreter-version=35` was tried and
changed nothing.

## What still substitutes

- **Sizes outside 9–24.** No `hdmx` row, so no strike; `FontBook.nearest`
  rounds and errs small. Nothing in the corpus asks for one.
- **Bold.** The group title "Put the system to sleep whenever it's
  inactive for" is bold Charcoal on the machine and nothing here draws
  it; a naive QuickDraw smear does not reproduce it either (80.8%
  disagreement, i.e. no match at all). Charcoal's suitcase holds one
  `sfnt` and no bold outline, so whatever the Font Manager does there is
  not in the file, and this is not closed.
- **Font id 2002.** [open-issues.md](open-issues.md) argues it is
  Charcoal under a runtime-allocated id; 106 of its runs were measured
  against their own clips here and **that test does not discriminate** —
  Charcoal, Geneva 9 and Geneva 10 all fit, Chicago overruns two. Key
  Caps' clips are simply loose. It still resolves to Geneva and is still
  open.

## Where the strike says where it came from

The metrics JSON beside each sheet carries `widthSource: "hdmx"`,
`shapeSource: "freetype-mono"` and `rasterisedFrom: "sfnt"`, and
`testACharcoalStrikeDeclaresWhereItsWidthsCameFrom` gates it. A width
that is Apple's own device metric and a width that is a rasteriser's
answer are not the same claim, and the file is where that distinction
survives the trip out of the extractor.

## Verification level

- **Tested** — `scripts/test-all` and `scripts/test-mirrorkit` green;
  four new gates watched to fail by restoring the substitution.
- **Measured against guest pixels** — the tables above, from committed
  screendumps of three control panels.
- **Not metal-verified.** Nobody has watched a PowerBook draw this.
