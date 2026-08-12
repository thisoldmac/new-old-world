<!-- now-doc-provenance: generated reviewed=false -->

# Fidelity sweep, 2026-08-06 — the host render against the guest's own pixels

> **THE A/B WAS TAKEN. See
> [fidelity-sweep-2026-08-06-b.md](fidelity-sweep-2026-08-06-b.md)
> (2026-08-06 evening).** This page is the **A** side and stays exactly
> as it was: a pre-asset-pack baseline, correct for the tree it names
> and for no other. Do not quote a score from here as current. B also
> changed one thing about the method — it renders each capture onto the
> scene it was captured against rather than onto a canned one — and says
> per row where that makes the two not strictly comparable.

## WHICH BUILD THIS TABLE DESCRIBES — read this before quoting a score

Scores age badly and silently. This table is a **deliberate baseline**,
taken immediately *before* the icon asset pack landed, and it is only
meaningful against the exact tree named here.

| | |
|---|---|
| **Renderer tree** | branch `claude/fidelity-sweep-2026-08-06`, forked from `claude/gworld-interior-host-render-98ddd5` at `eb952325`. Every render in this document was produced from a working tree whose only differences from that fork point are `tools/fidelity-*.py`, this file, the new fixtures, and the render-list entries that name them. |
| **Asset pack** | the **OLD** one: `MirrorKitUI/Resources/appicons` carries **186** per-app icons and `Resources/icons` carries **5** generic System-file icons (`application`, `disk`, `document`, `folder`, `system-folder`), one size only. |
| **Guest build** | `1bff0bd2ca39 2026-08-06T20:04:32Z`, asserted by `--expect-build auto` on **every** capture — no foreign guest answered this listener. |
| **Guest machine** | QEMU `mac99`, Mac OS 9.1, 800×600. Two session-private clones: `nowvm-fsw1` (the control panels, Note Pad, Stickies, Scrapbook) and `nowvm-fsw2` (Sherlock 2, Key Caps, the Finder), rebooted between because the scene walk goes stale. Each capture names its own in `provenance.vm`. Anchor 1760, wire 5361 — **never** the defaults, both checked free with `lsof` before either boot, and both released afterwards. Nothing here touched metal. |

**The asset pack changed on another branch while this sweep was running**
— 186 → 914 per-app icons, 5 → 127+10 System-file icons, and 16×16 art
shipped beside 32×32 so the renderer picks by size instead of
downsampling. That change regenerated all nine of the previously
committed capture renders. **None of it is in the tree above**, which was
confirmed by counting the resource directories rather than by reasoning
about branch order, so no row here mixes two asset packs. Every ICON
observation below is therefore a statement about the OLD pack and is
expected to move; the A/B is the point.

Axes other than icon art — TEXT, PLACEMENT, CHROME, and the hatch
question under CONTROLS — do not depend on the asset pack, and those
rows should survive the A/B unchanged. If one of them moves, that is
itself a finding.

## What this is

**Status: SURVEY.** Nothing here is a fix. Every row is a judgement about
one window, made by looking at two images of the same moment: the host's
render of a capture, and a QMP screendump of the machine taken while that
window was front. Nothing here touched metal — the guest is a QEMU
`mac99` running Mac OS 9.1.

The sweep exists because the mirror's gates prove that *strings cross*.
They do not prove the window **looks** like the window. `docs/mirror-renders.md`
said so plainly on 2026-07-31 — "fidelity is unjudged" — and every capability
added since has been gated on presence, not appearance. This is the first
pass that puts a number on appearance, and its deliverable is the RED LIST
at the bottom.

## How to reproduce it

    tools/fidelity-sweep.py --port <wire> --qmp <run>/qmp.sock \
        --anchor <anchor> --vm <run> --expect-build auto \
        --outdir /private/tmp/fsweep-out \
        --target "Memory=Macintosh HD:System Folder:Control Panels:Memory"

Each target leaves `<label>.json` (a drain in fixture shape, carrying
`provenance`), `<label>-scene.json` and `<label>-guest.ppm`. The fixtures
that earned a row here are committed under
`now-host/Tests/HostTests/Fixtures/qdtrace-drain-sweep-<label>.json`, and
the renders come from

    NOW_RENDER_DIR=/private/tmp/renders swift test --filter testRenderEveryCapture

