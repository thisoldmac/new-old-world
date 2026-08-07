# Fidelity sweep D, 2026-08-07 — scoring the composed result of rounds 6 and 7

**STATUS: IN PROGRESS. This file is a live checkpoint, not a finished
sweep.** Everything below is recorded as it is measured, so that a session
that ends without warning still leaves the measurements behind. Rows
without evidence beside them have not been taken.

Sweep C (`docs/fidelity-sweep-2026-08-07-c.md`) is the most recent
finished word; nothing here edits it.

## Why this sweep exists

Two integration rounds have landed since sweep C — round 6 (16 lanes) and
round 7 (15 lanes), roughly 157 commits — and **nothing has scored the
composed result.** Round 7 reports `GATE_EXIT=0` with the host gate run
twice and no flake. This sweep asks whether the composition is what the
lanes each claimed.

## WHICH RIG THIS DESCRIBES — read before quoting anything

| | |
|---|---|
| **Sweep tree** | `claude/019-sweep-d`, forked from `claude/019-integration-7` at `1a35e96f` ("docs(open-issues): four things round 7's merge could see and no gate could"). |
| **Spec** | `docs/fidelity-sweep-spec.md` at version **3.1** (the version-history row is present in the copy on this branch; it is byte-identical to the copy on `claude/019-sweep-c`). |
| **Lane block** | **982** via `tools/lane-ports` — anchor **19856**, wire **19857**. The human's reserved block 590 / ports 16728–16729 was never dialled. |
| **Base image** | `~/Lab/Assets/os91-qemu/now-mirror-stage.qcow2`, named explicitly (it is also what `tools/base-image` designates for `ppc-work`). |
| **Guest build** | `scripts/build-guests` green for all six targets on this tree before any capture. |

## Method changes from sweep C

- (to be filled in as they are made)

## Claims under test — what changed since sweep C

Each is a rectangle to look at, not a vibe.

1. **Title-bar widgets, per window class.** `WindowChrome.widgetBox`
   previously opened `guard win.kind != 2`, so every Dialog-Manager-owned
   window got no widgets. Claimed now at 100% agreement on close box,
   collapse box, stripes, frame row and the bar's bottom edge. The band's
   residual (Chicago standing in for Charcoal) is known and out of scope.
2. **`Platinum.contentTop` 22 → 20.** If the claim holds, every window's
   interior has been two pixels low and one right in every render this
   project has taken. Check that every window moved, and that nothing else
   moved with it.
3. **The zoom box is drawn nowhere.** IR v1 cannot say whether a window
   has one and `kind` cannot stand in. Confirm the absence is honest
   rather than a new gap.
4. **Render stability.** `ImageRenderer.cgImage` now renders into our own
   bitmap context; 1,471 of 57,600 fixture pixels changed. Confirm against
   the machine, not against the old render.
5. **CDEF classification counts went DOWN deliberately** (Memory 33→23 of
   44; Date & Time 19→10 of 21). A lower number is the fix.
6. **`controlsState`** now distinguishes `complete` / `empty` / `unknown` /
   `notFetched`.
7. **The desktop reports who answered** — `machine` / `assetPack` / `none`
   — and a substituted desktop draws a corner plate. An unmarked desktop
   now means the machine named it.

## Live defects to report, never to fix

- **Mail's modal has unclickable buttons** — correct labels, no action,
  "the guest did not provide complete, authoritative semantics." A lane
  owns it. Note what a wedged modal blocks.
- **One interior at a time** is the built behaviour; a screenshot with one
  live interior and the rest hatched is not a defect.

## ✗ FIRST — a FALSE NEGATIVE on an act that landed, caught in the guest's own pixels

**This is the row the spec calls "the expensive one", and the sweep has
one.**

SEQ-A step 4 pressed a control in the Appearance panel — the help "?"
button, `role: button`, rect `(598,125)-(627,153)` — with `ctlact
part: 11`. The act answered:

```
{"code": "act-not-taken",
 "message": "armed, and the application never called TrackControl",
 "correlation": "4F976CC0-00000003",
 "settlement": "timed-out"}
```

A refusal, with a reason, and a settlement that timed out. Under sweep
C's reading that is a **pass** — the plane declining to claim something it
could not verify.

**It is not a pass. The press landed.** The screendump taken before the
press (`c/A2-after.ppm`) shows Appearance on its Themes tab and no Help
Viewer anywhere on the machine. The screendump after the sequence
(`c/A5-back.ppm`) shows **Mac Help open and frontmost, having run a search
for "Appearance", with ten results on screen.** Nothing else in the
sequence could have opened it: step 5's only act was refused with
`element-not-found` in 5 ms.

