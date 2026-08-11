<!-- now-doc-provenance: generated reviewed=false -->

# Fidelity sweep C, 2026-08-07 — the first sweep that DID rather than looked

**Status: SURVEY, run alone, no human co-drive.** The first sweep under
[version 3 of the specification](fidelity-sweep-spec.md), which this run
wrote before it ran, on Michelle's ask:

> maybe even expanded to start to include more interactions on top of the
> current sweep spec

It does not replace [sweep B](fidelity-sweep-2026-08-07-b.md) or
[sweep A](fidelity-sweep-2026-08-07-a.md); both are untouched, as are the
two 2026-08-06 sweeps. **The method changed in ways that make several rows
incomparable, and each says so on its own row.**

**The headline is not a score.** It is that the instrument built to answer
this arc's live-render question **cannot run**, because a verb on the
product's own agent surface closes the connection without replying — and
that failure has no reason attached, which is the one thing every refusal
in this tree has always had.

---

## WHICH RIG THIS DESCRIBES — read before quoting anything

| | |
|---|---|
| **Sweep tree** | `claude/019-sweep-c`, forked from `claude/019-integration-5` at **`33894275`** ("docs(open-issues): round 5's LOOK"). |
| **Guest build** | `113f1b176035 2026-08-07T16:36:09Z`, asserted by `--expect-build auto` on the capture pass and by `expect_build` on **every** phase-C wire connection. |
| **Base image** | `~/Lab/Assets/os91-qemu/os91-runner.qcow2`, sha256 `f34f7e5df64e09ced96c7968776692bb94d9639ee32a6f51652449e1a9cda776`. Plain base, never baked; `scripts/spin-up-ppc` clones it and stages **this checkout's** ext and app. The shared oracle `now-mirror-stage.qcow2` was **not used**. |
| **Resident** | guest's own `mirror` at boot: lifecycle `active`, capabilities `511`, sourceManifest `f41867cfe431`, buildFingerprint `4d0988e8e891` — the local build's own fingerprint, matched. `actselftest` → `abi-agreed`. |
| **Guest machine** | QEMU `mac99`, Mac OS 9.1, 800×600. Lane block **817** (`tools/lane-ports`): anchor **18536**, wire **18537**, run dir `/private/tmp/nowvm-swc`. |
| **Host app** | built from this tree into `/private/tmp/nowhost-swc`, and — unlike sweep B — **launched**, isolated with `NOW_PREFS_SUFFIX=swc` and `NOW_AGENT_SOCKET_SUFFIX=swc`. |
| **Who answered** | every capture and every phase-C connection asserted the build in the guest's own `hello`; the host's `session_health` re-reported the same build. No result here could have come from another session's VM. |
| **Left alone** | Michelle's stack (VM pid 13498, host 17303, ports 16728/16729) and another session's VM (pid 29147) were never dialled. |

### Artefacts

Out of git: `~/Lab/Assets/now-mirror-assets/sweep-2026-08-07-c/` — 47 MB,
88 files (capture pass, renders, pairs, every interaction sequence's JSON
and screendumps, the REST trace, every driver script, and the run's own
provenance). Manifest
`~/Lab/Assets/now-mirror-assets/sweep-2026-08-07-c.sha256`, itself sha256
**`d592f4d19cd716f1b5830533acbf7a6119713619f6dd74179618bb46e45ded81`**.
Copied out **before** any teardown.

### P3 was armed, and this run checked rather than assumed

