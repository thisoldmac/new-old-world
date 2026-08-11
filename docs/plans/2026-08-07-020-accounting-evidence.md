<!-- now-doc-provenance: generated reviewed=false -->

# Slice-by-slice verification against the tree — raw findings

**2026-08-07. Five verification sub-agents, dispatched by the coordinator,
each reading `docs/plans/2026-08-06-018-feat-stable-honest-render-plan.md`
against the working tree rather than against any lane's report.**

This file exists because these five reports arrived in a coordinator
context that then compacted. **An agent's report is not a durable
artifact** — the rule this arc committed (`6fe8e213`) — and five reports
sitting in one session's head is the precise shape of the thing that rule
forbids. This is the "written into docs" disposition for all five.

It is deliberately RAW. The consolidated accounting
(`2026-08-07-020-accounting.md`) is the derived, dispositioned document;
this is its evidence, kept separate so a disagreement between them can be
adjudicated rather than argued.

**Method, and its limit.** Each agent was asked, per slice: (a) does the
implementing code exist, (b) is there test coverage, (c) what is deferred
or TODO. They grep and read; **a "not found" here is weaker evidence than
a "found", and one of them is already suspect** (see the slice 8 note).

---

## Slice 0, 1, 2 — LANDED, tested

All three fully implemented with mutation-tested coverage and no
deferrals. Notable: the shape-matching route for offscreen worlds was
kept as a **documented engineering decision** — `LockPixels` relocates
the PixMap *record*, so pointer identity fails — rather than quietly
skipped.

## Slice 7 — LANDED as a separate tool, and NOT RUN

Implemented as `tools/fidelity-live.py` rather than as an extension of
`fidelity-sweep.py`. **Sweep B did not run it**, and says so in its own
report at line 390. So the A-side flicker baseline exists (2,099 frames,
four traces, 122 flicker events all one `process-visibility` oscillation
at 3.28 s median, `baseComplete` false in every frame, **zero rect owner
flips**) and the post-fix comparison was never taken.

An instrument was built to answer a question, and the sweep meant to
answer it used the older instrument that could not. Sent to Sweep C.

## Slice 3 — DIAGNOSED ONLY, deferred (not fixed)

No `dBoxProc` / movable-modal / `WDEF` / Notification Manager handling
anywhere in `now-guest-ppc/src/scene/*`.
`docs/raising-the-unknown-creator-modal.md` is a **rig procedure**, and
says so ("not a product feature"). No test coverage.

`docs/open-issues.md:14582` states the honest position: on that rig **no
Finder window entered the scene at all**, so the modal was not a special
case and **nothing about its window class was measured**.

The Mail half turned out to be a different, already-resolved problem —
"not dismissible" is **REFUTED** (dismisses via `dialogItem` in 7.6 s);
the real defects were a missing title causing a false `open "Mail"`
timeout, and contradictory button titles between the control walk and the
dialog-item walk, which fed slice 4.

## Slice 4 — LANDED, tested

`now_scene_title_is_publishable()` (rejects control bytes/DEL; an
unpublishable title is **omitted**, never shipped as raw bytes) and
`now_scene_rect_is_sane()` / `sanitize_rect()` (`kNowSceneCoordSane =
4096`, clamping the `l=16555` address-as-short defect). Host-side
`displayableTitle` retained as defence in depth. Tests:
`scene_title_test.c`, `scene_build_test.c`, `scene_walk_test.c`.

The NOW-68K asymmetry is **declared**, not merely absent —
`docs/contract-coverage.md:185`: it has gained none of this and cannot,
because it serves no scene at all.

## Slice 5 — PARTIAL; two gaps priced, one closed by another route

- **Tab art: confirmed not extractable.** No tab bitmap anywhere in
  `Apple platinum`. Subsequently **fixed by a different route** —
  procedural `DrawThemeTab` parameter capture (slice 11), which is the
  fallback the plan anticipated.
- **Charcoal NFNT strike: confirmed absent, and STILL OPEN.** Charcoal
  ships TrueType-only; `Charcoal.ttf` carries no `bdat`/`bloc`. Closing
  it needs a TrueType rasteriser **or an explicit decision to keep
  substituting and say so** — and *that decision has not been made*.
  We are still substituting Chicago and mis-measuring width.

## Slice 9 — PARTIAL, and NOT what the slice specified

