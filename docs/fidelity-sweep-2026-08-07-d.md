# Fidelity sweep D, 2026-08-07 — scoring the composed result of rounds 6 and 7

**Verification level: TESTED on an emulated guest, with the build
asserted on every connection. Nothing here is metal-verified, and no
sentence in this document says anything "works".**

Sweep C (`docs/fidelity-sweep-2026-08-07-c.md`) is the previous word;
nothing here edits it. Two of its rows are **corrected** by this run and
both corrections are argued in place: its account of the "Set Time Zone"
contamination, and its scoring of `act-not-taken` as an unambiguous
clean refusal.

## The short version

- **A false negative on an act that landed.** `ctlact part 11` reported
  `act-not-taken … settlement: timed-out` over a press that opened Mac
  Help and ran a search. Proven in the guest's own pixels, before and
  after.
- **One of the seven claims under test is not in the tree**, and its
  absence is priced here on real windows rather than on a fixture.
- **The two big chrome claims are confirmed and quantified**: close and
  collapse boxes at 121/121 pixels on nine windows out of nine, and six
  of nine windows agreeing on all 24 sampled title-band rows where sweep
  C's store agrees on 2.
- **The zoom box's honest absence costs five of nine windows a widget the
  machine draws** — measured, and split exactly on the line the code's own
  doc comment predicted.
- **STABILITY is scored for the first time.** Six of nine targets are
  pixel-identical in both the guest and the render across two independent
  captures.
- **Two things landed and should be left alone**: `ctlact part 0`'s
  `dispatched-but-unconfirmed`, and `controlsState`.

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
| **Guest build** | `d9a78b62a414 2026-08-07T20:08:53Z`, from the guest's own `hello`, asserted by `--expect-build auto` on both capture passes and by `expect_build` on every phase-C connection. `scripts/build-guests` green for all six targets first. |
| **Base image sha256** | `c466baa9a5455c343908e12197d68e57ffc7f07c140276a90c97a5ae2a137d70`, checked **after** the run — the same bytes `base-fitness.json` names, so nobody baked over the shared oracle during this sweep. **The image was never written to**: `spin-up-ppc` clones it and stages this checkout's ext and app into the clone. |
| **Resident** | staged from this tree: sourceManifest `ad1b8d35302e`, buildFingerprint `1247f064b341`. `actselftest` → `abi-agreed`, by a real `MenuSelect` inside the target process. The base image's own resident **predates** the six 6-August extension commits, and is not what was under test. |
| **Guest machine** | QEMU `mac99`, Mac OS 9.1, 800×600. Run dir `/private/tmp/nowvm-swd`. |
| **Host app** | **not launched.** Renders were taken by `LiveShapedRenderTests` composing each drain onto its own captured scene, which is the app's composition path; nothing in this run used the agent socket. |
| **Who answered** | every capture and every interaction connection asserted the build in the guest's own `hello`. No result here could have come from another session's VM. |
| **Artefacts** | `~/Lab/Assets/now-mirror-assets/sweep-2026-08-07-d/` — 53 MB, 139 files (both capture passes, four render passes, the pairs, every driver script, every sequence's JSON and screendumps, the rectangle instrument and its output for **both** this sweep and sweep C, and the run's own provenance). Manifest `sweep-2026-08-07-d.sha256`, itself sha256 **`314265006aa2ba765928261727820acbb68e2f322884277f765ad9f0fdb870cc`**. Copied out **before** teardown. |

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
  owns it. **Mail was NOT opened this sweep**, so this report adds no
  evidence about it; sweep A's account is still the most recent.
  <br>**But an equivalent wedge happened anyway and it is worth reading
  across.** Date & Time's `Set Time Zone` modal was left open by target 3
  and stayed up for the rest of both passes. What a modal nobody can
  dismiss actually cost, measured rather than imagined:
  - it **voided the Date & Time stability row**, because pass 2 fronted
    the modal and the two passes captured different windows under one
    label;
  - it **contaminated five later targets**' scenes with two extra
    windows, which the tool declared but which no score can subtract;
  - and it **blocked the clean-shutdown route**: `shutdown-guest.py`
    reported *"Date & Time is still front; shutting down over it"* and had
    to fall back from the Finder route — the one route measured to leave
    a clean volume — to the staged applet, which the tool's own text calls
    "a fallback, not a plan". **An undismissable modal reaches all the way
    to whether the next clone boots into Disk First Aid.**
