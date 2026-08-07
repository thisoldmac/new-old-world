# Fidelity sweep B, 2026-08-07 — the first sweep that went looking for seams

**Status: SURVEY, run alone, no human co-drive.** The first sweep under
[version 2 of the specification](fidelity-sweep-spec.md), whose job changed
from *is this horribly broken* to *where do two things meet and disagree*.
It does not replace [sweep A](fidelity-sweep-2026-08-07-a.md), which is the
baseline it compares against; A is untouched, as are the two 2026-08-06
sweeps.

Six of A's twenty-odd rows are **not comparable** with this page and each
says so on its own row. The reasons are declared rather than smoothed:
A ran before anchor acquisition was understood, before the content plane's
arming was understood, and — the largest one — **before dialog-item titles
were real strings**, which is a landed improvement that this sweep finds
has broken the render.

---

## WHICH RIG THIS DESCRIBES — read before quoting anything

| | |
|---|---|
| **Sweep tree** | `claude/019-sweep-b`, forked from `claude/019-integration-4` at **`8f75018d`** ("merge(int4): 019-charcoal"). The integration branch moved **18 commits** while this ran; the sweep body measures the frozen commit, and an explicitly-labelled **addendum** re-measures three rows against `924e30d5`. |
| **Guest build (body)** | `7e8d5e35bc36 2026-08-07T07:03:28Z`, asserted by `--expect-build auto` on **every** capture and re-asserted on every phase-B connection. |
| **Guest build (addendum only)** | `c0b3359eb5c4 2026-08-07T07:39:16Z` — the app rebuilt at `924e30d5` and restaged live (`tools/local-restage-app.py`). `ext/` is unchanged between the two commits, so the resident is the same and no cold boot was owed. |
| **Base image** | `~/Lab/Assets/os91-qemu/os91-runner.qcow2`, sha256 `f34f7e5df64e09ced96c7968776692bb94d9639ee32a6f51652449e1a9cda776`. Plain base, never baked — `scripts/spin-up-ppc` clones it and stages **this checkout's** ext and app, so the resident under test is this tree's. The shared oracle `now-mirror-stage.qcow2` (`c466baa9a545…`) was **not used**; its newest receipt is from `claude/018-image-discipline` at 2026-08-06T22:58. |
| **Resident** | guest's own `mirror` at boot: lifecycle `active`, capabilities `511`, sourceManifest `f41867cfe431`, buildFingerprint `4d0988e8e891` — the local build's own fingerprint, matched. |
| **Guest machine** | QEMU `mac99`, Mac OS 9.1, 800×600. Lane block **238** (`tools/lane-ports`): anchor **13904**, wire **13905**, run dir `/private/tmp/nowvm-swb`. Michelle's stack (anchor 1940 / wire 5490, pid 10147 / 13485) was left alone and never dialled. |
| **Who answered** | every capture and every phase-B connection asserted the build in the guest's own `hello`. No result here could have come from another session's VM. |
| **Host app** | built from this tree into `/private/tmp/nowhost-swb`. **Not launched** — see "what this sweep could not measure". |
| **Asset pack** | `~/Lab/Assets/now-mirror-assets/pack-2026-08-06`, unchanged from A. |

### Artefacts

