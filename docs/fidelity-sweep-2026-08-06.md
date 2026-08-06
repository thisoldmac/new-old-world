# Fidelity sweep, 2026-08-06 — the host render against the guest's own pixels

## WHICH BUILD THIS TABLE DESCRIBES — read this before quoting a score

Scores age badly and silently. This table is a **deliberate baseline**,
taken immediately *before* the icon asset pack landed, and it is only
meaningful against the exact tree named here.

| | |
|---|---|
| **Renderer tree** | branch `claude/fidelity-sweep-2026-08-06`, forked from `claude/gworld-interior-host-render-98ddd5` at `eb952325`. Every render in this document was produced from a working tree whose only differences from that fork point are `tools/fidelity-*.py`, this file, the new fixtures, and the render-list entries that name them. |
| **Asset pack** | the **OLD** one: `MirrorKitUI/Resources/appicons` carries **186** per-app icons and `Resources/icons` carries **5** generic System-file icons (`application`, `disk`, `document`, `folder`, `system-folder`), one size only. |
| **Guest build** | `1bff0bd2ca39 2026-08-06T20:04:32Z`, asserted by `--expect-build auto` on **every** capture — no foreign guest answered this listener. |
| **Guest machine** | QEMU `mac99`, Mac OS 9.1, 800×600, run `nowvm-fsw1`. Nothing here touched metal. |

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
said so plainly a week ago — "fidelity is unjudged" — and every capability
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
  resident problem, not a renderer one. `desktopItems` is the shape.

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

The lesson generalises: **a survey's first duty is to its own
instrument.** Two of the five candidate findings from the first pass
were the measuring apparatus.

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
| **Monitors** | 0 | – | – | 0 | – | Nothing to render. Fully drawn on the machine, fully occluded by NOW, and **0 captured ops** on its window port — even after escalating to hide/reveal. |
| Finder desktop | – | – | – | – | – | N/A — harness cannot place a desktop capture (see above). 20 desktop item labels were captured. |

No window in this sweep drew a **"Bitmap unavailable" hatch**. That is
worth stating plainly: `DisplayReplay.controlSized` is doing its job, and
the false-claim failure mode the rubric scores 0 for did not occur once
across eleven windows.



## THE RED LIST

Six items. Each says which side it is on, what the evidence is, and
enough to pick it up cold. **None of these is fixed here** — this is a
survey, and four other agents are working the same tree.

### R1 — Small system text renders 33% too large, and overruns (RENDERER)

`mirror/host/MirrorKit/Sources/MirrorKitUI/DisplayReplay.swift`,
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

## What is NOT broken, and should be said

- **No false "Bitmap unavailable" hatch, anywhere, across eleven
  windows.** The `controlSized` bound is holding.
- **The join works.** Sound's list, Appearance's labels, Date & Time's
  values and General Controls' entire layout all cross from offscreen
  worlds hooked at birth and land at the right coordinates.
- **PLACEMENT is the strongest axis** — 3 on nine of ten scored windows.
  No whole-region offset appeared in this sweep; the destination-origin
  arithmetic fixed earlier the same day is holding.
- **Chrome is right once the window is sized right**: title, close box,
  zoom box, grow box and scroll bars all draw correctly at the guest's
  own geometry.

## Gaps in this sweep — what a follow-up should cover

Not attempted or not reached, and honestly so: SimpleText with a
document and with a dialog, Sherlock 2, the three Finder *window* views
(only the desktop was captured), a Get Info window, a Standard File
dialog, an alert, and a pulled-down menu. Calculator and Key Caps both
failed to launch through the anchor (`-192`, and a dropped connection
after eleven processes were open) rather than being judged. The
remaining control panels — Keyboard, Mouse, Startup Disk, Extensions
Manager, Energy Saver, Numbers, Text, Apple Menu Options, File Sharing,
Control Strip — are untouched.

