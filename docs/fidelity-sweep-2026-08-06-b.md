# Fidelity sweep B, 2026-08-06 evening — the A/B the first sweep was owed

**This does not replace [the first
sweep](fidelity-sweep-2026-08-06.md).** That document's scores are a
deliberate baseline taken before the icon asset pack landed, they are
hard-won, and they are still the correct description of the tree they
name. Nothing here edits them. Read A for the rubric, the harness rules
and the red list; this page is the second half of the measurement A was
explicitly set up to enable.

| | A (morning) | B (this run) |
|---|---|---|
| **Renderer tree** | `claude/fidelity-sweep-2026-08-06` off `eb952325` | `claude/gworld-interior-host-render-98ddd5` at `cea30543` |
| **Asset pack** | the OLD one: 186 app icons, 5 generic | `~/Lab/Assets/now-mirror-assets/pack-2026-08-06` — 917 app icons, 139 generic, 16×16 beside 32×32, `manifest.json` sha `4b1775e2d486…` |
| **Guest build** | `1bff0bd2ca39` | `59dce8562ad4 2026-08-06T23:15:12Z`, asserted by `--expect-build auto` on every capture |
| **Guest machine** | `nowvm-fsw1` / `nowvm-fsw2`, anchor 1760 wire 5361 | `nowvm-sweepb`, anchor **1700**, wire **5250**, qmp `/private/tmp/nowvm-sweepb/qmp.sock` — a session-private clone spun by `scripts/spin-up-ppc`, never the defaults, and never the human's stack (QEMU 45724 / wire 5350 / anchor 1740 was left untouched throughout) |
| **Renders drawn from** | the coverage harness's **canned** scene | each target's **own** `<label>-scene.json` — see below |

Nothing here touched metal. **Tested**, in this project's sense.

## The one methodological change, and it is the finding

A's renders were produced by `testRenderSweepCaptures`, which composes
every capture onto `now-scene-ir-v1` with `controls = []` and no
`dialogItems` at all. That isolates the capture — and it means every A
render was drawn with an **empty semantic-exclusion list**, while the app
draws the same capture with one entry per DITL row.

That difference was the entire content of a regression reported against
the live app this evening: Date & Time rendered whole in the harness and
lost its date, its time, both group boxes and every field in the app,
from the same bytes. A sweep judged from canned-scene renders scores a
picture the app never draws.

So B renders each capture onto **the scene it was captured against**,
through `LiveShapedRenderTests.testRenderASweepAsTheAppWouldDrawIt`:

    tools/fidelity-sweep.py --port 5250 --qmp /private/tmp/nowvm-sweepb/qmp.sock \
        --anchor 1700 --vm nowvm-sweepb --expect-build auto \
        --outdir /private/tmp/fsweepB --target …

    NOW_SWEEP_DIR=/private/tmp/fsweepB NOW_RENDER_DIR=/private/tmp/rendersB-live \
        swift test --filter LiveShapedRenderTests

    tools/fidelity-pair.py --sweep /private/tmp/fsweepB \
        --renders /private/tmp/rendersB-live --out /private/tmp/pairsB

**Because of this change, B and A are not strictly the same measurement.**
B is the harder one and the honest one. Where a B score is lower than A,
say whether the picture got worse or the measurement got truer — this
page does, per row.

## The table

Scores are TEXT / PLACEMENT / CONTROLS / REGIONS / CHROME, 0–3, against
A's rubric. Every row was judged from `<label>-pair.png`: the guest's own
QMP screendump on the left, the host render on the right, same moment.

| Window | A (T/P/C/R/Ch) | B (T/P/C/R/Ch) | What moved |
|---|:-:|:-:|---|
| **Memory** | 1/2/2/2/3 | **3/3/1/2/3** | The biggest move in the sweep. A's "every string present and every string too wide" is gone — every sentence now reads as the machine writes it, at the right size and inside its own control. **T 1→3, P 2→3.** CONTROLS drops 2→1 and that is the truer measurement, not a regression: the three left-hand icons are blank plates, the radio dots and the slider thumb are absent. |
| **Date & Time** | 2/3/2/3/3 | **3/3/2/3/3** | The date `8/ 6/2026` and the time both cross and land in their fields; both group boxes, the time-zone sentence and the time-server line are all back. Ellipses now render on the button titles. One string still clips — see R-B1. |
| **General Controls** | 2/3/1/2/3 | **3/3/1/3/3** | Every string present and placed; both slider scales with their tick labels; group boxes right. Control GLYPHS still absent (no ticks, no dots, no thumbs), so C stays 1. Two group titles still lose their last glyph — R-B1 again. |
| **Appearance** | 1/3/2/1/3 | **2/3/2/2/3** | The description now carries its honest truncation ellipsis instead of stopping mid-word, and the theme names, the current-theme line and the live scroll bar all draw. **The two missing tab labels are unchanged** — "Themes" and "Appearance" are still absent while Fonts/Desktop/Sound/Options draw. Theme swatches still blank. |
| **NOW's own window** | not in A | **3/3/2/3/3** | New row. Fifteen sidebar rows that rendered as fifteen "Visual unavailable" hatches this evening now draw as icon stubs at their true positions; all text, both button rows and the status bar match the machine. |
| **Finder desktop** | N/A (harness) | **not scored** | The harness limitation A names is gone — the desktop composes — but the sweep's own scene comes from `scene.request` and carries no `desktopItems`, so the backdrop renders empty for a reason that is the RIG, not the mirror. See "what B cannot judge". |
| Note Pad, Scrapbook | 3/3/2/3/3, 2/3/2/3/3 | **not captured** | `launch error` through the anchor, twice. Not a mirror result; A's rows stand. |