Two rig rules the sweep encodes rather than documents, both paid for
earlier the same day: the tool refuses a guest whose build is not this
checkout's (`--expect-build auto`), because every QEMU guest on this Mac
dials 10.0.2.2 and another session's VM will answer your listener; and a
target whose window comes back without an address is reported SKIPPED with
the window list, because the scene walk goes stale over a long session and
a miss that reads as an absence manufactures findings.

## The rubric

Five axes, 0–3 each, judged from the render/screendump pair. A score is
about **this window**, not about the mirror in general.

| Axis | 3 | 2 | 1 | 0 |
|---|---|---|---|---|
| **TEXT** | every visible string present, none duplicated or truncated | one or two minor strings missing | many strings missing, or systematic truncation | no text, or text belonging to another window |
| **PLACEMENT** | text and art within a pixel or two of the guest | small local drift | a whole region offset (the join-translation signature) | content in the wrong window or wildly displaced |
| **CONTROLS** | drawn as real controls | neutral plates where the stream did not say which control | plates where a real control was identifiable | "Bitmap unavailable" hatches over ordinary themed controls — a FALSE CLAIM of missing data |
| **REGIONS** | nothing absent | one minor region empty | a list, picker or pane entirely blank | the interior is empty |
| **CHROME** | frame, title bar, scroll bars and grow box right shape and size | minor size drift | wrong furniture for the window kind | no chrome, or chrome from a different window |

**A hatch is worse than a blank.** `DisplayReplay` already knows this —
`controlSized` exists because "Bitmap unavailable" was the wrong claim
for most of what a control panel blits. A hatch over a themed control is
scored 0 on CONTROLS wherever it appears, not 1.

**Renderer-side versus capture-side.** Every failure is one or the other,
and the distinction decides who fixes it:

- **Renderer-side** — the guest sent it and the mirror drew it wrong.
  The evidence is in the fixture: the string, the rect or the blit is in
  `ops` and the render disagrees with it.
- **Capture-side** — the guest never sent it. The evidence is the same
  fixture: nothing in `ops` covers that region. This is a plane or
  resident problem, not a renderer one. **Monitors is the shape**: zero
  ops on its own window port, twice, while fully drawn on screen.

> **`desktopItems` was the example here and it was the wrong one
> (corrected 2026-08-06).** It looks like the canonical capture-side
> failure and is not one: the guest had been answering correctly all
> along — `osaErr` 0, `N 20`, three pages with the Finder's own
> positions — and the HOST discarded the roster one poll later, because
> the plane had no home on `MirrorReplica`. A third category, and the
> most dangerous one, because it presents exactly like the guest going
> quiet: **read correctly and dropped afterwards.** Anyone using this
> rubric should test for it explicitly rather than assuming silence at
> the glass means silence on the wire.

A row cannot be judged without opening the fixture. "It looks empty" is
not a finding; "the fixture has no ops on that rect" is.

## Two things the harness cannot judge — read before the table

**The semantic plane was never active.** `mirror` reported
`requested: 0, active: 0` on every plane for the whole sweep: these
captures carry the CONTENT plane only. The content plane sees drawing,
not meaning — a checkbox reaches it as a small themed blit, and the
replay's honest rendering of a small themed blit is a neutral plate. So
every CONTROLS score below is a statement about **what one plane can do
alone**, and "checkboxes draw as plates" is not evidence that the mirror
cannot draw a checkbox. It is evidence that nothing in this sweep asked
the plane that knows.

**Two harness artifacts were found and removed rather than reported.**
Both were one step from the red list, and both were the harness:

- *The window title never renders.* It did not, for Appearance, Memory,
  Date & Time and Scrapbook — because the coverage test derives a
  captured window's size from `contentSize`, a union of everything
  drawn, which made Scrapbook nearly twice its true width and pushed its
  centred title outside the visible area. The sweep already records each
  window's real rect, so `composedSweep` uses that. Every render below
  is at the guest's own window size, and the titles are all there.
- *The Finder desktop renders empty.* The desktop capture composes onto
  `windows[1]` of the canned scene, which the coverage helper documents
  as attaching a display that renders nowhere. Scored N/A, not 0.

