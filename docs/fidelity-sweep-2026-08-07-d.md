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

## ✗ FIRST — a claim under test IS NOT IN THE TREE

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

## Targets reached / not reached

| Target | Captured | Scored | Note |
|---|---|---|---|
| — | — | — | capture pass 1 in flight |

## Rotated new target

**Apple System Profiler**, at
`Macintosh HD:System Folder:Apple Menu Items:Apple System Profiler`. No
earlier sweep has taken it (checked against all five earlier sweep
documents). It is also a target that could not be reached through the
guest's own `launch` verb at all — see below.

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