| act said | machine did | verdict |
|---|---|---|
| `act-not-taken` + `settlement: timed-out` | **Mac Help opened and searched** | **✗ false negative** |

### And the mechanism is in the message

The refusal says exactly why it believes nothing happened: *"the
application never called TrackControl."* **That is one mechanism's
evidence being reported as the world's state.** A Carbon control that is
actuated by any other route — and a Help button on CarbonLib is a prime
candidate — lands while `ctlact` reports it did not, because the only
thing being watched is a trap the application never had to call.

So the finding is not "the refusal text is wrong". It is that
**`act-not-taken` is inferred from a single observation and phrased as a
conclusion about the machine.** `dispatched-but-unconfirmed` — which
`ctlact part 0` now returns, and which is the honest shape — was
available and was not used here.

### What this costs, said plainly

Sweep C's report scored an identical message on `part 11` as *"REFUSED
CLEANLY"* and listed the act plane's refusal vocabulary among the two
things that should be **left alone**. On this evidence that row cannot
stand as written: the same message, in the same verb, is sometimes a
correct refusal and sometimes a false negative, **and nothing in the
message distinguishes the two.** An agent cannot tell them apart, and
neither could a sweep that did not happen to screendump the whole screen
afterwards.

**Verification level: this is a driven observation on an emulated guest,
with the build asserted. Not metal-verified.**

## ✗ SECOND — a claim under test IS NOT IN THE TREE

**Claim 4, render stability, is not on `claude/019-integration-7`.** The
fix exists — `49c9a6f6` *"fix(mirror): one scene, one picture — and the
buffer that was never ours"*, the commit that measured the 1,471 of 57,600
changed pixels — and it lives on **`claude/019-first-render-differs`**, a
branch this round did not merge.

Derived, not remembered:

```
$ git merge-base --is-ancestor 49c9a6f6 HEAD ; echo $?
1                                   # NOT an ancestor
$ git branch -a --contains 49c9a6f6
+ claude/019-first-render-differs    # and nothing else
$ git log --oneline --merges claude/019-integration-7 ^claude/019-integration-5 \
    | grep first-render
                                     # no merge of that lane in rounds 6 or 7
```

And the code says the same thing: `RenderShot.png`
(`mirror/host/MirrorKit/Sources/MirrorKitUI/SceneView.swift:64-68`) still
reads

```swift
let renderer = ImageRenderer(content: view)
renderer.scale = 1
guard let cgImage = renderer.cgImage else { … }
```

— the borrowed backing store, not a bitmap context of our own.

**Why this outranks the rest of the report.** It is not only an unlanded
fix. It is a live hazard for *this* sweep and for every render finding
taken from this tree, because the composed renderer's output depends on
how many renders have already happened in the process. The nine targets in
a capture pass are rendered by one `LiveShapedRenderTests` process in list
order, so the earliest targets are drawn by a renderer that has not
settled and the later ones by one that has. **A per-target render finding
from this tree carries an ordering artefact nobody has been subtracting.**

The other six claims ARE in the tree, checked the same way:

| # | Claim | Landed? | Where |
|---|---|---|---|
| 1 | title-bar widgets per window class | **yes** | `WindowChrome.hasTitleBar` now `!(kind == 2 && title.isEmpty)`; lane `019-titlebar-fidelity` merged at `5c29db31` |
| 2 | `Platinum.contentTop` 22 → 20 | **yes** | `PlatinumTheme.swift:131` and `PlatinumTitleBar.Row.contentTop` both 20 |
| 3 | zoom box drawn nowhere | **yes** | `WindowChrome.zoomBox` returns `nil` unconditionally, with the Extensions-Manager/Memory pair written into the doc comment |
| 4 | render stability | **NO** | see above |
| 5 | CDEF counts down deliberately | **yes** | `8bb266b5` "a button family is not a push button", in HEAD |
| 6 | `controlsState` 4-way | **yes** | `Scene.ControlsState` = complete/empty/unknown/notFetched, read through `controlsKnowledge` |
| 7 | desktop names who answered + corner plate | **yes** | `SceneRenderer.swift:332-352`, lane `019-honest-substitution` merged at `b64a1504` |

## A seam found while checking claim 1, before any pixel was taken