A third candidate died the same way, and it is the one worth keeping in
mind: the Sound list's disappearance was first written up as the
composition *losing* the rows. The gate written to hold that claim
**failed** — the rows are in the composed display — and the real
mechanism (draw order, R3) came out of the failure. The claim would have
read perfectly plausibly in this document.

The lesson generalises: **a survey's first duty is to its own
instrument.** Three of the first pass's candidate findings were the
measuring apparatus or a wrong reading of it.

## Verification status

**Tested**, in the project's sense — never metal. `scripts/test-all`
green: 122 native tests, both guests cross-compile (source hash
`1bff0bd2ca39`, unchanged by this work), and the host suite passes. Each
individual claim below that could be gated *is* gated, and each of those
gates was watched to fail before it was believed:

| Claim | Gate |
|---|---|
| every sweep capture still composes | `testEverySweepCaptureComposes` |
| a later pass paints over the Sound list; one pass does not | `testFlattenedPassesPutAWindowBlitOverTheSoundList` |
| the Finder's selection never reaches the capture, and the painted half renders wrong | `testTheFindersSelectionNeverReachesTheCapture` |

The scores themselves are **judgements**, not measurements. They come
from a person-equivalent reading of a render beside a screendump of the
same moment, against the rubric above. Another reader could move a 2 to
a 3. What should not move is the red list, because each item there names
a mechanism and points at the bytes.

## The table

Scores are TEXT / PLACEMENT / CONTROLS / REGIONS / CHROME, 0–3 each.
Every row's render is `<label>.png` and its screendump `<label>-guest.ppm`,
paired as `<label>-pair.png` by `tools/fidelity-pair.py`.

| Window | T | P | C | R | Ch | Verdict |
|---|:-:|:-:|:-:|:-:|:-:|---|
| **Date & Time** | 2 | 3 | 2 | 3 | 3 | The best window in the sweep. Every group box, button and label within a pixel or two; values cross. Ellipses dropped from four button titles. |
| **Scrapbook** | 2 | 3 | 2 | 3 | 3 | Near-faithful. All body text, the item panel and the scroll bar with its thumb. Bullets and curly quotes drop; one line clips at the right margin. |
| **Note Pad** | 3 | 3 | 2 | 3 | 3 | Faithful — page, dog-ear, page number, frame all right. Almost no content to get wrong. |
| **Sound** (1 pass) | 2 | 3 | 2 | 3 | 3 | The whole sound list draws: headers, nine rows, per-row icons, live scroll bar. The best evidence in the sweep that the join works. |
| **Stickies** | 3 | 3 | 2 | 3 | 2 | Note colour, size and frame all right; the note was empty. Standard Platinum chrome drawn for a window kind that has its own. |
| **General Controls** | 2 | 3 | 1 | 2 | 3 | Structurally excellent, control glyphs absent: no checkbox ticks, no radio dots, sliders without thumbs, preview icons as blank plates. Two group titles lose their last glyph. |
| **Appearance** | 1 | 3 | 2 | 1 | 3 | Two tab labels and both theme swatches painted over by a later pass. Long description silently truncated at 64 bytes. |
| **Memory** | 1 | 2 | 2 | 2 | 3 | Every string present and every string too wide: 251 of 266 text ops ask for size 9 and render at 12, so labels overrun their controls and spill past the window edge. |
| **Sound** (3 passes) | 1 | 3 | 2 | 0 | 3 | Same window as the good row above. The entire sound list is painted over by a later pass's full-window blit. |
| **Sherlock 2** | 2 | 3 | 2 | 2 | 3 | The list is excellent — header, row, and the volume's real index date. The 16-icon channel grid arrives as one generic document icon (another thread owns that); the Custom popup's label is absent. |
| **Monitors** | 0 | – | – | 0 | – | Nothing to render. Fully drawn on the machine, fully occluded by NOW, and **0 captured ops** on its window port — even after escalating to hide/reveal. |
| **Key Caps** | 0 | 0 | 1 | 0 | 3 | The worst render in the sweep. All ~80 key frames arrive as `[0, 0, w, 21]` — every key collapsed onto the window origin — so the keyboard draws as a handful of stacked boxes in the corner. Only the chrome is right. |
| **Finder icon view** (selected) | 2 | 3 | 2 | 2 | 3 | All ten labels, the header, correct positions, right chrome. Every icon is the generic document (old asset pack — this is the A/B baseline). The selected label draws as a **solid black bar** (R8). |
| Finder desktop | – | – | – | – | – | N/A — harness cannot place a desktop capture (see above). 20 desktop item labels were captured. |
| SimpleText, Calculator | – | – | – | – | – | Not judged: `launch err -192` through the anchor. Not a mirror result. |