Out of git: `~/Lab/Assets/now-mirror-assets/sweep-2026-08-07-b/` — 59 MB,
161 files (capture pass, renders, the sweep-A re-render, pairs, phase-B
screendumps and scenes, the three mutation experiments, every driver
script, and the run's own provenance). Manifest
`~/Lab/Assets/now-mirror-assets/sweep-2026-08-07-b.sha256`, itself sha256
**`5de039bf60b19e575b9e64120c708c2596955577805f6ead92aa1bb2dd482792`**.
Copied out **before** any teardown, because a lane reported this week that
`tools/lane-ports reclaim` deletes evidence PNGs with the run directory.

### Where to look, for the claims that carry the most weight

All paths relative to `~/Lab/Assets/now-mirror-assets/sweep-2026-08-07-b/`.

| Claim | Guest's pixels (the truth) | The render | The control |
|---|---|---|---|
| R1 Memory drawn twice | `p1/memory-guest.ppm` @ `80,60,432,378` | `r1/memory.png` | `rA/memory.png` — sweep A's capture, **today's renderer**, clean |
| R1 proved by mutation | — | `x4/memory.png` — DITL titles blanked, doubling gone | `x3/memory.png` — root rect reverted, doubling stays |
| R2 the extra stroke | `p1/memory-guest.ppm` @ `142,170,225,188` | `r1/memory.png`, same rect | `rA/memory.png`, same rect |
| Six tabs draw | `p1/appearance-guest.ppm` @ `167,70,631,400` | `r1/appearance.png` | — |
| The "r" in "Serve**r**" | `p1/date-and-time-guest.ppm` @ `235,285,470,305` | `r1/date-and-time.png` | — |
| A tab switched | `b/add2-tab-desktop.ppm` @ `167,70,631,400` | — | `b/add2-tab-desktop.json` (tab value 4) |
| A list row selected | `b/add3-listrow.ppm` @ `167,70,631,400` | — | the panel's own `Pattern: Lollipop 4` label |
| A creatorless icon | `b/add-finder-nowdev.ppm` @ `21,49,425,287` | — | — |

`crop.py` and `px.py` (in the same directory) are how every rectangle above
was pulled and profiled; `px.py` prints run-length colour profiles rather
than a similarity score, on purpose.

---

## ✗ FIRST — two regressions, because a regression outranks any seam

### R1. Memory's interior is now drawn TWICE, and the cause is a fix that landed

**Sweep A scored Memory TEXT 3.** It is now unreadable in the render:
"Disk Cache" over "Disk Cache", "Select Hard Disk:" over "Macintosh HD",
and the explanatory paragraph overprinted on itself.

It is **not** the renderer. Sweep A's own capture, re-rendered through
*today's* tree, comes out clean — `rA/memory.png` in the artefact store,
same code, same day, no doubling. Same renderer, different capture.

The capture's drain is equivalent to A's (4,744 ops in both, 265 text ops
in both, identical pen positions for every string checked). The
difference is entirely in the **scene**, and it is this:

| | sweep A dialog item | sweep B dialog item |
|---|---|---|
| #2 | `'\x1fo_d\x1fo^ '` | `Virtual Memory` |
| #5 | `'\x1fo_\x0c\x1fo^ '` | `Select Hard Disk:` |
| #19 | `'\x1fo_¯\x1fo^ '` | `Disk Cache size is calculated when the computer starts up. The current estimated size is ^1K.` |

**The pointer-title defect is fixed** — sweep A's single loudest callout
("pointer titles are not a Memory problem, they are everywhere") is gone,
and that is a real and large win. But nothing downstream was ready for the
titles to be real: the semantics plane now draws its DITL text on top of
the content plane's captured pixels of the same words, a few points off,
with `ParamText` placeholders (`^1`, `^2`, `^3`) still uninstantiated
because the DITL carries the *template* and only the machine knows the
substitution.

**Proved by mutation, not by inspection.** Blanking every dialog-item
title in sweep B's own scene and re-rendering removes the doubling
(`x4/memory.png`). Reverting only the root control's rect does not
(`x3/memory.png`). This is the seam the specification asks for, in its
purest form: **two producers of one answer, both now correct, drawing at
once.**

### R2. A one-pixel vertical stroke is drawn at the left of static text

Survives the mutation above, so it is a second and independent defect.
Every string owned by a `role: static` control gains a full cap-height
vertical bar immediately to its left, which merges with the first glyph:

- Memory renders **"Ⅱirtual Memory"**, **"Ⅱvailable for use on disk"**.
- Appearance renders **"Ⅱurrent Theme: Indigo Foam"** and **"Ⅱo create a new theme…"**.
- Column profile at the same x: sweep B's render has a 12-row black run
  where the machine and sweep A's render have 4 and 6 rows respectively.

Sweep A's capture through today's renderer draws a clean "V". So this,
too, arrived with the scene's new control classification
(`provenance: guest-cdef-resource`, `role: static`), which sweep A's scene
reported as `role: unknown`.

**This is exactly the defect class the specification warns about** — a
one-pixel error no whole-window similarity score can see, in text that
still reads *almost* right. It was found by zooming one rectangle.

---

## The standing checks

Taken opportunistically, and read as **agreement with the guest's own
pixels** rather than as expected appearance, per the two corrections
Michelle made to the list while this ran.

| Check | Verdict | Evidence |
|---|---|---|
| A scrollbar scrolls | **✓** | Extensions Manager, the guest's own re-read `0 → 10 → 80` of `max 146` over nine `part: 23` presses |
| A tab switches | **✓ (addendum build)** / **✗ at `8f75018d`** | tab control value `1 → 4 → 1`, and the screendump shows the Desktop pane. At the swept commit the tab strip carried **no ref at all** |
| A list row selects | **✓ (addendum build)** | Appearance > Desktop > Patterns: "Lime" → **"Lollipop 4"**, the panel's own label re-reading `Pattern: Lollipop 4, 128 X 128, 64K` |
| A list row selects — **Finder's file list** | **✗ / unreachable** | the list window publishes 13 controls, **all** with refs, and **none is the list body**: four column headers, two scroll bars, a triangle, three degenerate buttons at `{0,-21,0,0}`. There is nothing to name |
| A menu item lands where named | **✓** | `menuact menu=259 item=3 titleLeft=110` + serials → the Finder's **own** View menu mark moved from `as Icons` to `as List`, and `Arrange` became `Sort List` |
| A press at an unknown menu position is refused | **n/a — could not be posed** | `menuact` refuses first, and correctly, for a missing `serialHi`/`serialLo`; with serials supplied the position is by definition known. See "instrument" below |
| A window opens, closes, one behind redraws | **✓ (open/close)** | `reveal` 9 → 10 windows; `winact close` → 9. The redraw-behind half was not separately proven |
| Fronting a process — window list **answered** | **✓** | read against Michelle's correction: `empty` is a pass, `unknown` is the failure. The Finder with no window open answers `coverage: complete` with zero windows; before it is driven it answers `unavailable / not-observed` and `meta.errors: ["Finder: ax_oracle_not_found"]`. The two are distinguishable |
| `cycle` populates an undriven machine | **✓** | `considered 11, alreadyAnchored 5, woken 6, backgroundOnly 6, refused 0, vanished 0, restored true` — headless processes named as a kind, not a failure |
| The desktop shows its icons | **✗ (scene) / ✓ (content)** | the Finder's Desktop window carries `desktopItems: 0` in every wire scene, before and after `cycle`, while its drain carries **19 text ops and 19 blits**. The icons reach the content plane and never the structure plane |
| Icons resolve to art, unknowns legible | **mixed** | Extensions Manager's ten checkboxes and ten document icons render as dithered unknown plates at ~14 px — legible as unknown but not art. Memory's three sidebar icons render as **plain white rectangles**, which is worse than an unknown plate. Read against the machine: the guest draws real art in both places, so both are divergences; the white one is the honest failure and the dither is the honest unknown |
| No hatching where the machine drew | **✓** | no "Bitmap unavailable" hatch anywhere in this sweep. Sweep A's worst single result — the Finder's whole interior as one hatch — **did not reproduce** |
| Panel faces are the guest's grey | **✓** | Appearance, Date & Time, Extensions Manager, Memory all render `#dddddd`-family faces matching the screendump; no white plates where the machine drew grey |
| Window stacking matches, incl. two of one process | **partial** | see seam S3 |
| Text is what the machine drew | **✗** | R1 and R2 above; plus a lost leading space (`3:14:44AM` for ` AM`) |
| The Mirror opens from menu / verb / button | **not taken** | the host app was built but never launched; see "could not measure" |
| An act that cannot verify its effect says so | **✓ and ✗** | the vocabulary is there (`dispatched-but-unconfirmed`, `act-not-taken: armed, and the application never called TrackControl`) and it is good. But the list-row select that **demonstrably worked** reported `Settlement: timed-out` with `Re-read value: the anchor plane is absent or not armed`. A false negative on a landed act |

### The incidental capture the coordinator asked for

`b/add-finder-nowdev.ppm`. `Macintosh HD:TimBotTu` in icon view: the file
`runner-execution-next.current` — no creator — is drawn by the guest's own
Finder as the **plain generic document icon**, a blank white page with a
folded corner and no art. It was already in view; nothing was
manufactured. That is the machine being correct and looking exactly like a
renderer giving up, which is the point of
`an-appearance-check-flags-correct-absences` (unlanded: it is on the
parent's `claude/018-findings` branch, not on its `main`). Two other cases sit beside it
in the same window: `tbt-worker` with a real custom icon, and
`runner-0.2b-retired` as an alias (italic name, arrow badge).

---

## The six claims, verdict by verdict

| # | Claim | Verdict |
|---|---|---|
| 1 | **All six Appearance tabs draw, front ones included** | **PASS.** Themes / Appearance / Fonts / Desktop / Sound / Options all render, with tab outlines, the selected-tab join and the panel edge. Sweep A lost "Themes" and "Appearance" entirely on three separate VMs; that is gone. `rehome` using the birth rect is confirmed by the pixels |
| 2 | **"Use a Network Time Serve*r*" has its "r"** | **PASS.** Zoomed 6× against the screendump: identical glyph run, identical widths, the final `r` present. The Charcoal strike landed and this is the sharpest evidence for it in the sweep |
| 3 | **Group-box labels no longer meet their frames** | **PASS for four of five.** "Current Date", "Current Time", "Time Zone", "Menu Bar Clock" all break their frame cleanly around the label. **The fifth is a different defect**: the machine draws a **checkbox** inside the "Use a Network Time Server" frame gap and the render omits it, so the frame's left stub ends early. Missing control, not a chrome overrun |
| 4 | **Window stacking is correct with two applications overlapping** | **PASS in pixels, UNSOUND in data.** See seam S3 — the renders order correctly only because array order happens to be front-first |
| 5 | **Panel faces are the guest's grey, not white** | **PASS.** No white panel faces in any of nine targets |
| 6 | **Unknown regions are legible at 32×32** | **PASS where they are unknowns.** Extensions Manager's ~14 px unknowns read as dither rather than blank. But Memory's three ~32 px sidebar icons render as **flat white**, not as legible unknowns — that rectangle fails the claim |
| — | **A scrollbar scrolls, a tab switches, a list row selects** | **All three now watched on a guest — but only on the addendum build.** At the swept commit `8f75018d` the tab strip and the pattern list carry no reference and none of the three is reachable. `kNowAxResolveMaxControls` is **32** there and **96** at `924e30d5`; Appearance goes from 32/73 controls with refs to **73/73** |

---

## The seams

### S1. Two producers of one answer, both correct, drawing at once
R1 above. The measurement that makes it a *seam* rather than a bug report:
the drains agree, the renderer is unchanged, and the divergence appears
exactly where the semantics plane started telling the truth.

### S2. `windows[].rect` and `controls[].rect` use different origins, and nothing says so
`winact move --left 620 --top 470` answers `Re-read: 620, 470 to 800, 590`.
The very next scene reports that window's rect as `{620, 450, 800, 590}`.
**Twenty points, exactly the title bar.** The act re-reads the *content*
rect; the scene reports the *structure* rect. The same 20 points then
decide whether an act lands:

- Converting Appearance's tab-strip rect to global with `windows[].rect`
  and pressing gives `bad-request: that point is outside the control this
  reference names` — **a correct refusal to a caller doing the obvious
  thing.**
- Adding 20 to the same arithmetic switches the tab, first try.

The refusal is excellent. The ambiguity that makes it necessary is the
defect, and it is invisible to anyone who has not measured it.

### S3. `z` is a per-process index, so it cannot order two applications
Every process's frontmost window is `z: 0`. Date & Time's panel and its
own modal are `1` and `0`, correctly. Across processes there is no
ordering at all — nine windows in one scene carried `z` values
`0,1,0,1,0,0,0,0,1`. The renders are right only because the array happens
to arrive front-first. **The state cell that exposes it is two windows of
the same process overlapping two windows of another**, and that is
reachable: Date & Time's pair over the Finder's pair.

### S4. Two paths to one capability: a control panel cannot be launched from the guest
`launch` over the wire answers `launch-refused: not an application (type
APPC)` for every control panel. The **anchor worker** launches the same
HFS path without complaint, which is why the capture pass worked and phase
B's first attempt did not. A person at the guest's own console cannot open
a control panel; the host's rig can. That is a command-parity asymmetry
nobody has declared.

### S5. `ditemact` cannot be reached with the reference the scene hands you
The scene reports a dialog window as `now-window-…`. `ditemact` requires
`now-element-…` and answers `bad-request: that is not a well-formed
now-element- reference`. Sweep A dismissed the Mail modal through the
host's `mirror_drive --gesture dialogItem --entityID <window>`, which
accepts the window. **The same act, two doors, two different reference
kinds** — and the guest-side door needs an `elements` walk first, which
(per the cdef lane) truncates at 10 of 73.

### S6. The Desktop's rectangle is not the screen, and it moves
`{0, 0, 800, 600}` when nothing else is open; `{506, 0, 800, 600}` once a
SimpleText window covers the left of the screen. The Desktop "window" is
being reported at something like its unobscured remainder. Sweep A read
it as the full screen. Two derivations of one rectangle.

### S7. Control counts fluctuate between scenes with nothing driven
Date & Time's panel reported 21 controls in one scene and **0** in the
next; NOW's own window 9 then 3; Extensions Manager 6 while Appearance
held 73. Nothing was driven between them. A caller that walks a window
twice gets two different machines.

### S8. A phantom out-of-port window
Extensions Manager contributes a second window with an empty title,
`kind: -32767`, rect `{16000, 15980, 16004, 16004}`. The `16xxx` family
sweep A found in *control* rects now appears at *window* level. Related:
Memory's out-of-port control rects, `l: 16448` in sweep A, are now
**clamped to the window's right edge** (`l: 352, r: 352`) — more contained,
still degenerate, and now indistinguishable from a real zero-width control
sitting on the frame.

### S9. The content plane arms, and the wire scene says nothing about it
`scene.request` arms structure, semantics and interaction — three requests
in a row leave `content` and `transitions` at `inactive`. Only `qdtrace
start` claims `kNowPeekOwnerContent`, after which `mirror` reports content
`active-current`. **But no window in the scene gains any `content` field
at all, armed or not.** So the `content: false` rounds 2 and 3 saw is a
*host-derived* field, and arming P3 changes the drain, never the scene
document. `tools/fidelity-sweep.py` arms per target as part of its capture,
so this sweep's interiors are armed; a rig that only takes scenes cannot be
fixed by "arming the content plane" because the scene is not where the
interior lives.

---

## The scores

Nine targets, rendered onto their own scenes through the app's composition
path, judged against the screendump of the same instant.

| # | Target | T | P | C | R | Ch | **STAB** | **DRIVE** | comparable with A? |
|---|---|:-:|:-:|:-:|:-:|:-:|:-:|:-:|---|
| 1 | Appearance (6 tabs) | 2 | 3 | 1 | 1 | **3** | – | **0** → 3 (addendum) | **no** — A measured it undriven and CHROME 2 |
| 2 | Date & Time | 3 | 3 | 2 | 2 | 3 | – | 2 | partly — A's STAB row was void |
| 3 | **Extensions Manager** (new) | 3 | 3 | 2 | 1 | 3 | – | 2 | **no** — never swept |
| 4 | Memory | **0** | 3 | 1 | **0** | 3 | – | 1 | **no** — R1/R2 |
| 5 | Monitors | 0 | 2 | 2 | 0 | 3 | – | 1 | yes — identical to A |
| 6 | SimpleText + document | 3 | 3 | 2 | 3 | 2 | – | 1 | yes |
| 7 | Sherlock 2 | 2 | 3 | 1 | 2 | 3 | – | 1 | yes |
| 8 | Finder — desktop | 1 | 2 | – | 0 | 3 | – | 0 | **no** — A had no desktop render |
| 9 | NOW's own Workshop | 3 | 3 | 2 | 3 | 3 | – | 2 | yes |
| — | Calculator | – | – | – | – | – | – | – | **unreachable**: `launch err -192` |

**STABILITY is `–` for every row and that is a method change, declared.**
Sweep A ran two capture passes and diffed content rectangles; this sweep
spent that budget on states and seams instead. A's answer — eight of nine
panels pixel-identical across two passes — has not been re-measured and
should not be assumed to survive R1.

**Extensions Manager is the rotated new-target slot** and it earned it: a
real list with four column headers, a scroll bar with a live 0–146 range,
ten checkboxes, disclosure triangles, two disabled buttons and a popup
menu. Text, columns, row banding and button chrome all agree with the
machine closely; what it costs is REGIONS 1 (every icon an unknown plate)
and one clean CHROME divergence below.

### Free-text callouts, per the mandatory field

- **Scroll arrows are at the wrong END, consistently.** The machine puts
  both arrows together at one end of a scroll bar — OS 9's "smart
  scrolling", visible in Appearance's horizontal bar and Extensions
  Manager's vertical one. The render splits them one to each end. Two
  targets, two axes, same divergence. Not previously named.
- **A lost leading space.** The machine draws `3:14:38 AM`; the render
  draws `3:14:44AM`. The drain carries `' AM'` with its space. A separate
  text run's origin, not a font problem.
- **Text records cap at 64 bytes, and the render says so honestly.** The
  guest sent `'To create a new theme, modify the settings in the following
  sect'`; the drain carries `trunc` and `fullLen`, and the render ends the
  line with an ellipsis. That is right. It also means the render draws the
  *same glyph* for "the machine drew …" and "we truncated", which nothing
  distinguishes downstream.
- **Bold is lost.** "Control Panels" is bold on the machine and regular in
  the render; "Current Theme: Indigo Foam" likewise.
- **The help "?" button is a blank or dithered plate** in Appearance, Date
  & Time and Extensions Manager — three for three, where sweep A said five
  for five. Still unresolved.
- **Monitors is unchanged from A and from July**: 17 records, none on its
  own window port, interior a hatch. The pure capture-side hole.
- **SimpleText's window port records no `text` op at all** (state 82, rect
  44, bits 14, line 42, rgn 12). A document window that is almost entirely
  text produces no text records. Not chased.
- **`--quit-after` still cannot close a modal, and the tidy OPENS one.**
  `Sweep._dismiss` presses DITL items 2 then 1 on any window of kind 1–3.
  A control panel is a modeless dialog of kind 2, and Date & Time's item 2
  is **"Set Time Zone…"**. The hygiene routine opened the modal it then
  failed to close, and contaminated every target after it. Sweep A voided
  a row to this; the fix made it worse.

---

## State cells: visited, and the ones that could not be reached

| Cell | Reached | Note |
|---|---|---|
| Front | ✓ | every target |
| Behind | ✓ | NOW behind the Finder; Appearance behind Extensions Manager |
| Modal over a window | ✓ | Date & Time + "Set Time Zone", captured together |
| The window after the modal closes | **✗** | `ditemact` refused the window reference (S5) and the panel then declined `quit`; the modal stayed up for the whole run |
| Two windows of the same process | ✓ | Date & Time's panel + modal, `z` 1 and 0 |
| Two windows of the same process, **overlapping, both documents** | **✗** | SimpleText answers `osaErr -1753` to `make new document`, and there is no wire verb for "open a second window" |
| A control at its minimum | ✓ | Extensions Manager's scroll bar at 0 |
| A control at its maximum | ✓ | driven to 80 of max 146, which is the bottom of its travel |
| An empty list | **✗** | no empty-folder or empty-list target was set up |
| A full / scrolling list | ✓ | Extensions Manager, ~150 rows |
| Resized narrow enough to truncate a label | ✓ | Finder window to 180×120; screendump taken |
| Moved to a screen edge | ✓ | to `620,470`, i.e. hard against the bottom-right |
| Selected row / selection by invert | ✓ | `reveal` selects, and the Patterns list selection moved |
| A very long filename | **✗** | the folder was created; the files were not. Out of time, not out of reach |
| A high-MacRoman name | **✗** | same |
| An empty name | **✗** | same |
| A creatorless document's icon | ✓ | incidental, `add-finder-nowdev.ppm` |
| Icon / list / button Finder views | icon ✓, list ✓, button **✗** | list verified from the machine's own View-menu mark, not from a slug — round 3 is right that the old `finder-list` baseline is void |
| A modal that cannot be dismissed normally | ✓ (unintentionally) | the Date & Time one, which is why the row above is ✗ |

---

## Reliability and latency, in separate columns

| Operation | attempts to land | time to settle |
|---|---|---|
| `scene.request` (wire, full document) | 1/1, 16 scenes | **16–209 ms**, median **21 ms** |
| `ctlact` scroll (`part: 23`) | 1/1 × 9 | 90–106 ms |
| `ctlact` tab (`part: 0` + point) | **3 attempts** — 2 refused on the rect seam, 1 landed | 5–7 ms to refuse; 5.6 s to land |
| `ctlact` list row | 1/1 | 5.7 s |
| `menuact` (with serials) | 1/1 | 161 ms |
| `winact` move / resize / close | 3/3 | 117 / 141 / 283 ms |
| `cycle` (11 processes) | 1/1 | 503 ms |
| `launch` a control panel over the wire | **0/1** — refused by kind | 6 ms |
| capture pass (10 targets, drains + screendumps) | 9/10 ok, 1 launch failure | ~8 min wall |

**Reliability is high and latency is bimodal.** Anything that only reads
answers in tens of milliseconds — the wire scene is now two orders of
magnitude faster than sweep A's ~1.9 s host walk. Anything that has to be
*settled against the machine* costs 5–6 s, and that is the whole of the
"perf is still meh" complaint: it is settlement, not dispatch, and the
9-press scroll run at 100 ms each shows dispatch alone is cheap.

---

## What this sweep could not measure

- **The live app's own pixels, again.** The host app was built and not
  launched: the agent socket is one per user (`TMPDIR/dev.newoldworld.now-agent-501/host.sock`)
  and **two other sessions' hosts were already running**, one holding it
  since 00:26. `NOW_AGENT_SOCKET_SUFFIX` would have isolated mine, but the
  wire port can be held by the sweep tool or by a host and not both, and
  the states-and-seams work needed the wire. So: **no `mirror_read`
  numbers, no DRIVE-from-the-agent-surface column, and the "Mirror opens
  from menu / verb / button" check untaken.** A's drivability table is the
  most recent word on that surface.
- **Flicker.** Same limit as A: this instrument renders settled captures.
  `tools/fidelity-live.py` exists now and was not run.
- **Anything on metal.** Emulator only.

## Instrument blind spots found — the fourth, fifth and sixth of this arc

The coordinator asked to be told if a standing check could not tell "the
machine has none" from "we could not see". Three more, and one is in the
list itself:

1. **"A press aimed at a menu whose position is unknown is refused, not
   armed at x=0" cannot be posed.** `menuact` refuses first, for a missing
   `serialHi`/`serialLo`, and once those are supplied the position is
   known by construction. The check as written has no reachable case.
2. **The sweep's own hygiene cannot tell a window a target OPENED from a
   window that became VISIBLE.** Fronting the Finder makes its Desktop
   window appear; `Sweep.tidy` compares against a fingerprint taken before
   the front, calls it residue, and marks the next target contaminated. It
   did exactly that on this run.
3. **The hygiene routine's dismissal is a guess that can act.** Item 2 is
   Cancel *by convention*; on a modeless control panel it is whatever the
   DITL says, and here it was "Set Time Zone…". A cleanup step that opens
   a modal is worse than one that leaves the world dirty, because it looks
   like the target's own defect.

To which this sweep adds a fourth of its own: **`content: false` cannot be
fixed by arming the content plane**, because the wire scene has no
per-window content field at all (S9). A rig that reports empty interiors
is reporting its drain, and the drain is a different channel.

---

## What should be fixed before sweep C

In order, by what a person would notice first:

1. **Decide which producer owns a string, and draw it once (R1).** The
   semantics plane's DITL titles and the content plane's captured text are
   now both correct and both drawn. The DITL is a template with `^1`
   placeholders and the content plane has the substituted truth, so the
   content plane should win wherever it has the rectangle. This is the
   single most visible regression in the tree.
2. **Find the extra vertical stroke on `role: static` controls (R2).** One
   pixel, every static label, arrived with the CDEF classification.
3. **Declare the coordinate origin in the scene, or make the two agree
   (S2).** Twenty points decide whether an act lands and nothing in the
   document says which origin a control rect uses. Either put the content
   origin on the window or state the convention where both sides read it.
4. **Make `z` a scene-wide order, or stop calling it `z` (S3).** The
   renders are correct by accident of array order and there is now a test
   pinning that accident.
5. **Give the Finder's list rows something to name.** Every other list in
   this sweep is drivable; the Finder's is not, and it is the one Michelle
   named. The column headers carry refs and the rows do not.
6. **Settlement reports a false negative for a landed act.** The list-row
   select that visibly worked answered `timed-out` / "the anchor plane is
   absent or not armed".
7. **The sweep tool's hygiene needs the three fixes above** (blind spots
   2 and 3) before another sweep runs, or it will contaminate rows again.
8. **`launch` should serve control panels** (S4), or the asymmetry should
   be declared in `docs/command-parity.md`.

And one thing that should be **left alone**: the refusal vocabulary. Every
refusal this sweep met — `act-not-taken: armed, and the application never
called TrackControl`; `that point is outside the control this reference
names`; `menuact requires serialHi and serialLo…`; `4744 ops named no
window in this scene`; `quit-declined … declined, or asking about unsaved
work`; `backgroundOnly: 6` — said what happened and why. Two of this
report's findings exist *because* a refusal was precise enough to argue
with.