Guest-side `GetTheme` / `kThemeDesktopPatternTag` **is** implemented
(`desktop_theme.c:215,321`) and the contract **has** a `desktop` gestalt
verb (`asyncapi.yaml:3774`). But git history shows both landed *before*
slice 9 was written (`1257c425`, `7b3415d2`, 2026-08-06 22:16/22:26) as a
standalone diagnostic.

**Nothing consumes it.** `hasPattern` / `patternCarried` /
`patternBytes` / `kThemeDesktopPatternTag` return **zero matches** across
`now-host` and `mirror`. The renderer's `DesktopPattern`
(`BitmapFont.swift:271+`) reads **only the offline asset-pack
manifest** — true solely for a guest booted from that stage image and
unchanged since. The code says so itself at `BitmapFont.swift:266-270`.

So: ppat-16 tiling is gone, replaced by the manifest route, not by the
live verb. **Slice 9 as specified is not landed.**

## Slice 6 — DELIVERED, format deliberately superseded

`docs/fidelity-sweep-2026-08-07-b.md` (458 lines) exists, leads with
`## ✗ FIRST — two regressions, because a regression outranks any seam`,
and carries a nine-target scores table with a `comparable with A?`
column.

The plan's original "three-level verification status stamped per claim"
is **absent** — but slice 17 explicitly supersedes slice 6 and changes
how it is run, so this is a **declared** divergence, not a silent one.

## Slice 16 — DELIVERED, with a documented correction