No window in this sweep drew a **"Bitmap unavailable" hatch**. That is
worth stating plainly: `DisplayReplay.controlSized` is doing its job, and
the false-claim failure mode the rubric scores 0 for did not occur once
across eleven windows.



## THE RED LIST

Six items. Each says which side it is on, what the evidence is, and
enough to pick it up cold. **None of these is fixed here** — this is a
survey, and four other agents are working the same tree.

**Four of them are fixed now, on `claude/renderer-text-fidelity`**, and
each item below carries its own STATUS line. The scores in the table
above describe the tree named at the top of this file and were NOT
re-judged: a fix is not a score. What the fixes do carry is a
render-beside-screendump pair each, and gates in
`now-host/Tests/HostTests/RendererTextFidelityTests.swift` over these
same committed fixtures, every one of them watched failing by putting
the defect back.

### R1 — Small system text renders 33% too large, and overruns (RENDERER)

`now-host/Packages/MirrorKit/Sources/MirrorKitUI/DisplayReplay.swift`,
`strike(font:size:)`:

```swift
if font == 0 || font == 1 {
    return FontBook.system            // Chicago 12
}
```

The requested **size is discarded** for the system font. The Memory
panel draws **251 of its 266 text ops with font 1 at size 9**; every one
renders at 12. The result is not subtle — "Disk Cache size is calculat",
"Percent of available mem", "RAM Disk S", "Custom sett" — and the
overflow spills past the window's right edge onto the desktop, which is
the one artifact a viewer reads as a broken mirror rather than a
mis-metric.

The Geneva branch immediately below already does the right thing
(nearest bundled size). The system branch needs the same treatment, plus
a bundled Charcoal/Chicago at 9 and 10 to fall back to. Evidence:
`qdtrace-drain-sweep-memory.json`, `memory-pair.png`.

**STATUS: FIXED**, `a93f6f3f`. The diagnosis above is right about the
size and wrong about the face, and the machine's own pixels settle it:
font **1 is `applFont`, which is Geneva**, not the system font, and
Memory's body text is Geneva 9 in `memory-guest.ppm`. So the cure was
not a Chicago at 9 — it was to stop sending `applFont` to the system
branch at all. Sizes now round to the nearest bundled strike with ties
going SMALL (too wide overruns, too narrow only sits loose), and Geneva
18/20/24 joined the bundle. Gated two ways: the strike chosen for those
251 ops is Geneva 9, and none of them is measured wider than the clip
the application itself set for it — 113 were, at Chicago 12, which is
also how "Check Disk" lost its last glyph.

### R2 — Text over 64 bytes is truncated, and the render hides that it was (RENDERER)

The capture is **honest**: a text record carries `len`, `fullLen` and
`trunc`, and the Appearance panel's description arrives as

```json
{"len": 64, "fullLen": 69, "trunc": true,
 "text": "To create a new theme, modify the settings in the following sect"}
```

Nothing on the host reads `trunc` or `fullLen` — neither
`NOWMirrorContentPlane` nor `DisplayReplay` mentions either field — so
the render draws 64 characters as though they were the whole string.
A truncation the guest declared becomes a silent one at the glass.

The cheap correct fix is an ellipsis when `trunc` is set; the honest one
also widens the record. Do not raise the cap without measuring the ring:
64 bytes is a deliberate bound, and the record already says when it bit.

**STATUS: FIXED**, `a93f6f3f`. All three fields reach `DisplayOp` (and
the IR property freeze, additively — `c6b85d75`), and a truncated run
draws with an ellipsis. The cap was not touched, for the reason stated
above. `fullLen` is carried and deliberately not painted: it is there
for a tooltip or a semantic join, and printing "69" beside the text
would be the mirror talking about itself inside a picture of the
machine. The argument for the mark, and against the alternatives, is at
`DisplayReplay.shownText`.