- **One interior at a time** is the built behaviour; a screenshot with one
  live interior and the rest hatched is not a defect. **Consistent with
  what was seen**: no render in either pass carried a whole-interior
  "Guest content not reported" hatch, and background windows were drawn
  from their semantics rather than hatched.

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
(`now-host/Packages/MirrorKit/Sources/MirrorKitUI/SceneView.swift:64-68`) still
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

### SEQ-R, refusals — five clean, one unposeable, one needing a re-pose

Posed against Date & Time, whose front window at the time was the
`Set Time Zone` modal (10 controls, 10 with refs).

| # | case posed | act said | verdict |
|---|---|---|---|
| 1 | press a control whose position cannot be established | — | **could not be posed**: this window has no degenerate-rect control. Sweeps A and B found the `{0,-21,0,0}` and `16xxx` families elsewhere; the case needs a named target rather than "whatever is front" |
| 2 | press a point outside the control the ref names | `bad-request: that point is outside the control this reference names. Send a point inside its rect, in the same global coordinates the observation reported` — 377 ms; window IDENTICAL | **✓** |
| 3 | act on a reference into a window just closed | **`ok`** — 1,491 ms | **needs re-posing, see below** |
| 4 | `winact close` on the window just closed | `act-not-armed: the target served the request and did not arm` — 1,295 ms | **✓** |
| 5 | `dragpress` at a point owned by no window | `bad-request: dragpress requires element or window: one opaque reference minted by an observation` — 100 ms | **✓ refusal, but the case is UNPOSEABLE — see below** |
| 6 | `dragmove` with no press outstanding | `bad-request: dragmove requires session, h and v: the nonce dragpress returned, and a global point` — 612 ms | **✓** |
| 7 | `ditemact` with a `now-window-` reference (sweep B's S5) | `bad-request: that is not a well-formed now-element- reference` — 191 ms | **✓ — S5 reproduced a third time** |

**Case 3 is reported as unproven, not as a defect, and the distinction is
the point.** `ctlact part 11` answered `ok` on a reference into a window
the sequence had just asked to close — but the precondition was never
established: Date & Time has two windows, so "is a Date & Time window
still in the scene" cannot tell you whether *that* window closed, and
nothing looked at the machine afterwards. The evidence leans one way —
case 4's `winact` on the same reference refused, which is what a closed
window should produce — and it is not enough. **A case whose precondition
is not proven cannot score a defect**, and sweep C's own case 3 shows the
standard: it proved `window gone: true` first.

**Case 5 is unposeable, and the harness that judged it has a defect of its
own.** `dragpress` refuses for a missing `element`/`window` argument
*before* the point is ever considered, so "a drag whose start cannot be
attributed to a rectangle" has no reachable case through this verb —
**the same shape as sweep B's struck menu check**, and it should be
recorded the same way. Meanwhile the harness scored it a false negative
because 8,592 pixels changed in the window rect during the 2.5 s
observation. **That window is the Date & Time panel and it contains a
running clock.** The movement detector cannot tell a drag from a second
passing, and sweep C ran the same detector against the same panel. That
is an instrument finding, and it is why this report's one real false
negative (SEQ-A step 4) is argued from a whole-screen screendump showing
an application that was not running before, rather than from a pixel
count.

## The standing checks

Take each where the target affords it.

| Check | Verdict | Evidence |
|---|---|---|
| A scrollbar scrolls — content, not just the thumb | **not taken** | budget went to the two capture passes; sweep C's ✓ (SEQ-B.3) is the most recent word |
| A tab switches — **pane, not just the strip** | **✗** | SEQ-A.3: value 1→1, strip 0 of 11,648 px, pane 0 of 120,960 px. Sweep C's ✗, unfixed |
| A list row selects | **not taken** | |
| A menu item lands where it was named | **not taken** | sweep B's ✓ is the most recent word |
| ~~a press at a menu of unknown position is refused~~ | **struck** (sweep B) | and this run adds a second unposeable case, SEQ-R.5 |
| An interaction SEQUENCE completes, or names the step it broke at | **✓ (instrument)** | SEQ-A names step 3 and step 5 |
| **A refusal names its reason** | **✓ 5/5 reachable cases** | SEQ-R; every message is specific enough to argue with |
| **An act that landed is never reported refused** | **✗** | **SEQ-A step 4 — the headline. `act-not-taken` + `timed-out` over an act that opened Mac Help** |
| A window opens, closes, and the one behind redraws | **partial** | windows opened and closed all run; the redraw half was not isolated |
| Fronting a process makes it OBSERVABLE | **✓** | `front` answered 8/8; `controlsState: empty` read as a pass, `notFetched` as a fact about us |
| The desktop shows its icons | **✗ (this rig)** | `scene.desktop` absent in all 18 scene files; the corner plate says so on every render |
| Text is what the machine drew | **✓, with the two known caps** | nine targets; 31-char control titles and the 64-byte text cap both still present, the second marked honestly |
| An icon renders what the machine drew | **✗** | Finder 9/9 plates, Extensions Manager every row, most of NOW's own sidebar. Legible as unknown, which is the honest half |
| No hatching where the machine drew | **✓ apart from the icons** | no whole-interior "Guest content not reported" caption anywhere in eighteen renders |
| Panel faces are the guest's grey | **✓** | all nine |
| Window stacking matches the guest | **✓** | every pair |
| The Mirror opens from the menu item / agent verb / guest's button | **not taken** | no host app was run this sweep |
| An act that cannot verify its effect says so | **✓ and ✗** | `ctlact part 0` now says `dispatched-but-unconfirmed` — landed, and exemplary. `ctlact part 11` says `act-not-taken` over an act that landed |

## The seams

- **S-D1. `act-not-taken` is one mechanism's evidence worn as a
  conclusion.** The headline. `ctlact part 11` watches for `TrackControl`
  and reports the machine's state from its absence.
- **S-D2. The settlement loop evicts the reference it is waiting on.**
  96 reference slots, and every `scene.request` mints a fresh set, so
  polling for settlement destroys the thing you are about to act on.
  SEQ-A step 5.
- **S-D3. Two producers of one window's control list disagree across
  scenes.** Date & Time's panel carries 21 controls in its own capture,
  `controlsState: notFetched` with 0 in a later one, and `dialogItems`
  present in some scenes and absent in others for the same window. The
  `notFetched` word makes the first honest; nothing explains the second.
- **S-D4. `WindowChrome` uses two different discriminators for one
  question.** `hasTitleBar` was corrected off `kind != 2`; `growBox` was
  not, and it fabricates a grow box on Appearance.
- **S-D5. `launch` refuses `cdev` AND `APPD`; the anchor opens both.**
  Sweep C's S4, wider, still undeclared in `docs/command-parity.md`.
- **S-D6. `quit` on a control panel neither quit it nor left it alone.**
  See the rotated-target section.
- **S-D7. A window the render is stable across and the machine is not.**
  Extensions Manager, 1,064 guest pixels to 0 render pixels.

## The scores

Nine targets, rendered onto their own scenes through the app's composition
path, judged against the screendump of the same instant. 0–3.

| # | Target | T | P | C | R | Ch | **STAB** | **DRIVE** | **INTER** | comparable with C? |
|---|---|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|---|
| 1 | Appearance (6 tabs) | 3 | 3 | 2 | 1 | **3** | **3** | 3 | **0** | **no** — Ch rose on the chrome fix; STAB is new |
| 2 | Date & Time | 3 | 3 | 3 | 2 | **3** | **n/a** | 2 | – | **no** — Ch rose; STAB voided by contamination |
| 3 | Memory | 3 | 3 | 1 | 1 | **3** | **3** | 1 | – | **no** — Ch rose |
| 4 | General Controls | 3 | 3 | 1 | 1 | **3** | **3** | 2 | – | **no** — Ch rose |
| 5 | Extensions Manager | 3 | 3 | 2 | 1 | **2** | **1** | – | – | **no** — Ch is 2 not 3: the machine's zoom box is not drawn |
| 6 | SimpleText | 3 | 3 | – | 3 | **2** | **3** | 1 | – | **no** — Ch 2 for the missing zoom box |
| 7 | **Apple System Profiler** (new) | **3** | 3 | **1** | 2 | **2** | **3** | 2 | – | never swept |
| 8 | Finder — `Macintosh HD` | 3 | 3 | 2 | **0** | **2** | **3** | 1 | – | **no** — different window from C's `Desktop` |
| 9 | NOW's own Workshop | 3 | 3 | 3 | 2 | **2** | **3** | 2 | – | **no** — Ch 2 for the missing zoom box |

**CHROME moved for two opposite reasons at once and the column would lie
if it did not say so.** Every window's title-bar band, close box, collapse
box and content frame went from disagreeing on 22 of 24 rows to agreeing
on all of them — that is a large rise. And five of nine windows lost a
widget the machine draws. So the four control panels score **3** (their
chrome is now exact, zoom included, because they have none) and the five
windows with a real zoom box score **2**.

**STABILITY is a real column for the first time.** `3` means
pixel-identical in both the guest and the render across two independent
captures; Appearance is `3` on the guest and carries the one-pixel render
difference in its callout; Extensions Manager is `1` because the guest
moved 1,064 pixels and the render did not move at all; Date & Time is
`n/a` because the two passes captured different windows.

**REGIONS is 0 for the Finder row**: nine of nine icons are hatched
plates. It is an honest unknown and it is still the whole of the content.

### Free-text callouts, per the mandatory field

- **The help "?" button is a blank plate** in Appearance, Date & Time,
  General Controls and Extensions Manager — **four for four, and four
  sweeps running.** It is also the button SEQ-A pressed, which means the
  one control this sweep proved is actuatable-but-misreported is also the
  one nobody can see.
- **Check-box and radio marks: Date & Time draws them, Memory and General
  Controls do not**, on one build in one run. The CDEF reclassification
  did not change it (Date & Time is down to one `pushButton`), so sweep
  C's conclusion stands: the briefed explanation is not the cause.
- **Slider thumbs are still not drawn** — General Controls' two, Memory's
  one — with the values present in the scene.
- **Disclosure triangles are not drawn** in Apple System Profiler (12 of
  them, values present, three open) but ARE drawn in NOW's own Workshop.
  A new family, and it is not uniformly missing.
- **Stepper arrows are still not drawn** beside Date & Time's and
  Memory's fields.
- **Scroll arrows are still at the wrong end** — the machine groups both
  at one end, the render splits them. Seen twice: Appearance's horizontal
  bar, NOW's own sidebar. Sweep B's finding, third sweep unfixed.
- **Theme preview thumbnails still lost**, "Lime Horizon" still losing
  its green. Sweep C's finding, unfixed.
- **Icons**: every Finder item, every Extensions Manager row, most of
  NOW's own sidebar. All render as one generic or hatched plate.
- **The 64-byte text cap still shows**, still marked honestly with an
  ellipsis.
- **A fabricated grow box on Appearance** — new this sweep, in pixels.
- **No hatching anywhere except the icon plates.** No whole-interior
  "Guest content not reported" caption in any of the nine renders, which
  is the caption an absent drain produces — so no capture in this run was
  taken over an envelope alone.

## State cells: visited, and the ones that could not be reached

| Cell | Reached | Note |
|---|---|---|
| Front | ✓ | all nine |
| Behind | ✓ | NOW's Workshop behind every panel; up to six background windows by the last target |
| **Two windows of ONE process, both visible** | **✓ (new)** | Date & Time's panel + `Set Time Zone`; sweep C could not reach this |
| **An INVISIBLE window with a full control walk** | **✓ (new)** | Apple System Profiler's five, 41 controls, all with refs |
| **A modal over a window** | **✓ (new, unintended)** | `Set Time Zone` over the Date & Time panel, from target 3 onward |
| A control at min / max | ✓ / ✗ | scroll bars at 0 and at 17,880 present in ASP's scene; none driven to max this run |
| A full / scrolling list | ✓ | Extensions Manager, ~10 visible rows of many |
| An empty list | ✓ | SimpleText's empty document; the Finder `Desktop` window with `controlsState: empty` |
| A stale / evicted reference | **✓** | SEQ-A step 5, proven by the successful use of the same ref two steps earlier |
| A degenerate-rect control | ✗ | not posed — the front Date & Time window in the refusal pass was the modal, which has none |
| A tab on a non-front pane | ✗ | the tab never switched |
| Resized, or narrow enough to truncate a label | ✗ | not taken |
| A very long / high-MacRoman / empty filename | ✗ | not set up — the same gap as sweeps B and C |
| **Undriven, past the lease (REST)** | ✗ | **not taken this run** — see below |

**REST was not measured and that is a gap, not a result.** Sweep C's REST
row depended on the host app being up with its agent socket; this run put
its budget into two capture passes and the interaction axis instead.
Sweep C's finding — no decay at the document level in 120 s, with the
explicit caveat that it read metadata and not pixels — remains the most
recent word.

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

---

## What should be fixed before sweep E — the pain points, to steer work in flight

In order of what a person pays for first.

1. **`ctlact part 11` must stop concluding from `TrackControl` alone.**
   It reported `act-not-taken … settlement: timed-out` over a press that
   opened Mac Help. `dispatched-but-unconfirmed` already exists in the
   same verb's other form and is the honest word for exactly this. **This
   is the one finding that fires a round on its own**, because an agent
   that believes a refusal will press again, and the second press lands
   too.
2. **Merge `claude/019-first-render-differs`, or say why not.** It is the
   only claim in the brief that is not in the tree, and this run priced
   its absence on real windows: reordering the render list changes four of
   nine renders, by up to 338 pixels and 157/255 in a channel, and it
   produces a **one-pixel** difference between two renders of an
   identically-drawn Appearance window — the exact error class the spec
   says no similarity score can see.
3. **Fix `WindowChrome.growBox`'s discriminator.** It is `guard win.kind
   != 2`, one function below the `hasTitleBar` that was just corrected off
   the same test, and it draws a grow box on Appearance that the machine
   does not draw. Small, mechanical, and the same defect class the zoom
   fix was landed to remove.
4. **Carry the zoom flag in the contract.** The absence is honest and it
   costs five of nine windows a widget the machine draws. `spareFlag` is
   the zoom flag and it sits beside the `windowKind` the walk already
   reads. Until it lands, "the render is exact on chrome" is only true of
   windows without a zoom box.
5. **Find why Appearance's tab does not switch.** Two sweeps now: press
   accepted, value unmoved, zero pixels in the strip and zero in the pane.
   Sweep B switched it. It is sweep C's item 3, unmoved.
6. **Make a reference survive its own settlement wait.** 96 slots, and
   every poll mints a fresh set. Either the settlement loop should not
   mint, or a reference in use should not be evictable.
7. **Draw the values the scene already carries** — slider thumbs, stepper
   arrows, and now **disclosure triangles**, twelve of which Apple System
   Profiler reports with their state and none of which are drawn. Sweep
   C's item 6 with a new family attached.
8. **Decide what draws a check box's mark.** Sweep C's item 4, reproduced
   exactly, and now with the CDEF reclassification ruled out as the cause
   by measurement rather than argument.
9. **Draw Apple System Profiler's tab strip, and put its scroll bar on the
   right.** The rotated target's two structural losses.
10. **The help "?" button has been a blank plate in four consecutive
    sweeps** and is now also the control that proved finding 1. It has
    outlived "we'll get to it".
11. **`quit` on a control panel should quit it or refuse.** In this run it
    did neither, and it left a modal that voided a stability row. Sweep
    C's attribution of that contamination to the hygiene routine is
    wrong; fixing the hygiene routine would not have prevented it.
12. **`launch` should serve `cdev` and `APPD`, or the asymmetry should be
    declared in `docs/command-parity.md`.** Asked by sweep B, asked by
    sweep C, wider than either said.
13. **Fix the sequence harness's movement detector** before another sweep
    quotes it: it cannot tell a drag from a clock tick, and it scored a
    false negative against a panel that displays the time.

### And two things to leave alone

- **`ctlact part 0`'s new answer.** `dispatched-but-unconfirmed` is
  exactly right, it replaced the worst epistemics in the surface, and it
  came with a 2.4× dispatch improvement. It is also the word finding 1
  asks `part 11` to adopt.
- **`controlsState`.** Three of its four words appeared in the field
  within one run, and `notFetched` did the job it was added for — it
  turned "this window has no controls" into "nobody walked it" on a
  window that has 21.

---

## Where the method changed, so nobody quotes a row as comparable

- **The before is measured, not remembered.** `rects.py` was run over
  sweep C's published store as well as this run's, so the chrome rows are
  a measured delta. No earlier sweep did this.
- **Two capture passes on one boot**, and STABILITY is scored per target
  **inside its own window rect** rather than over the screen. Sweeps B and
  C left the column blank; its rows here are comparable with nothing.
- **The renders were taken three times** — twice in list order (identical)
  and once reversed — so the render-order artefact is subtracted rather
  than assumed away.
- **The Finder row is `Macintosh HD`, not `Desktop`.** A folder window was
  open and `find_window` takes the front one. Not comparable with sweep
  C's Finder row.
- **CHROME is not comparable with sweep C on any row**, in both
  directions at once: the band and widgets became exact, and five windows
  lost their zoom box.
- **REST was not measured.** Sweep C's remains the most recent word.
- **No host app was run**, so every check that needs the agent socket or
  the Mirror's own UI is "not taken" rather than ✗.