The coordinator warned that a capture with the content plane unarmed is
void. **Verified directly**: `tools/fidelity-sweep.py` issues `qdtrace
start` per target window with the window address and PSN
(`tools/fidelity-sweep.py:220`) and aborts the row with status
`arm-refused` if the arm does not take. Every render sentence in this run
carries real content counts (Appearance: *"2177 new draw ops; 87 offscreen
worlds hooked at creation"*), which an unarmed capture cannot produce. The
void instrument is `tools/local-pair-capture.py` — zero occurrences of
`qdtrace` — **which this sweep did not use**.

---

## ✗ FIRST — the regression, because a regression outranks any seam

### R3. `mirror_read --intention snapshot` closes the connection without replying

Reproducible **3/3**, and again after shrinking the scene by closing three
windows. The host **survives** — it keeps serving. Every other intention
answers normally:

| intention | result |
|---|---|
| `status` | ✓ answers |
| `metrics` | ✓ answers (6 windows, 180 elements) |
| `find` | ✓ answers, with matches and freshness |
| **`snapshot`** | **connection closed, no reply, no error frame** |

Two things make this the most serious finding in the sweep.

**It silently disables `tools/fidelity-live.py` entirely.** That is the
instrument built specifically to measure the flicker a settled-capture
sweep cannot see, and the one sweep B was faulted for not running.
`Live.snapshot()` is the first thing it calls after its `[pre]` phase, so
the tool dies at `[pre]` every time with `the host closed the connection
without replying`. **The A-side live baseline therefore still has no B or C
side**, and the reason is a product defect, not a scheduling one.

**A refusal with no reason is the failure this project has spent the arc
preventing.** Sweep B closed by asking that the refusal vocabulary be left
alone, because every refusal it met *"said what happened and why"*. This
one says nothing at all — it is not even a refusal, it is a hang-up. Under
[version 3's four-way table](fidelity-sweep-spec.md) it is the bottom row
in its purest form.

---

## Michelle's two re-checks: both CONFIRMED FIXED

Evidence: `pairs/memory-pair.png` (guest left, render right), against
`p1/memory-guest.ppm` and `r1/memory.png`.

### R1 (sweep B) — Memory drawn twice — **FIXED**

The interior is readable and drawn once. "Disk Cache", "Select Hard Disk:",
"Macintosh HD", "Available for use on disk: 3803M", "Available built-in
memory: 512M" and the whole explanatory paragraph — *"Disk Cache size is
calculated when the computer starts up. The current estimated size is
8160K."* — each appear exactly once, with the `^1` placeholder now
**substituted** (`8160K`, not `^1K`).

**How it was fixed is visible in the scene**: every `role: static` control
in Memory now reports `title: ""`. The semantics plane stopped competing,
and the content plane — which has the substituted truth — won. That is
precisely the resolution sweep B recommended.

**Confirmed independently on General Controls**, where the effect is
sharper: the scene's control title is truncated to `"Check disk if computer
was shut"` and the render draws the **full** sentence *"Check disk if
computer was shut down improperly."* The content plane is demonstrably the
owner, and it has the better string.

### R2 (sweep B) — the cap-height stroke on every static label — **FIXED**

"Virtual Memory" draws as "Virtual Memory", not "Ⅱirtual Memory".
"Current Theme: Indigo Foam" is clean in Appearance. Zoomed against the
screendump, the glyph runs match. No target in this sweep shows the stroke.

### And nothing else regressed with them

| Round-5 claim | Verdict | Evidence |
|---|---|---|
| Memory readable | **✓** | above |
| Six Appearance tabs | **✓** | `pairs/appearance-pair.png` — Themes / Appearance / Fonts / Desktop / Sound / Options, tab outlines and the selected-tab join all present |
| The group boxes with the `r` | **✓** | `pairs/date-and-time-pair.png` — "Use a Network Time Serve**r**" complete; all five group boxes break their frames cleanly around their labels |
| Stacking right | **✓** | every pair shows the panel over NOW's Workshop, matching the guest |

**And one of sweep B's open defects is now fixed too, unremarked**: its
claim-3 finding that *"the machine draws a checkbox inside the 'Use a
Network Time Server' frame gap and the render omits it"* — the render now
**draws** that checkbox.

---

## The briefed bare-label regression — scored honestly, and the stated cause is WRONG

Michelle's brief said to expect Memory's six radios and its "Save contents
to disk" check box to draw as **bare labels**, "because the guest reports
them as the button *family* and the machine's own mark does not reach the
replay." Known, deliberate, visibly worse than the wrong Platinum pill.

**Confirmed, and worse than briefed**: it reproduces on **General
Controls** too — a target nobody had ever swept — where *seven* controls
lose their marks (two Desktop check boxes, three Documents radios, the
Check Disk check box, the Launcher check box).

**But the stated cause does not survive checking, and this is the useful
part of the row.** All three panels classify these controls **identically**:

| panel | control | role | semantic.kind | provenance | draws its mark? |
|---|---|---|---|---|---|
| Date & Time | "Set Daylight-Saving Time Automatically" | `button` | `pushButton` | `guest-cdef-resource` | **YES** |
| Date & Time | Menu Bar Clock "On"/"Off" | `button` | `pushButton` | `guest-cdef-resource` | **YES** |
| Memory | "Default setting" / "On" / "Off" | `button` | `pushButton` | `guest-cdef-resource` | **no** |
| General Controls | "Show Desktop when in background" | `button` | `pushButton` | `guest-cdef-resource` | **no** |

**Same classification, opposite outcome.** Date & Time renders proper check
boxes and a correctly-filled radio; Memory and General Controls render bare
text. So "the guest reports them as the button family" is true of all
three and therefore explains none of the difference. **Whatever decides
this sits downstream of classification, and it is still open.**

I formed a hypothesis and **falsified it**, which is worth recording so
nobody re-runs it: the renderer's own sentences name deferred ops
(`memory: renderer defers 14×poly`; `general-controls: renderer defers
28×rgn (bounds only)`; date-and-time defers nothing), which looked like the
answer. It is not. The deferred rectangles are elsewhere:

- Memory's 14 `poly` ops are all at `[326,90,334,94]` / `[326,96,334,100]`
  — 8×4 px. Those are the **popup and stepper arrow triangles**, and the
  render does indeed lose them.
- General Controls' 28 `rgn` ops are at `[248,19,308,71]`, `[248,69,308,121]`
  and `[53,144,104,193]` — exactly the scene's `Show Desktop Picture`,
  `Launcher Picture` and `Menu Blink` preview rects. The render loses those
  **pictures**, which it does.

So the deferral list explains the missing **arrows and preview pictures**,
not the bare labels. Two real defects found; the briefed one still
unexplained.

---

## Axis 4 — the interactions. Reported step by step, per version 3

Timing is per step: **attempts to land, time to dispatch, time to settle**,
separately, because sweep B's central number was that dispatch is cheap and
settlement is not.

### SEQ-B, browse — 4 of 5 steps clean, and it answers sweep B's open question

Target: Extensions Manager. `c/seq-B.json`, screendumps `c/B*.ppm`.

| step | what | act said | machine did | verdict | attempts | dispatch | settle |
|---|---|---|---|---|---|---|---|
| 1 | front, open its window | launched | rect `{150,51,622,391}`, 13 controls, 13 with refs | **ok** | 1 | — | — |
| 2 | find the scroll bar | — | ref minted, value 0, max 146 | **ok** | — | — | — |
| 3 | **scroll ×9 — did the CONTENT move?** | 9 dispatched | bar `0 → 80`; thumb **changed**; **content changed** | **ok** | 9/9 | 4517 ms | 537 ms |
| 4 | select a list row, read it back | `bad-request: this command requires element…` | row rect **IDENTICAL** | **REFUSED CLEANLY** | 1 | 4 ms | — |
| 5 | close it — did the one behind redraw? | `winact` dispatched, re-read | window gone; **Appearance behind it changed** | **ok** | 1 | 93 ms | 567 ms |

**Step 3 is the row version 3 was written for.** Sweep B scrolled and read
the *scroll bar's own value* back (`0 → 10 → 80`) and scored it a pass.
That is the thumb. This sweep checked the **list body rectangle** in the
guest's own pixels and it moved. **The scroll genuinely scrolls** — a
stronger claim than sweep B was able to make, and it costs one extra
screendump.

**Step 4 is a refusal, and therefore a pass** — but it carries a product
finding. `ctlact` by point requires an `element` reference *"minted by an
observation that saw the element"*, and Extensions Manager's list body has
none. Sweep B found this for the **Finder's** list; it is now confirmed for
a second list. **A list row cannot be selected by pointing at it**, on
either list, over the wire.

### SEQ-A, panel — broke at step 3, and the tab REGRESSED

Target: Appearance. `c/seq-A.json`.

| step | what | act said | machine did | verdict | dispatch | settle |
|---|---|---|---|---|---|---|
| 1 | open and anchor | launched | rect `{167,70,631,400}`, **73 controls, 73 with refs** | **ok** | — | — |
| 2 | find the tab control | — | `role: tab`, ref minted, value 1, min 1, max 6 | **ok** | — | — |
| 3 | **switch the tab** | `Dispatch: click posted` | value **1 → 1**; strip **IDENTICAL (0 of 11 648 px)**; pane **IDENTICAL (0 of 120 960 px)** | **BROKE HERE** | 5078 ms | 21 545 ms |
| 4 | change a control on the new pane | `act-not-taken: armed, and the application never called TrackControl` / `settlement: timed-out` | value 0 → 0; rect IDENTICAL | **REFUSED CLEANLY** | 5082 ms | 15 346 ms |
| 5 | switch back | `Dispatch: click posted` | value 1 → 1; first pane IDENTICAL | **ok, trivially** | 5067 ms | 24 068 ms |

**Comparability: this row is NOT comparable with sweep B's.** Sweep B
switched Appearance's tab `1 → 4 → 1` on its **addendum** build and scored
it ✓. Here the reference resolves, the control is found, `kNowAxResolveMaxControls`
is clearly at 96 (73/73 controls carry refs, matching sweep B's addendum),
the press is **accepted** — and **nothing moves at all, not one pixel of
the strip**.

**Step 3 is the four-way table's bottom row, with a caveat I will not
smooth over.** `Dispatch: click posted` is honestly a *dispatch* claim, not
a settlement claim, and step 4 proves the plane **can** report settlement
failure precisely when it detects one. So this is not a verb lying. It is
`ctlact part 0` (a raw point press) having **no settlement check at all**,
where `ctlact part 11` has one. **Two forms of the same verb, one
verified, one not** — a seam, and the reason a five-second press can report
"posted" over a machine that did nothing.

### SEQ-T, text — a seam, found by trying to type

`textset` and `textget` both refuse on Memory's edit fields:

> `not-text: that reference names a control, not a text element`

The scene reports those very controls as **`role: "edit"`**, three of them,
each with a minted reference. **The scene says `edit`; the act plane says
"not a text element".** Two producers disagreeing about what a thing *is*,
which is the seam class version 2 named first and nothing had yet caught in
this direction. Typing into a field and reading it back — version 3's
first-named state-changing interaction — **cannot be done on this panel at
all**, and the refusal is the only reason anybody would know.

### SEQ-R, refusals — and two of my own findings were instrument artefacts

Posed deliberately. **A refusal with a reason is a pass.**

| # | case posed | act said | machine | verdict |
|---|---|---|---|---|
| 1 | press a control whose position cannot be established (zero-width rect `{352,315,352,318}`, Memory) | `bad-request: that point is outside the control this reference names. Send a point inside its rect, in the same global coordinates the observation reported` | IDENTICAL | **✓** |
| 2 | press a point outside the control the ref names | same message | IDENTICAL | **✓** |
| 3 | act on a reference into a window **proven** gone | `element-not-found: the process this reference names is no longer running` | window gone: true | **✓** |
| 4 | `winact` on a window already closed | `act-not-armed: the target served the request and did not arm` / `dispatched-but-unconfirmed` | — | **✓** |
| 5 | drag with no trustworthy home (`dragpress` at a point owned by no window) | `bad-request: this command requires element: one opaque now-element- reference…` | still window IDENTICAL | **✓** |
| 6 | `dragmove` with no press outstanding | `bad-request: dragmove requires session, h and v: the nonce dragpress returned, and a global point` | — | **✓** |
| 7 | `ditemact` with a `now-window-` reference (sweep B's seam S5) | `bad-request: that is not a well-formed now-element- reference` | — | **✓ — S5 reproduced exactly** |

**Seven for seven, every one naming its reason.** The act plane's refusal
discipline is intact, and case 5's answer is a design statement worth
keeping: a drag cannot be posed by point at all, because `dragpress`
requires an element — **drags are element-anchored by construction**, so
"a drag with no trustworthy home" is unreachable by design rather than
unguarded.

**Two cases needed re-posing, and both first-pass results were my
instrument, not the product.** Recording them because version 3 says an
instrument blind spot is a finding:

- **The first pass scored case 5 a `✗ FALSE NEGATIVE`** — refused, yet the
  rectangle "changed". The rectangle was **Date & Time's window, which
  contains a running clock**, and 2.5 s elapsed between screendumps. The
  instrument produced the finding. Re-posed against Memory — a still window
  — it is a clean ✓. This is `instrument-feeds-the-clock` in a new costume,
  and it would have shipped as a defect.
- **The first pass scored case 3 a `✗ CLAIMED SUCCESS`.** Its precondition
  had failed: the close meant to make the reference stale answered
  `dispatched-but-unconfirmed`, so the window never left the scene and the
  reference was never stale — acting on a live object successfully is
  correct. Re-posed with the precondition **checked** (`window gone: True`
  proven from the scene), the act refuses properly.

**Both corrections came from re-posing, not from inspection.** A sweep that
had reported its first pass would have filed two defects that do not exist.

### Reliability and latency, in separate columns

| operation | attempts to land | dispatch | settle |
|---|---|---|---|
| `scene.request` (wire, full document) | 1/1, ~90 scenes | 20–900 ms | — |
| `ctlact` scroll (`part: 23`) ×9 | 9/9 | 4517 ms total (~500 ms each) | 537 ms |
| `ctlact` tab (`part: 0` + point) | 1/1 accepted, **0/1 landed** | 5067–5078 ms | 21.5–24.1 s (never settled) |
| `ctlact` (`part: 11`) | refused honestly | 5082 ms | 15.3 s to `timed-out` |
| `winact close` | 1/1 | 93–238 ms | 567 ms |
| `front` | 1/1 | 2–211 ms | — |
| `menuact`-class refusals | 7/7 | 3–996 ms | — |
| anchor-worker `launch` | 5/5 | ~10 s settle | — |
| wire `launch` of a control panel | **0/5** — `launch-refused: not an application (type APPC)` | 2 ms | — |

**Sweep B's split holds and has widened.** Reads answer in tens to
hundreds of milliseconds; anything that must settle against the machine
costs **5–24 s**. Every `ctlact` on a point took **just over 5 seconds to
dispatch** — that is not settlement, that is the *dispatch* itself, and it
is an order of magnitude worse than the 90–106 ms sweep B measured for
`part: 23` scroll presses. The 9-press scroll run at ~500 ms each sits in
between. **Dispatch cost now varies by two orders of magnitude between
`ctlact` forms**, which nothing has characterised.

---

## REST — does an undriven Mirror decay? **Not at the document level, in 120 s**

The measurement version 3 adds, and the one no continuously-driving
instrument can take. `rest/rest.json`; 14 samples over 120 s with
**nothing** fronted, cycled or acted on — a deliberate violation of the
spec's own front-or-cycle rule, which is the point.

| | first | last |
|---|---|---|
| windows | 6 | 6 |
| entities matched | 17 | 17 |
| freshness | **all 17 `fresh`** | **all 17 `fresh`** |
| `sceneGeneration` | 2 | **5** |
| `contentGeneration` | **2** | **2** |
| `baseComplete` | false | false |
| `sequence` | 243 | 285 |

**Verdict: no decay in the STRUCTURE.** Nothing went stale, no window
vanished, no entity lost freshness, and the host kept walking (sequence
+42, `walk: full`, `outcome: ok`, 180 elements every cycle) the whole time
unprompted.

### How I know this ran against an arming host — and what that does NOT cover

`fidelity-live.py` and `mirror-corpus` both read the live host, which arms
P3 itself. **Neither tool CHECKS that it did**, so a run against a host
that never armed would report every window stably empty and read as a
stability result, with nothing in the run saying which. This measurement
came through that path, so it owes the evidence rather than the assumption.

**The evidence: `contentGeneration` was non-zero and observed to
increment.** It read `1` on the first status after `mirror_open`, `2` by
the metrics read minutes later, and `2` for all 14 REST samples. A host
that never armed content would have no generations to count. Together with
`walk: full` / `outcome: ok` on every cycle, that is positive evidence the
host was arming and draining.

**But it does not carry the weight I first put on it, and this is the
important correction.** `contentGeneration` frozen at **2** for the whole
120 s, while `sceneGeneration` advanced **2 → 5**, is equally consistent
with two opposite readings:

- **the content is stable** — nothing changed, so nothing regenerated; or
- **the content stopped arming** — renewal lapsed and the structure kept
  going without it.

**My instrument cannot separate those, and they are opposite
conclusions.** So "no decay" is sound for the structure and **unproven for
the content** — which is precisely the half the decay question is about. I
should not have written the flat verdict.

The asymmetry itself remains the thing worth handing on: if a renderer
composites a fresh scene against a content generation that never renews, an
interior could degrade while the frame around it stays current — the
*shape* of what Michelle described (group boxes lost, the date field a
stipple, labels truncated mid-word, chrome intact). **Offered to
`claude/019-interior-decay` as a baseline observation, not a mechanism.**

**Three limits, stated rather than assumed.** This reads the host's
published snapshot **metadata**, not drawn pixels, so a decay visible only
in pixels is invisible to it. It is a **substitute measurement**: the right
instrument is `fidelity-live.py --idle`, which could not run for the reason
in R3 above, so **`snapshotsMissed` does not exist for this run** — no
flicker number does. And **the VM is now down and the lane reclaimed**, so
none of this can be re-measured without a fresh boot.

**A gap worth closing before sweep D**: `fidelity-live.py` and
`mirror-corpus` should **assert** that content is arming — a
`contentGeneration` of 0, or one that never advances across a provoked
redraw, should fail the run rather than read as stability. That is the same
rule as `requireTheBuildUnderTest()`, applied to the plane instead of the
build.

---

## Hatching, attributed to its instrument — re-derived, and it moved

**A retraction first, because the provenance matters more than the
numbers.** An earlier revision of this document reported this section as
**"16 STANDS · 3 ARTEFACT · 2 UNATTRIBUTABLE"**. That count came from a
delegated agent and **I published it without verifying it**. It is
withdrawn. What follows I derived myself, from the artefact stores on disk
and from the source, and every claim below names the evidence that
produces it.

The count is withdrawn rather than replaced, because the honest unit here
is **the store, not the observation**: a store either could or could not
have carried an interior, and that is checkable. Counting individual
sentences across five documents is what produced an unverifiable number
the first time.

### The discriminator I used first was unsound

`<label>-guest.ppm` is written by **both** tools — `fidelity-sweep.py:293`
**and** `local-pair-capture.py:217`. The `.ppm` shape separates nothing.
The discriminators that hold, verified in the source:

| signature | written by | line |
|---|---|---|
| `manifest.json` | **pair capture only** | `local-pair-capture.py:236` |
| `<slug>-guest.png` | **pair capture only** | `local-pair-capture.py:219` |
| `sweep-summary.json`, `LIMITS.md` | **sweep only** | `fidelity-sweep.py:587,589` |
| `<label>.json` (the drain) | **sweep only** | — pair capture never writes one |

### And arming was necessary but not sufficient

`SceneBuilder.normalizeWindows` sets **`display: nil` unconditionally**
(`now-host/Packages/MirrorKit/Sources/MirrorKit/SceneBuilder.swift:285` — the
sole occurrence of `display` in that function, with no branch). **No scene
envelope from any capture has ever carried content ops.** The interior
arrives only on a *second* artifact, the `qdtrace` drain.

So the question "was P3 armed" is the wrong one to ask of a stored
capture. The answerable question is **"did this capture write a drain"** —
and if it did not, the interior was never on disk, whatever the guest was
doing.

### What the stores actually are

| store | `manifest.json` | `-guest.png` | drains (`<label>.json`) | verdict |
|---|:-:|:-:|:-:|---|
| `019-integration` (**round 2**) | 1 | 6 | **0** | **PAIR CAPTURE** |
| `019-integration-3` (**round 3**) | 1 | 6 | **0** | **PAIR CAPTURE** |
| `sweep-2026-08-07-a` | 0 | 0 | present (`p2/*/*.json`) | **SWEEP** |
| `sweep-2026-08-07-b` | 0 | 3 (`b_*`, hand-made crops) | present (`p1/*.json`, 747 KB+) | **SWEEP** |
| `sweep-2026-08-07-c` (this one) | 0 | 0 | present (`p1/*.json`) | **SWEEP** |

Both integration stores contain **only** `<slug>-scene.json` and
`manifest.json`. **Zero drains.** Round 3's own method note confirms the
path independently: *"host render via `MirrorApp --render-scene` over the
same envelope"* — and the envelope is exactly the artifact that carries
`display: nil`.

**So rounds 2 and 3 rendered from a document that structurally cannot hold
an interior.** Every empty-interior and missing-chrome observation in those
two rounds is an instrument artefact, by construction, independent of
anything the guest or the renderer was doing.

### What moved: the retroactive correction

**Four of round 3's six rows already self-declared it** — that round says
plainly *"four of the six 'unchanged' verdicts are one unarmed plane
rather than four defects."* Those need no retraction and they are to its
credit.

**The row that did not self-declare is the one that moved.** Round 3's
Date & Time row — *"Still **no group boxes at all**… Text fields are empty
grey slabs"* — was attributed to a **different, semantic** cause: the
controls *"arrive with correct rects and correct titles and no kind, so
there is nothing to draw them as."* It was listed as a separate finding
from the four content rows, and that explanation then propagated as
durable prose in four places:

- `docs/open-issues.md:228` — *"This is why the panel has had no group
  boxes, no static text and no field values in **both** rounds"*
- `docs/open-issues.md:631` — *"**This is also why Date & Time renders with
  no group boxes.**"*
- `docs/open-issues.md:1123` — *"**Date & Time has no group boxes.**… render
  as nothing at all"*
- `docs/render-composition.md:299` — *"which is why that panel has had no
  group boxes **in any sweep**"*

**Sweep C renders Date & Time's five group boxes correctly**, with frames
breaking cleanly around their labels, its check boxes and radios drawn, and
its text fields carrying values (`pairs/date-and-time-pair.png`). So the
appearance is gone.

**But this sweep cannot say which cause was the real one, and neither
could round 3.** Two things changed between them: the drain arrived, *and*
the semantic tie-break was fixed (`semanticOutranks`, replacing the broken
`knowledge == .known` test — `render-composition.md:295`). My capture has
both. The coordinator's mutation control is the experiment that
discriminates: on a tree whose renderer draws the panel correctly,
disabling one arm reproduces round 3's LOOK almost exactly — armed 3917
drain records across 9 op families, control **0** — **and it lands as the
quiet hatch, not "Bitmap unavailable"**.

So the precise correction is **not** "the semantic defect was fake". That
defect has independent evidence — a named code path, a broken comparison,
and a fix. It is that **the pixel evidence offered for it could not have
falsified it.** A render taken over an envelope with `display: nil` shows
no group boxes whatever the semantics do, so citing those renders as
*"in both rounds"* and *"in any sweep"* is an inference the artifact cannot
support. **Those four sentences should be corrected to cite the code path
and the mutation control, not the round-2/3 renders.**

### The premise inversion, verified rather than inferred

There are *three* hatches, and I checked each string myself:

- **"Guest content not reported"** — `SceneRenderer.swift:814`. Whole
  interior. **This is the one an absent drain produces**, and it is what
  the mutation control emitted.
- **"Bitmap unavailable"** — `DisplayReplay.swift:835`. Per rectangle,
  inside the *display replay*. Since `display: nil` guarantees display ops
  reach the renderer **only** via a drain, `DisplayReplay` cannot run
  without one. **So this caption is positive proof the capture had a
  drain.**
- **"Visual unavailable"** — `SceneRenderer.swift:1920/1941`. The semantic
  plane, drain-independent entirely.

**Sweep A's most dramatic result — the Finder's whole interior as one
hatch — STANDS**: sweep A is a sweep, it has drains, and its mechanism was
independently re-derived and fixed.

The coordinator reports the signature held under a controlled experiment
rather than as an inference, which is a stronger footing than this sweep
could give it alone.

**One documentation defect found, of the class AGENTS.md warns about**:
sweep B's standing-checks table asserts *"no 'Bitmap unavailable' hatch
anywhere in this sweep"* while its own free-text callouts report Monitors'
*"interior a hatch"*. A two-place enumeration disagreeing with itself.
**Sweep B is not edited** — recorded here, forward.

---

## The standing checks

Read as **agreement with the guest's own pixels**, never as expected
appearance. Zero is a pass when the machine has zero.

| Check | Verdict | Evidence |
|---|---|---|
| A scrollbar scrolls — **content, not just the thumb** | **✓** | SEQ-B.3; list body rectangle moved in the guest's own pixels |
| A tab switches — **pane, not just the strip** | **✗** | SEQ-A.3; press accepted, 0 pixels moved anywhere |
| A list row selects | **✗ / unreachable** | SEQ-B.4; the list body carries no reference, on a second list |
| A menu item lands where named | **not taken** | out of time; sweep B's ✓ is the most recent word |
| ~~a press at a menu of unknown position is refused~~ | **struck** | no reachable case (sweep B); replaced by refusals 1 and 2, which pose the property properly and pass |
| An interaction SEQUENCE completes or names its step | **✓ (instrument)** | every sequence here names its step |
| A refusal names its reason | **✓ 7/7 acts · ✗ 1 agent verb** | refusals table; `mirror_read snapshot` names nothing |
| An act that landed is never reported refused | **✓** | no false negative survived re-posing |
| A window opens, closes, one behind redraws | **✓** | SEQ-B.5, both halves proven in pixels |
| Fronting a process — window list **answered** | **✓** | `front` answered 5/5; `empty` read as a pass |
| The desktop shows its icons | **✓ (content)** | Finder capture: 151 records, 20 distinct strings, 19 text + 19 blits |
| Text is what the machine drew | **✓, with one cap** | R1/R2 fixed; but control titles cap at 31 chars — see S3 |
| Icons resolve to art, unknowns legible | **✗** | Memory's 3 sidebar icons, General Controls' 3 previews, Appearance's 2 theme thumbnails all absent or blank |
| No hatching where the machine drew | **✓** | no hatch in any of eight targets |
| Panel faces are the guest's grey | **✓** | all eight |
| Window stacking matches the guest | **✓** | every pair |
| **The Mirror opens from the agent verb** | **✓** | `mirror_open` → *"The Mirror is running on Power Mac G4, on the Mirror page."* **Sweep B could not take this check** |
| The Mirror opens from menu / guest's button | **not taken** | no UI driving available to this run |
| An act that cannot verify its effect says so | **✓ and ✗** | `act-not-taken`/`timed-out` is exemplary; but `ctlact part 0` has no settlement check at all |

---

## The seams

### S1. Two forms of one verb, one verified and one not
`ctlact part 11` reports `act-not-taken: armed, and the application never
called TrackControl` with `settlement: timed-out`. `ctlact part 0` reports
`Dispatch: click posted` and **nothing else** — no settlement row — over a
machine on which zero pixels changed. Same verb, same reference, opposite
epistemics.

### S2. The scene says `edit`; the act plane says "not a text element"
Memory's three `role: "edit"` controls, each with a minted reference,
refuse both `textget` and `textset` with `not-text`. Two producers, one
object, incompatible answers.

### S3. Control titles are capped at 31 characters and the record claims completeness
`kNowSceneCtlTitleMax = 32` (`now-guest-ppc/src/scene/scene.h:185`) —
31 chars plus NUL — while `kNowSceneDialogTitleMax = 160`. So the scene
carries `"Menus (opening menus, choosing "`, `"Double-click title bar to colla"`,
`"Check disk if computer was shut"` — and each of those records still says
`semantic.completeness: "complete"`. Sweep B found the 64-byte **text**
cap, which the render marks honestly with an ellipsis; **this one is
unmarked and asserts the opposite.** A caller matching a control by title
cannot match anything longer than 31 characters and has nothing telling it
so.

### S4. `launch` still refuses control panels — sweep B's S4, unchanged
`launch-refused: not an application (type APPC)`, 5/5. The anchor worker
opens the identical HFS path without complaint. **A person at the guest's
console cannot open a control panel; the rig can.** Still undeclared in
`docs/command-parity.md`.

### S5. `ditemact` still cannot be reached with the reference the scene hands you
Reproduced verbatim: `that is not a well-formed now-element- reference`.

### S6. Dispatch cost varies 100× between `ctlact` forms
`part: 23` presses cost ~500 ms each; `part: 0` presses cost **just over
5 s each**, three times, consistently. Nothing declares this.

---

## The scores

Eight targets, rendered onto their own scenes through the app's composition
path, judged against the screendump of the same instant.

| # | Target | T | P | C | R | Ch | **STAB** | **DRIVE** | **INTER** | comparable with B? |
|---|---|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|---|
| 1 | Appearance (6 tabs) | **3** | 3 | 2 | 1 | 3 | – | 3 | **0** | **no** — B's tab switched; T rose 2→3 (R2 fixed) |
| 2 | Date & Time | 3 | 3 | **3** | 2 | 3 | – | 2 | – | partly — C rose on the fixed checkbox |
| 3 | Memory | **3** | 3 | 1 | 1 | 3 | – | 1 | – | **no** — R1/R2 fixed; T 0→3, R 0→1 |
| 4 | **General Controls** (new) | 3 | 3 | 1 | 1 | **3** | – | 2 | – | **no** — never swept |
| 5 | Extensions Manager | 3 | 3 | 2 | 1 | 3 | – | 2 | **2** | yes |
| 6 | SimpleText + document | 3 | 3 | 2 | 3 | 2 | – | 1 | – | yes |
| 7 | Finder — desktop | 1 | 2 | – | 1 | 3 | – | 0 | – | partly |
| 8 | NOW's own Workshop | 3 | 3 | 2 | 3 | 3 | – | 2 | – | yes |

**STABILITY is `–` for every row, as in sweep B, and for the same declared
reason**: the budget went to interactions instead. Not re-measured.

**INTERACTION is scored only where a sequence was run** — Appearance 0 (the
sequence broke at step 3 and nothing changed on the machine), Extensions
Manager 2 (four of five steps, the fifth a clean refusal). It is a new
column; no row is comparable with anything.

**General Controls is the rotated new-target slot** and it earned it: five
group boxes with correct titles and frames, two sliders whose values are in
the scene, three preview pictures, seven check boxes and radios, and 28/28
controls carrying references. It is also where the bare-label defect was
independently reproduced and where the deferred-`rgn` picture loss is
cleanest.

### Free-text callouts, per the mandatory field

- **Scroll arrows are still at the wrong END.** The machine puts both
  together (OS 9 smart scrolling); the render splits them one to each end.
  Visible in Appearance's horizontal bar. **Sweep B's finding, unfixed.**
- **The help "?" button is a blank plate** in Appearance, Date & Time and
  General Controls — three for three. Sweep B said three for three, sweep A
  five for five. **Unfixed across three sweeps.**
- **Theme preview thumbnails are lost.** Appearance's two rich previews
  render as empty rectangles with only their labels; "Lime Horizon" also
  loses its green entirely and renders white, while "Indigo Foam" keeps its
  tint and selection highlight. A content loss *and* a colour divergence in
  one rectangle.
- **Slider thumbs are not drawn** in General Controls, though the scene
  carries the values (`Menu Blink Slider` v=3 of 0–3; `Insertion Point
  Slider` v=2 of 1–3). **The data is present and the drawing is absent** —
  the cleanest attributable defect in the sweep.
- **Stepper arrows are not drawn** beside Date & Time's date and time
  fields, or Memory's.
- **The 64-byte text cap still shows** — "…in the following sect…" — and
  still cannot be distinguished downstream from a truncation the machine
  itself made.
- **SimpleText still records no text op at all** (190 records, 0 distinct
  strings), reproducing sweep B exactly. Not chased.
- **The sweep tool's hygiene is still unfixed** and this run routed around
  it: `Sweep._dismiss` still presses DITL items 2 then 1 on any window of
  kind 1–3, which is what opened "Set Time Zone…" in sweep B. This sweep ran
  `--no-hygiene --quit-after`, cleaning up by **asking each app to quit**
  rather than by pressing a guessed button. **This is a method change and it
  is not sweep A's mistake** — A ran with no cleanup at all; this ran with a
  cleanup that cannot act on the panel's own controls. Version 3 now
  requires it.

---

## State cells: visited, and the ones that could not be reached

| Cell | Reached | Note |
|---|---|---|
| Front | ✓ | all eight targets |
| Behind | ✓ | NOW's Workshop behind every panel; Appearance behind Extensions Manager |
| **Undriven / at rest, past the lease** | **✓ (new)** | 120 s, nothing touched — see REST |
| A control at its minimum / maximum | ✓ / ✓ | Extensions Manager's bar at 0, driven to 80 of 146 |
| A full / scrolling list | ✓ | Extensions Manager, ~150 rows |
| A window closing, with one behind | ✓ | SEQ-B.5, both halves in pixels |
| A stale reference | ✓ | refusal 3, precondition proven |
| A degenerate-rect control | ✓ | refusal 1, Memory's `{352,315,352,318}` |
| A tab on a non-front pane | ✗ | the tab never switched |
| A modal over a window | ✗ | not posed; the run went to interactions instead |
| An empty list | ✗ | no empty-list target set up |
| A very long / high-MacRoman / empty filename | ✗ | not set up — same gap as sweep B |
| Resized to truncate a label | ✗ | not taken this run |
| Two windows of one process overlapping | ✗ | not taken this run |

---

## What should be fixed before sweep D

In order, by what a person would notice first.

1. **`mirror_read --intention snapshot` must answer or refuse.** It closes
   the connection with no reply and no reason, it is on the product's own
   agent surface, and it silently disables `tools/fidelity-live.py` — so
   the arc's live-render question still has only an A side. **This is the
   one thing whose absence blocked a measurement this sweep was asked for.**
2. **Give `ctlact part 0` a settlement check.** `part 11` already has one
   and its refusal text is exemplary. A five-second press that reports
   "click posted" over a machine where nothing moved is the exact failure
   the act plane was rebuilt to prevent, arriving through the one form
   nobody verified.
3. **Find why Appearance's tab stopped switching.** Sweep B switched it
   1→4→1 on an equivalent build with 73/73 refs; here the press is accepted
   and zero pixels move. Between the two sweeps this went from working to
   silently not.
4. **Decide what draws a check box's mark.** Date & Time draws them, Memory
   and General Controls do not, on *identical* classification — so the
   briefed "reported as the button family" explanation is not the cause and
   the real one is unknown.
5. **Mark truncated control titles, or raise the cap.** 31 characters,
   `completeness: "complete"`, no flag. The text plane already models this
   honestly with `trunc`/`fullLen`; controls should too.
6. **Draw the values the scene already carries** — slider thumbs above all,
   where the value is present and only the drawing is missing.
7. **Make `role: edit` and the act plane agree**, or say why an `edit`
   control is not a text element.
8. **Correct the four sentences that cite round-2/3 renders as evidence for
   the `kind: null` group-box defect** (`open-issues.md:228`, `:631`,
   `:1123`, `render-composition.md:299`). The defect has independent
   evidence; those renders are not it, because they were taken over an
   envelope that carries `display: nil`.
9. **Make the live-reading instruments assert that content is arming.**
   `fidelity-live.py` and `mirror-corpus` both depend on the host arming
   P3 and neither checks, so an unarmed host reads as a stability result.
10. **Fix the sweep tool's hygiene** (still open from sweep B), or make
    `--no-hygiene --quit-after` the documented default now that version 3
    requires a cleanup that cannot act.
11. **`launch` should serve control panels**, or the asymmetry should
    finally be declared in `docs/command-parity.md`. Sweep B asked;
    nothing moved.

And two things that should be **left alone**:

- **The act plane's refusal vocabulary.** Seven for seven, each naming its
  reason precisely enough to argue with, and two of this report's findings
  exist *because* a refusal was specific. `element-not-found: the process
  this reference names is no longer running` and `dragmove requires
  session, h and v: the nonce dragpress returned` are the standard the rest
  of the surface should be held to — including R3.
- **The content plane winning over the DITL title.** It fixed R1, and
  General Controls proves it is also the *better* string: the content plane
  has "Check disk if computer was shut down improperly." where the scene's
  title has 31 characters of it.