### R3 — A later repaint pass paints over an earlier one (RENDERER, caused by a capture-side flattening)

`displayEpoch` advances **once per ARM and never per repaint pass**.
Every record in every capture here carries a single epoch value
(`appearance` 1, `date-and-time` 2, `memory` 3, `sound` 5,
`general-controls` 6), so a capture spanning three front/back cycles
arrives as one frame with three repaints concatenated end to end.

Where an application composites from more than one offscreen world, a
later pass's full-window blit then lands on top of an earlier pass's
content and erases it. The Sound panel is the clean case, and it has a
**control**: the same window on the same build, captured over one pass
instead of three, keeps all nine list rows —

| | 3 passes | 1 pass |
|---|---|---|
| list rows in the composed display | present | present |
| list rows in the render | **gone** | all nine |

The rows are in *both* composed displays. This is draw **order**, not
composition — the first version of the gate asserted the rows were
missing and failed, which is how the mechanism got named correctly.
Gated by `testFlattenedPassesPutAWindowBlitOverTheSoundList`.

Two possible cures, and they are on different sides: advance the epoch
per update pass in the resident (capture-side, correct), or have the
plane keep only the last complete pass (renderer-side, cheaper). The
same signature costs Appearance its first two tab labels and both theme
swatches.

### R4 — Monitors reports nothing at all (CAPTURE)

The `Monitors` control panel's window (`VGA Display`, `0x1e91a310`) is
fully drawn on the screendump, sits entirely inside NOW's window, and
produced **0 records on its own port** — twice. The second run escalated
past the front/back cycle to hide/reveal and got 17 records, **none of
them on the panel's window**; the only port that answered was the shared
theme world.

This is not the rig being too gentle, and it is not an occlusion
problem: the window is wholly covered by NOW's and comes back looking
correct. Something about that panel's drawing never reaches the hooked
port. It is the only window in the sweep the mirror can say nothing
whatever about, and a viewer would see an empty interior with no
explanation.

Pick-up: `/private/tmp/fsweep-out/monitors-guest.ppm` is the machine's
own pixels; `monitors-scene.json` has the window and psn. Start by
asking whether the panel draws through a port the window-port hook and
the birth-hook both miss.

### R5 — Control glyphs are absent wherever the semantic plane is not asked (RENDERER, scoped)

Checkbox ticks, radio dots and slider thumbs do not draw in any panel:
General Controls' three Documents radios, its two Desktop checkboxes,
Date & Time's daylight-saving checkboxes, Memory's six radios. They
arrive as small themed blits and the replay draws the neutral plate that
`controlSized` prescribes — which is the *honest* fallback, and better
than the hatch it replaced.

**Scoped deliberately:** the semantic plane was inactive for this whole
sweep (`requested: 0, active: 0`), and that plane is what knows a blit
is a checkbox. So this is a red-list item about the composition NOW
actually ships in this configuration, not proof the mirror cannot draw a
control. The question worth answering first is whether the shipping
product ever renders a control panel with the content plane alone; if it
does, these windows look like this.

### R6 — MacRoman punctuation drops silently (RENDERER)

Systematic across every window: `…` (0xC9) drops from "Save Theme…",
"Clock Options…", "Set Time Zone…", "Date Formats…", "Server Options…";
`•` (0xA5) drops from all five Scrapbook bullets; `'` (0xD5) drops from
"user's guide"; "Check Disk" renders as "Check Disl" and
"8/ 6/2026" as "8/ 6/202(", which is a *wrong* glyph rather than a
missing one and may be a separate defect in the strike's high range.

Individually cosmetic; together they are the most-repeated visible
difference in the sweep, and the wrong-glyph cases mean the bitmap
strike's mapping above 0x7F wants checking, not just filling in.

**STATUS: the dropped punctuation is FIXED** (`bfc51477`); **the
wrong-glyph half was a different defect and is NOT.** They only looked
like one item.