`WindowChrome.hasTitleBar` was corrected from `win.kind != 2` — the
discriminator that gave every Dialog-Manager-owned window no widgets.
**`WindowChrome.growBox` (`WindowChrome.swift:96`) still reads
`win.kind != 2`.** So a `kind == 2` window that IS resizable — Extensions
Manager is the corpus's own example, and it is the very window the zoom-box
doc comment cites for exactly this "kind cannot stand in" reason — gets no
grow box from the hit-tester. Same wrong discriminator, same file, one
function apart, fixed in one place. Not yet checked against the machine.

## Method change: the BEFORE is measured, not remembered

Claims 1 and 2 are "this changed" claims, and a sweep that only measures
the after cannot score them. So this sweep re-ran its own rectangle
instrument over **sweep C's stored artefacts** — the same guest
screendumps and the same renders sweep C published, taken from the round-5
tree — and reports the before and after side by side, derived twice by one
script.

That is a method change and it is declared: no earlier sweep re-measured
an earlier sweep's pixels.

The instrument is `rects.py` (in this sweep's artefact store). It samples
the modal colour of a window's row `t-2 … t+21` across the window's own
width, on the guest and on the render, and separately compares the three
widget boxes `PlatinumTitleBar` defines. **No similarity score anywhere**
— every number is a named row or a named box.

### The BEFORE, sweep C's own eight targets, re-derived from its store

`rects.py --sweep …/sweep-2026-08-07-c/p1 --renders …/r1`

| target | guest's black rows | render's black rows | rows agreeing | widget px agreeing |
|---|---|---|---|---|
| appearance | `-2, +19` | `0` | 2/24 | 33/363 |
| memory | `-2, +19` | `0` | 2/24 | 37/363 |
| general-controls | `-2, +19` | `0` | 2/24 | 37/363 |
| extensions-manager | `-2, +19` | `-1, 0` | 2/24 | 49/363 |
| date-and-time | `-2, +19` | `0` | 2/24 | 37/363 |
| simpletext | `-1, +19` | `0` | 2/24 | 43/363 |
| finder | `+19` | `+20` | 0/22 | 0/341 |
| new-old-world | `-2, +19, +20` | `0` | 2/24 | 42/363 |

**Read the first two columns together and the claim is already visible in
sweep C's own store.** The machine puts a black frame row two rows ABOVE
the scene rect and another at `t+19`, on eight windows out of eight. Sweep
C's render put one black row at `t+0` and drew no `t+19` frame at all —
so the whole title band was two rows low and the content frame was
missing. Twenty-two of twenty-four rows disagreed on every window.

The widget columns are the same story from the other side: the three
boxes are 363 pixels and between 33 and 49 of them agreed, which is what
a widget drawn in the wrong place and (for `kind == 2`) not drawn at all
looks like.

**This is the number sweep D's captures have to beat**, and it is
recorded here before the after was taken.

## Measurements taken so far

Capture pass 1 was running when this checkpoint was written. See
"Targets reached" below.

## How I know these captures are steady-state, and where the warm-up went

Three things, and the first is the one the spec asks for by name:

- **`tools/fidelity-sweep.py` is the instrument, not
  `tools/local-pair-capture.py`.** It issues `qdtrace start` per target
  window with that window's address and PSN and aborts the row with
  status `arm-refused` if the arm does not take, so an unarmed row cannot
  reach the summary as an `ok` row. Checked in the artefact rather than
  in the intent: every `ok` row in `sweep-summary.json` carries a
  non-zero `records` count, and a drain cannot produce records without
  an arm.
- **The first row of the pass is a declared warm-up.** The planes arm as
  a result of the first `scene.request` on a connection, so `New Old
  World` was placed first deliberately and is captured again in pass 2
  from a warmed connection. Where the two disagree, pass 2 is the row.
- **Every target is fronted and then front/back-cycled with the drain
  pumping continuously** before its screendump, so the screendump and the
  drain describe a window that has just repainted, not one that has been
  sitting.

**Two things this rig cannot see, stated rather than left implied.** The
render pass draws every target in ONE process in list order, and the
`ImageRenderer` backing-store fix is not in this tree (see the regression
above) — so a per-target render difference of a few pixels is not
attributable to the target. And nothing here observes the guest while it
is undriven; see REST.

## The AFTER — claims 1, 2 and 3, per rectangle

`rects.py --sweep p1 --renders r1`, nine targets, this tree's guest and
this tree's render of the same instant.

| target | window kind | guest's black rows | render's black rows | rows agreeing | close | collapse | zoom |
|---|---|---|---|---|---|---|---|
| new-old-world | 8 | `-2, +19, +20` | `-2, +19, +20` | **24/24** | 121/121 | 121/121 | **1/121** |
| appearance | 2000 | `-2, +19` | `-2, +19` | 23/24 | 121/121 | 121/121 | 121/121 |
| date-and-time | 2 | `-2, +19` | `-2, +19` | **24/24** | 121/121 | 121/121 | 121/121 |
| memory | 2 | `-2, +19` | `-2, +19` | **24/24** | 121/121 | 121/121 | 121/121 |
| extensions-manager | 2 | `-2, +19` | `-2, +19` | **24/24** | 121/121 | 121/121 | **1/121** |
| general-controls | 2 | `-2, +19` | `-2, +19` | **24/24** | 121/121 | 121/121 | 121/121 |
| apple-system-profiler | 8 | `-1, +19` | `0, +19` | 19/24 | 121/121 | 121/121 | **1/121** |
| simpletext | 8 | `-1, +19` | `0, +19` | 21/24 | 121/121 | 121/121 | **1/121** |
| finder (`Macintosh HD`) | 20 | `-2, +19` | `-2, +19` | **24/24** | 121/121 | 121/121 | **1/121** |

### Claim 1 — title-bar widgets per window class: **CONFIRMED, and it is 100%**

**The close box and the collapse box are 121 of 121 pixels, on nine
windows out of nine, across five distinct window kinds** (2, 8, 20, 2000).
Sweep C's store, same instrument, same boxes: 33 to 49 of 363. The four
`kind == 2` control panels are the class that used to get no widgets at
all, and they are now among the exact ones.

### Claim 2 — `contentTop` 22 → 20: **CONFIRMED, and every window moved**

Six of nine windows now agree on **every one of the 24 sampled rows**,
where sweep C agreed on 2. The guest's `-2` outer frame and `+19` content
frame are reproduced exactly, which is the whole content of the claim:
the interior no longer sits two rows low.

The three that do not reach 24/24 are worth naming rather than rounding
away:

- **apple-system-profiler and simpletext, 19/24 and 21/24.** Both sit at
  `t = 20`, directly under a 20-pixel menu bar, so rows `t-2` and `t-1`
  fall *inside the menu bar*. The guest reports its black row at `-1` and
  the render puts it at `0`. **The residual is a one-row disagreement in
  the two rows the menu bar owns, and it appears only on windows flush to
  the top of the screen** — a real and small divergence, not the old
  two-pixel offset.
- **appearance, 23/24** — one row, and the band's known Chicago/Charcoal
  residual is in that band; not chased, per the brief.

### Claim 3 — the zoom box: **the absence is honest, and it costs five windows**

The zoom column splits perfectly and it splits on the line
`WindowChrome.zoomBox`'s own doc comment predicted:

- **121/121 on the four windows the machine draws no zoom box on**
  (Appearance, Date & Time, Memory, General Controls). The guest shows
  three colours in that box — plain title-bar band — and so does the
  render. Nothing invented. **This is the fix working.**
- **1/121 on the five windows the machine DOES draw one on** (NOW's own
  Workshop, Extensions Manager, Apple System Profiler, SimpleText, the
  Finder's `Macintosh HD`). The guest shows **nine** colours there, the
  render three. The render draws nothing where the machine drew a widget.

**So it is honest and it is not free.** Of the eleven windows the doc
comment reasoned about, this run's nine split 4/5 rather than 7/4 — a
majority of windows now MISS a widget they have, where before a minority
had one invented. Trading a fabricated affordance for a missing one is
the right trade and the report should not pretend the cost is zero. And
Extensions Manager (`kind == 2`, **with** a zoom box) beside Memory
(`kind == 2`, **without**) is reproduced here in pixels, so the reason
`kind` cannot stand in is now measured rather than argued.

## ✗ AND THE REGRESSION HAS A SECOND HALF: the render is ORDER-DEPENDENT ON REAL WINDOWS

The unmerged `ImageRenderer` fix is not an abstract debt. Posed directly:
render this sweep's nine captures **twice from identical input**, once in
list order and once with the list reversed, in two cold processes.

| target | pixels differing / 480,000 | worst channel | bbox of the difference |
|---|---|---|---|
| appearance | **338** | **65** | 202,296 – 569,592 |
| new-old-world | 19 | **157** | 163,96 – 757,592 |
| apple-system-profiler | 15 | **157** | 624,40 – 641,570 |
| finder | 5 | 65 | 62,152 – 589,592 |
| date-and-time, extensions-manager, general-controls, memory, simpletext | 0 | 0 | — |

Two renders of the same list in the same order are **byte-identical** for
all nine — which is why nobody has noticed. Change only the order and
**four of nine renders change**, by up to 338 pixels and by up to 157 of
255 in a channel.

The commit that fixes this measured *"eight pixels … one by 15/255"* on a
two-button fixture. **On this project's real windows it is 338 pixels and
157/255.** That is the size of the thing sitting on an unmerged branch,
and it is the reason no per-target render finding in this report is quoted
below a few pixels.

## Claim 5 — CDEF classification: **CONFIRMED, derived here, and the brief's numbers check out**

Classified means `semantic.kind` is non-null. Counted from the two
sweeps' own scene files, front window only:

| target | controls | refs | classified in C | classified in D | `pushButton` in C | `pushButton` in D |
|---|---|---|---|---|---|---|
| Memory | 44 | 44 | 33 | **23** | 10 | **0** |
| Date & Time | 21 | 21 | 19 | **10** | 10 | **1** |
| General Controls | 28 | 28 | 20 | **14** | 7 | **1** |
| Appearance | 73 | 73 | 71 | **61** | 16 | **6** |
| Extensions Manager | 6 | 6 | 6 | **3** | 3 | **0** |

Memory 33 → 23 of 44 and Date & Time 19 → 10 of 21 are exactly the numbers
the brief stated, re-derived rather than repeated. **Control totals and
reference totals are unchanged on every row** — nothing was lost; the
identical set of controls stopped being called push buttons. Scored as
the fix it is.

## Claim 6 — `controlsState`: **CONFIRMED, and it is answering in the field**

Not a code reading: three of the four words appear in this run's own
scenes.

- `empty` — the Finder's `Desktop` window, and one of Apple System
  Profiler's unopened dialogs. A proven zero.
- `notFetched` — **Date & Time's main window, in the Apple System
  Profiler scene**, carrying 0 controls while the same window carries 21
  in its own capture. That is the field earning its place: a walk that
  did not happen, said out loud, instead of an empty array that reads as
  "this window has no controls".
- absent beside a non-empty array — every other window, which rule 1 reads
  as `complete`.

## Targets reached / not reached

| Target | Captured | Scored | Note |
|---|---|---|---|
| New Old World (Workshop) | ✓ | ✓ | also the declared warm-up row |
| Appearance | ✓ | ✓ | |
| Date & Time | ✓ | ✓ | |
| Memory | ✓ | ✓ | |
| Extensions Manager | ✓ | ✓ | |
| General Controls | ✓ | ✓ | |
| **Apple System Profiler** | ✓ | ✓ | the rotated slot |
| SimpleText | ✓ | ✓ | |
| Finder — `Macintosh HD` folder | ✓ | ✓ | **not the Desktop**: `find_window` took the front Finder window and a folder window was open, so this row is not comparable with sweep C's Finder row |

## STABILITY — a column sweeps B and C both left as `–`, now measured

Method: **two full capture passes on one boot**, then each target compared
**inside its own window rect only**. The whole screen is not the unit —
the world behind a target legitimately differs between passes — and the
guest and the render are reported separately, because a difference in the
guest is the machine's and a difference the render has and the guest does
not is ours.

| target | guest, p1 vs p2 | render, r1 vs r2 |
|---|---|---|
| new-old-world | **0** / 373,500 | **0** |
| appearance | **0** / 155,044 | **1**, worst 22/255, at (453, 297) |
| memory | **0** / 113,600 | **0** |
| extensions-manager | **1,064** / 162,450, worst 221 | **0** |
| general-controls | **0** / 160,056 | **0** |
| apple-system-profiler | **0** / 337,960 | **0** |
| simpletext | 16 / 347,934, worst 255, at (8, 44)–(8, 59) | **16, the same 16** |
| finder | **0** / 97,680 | **0** |
| date-and-time | — | — (see below) |

Six of nine are **pixel-identical in both halves** across two independent
captures. That is a real result and it is the first time this project has
one.

Three rows carry information:

- **appearance: the guest is identical and the render differs by exactly
  ONE pixel.** Two captures of a window the machine drew identically,
  composed to two different pictures. This is the unmerged `ImageRenderer`
  fix again, and it is precisely the failure mode the spec's
  "per rectangle, never a whole-window score" rule exists for — a
  one-pixel difference in 155,044 is 99.9994% similar and completely
  invisible to any similarity score.
- **simpletext: the guest moved 16 pixels and the render moved the SAME
  16 pixels**, a 16-row column at x=8 flipping full-swing. That is the
  insertion caret blinking, and **the render tracked it exactly.** Scored
  as a pass, and worth recording because it is the only case in the run
  where the machine changed and the render followed.
- **extensions-manager: the guest moved 1,064 pixels and the two renders
  are byte-identical.** The machine's own list drew differently between
  the passes and the composed render did not change at all. That is the
  opposite of the appearance row and it is the more worrying direction:
  **a render that is stable while the machine is not is not showing
  something the machine did.** Not diagnosed here; posed as a finding.

**date-and-time has no stability row, and why is the finding.** In pass 2
the front `Date & Time` window is `Set Time Zone` at a different rect —
the modal left open by pass 1 (see "the guest's `quit` is not a quit").
So the two passes captured **two different windows under one label**, and
the instrument said so rather than diffing them. A contaminated row that
names its contamination is what sweep B's void was supposed to buy.

## Every target's pair, actually looked at

Nine of nine, side by side, `pairs/<label>-pair.png` (guest cropped to the
window on the left, the host's whole render on the right). What follows is
what is DIFFERENT, target by target — not a score.

### Claim 7 — the desktop names who answered: **CONFIRMED, and the answer is `assetPack`**

**The corner plate reads "desktop from asset pack, not this machine" on
every one of the nine renders.** So the mark works, it is legible, it does
not tint the desktop — and the fact it reports is that on this rig the
machine's own desktop answer never reached the scene. `scene.desktop` is
absent in all nine scene files, derived from the files rather than from
the picture.

**That is the claim working exactly as designed and it is also the
finding**: "an unmarked desktop means the machine named it" is now true,
and nothing in this run produced an unmarked desktop. A sweep on a rig
where the desktop DOES arrive is still owed.

### Apple System Profiler — the rotated target, and it earns the slot

The best-rendered interior in the run and the one with the most new
information. Text is essentially exact: every row of the Software /
Memory / Hardware overviews, the values, the alignment. 1,551 drain
records, 47 distinct strings — unlike SimpleText it records text.

What diverges, in the order a person would see it:

- **The six-tab strip is not drawn at all.** The scene carries the tab
  control (`role: tab`, `semantic.kind: tab`, value 1, min 1, max 6) and
  the machine draws six labelled tabs; the render draws a horizontal
  scroll bar across that band instead.
- **Twelve disclosure triangles are not drawn.** The scene carries all
  twelve as `semantic.kind: disclosureTriangle` with their values (three
  of them open), and the render draws none. **This is the slider-thumb
  defect in a new family: the data is present and the drawing is
  absent** — and `disclosureTriangle` is a control family no earlier
  sweep has reported at all.
- **The vertical scroll bar is drawn on the wrong side** — the machine
  puts it at the window's right edge, the render at its left.
- One line loses two characters: the machine draws `Printer overview`,
  the render draws `inter overview`.

And a state cell nobody has reached: **five invisible zero-area windows**
(`Preferences`, `Search options`, `Clipboard`, and two untitled) reported
with `visible: false`, `rect {0,-20,0,0}`, and **41 controls between them,
every one carrying a minted reference.** One of them carries a second tab
control at value 3 of 4. A caller reading `controls` without reading
`visible` would act on a window that is not on screen. The scene is
honest — `visible` is right there — but this is the first time the corpus
has contained the case.

### Extensions Manager — the list target

Rows, sizes, versions and package names are exact. What is missing:

- **The ⊠ marks in the On/Off column** — every row's mark, ~10 rows.
- **The disclosure triangle** beside `Control Panels`.
- **Every row's icon** renders as a grey plate.
- **The help "?" button is a blank plate** — sweep A, B, C and now D.
- The vertical scroll bar's top arrow is absent.

### Finder — `Macintosh HD`, and nine icons for nine

Text exact, including `10 items, 3.21 GB available` and all nine item
names. **All nine icons render as identical hatched plates.** The hatch is
legible as unknown at 32×32, which is what the spec asks of an unknown —
so this is an honest unknown rather than art wearing unknown's clothes,
and it is still nine icons of content lost. The zoom box the machine draws
on this window is absent (the 1/121 row above).

### Memory — R1 and R2 stay fixed, and the bare labels stay broken

No doubled drawing, no cap-height stroke on the static labels: **sweep C's
two confirmed fixes have not regressed.** Text exact throughout.

Absent: **every radio button's mark** (5), the check box's mark, all three
group-box frames, all three sidebar icons, the RAM-disk slider's thumb,
and the stepper arrows beside `513M`.

### Date & Time — and it still draws the marks Memory does not

**Check boxes and radio buttons DRAW here**, on the same build, in the same
run, where Memory's and General Controls' do not. So sweep C's finding #4
reproduces exactly — and the CDEF reclassification did not change it:
Date & Time is down to **one** `pushButton` and eleven `unknown` and its
marks still draw. **The classification is not what decides the mark**, and
the cause is still unknown.

Absent: the stepper arrows beside both fields; the help "?" plate.
Present and correct: five group boxes with their frames breaking cleanly
around their labels, including `Use a Network Time Serve`**`r`**.

### General Controls — five group boxes right, everything inside them bare

Group-box frames and titles exact. Absent: every check box and radio
mark, **both slider thumbs** (values present in the scene: Menu Blink 3
of 0–3, Insertion Point 2 of 1–3), all three preview pictures, the help
"?" plate.

### Appearance — the six tabs draw, the previews do not

Six tabs with outlines and the selected-tab join, exactly as sweep C
found. Unfixed from sweep C: the two theme thumbnails render as empty
rectangles, "Lime Horizon" losing its green entirely; the "?" is a blank
plate; the 64-byte text cap shows as `…in the following sect…` (marked
honestly with an ellipsis).

**And a fabricated affordance the zoom fix did not reach.** The machine
draws no grow box on Appearance. **The render draws one**, at the
bottom-right corner. `WindowChrome.growBox` still opens `guard win.kind
!= 2` and Appearance is `kind == 2000`, so it passes — the same
discriminator, in the same file, one function below the one that was
just corrected. This is the class of defect claim 3 was landed to remove,
surviving in the neighbouring function, **and it is now confirmed in
pixels rather than inferred from the source.**

**Scroll arrows are still at the wrong end** — confirmed twice this run,
in Appearance's horizontal bar and NOW's own sidebar: the machine groups
both arrows together, the render splits them one to each end. Sweep B's
finding, sweep C's finding, unfixed.

### SimpleText — and a correction to sweep C's row

An empty untitled document; guest and render agree on a blank page, a
caret and the title bar. **Sweep C reported "SimpleText still records no
text op at all (190 records, 0 distinct strings)" as a reproduction of a
defect. This run reproduces the numbers exactly — and the document is
EMPTY.** Zero text ops from a document with no text in it is a fact about
the fixture, not about the guest. That row needs a document with text in
it before it means anything, and no sweep has taken one.

### NOW's own Workshop

The most faithful interior in the run: the sidebar list, the module
titles and subtitles, the popup with its arrows, the three push buttons
with their bevels, `Compress on wire (PackBits)` **with its check mark**,
`Advanced Transport` **with its disclosure triangle**, the green
connection dot, the status line. Absent: most sidebar module icons render
as one generic plate. The zoom box the machine draws is absent; the grow
box is drawn and the machine draws one too.

## Axis 4 — the interactions, step by step

### SEQ-A, panel — five steps, and the fourth is the report's headline

Target: Appearance, opened through the anchor worker (the guest's own
`launch` refuses a `cdev`; see S4 below). Warm-up scenes discarded; plane
states after warm-up recorded: `structure active-current, semantics
active-current, content INACTIVE, interaction active-current`.

| step | what | act said | machine did | verdict | dispatch | settle |
|---|---|---|---|---|---|---|
| 1 | open the panel and anchor it | launched | rect `{167,70,631,400}`, **73 controls, 73 with refs** | **ok** | — | — |
| 2 | find the tab control | — | ref minted, `role: tab`, value 1, min 1, max 6 | **ok** | — | — |
| 3 | **switch the tab** | `Dispatch: dispatched-but-unconfirmed` | value **1 → 1**; strip **IDENTICAL (0 of 11,648 px)**; pane **IDENTICAL (0 of 120,960 px)** | **BROKE HERE** | **2,096 ms** | 21,719 ms |
| 4 | change a control on the new pane (the "?" button) | `act-not-taken: armed, and the application never called TrackControl` / `settlement: timed-out` | **Mac Help opened and ran a search** | **✗ FALSE NEGATIVE** | 5,705 ms | 15,806 ms |
| 5 | switch back | `element-not-found: no observation minted this reference, or it has expired` | value 1 → 1; first pane differs by 84,662 px (Help Viewer is over it) | **BROKE HERE** | 5 ms | 24,553 ms |

Four things this table says that sweep C's did not:

- **`ctlact part 0` has stopped claiming success.** Sweep C got
  `Dispatch: click posted` with no settlement row over a machine where
  nothing moved, and listed fixing that as its item 2. It now answers
  **`dispatched-but-unconfirmed`**, which is the honest word. **Landed.**
- **And it got 2.4× cheaper**: 5,067–5,078 ms in sweep C, **2,096 ms**
  here. Sweep C's S6 ("dispatch cost varies 100× between `ctlact` forms")
  is narrowed but not closed — `part 11` is still 5,705 ms.
- **The tab still does not switch.** Sweep C's item 3 is open on a newer
  tree: the press is accepted, the control's value does not move, and
  **zero pixels change in either the strip or the pane.** Sweep B switched
  this tab 1→4→1; C and D do not. Two sweeps running, unfixed.
- **Step 5 is new, and it is a drivability finding.** The tab's reference,
  minted at step 2 and used successfully at step 3, is
  `element-not-found` by step 5 — about 45 seconds and roughly forty
  intervening `scene.request`s later. The reference table holds 96
  entries and **every settlement poll mints a fresh set**, so *the
  instrument's own settlement loop evicts the reference it is about to
  act on.* Sweep C's step 5 dispatched; here it cannot. A five-step
  sequence cannot currently hold a reference across its own waiting.

### Reliability and latency, in separate columns

| operation | attempts to land | dispatch | settle |
|---|---|---|---|
| anchor `launch` of a control panel | 8/8 | — | ~10 s |
| guest `launch` of a `cdev` / `APPD` | **0/2, refused honestly** | ~5 ms | — |
| `front` | 1/1 | 6 ms | — |
| `ctlact` tab (`part 0` + point) | 1/1 accepted, **0/1 landed** | **2,096 ms** | 21.7 s (never settled) |
| `ctlact` (`part 11`) | **1/1 landed and was reported as not taken** | 5,705 ms | 15.8 s to `timed-out` |
| `ctlact` on an evicted reference | refused in **5 ms** | 5 ms | — |
| `scene.request` (full document) | ~120/120 | 20–900 ms | — |

## Rotated new target

**Apple System Profiler**, at
`Macintosh HD:System Folder:Apple Menu Items:Apple System Profiler`. No
earlier sweep has taken it (checked against all five earlier sweep
documents). It is also a target that could not be reached through the
guest's own `launch` verb at all — see below.

### The rotated target found a second thing: the guest's `quit` is not a quit

Posed by accident and then read carefully, which is worth stating plainly.

Pass 1 ran `--no-hygiene --quit-after`, so **no hygiene routine pressed
any button** — the whole mechanism sweep B and sweep C blamed for the
"Set Time Zone" contamination was switched off. The only act between
targets was `quit target=Date & Time` over the wire.

The Date & Time target's own scene has one window and no modal. **The very
next target's scene has two Date & Time windows, and the second is
`Set Time Zone`** — and it stayed up for the rest of the pass, appearing
in the general-controls, extensions-manager, simpletext, finder and
apple-system-profiler scenes and in the post-run health alert:

```
!! POST-RUN HEALTH: [{"app": "Date & Time", "title": "Set Time Zone", "kind": 2},
                     {"app": "Date & Time", "title": "Date & Time",   "kind": 2}]
```

So: **the app did not quit, and something opened its modal.** Sweep C
attributed this contamination to `Sweep._dismiss` pressing DITL item 2;
that explanation cannot cover this run, because `_dismiss` never ran.
The correction matters because it changes what needs fixing — fixing the
hygiene routine would not have prevented this.

Not chased further, and stated at the level the evidence supports: `quit`
on a `cdev` opened through the anchor left the process running with a
modal on screen, in a run with hygiene disabled.

### And it widens sweep C's S4 before it is even captured

Sweep C's S4 was *"`launch` still refuses control panels"*. Posed at this
guest directly:

```
launch Macintosh HD:System Folder:Apple Menu Items:Apple System Profiler
  -> launch-refused: not an application (type APPD)
launch Macintosh HD:System Folder:Control Panels:TCP/IP
  -> launch-refused: not an application (type cdev)
```

Two file types, not one, and the anchor worker opens both. **The refusal
is honest and specific — that half is a pass** — but the asymmetry is
wider than the sweep C row says, and `docs/command-parity.md` still
declares neither.