`docs/open-issues.md:1004` records the first watch of the integrated
render. **Six defects, not five** — and one is the inverse of how it has
since been paraphrased: the render showed the sidebar text **in full**
("Capture and stream") where the machine truncated it ("Capture and
stre…"). It is over-correction, and the entry calls it a fidelity
divergence *because it looks like an improvement*.

`d117c976` records that two of those were **misdiagnosed**: the grey
plates were already rung 4 drawn to specification (merely invisible at
32×32), and the frame-through-label was Chicago standing in for
Charcoal.

Also recorded there: this entry was itself **gutted by a keep-both
merge** — newer heading kept, older body dropped — and restored. "A
heading is not the entry."

## Slice 17 — DELIVERED

`docs/arc-coordination.md` (321 lines): the two cadences, computed
triggers, the stop rule.

## Slice 18 — LANDED, and wired into the live walk

`control_cdef.h` documents the route and the measurement that forced it:
`GetControlKind` is **Mac OS X only** (`Controls.h:2310`), and
`GetControlData(kControlKindTag)` answered **2 of 73** for Appearance and
**0 of 21** for Date & Time. `cdef_resolver.c` uses `GetResInfo` against
`contrlDefProc` with variant-byte disambiguation, and is called from
`scene_walk.c:220` — not standalone.

## Slice 11 — LANDED, with the parameter source narrower than specified

`DrawnTabStrip.swift` (300 lines) + `PlatinumTab.swift` (174) implement
the procedure host-side, and `PlatinumTabTests.swift` covers it.

**But the parameters are derived from the guest's own captured drawing
stream, not queried live.** `GetThemeMetric` appears only in comments as
the future replacement for hardcoded Universal Interfaces defaults;
**there is no `GetThemeMetric` call on the guest side at all.** The live
query remains deferred to plan 016 P2, which was amended for it
(`39bb7c05`).

Its regression (front tab inverted into diagonals) is recorded and
**FIXED** — root cause was `rehome`'s offscreen-world origin assumption,
a `NewGWorld` rect-in-window-coordinates double count, not the tab logic.
Emulator-capture-verified, **not metal-verified**.

## Slice 12 — LANDED, with one check deliberately warn-not-refuse

Source-digest (`ext-bake-gate check`) **is** enforced from
`.githooks/pre-commit`. The image-sha-vs-receipt check (`verify-image`)
**is not**, by design: without `--require` it returns 0 even on mismatch,
and the code says why — *"Refusing here would strand correct work for a
reason its author cannot act on."* `--require` exists and is exercised
only in `tools/image-discipline-tests:178`.

Per-agent throwaway bake is the default; `--shared` is the deliberate act
and is refused while other guests run. `ext/stage-receipts.json` conflicts
on purpose via a merge driver that prints its resolution procedure.

## Slice 13 — LANDED, tested

`proc_roster.c` is the single classification point and reads
`modeOnlyBackground` **nowhere else in the guest**. Three states are
genuinely distinct: headless-by-declaration (suppressed to no error), a
UI app with **no windows open** (`kNowSceneAnchorNoWindows`, not an
error), and a real acquisition failure.

The App Switcher derivation route was proposed and **rejected the same
day** — the Application Switcher is itself a faceless process reporting
`ax_oracle_not_found`, so reading it to classify processes is
self-referentially broken. Hook the source, not the menu.

`f030d741` records the retraction of the "independent corroboration"
claim: it was the same bit measured twice.

## Slice 14 — PARTIAL; cap raised, lazy delivery never started

`kNowSceneWalkMaxControls = kNowSceneMaxControls`, and
`kNowSceneMaxControls = 96` (was 48) — clears the 73-control Appearance
chain. A dropped control plane now reports **chain length**.

**Lazy delivery does not exist.** No `notFetched`, no generation stamp
for controls, no contract field — no code, no tests, nothing.

And the re-measurement that would have sized the pool **did not happen**,
for an honest reason: on that rig the anchor plane failed before the cap
was ever reached (Appearance reported zero windows), so raising it could
not be observed to matter. `e21d3bea`: *"one measured panel is not a
distribution."*

## Slice 15 — DOES NOT EXIST

No `Slice 15` heading anywhere in the plan. Numbering skips it.

## Slice 8 — LANDED scene-side; act-side claim UNRESOLVED

`walk_verdict` with eight values splits *our* bound
(`kNowSceneWalkControlsBound`) from *the machine being unreadable*
(`Invalid`) from *cyclic, no cap raise reaches it* (`Cyclic`), serialised
onto the wire and covered by two tests including a mutation
(`a_cycle_is_not_a_long_chain`).

**Open discrepancy.** That agent reports finding no
verification-of-effect logic on the act-dispatch side. Lane D reported
adding `kNowActPostMenuMark` confirmation and four named refusals. One of
those is wrong, and it is more likely a search that did not reach it than
a claim that did not survive — but **it is not settled here**, and the
consolidated accounting must adjudicate it against the tree rather than
against either report.

## Slice 10 — LANDED intra-guest; never dragged at a Finder item

Three verbs, of which **only `dragpress` is an act request**;
`dragrelease` "reports that it ASKED, never that it released". Dead-man
idle/cap deadlines clamped by the resident. Shared pure-logic state
machine with its own test, plus `tools/local-drag-vehicle.py` as a live
emulator probe.

Cross-machine **file** drag is explicitly held for its own plan — "an
arc, not a slice" — and confirmed absent.

`DragGrayRgn` is **still unmeasured**.

## Slice 10.5 — BUILT COMPLETE, never reached a guest

All five contract points found with line numbers: immediate visual drag
before confirmation; provisional styling as `UnknownVisual`'s **sibling**
sharing its lattice cell ("rung 4's sibling, and the same decision made
twice"); snap-back on release-before-confirm; snap-back on refusal; and
**refuse rather than guess** when home is not trustworthy
(`guard picked.item.homeIsTrustworthy`). Three test files, 593 lines.

`SceneRenderer.swift:182`: *"Nothing PROMOTES a provisional drag to this
on its own."*

**No live probe exercises it.** Code exists, render-tested, unverified
live — exactly as the handoff claims.

## Slice 10.6 — LANDED, NO TESTS

`LiveMirror.cursor(for:)` returns `.iBeam` only for
`semanticKind == "editText"`, `.arrow` everywhere else — the scope
Michelle set.

It **reuses the hit tester rather than paralleling it**:
`ObjectResolver.object(at:in:)` calls the same `HitTester.hitTest` the
gestures call, with a comment saying a second implementation "would drift
the day after it was written."

**No test coverage found at all.** A landed capability with nothing
pinning it.

Mirroring the guest's own cursor (43 extracted `CURS` resources are
already in the pack) needs a capture-side verb and a contract field and
is correctly its own slice.

---

## What this pass changes about the arc's shape

Four items move from "believed landed" to something else, and none of
them were caught by reading reports:

1. **Slice 9 is not landed** — the live verb exists and nothing reads it.
2. **Slice 14 is half** — the cap moved, lazy delivery was never begun,
   and the sizing measurement is blocked behind the anchor plane.
3. **Slice 7's instrument was never run**, so the flicker question the
   arc posed is still open.
4. **Slice 10.6 has no tests.**

Plus one **unresolved contradiction** (slice 8, act-side) and one
**undecided decision** (slice 5, Charcoal: rasterise or declare the
substitution).