The drops were never a mapping defect at all — they were an ABSENCE.
`render_strike`'s default char range stopped at 127, so no extracted
sheet ever held a character above ASCII, and the consumer substitutes
the space glyph for one it does not carry. The glyphs were in the NFNT
the whole time and nobody asked for them. The range now runs to 256 and
the keys are **MacRoman** rather than `chr(c)` — that second half is
what would have turned a missing glyph into a wrong one, since
`chr(0xC9)` is `É` where MacRoman 0xC9 is `…`. Re-extracted off a
session-private mac99; every strike goes 95 → 224 glyphs, and every
ASCII metric is byte-identical to the old sheets (checked, not
assumed). Date & Time's four button ellipses and Scrapbook's five
bullets now match the guest's own screendumps.

The wrong glyphs are a **face substitution**. `Check Disl` and
`8/ 6/202(` are font 0 — the system font, which under Appearance is
**Charcoal** — and Charcoal has NO NFNT strike in its suitcase (it is
TrueType-only; the pack's own manifest has said so since extraction).
The replay stands Chicago 12 in for it, Chicago is wider, and the last
glyph of a run is cut by the clip the application set. Nothing above
0x7F is involved. Closing it needs a rasterizer for the Tier-1
`fonts/ttf/Charcoal.ttf` — it carries no `bdat`/`bloc`, so there are no
embedded bitmaps to lift — and until then the same signature costs
Date & Time "Current Date" and "Use a Network Time Server" their last
letters too.

### R7 — Key Caps' whole keyboard collapses onto the window origin (CAPTURE)

Every one of Key Caps' ~80 key frames arrives as a rect at the origin —
`[0, 0, 21, 21]`, `[0, 0, 26, 21]`, `[0, 0, 31, 21]`, … — 4691 of them
across the capture, differing only in width. The key *labels* arrive
correctly spread (`pen [12, 65]`, `[53, 65]`, `[73, 65]`, `[93, 65]` …),
so the capture is not uniformly broken: the text stream describes the
keyboard and the rect stream does not. The render is the predictable
consequence — a few stacked boxes in the top-left corner of an otherwise
empty window.

The obvious suspect is a missing `SetOrigin`, and **it was checked and
is not the answer in general**: `kNowContentStateOrigin` exists, the
emitter handles it, and 1013 origin state ops appear across this sweep's
captures. Key Caps' own capture has **zero** — all 240 of its state ops
are clip changes.

So the question to pick up is what Key Caps does that the hook records
faithfully and misleadingly: the shape fits an application drawing each
key through a scratch bitmap it swaps under a port whose address never
changes (`SetPortBits`-style), where the recorded coordinates are true
of the scratch and meaningless against the window. Confirm that before
building on it. Evidence: `qdtrace-drain-sweep-key-caps.json`,
`key-caps-pair.png`.

## Selection, focus, and invert — the baseline for a fix landing now

Selection on this machine is drawn by **invert**, and the replay skips
invert outright:

```swift
default:   // invert needs destination pixels we do not carry
    break
```

The accent-ramp thread found what that costs as a measurement problem:
it changed the selected-row colour, regenerated all nine committed
renders, got byte-identical PNGs, forced the highlight to magenta as a
control, and got byte-identical PNGs again. **No capture in the old
corpus contains a selection**, so nothing anyone owns can show a
selection fix working — in either direction.

What this sweep adds, and what it does not:

- **157 invert ops (`verb: 3`) across five captures** — Stickies 52,
  Note Pad 52, Sherlock 2 31, Key Caps 18, Sound 4 — against 34 in the
  old corpus. Every one of them is skipped by the replay today. That is
  a usable before-picture for the invert fix.
- **A selected Finder icon view exists in the screendumps**, captured
  deliberately: `tools/fidelity-sweep.py --reveal` opens the enclosing
  window and selects the item, and
  `/private/tmp/fsweep-b4/finder-guest.ppm` shows "System Folder" with
  an inverted label and a darkened icon.
- **Getting it into a capture took a second attempt, and the reason is
  worth writing down.** Reveal-then-front/back does **not** make the
  Finder rebuild its offscreen icon-view composite: those captures carry
  73 and 209 records and *zero* text ops. The composite has to be
  invalidated, not merely re-exposed — so `--after` now issues a
  reflowing `winact resize`, which is what the committed Finder fixtures
  were always taken with. With it, all ten item labels and the header
  cross (`qdtrace-drain-sweep-finder-selected.json`).
- **And the answer is: half of it crosses, and the half that does is
  drawn wrong.** No invert op appears and no transfer mode other than
  `srcCopy` — but the Finder *paints* the selected label's background,
  so a filled rect does cross. The render (`finder-selected.png`) draws
  that fill as a **solid black bar with the label swallowed inside it**,
  because the text that follows is painted in the same colour. See R8.
- **Sound's selected row is the cleanest available case** and it is
  already committed: the guest screendump shows `SimpleBeep` highlighted
  and `sound-1pass.png` draws that row unhighlighted, in a capture whose
  other nine rows render correctly. One fixture, both states, same
  moment.

So: the invert baseline is real and improved; a *selected list row in a
capture* is still missing, and the route to it is named rather than
guessed.

### R8 — A selected label renders as a solid black bar (RENDERER)

The Finder draws a selected icon's label by painting its background and
writing the text over it in the inverse colour. The paint crosses; the
inverse does not. `finder-selected.png` draws "System Folder" as a black
rectangle with nothing legible in it, beside nine correctly-drawn
labels — which is worse than not drawing the highlight at all, because a
viewer reads a black bar as damage rather than as selection.

The replay tracks one foreground colour and one background colour per
port and draws text in `fg`; nothing carries the text transfer mode, so
white-on-dark cannot be expressed. This is adjacent to but *distinct
from* the skipped-invert work: fixing invert will not fix this label,
because this label was never inverted — it was painted.

Evidence: `qdtrace-drain-sweep-finder-selected.json` (11 paint ops, 0
invert ops, all ten labels present), `finder-selected-pair.png`. Gated
by `testTheFindersSelectionNeverReachesTheCapture`.

**STATUS: FIXED**, `a93f6f3f`. A run whose pen sits inside a rectangle
just painted in the colour the run would itself use is drawn in the
port's BACKGROUND colour — which is the white the machine's screendump
shows on that black bar. The rule is narrow on purpose: it fires only
where the alternative is provably invisible, and an ordinary run over
an ordinary fill keeps the colour it was given.

**This did not touch the invert work and could not have.** That capture
carries eleven paints and zero inverts; the label was painted, never
inverted, so nothing an invert implementation does reaches it. The two
items are adjacent and independent, exactly as this section says.

## What is NOT broken, and should be said

- **No false "Bitmap unavailable" hatch, anywhere, across eleven
  windows.** The `controlSized` bound is holding.
- **The join works.** Sound's list, Appearance's labels, Date & Time's
  values and General Controls' entire layout all cross from offscreen
  worlds hooked at birth and land at the right coordinates.
- **PLACEMENT is the strongest axis** — 3 on nine of eleven scored
  windows. No whole-region offset appeared in this sweep; the
  destination-origin arithmetic fixed earlier the same day is holding.
  (Key Caps' collapse is not that defect: it is a capture whose rect
  coordinates never described the window.)
- **Chrome is right once the window is sized right**: title, close box,
  zoom box, grow box and scroll bars all draw correctly at the guest's
  own geometry.

## Gaps in this sweep — what a follow-up should cover

Not attempted or not reached, and honestly so: SimpleText with a
document and with a dialog, the three Finder *window* views (only the
desktop was captured), a Get Info window, a Standard File dialog, an
alert, and a pulled-down menu. **SimpleText and Calculator failed to
launch through the anchor** (`launch err -192`, for the application, for
a document, and for the Apple Menu Items copy alike) rather than being
judged — that is a rig gap, not a mirror result, and it is what a
follow-up should close first, because a text editor with a document open
is the single most informative untested window here. The remaining
control panels — Keyboard, Mouse, Startup Disk, Extensions Manager,
Energy Saver, Numbers, Text, Apple Menu Options, File Sharing, Control
Strip — are untouched.

**One tuning question this sweep raises and does not settle.** The
number of repaint passes is a real trade: three passes cost Sound its
list (R3) but gave Appearance, Memory and General Controls four thousand
records each; one pass fixed Sound and left Sherlock 2 with 9 distinct
strings against the 20-plus a three-pass capture of the same window
yields. Until R3 is cured there is no setting that is right for every
window, and a capture's pass count belongs in its provenance — which is
why `--force-repaint` writes the escalation into the record.