No window in B drew a **"Bitmap unavailable"** or **"Visual
unavailable"** hatch. That was already true of the bitmap hatch in A; the
DITL hatch is new to B because A's canned scenes had no DITL to draw one
from.

## What B cannot judge, said before the red list

- **The desktop roster is not in a sweep scene.** `tools/fidelity-sweep.py`
  and `tools/gwprobe.py` speak `scene.request` to the guest directly.
  Desktop icons are HOST work — an AppleScript roster the app merges in
  `NOWMirrorSource.withIcons` — so no sweep scene has ever carried them
  and no sweep render can score them. This is the same hole that made an
  earlier "reconfirmation" of desktop items void. It was answered
  separately, live: the running app reports 19 placed desktop icons with
  the Finder's own coordinates, and a render fed those draws all of them.
- **The desktop PATTERN is a fixed substitution.** The pack's
  `patterns/desktop.png` (`ppat` 16, "Mac OS Default") is tiled
  unconditionally; the guest here is showing a different pattern
  entirely. Every B pair shows purple Mac faces beside a blue swirl. It
  is not a placeholder and not a hatch — it is a plausible wrong answer,
  which is the more dangerous kind.
- **CONTROLS is still one plane answering alone.** As in A, these
  captures carry the content plane; a checkbox reaches it as a themed
  blit and a neutral plate is the honest rendering of one.

## THE RED LIST — B

Three items. A's red list is not repeated here; four of its six were
fixed before this run and R1 in particular is what moved Memory from 1 to
3 on TEXT.

### R-B1 — The system font is a substitution, and the guest's own clip cuts it (PACK)

Font id 0 is "the system font", which under the Appearance Manager on
Mac OS 8.5+ is **Charcoal**. The pack carries no Charcoal strike, so
`DisplayReplay.strike(font:size:)` answers **Chicago**, which is wider.
Where an application clips its own text the extra width is fatal: Date &
Time sets `clip [40,195,210,217]` around a group-box title and draws
"Use a Network Time Server", and the mirror renders **"Use a Network Time
Serve"**. The machine's pixels have the whole word. General Controls
loses the last glyph of two group titles the same way.

Evidence: `fsweepB/date-and-time.json`, the `text` op at pen `[40,210]`
with `len 25 fullLen 25 trunc false`, immediately preceded by that clip.
The bytes are complete; the metrics are not ours.

**Not a renderer bug and not fixable in the renderer.**
`tools/extract-assets-offline` does not extract fonts at all — the
strikes in `Resources/fonts` predate it — so the fix is an extraction
path for Charcoal at 12, after which one line in `strike` changes.

### R-B2 — The dialog walk reports a POINTER where a label belongs (GUEST)

Memory's captured scene carries twenty `staticText`/`editText` DITL rows
whose `title` is not text: `\u{1e}πN,\u{1e}πM@` is eight bytes of 68K
address. The guest reads the item's text through a handle and, when that
read fails, reports the handle.

Two things went wrong with it downstream, and the second is the sharper
lesson. The renderer DREW them, so the panel read "πO πM@" where the
machine says "Disk Cache size is calculated when the computer starts
up." And the exclusion gate BELIEVED them: a non-empty title made the row
look like it carried content, so it silenced the guest's own drawing
underneath and the panel lost the sentence it had just been given back.

`SceneRenderer.displayableTitle` now rejects a title containing control
bytes — no Mac OS dialog label has one and a corrupted read reliably
does — which is a renderer-side defence, not the fix. **The guest defect
is open.** The same capture also reports item rects at `l = 16555` and
`l = 16448`, which is the same corruption one field over.

### R-B3 — Appearance's first two tab labels never arrive (unchanged from A)

"Themes" and "Appearance" are absent while "Fonts", "Desktop", "Sound"
and "Options" draw. A attributed this to a later pass painting over them.
B reproduces it exactly, on a different guest build and a different VM,
with the fixes in — so it is neither an asset-pack effect nor a
placeholder effect. It is the one A finding this run neither improved nor
explained.

## Provenance

Every capture in `/private/tmp/fsweepB` carries `provenance` naming the
build, the VM and the run. `date-and-time-scene.json` from the morning
sweep is now committed as
`now-host/Tests/HostTests/Fixtures/now-scene-sweep-date-and-time.json` —
the first scene fixture in the tree that carries a window's controls and
dialog items, because the defect this evening was invisible to every gate
that had only canned ones.
