---
title: A stable render with honest gaps - Plan
type: feat
date: 2026-08-06
---

# A stable render with honest gaps — Plan

Successor to [015](2026-08-06-015-feat-live-composition-plan.md) (live
composition, landed) and sibling to
[016](2026-08-06-016-feat-platinum-from-the-source-plan.md) (chrome
fidelity, not started). Subordinate to
[001](2026-08-03-001-now-mirror-ux-completion-plan.md).

## The decision this plan implements

Michelle, 2026-08-06 evening, after driving the live app:

> stable with honest gaps at this stage, with a caveat. trying to get
> things (a) green enough to be genuinely usable, even with some edge
> case limitations and (b) repeatable and understood. the core os9
> functionality are more important rn than chasing down transient
> errors. but im scoping "core os9 functionality" more broadly than you
> might want, so dont use that as an excuse to cut corners.

Read as three rules, in priority order:

1. **A stable honest gap beats an unstable plausible answer.** A
   rectangle we cannot attribute renders as a marked unknown, the same
   way every frame — never as a guess, and never differently on
   consecutive frames.
2. **Repeatable and understood beats maximal.** A window that renders
   the same way every time it is opened, with a provenance story we can
   state, beats one that renders beautifully once.
3. **"Core OS 9" is broad.** Finder in all views, the bundled control
   panels, the bundled applications, modals — including the ugly ones
   (TLS failure, unknown-creator). "That's an edge case" is not
   available as a reason to skip a window class a person hits in the
   first ten minutes at the machine.

## What the driving session found (the inputs)

Michelle's list from the live session, 2026-08-06 evening, with the
mechanism each traces to:

| # | Symptom | Mechanism (assessed, not all proven) |
|---|---|---|
| 1 | Hatching flickers; Finder content draws over/under/absent across redraws | Two clocks: scene poll vs P3 drain (`scene-gen 7 content-gen 2` observed live). Hatch is recomputed per frame from a moving answer. |
| 2 | View switch slow/brittle; list rendered once then hatched; old view under new | Stale composites: worlds/epochs never retired on view change. `displayEpoch`/`redrawServiced` exist and are not consulted by the join. |
| 3 | List view: cannot select items | Guest walk defect: rects at `l=16555`, pointer bytes as titles (sweep B, Memory). Hit-testing eats garbage geometry. |
| 4 | Mail double-click: broken modal, not dismissible via Mirror | Likely partially-captured window class. Manual override against the VM is authorised so it never blocks a sweep. |
| 5 | Tabs (Appearance, Energy Saver) missing edges | Asset gap: theme tab art not extracted (same family as the missing Charcoal strike). Overlaps plan 016's territory. |
| 6 | Some scrollbars render the blank-page icon, not arrows | Policy error: size-based blit classification asserts "document icon" for any icon-sized blit. A confident wrong answer. |
| 7 | Unknown-creator / open-with modal renders nothing at all | Likely a window class that never enters the scene. Capture gap, not render gap — confirm before touching the renderer. |

### Amendments from Sweep A (2026-08-07, appended not edited)

Sweep A ran against the unmodified tree and corrected four of the seven
rows above. The table stays as written — it is what was believed when
the plan was drawn — and these are the corrections:

- **Row 3 is far bigger than stated.** Pointer titles are not a Memory
  quirk: Date & Time 6, General Controls 7, Monitors 13, Mouse 12,
  Memory 21, Set Time Zone 5, plus the app-switcher **menu's own
  title**. And nothing inside a Finder window is addressable at all —
  ten list rows with **no refs**, still carrying icon-view grid rects of
  zero width and height; the desktop's 19 items report **screen**
  coordinates while every other surface is content-local.
- **Row 4's "not dismissible" is REFUTED.** The Mail modal dismissed on
  the first attempt via `dialogItem` in 7.6 s, no manual override used.
  What is actually wrong: the window has **no title**, so `open "Mail"`
  reports `timedOut` after 18 s having succeeded; and its buttons are
  reported **twice with contradictory titles on the same refs**
  (control walk `Yes/No/Set Up Now` correct, dialog-item walk
  `OK/Cancel/Don't Save` wrong).
- **Row 6 is aimed correctly but described wrongly.** There is no page
  icon in any scroll bar in fifteen windows — arrows are simply absent.
  The page icon fires where icon-sized **art** belongs: Mouse's tracking
  pictures, Sherlock's channel buttons, both alert icons. Size-based
  blit classification is still the defect; scroll bars are not its
  symptom.
- **Row 7 could not be reproduced.** No unknown-creator modal could be
  forced. Slice 3 must first build a repeatable way to raise one.
- **A defect no row predicted, and the largest in the set:** the
  Finder's entire window interior renders as one "Bitmap unavailable"
  hatch — no icons, no names, not even the item-count header — while
  the machine draws ten items. Neither 2026-08-06 sweep scored a Finder
  window, which is why this was invisible until now.
- **Stability was already good where it could be measured.** Zero
  differing pixels across two passes on eight panels. But the instrument
  renders a *settled capture twice* and never draws two consecutive live
  frames, so it **cannot see** the flicker Michelle reported. The live
  signal that does exist: `baseComplete` false in every snapshot across
  ten minutes, scene-gen 1→7 against content-gen 2→7. Slice 1 is still
  justified; its evidence is that, not the two-pass diff.

## Slices

Ordered so each leaves the tree green and the app usable. Per
[milestones-are-working-tiers], no stopping between slices.

### Slice 0 — Sweep A: measure before touching anything

Run the sweep specified below against the CURRENT tree, exactly as it
stands. This is the A side; nothing may be "fixed" first, however
tempting — the whole point is to price the defects before the work, so
the B side means something. Output:
`docs/fidelity-sweep-2026-08-07-a.md` (or same-day letter suffix if run
tonight). Sweeps A and B from 2026-08-06 remain untouched history.

### Slice 1 — One clock: a frame is a (scene, content) pair from the same epoch

**Before designing the pairing, read
[mirror-knowledge.md](../mirror-knowledge.md) and the relevant Mirror
source.** Epoch coherence between a polled structure and a streamed
content plane is exactly the kind of problem the sibling may have
already solved — or already failed at instructively. NOW has re-derived
Mirror's answers twice in one day before; the check is one read.

The render stops pairing "latest scene" with "latest drained content".
Instead:

- The content plane stamps each drained batch with the scene generation
  it was captured under (the guest already knows this; if the wire needs
  a field, the contract gains it first — asyncapi.yaml, then both
  halves).
- The compositor renders the newest **coherent pair** and holds the
  last coherent frame while a new one assembles. A half-drained epoch
  is never shown.
- On view change / window resize, composites from the dead epoch are
  retired — `worldDied` already fires; the join starts consulting
  `displayEpoch` so a world that survives a view switch does not carry
  its stale pixels into the new view.

**The degradation rule, stated up front because its absence is a
deadlock:** coherence gating applies only to windows with a live P3
stream. Content is often absent by design — record mode off, an app
never armed, a window with no plane; a healthy session was observed at
`content-gen 2` with `scene-gen 7`. A semantics-only window renders
semantics-only, immediately, honest gaps and all. "Hold the last
coherent frame" must never mean "hold forever waiting for content that
is not coming" — that would be a worse instability than the flicker
this slice exists to kill. Same family as "a resident component is
always optional": the product degrades honestly without it.

Exit: opening/closing/switching Finder views ten times in a row renders
each view the same way every time. The hatch set for a given window
state is **deterministic** — same window, same gaps. Verified against
guest pixels, not by eyeball.

### Slice 2 — One owner per rectangle: the provenance ladder

Replace the five accreted predicates (`semanticOwnsDisplay`,
`dialogItemOwnsDisplay`, `Coverage`, `semanticSupersedesResource`,
`displayableTitle`) with a single resolution: every rectangle gets
**(source, epoch, confidence)** and one ordered rule decides who draws.
The ladder, highest claim first:

1. P3 ink from the current epoch (the machine drew it; we show it).
2. A semantic control that owns its display (the per-kind gates,
   preserved as data on the ladder rather than scattered predicates).
3. Asset-pack art addressed **by identity** (an icon the guest named,
   a pattern the guest referenced) — never by size or shape guessing.
4. The marked unknown. Styled once, drawn stably.

**The unknown's look is a design decision, not a detail.** Half the
"excessive hatching" complaint is the hatch itself being loud — a
high-contrast diagonal screaming from every gap. The unknown will be
all over the render for a while, honestly, so it must be QUIET:
something like a flat neutral fill with a subtle marker, sitting back
the way an unloaded image does in a browser. Per the mock-before-fleet
rule: render 2–3 candidate styles over a real captured scene in
minutes, put them side by side, and get Michelle's pick BEFORE wiring
the ladder's rung 4. This materially decides whether "usable with
gaps" feels usable.

Explicitly deprecated by this slice:

- **Size-based blit classification** (the scrollbar page-icon bug, #6).
  An icon-sized blit whose identity is unknown is an unknown.
- **Shape-matching fallback for blit sources**
  (`now_content_blit_source`'s route 2) — contingent on birth-hooking
  holding up across the sweep set; if it does, route 2 goes, because a
  guess that can be ambiguous has no rung on the ladder. If it does
  not hold, the fallback stays and the sweep report says WHERE it was
  needed, which becomes the next chase.

`docs/render-composition.md` is rewritten around the ladder in the same
commit — it owns this policy.

Exit: `LiveShapedRenderTests` extended: for a fixture with all three
sources present, each rectangle's owner is asserted, and each rule
watched failing by mutation. Scrollbars on every swept window show
arrows or a marked unknown — never the page icon.

### Slice 3 — The windows that never arrive (capture gaps #4, #7)

Diagnose before implementing: for the unknown-creator modal and the
Mail modal, determine what the guest's walk actually emits (drive the
live guest; QMP screendump for truth). Expected findings, handled in
order:

- If the window class never enters the scene: the guest's walk gains
  the class. Contract first if a new field is needed. These are likely
  `dBoxProc`/movable-modal WDEFs or Notification Manager alerts — the
  exact class is the diagnosis's job, not this plan's.
- If it arrives structurally but renders nothing: it is a ladder bug,
  and slice 2's machinery names the rectangle owner that went missing.
- The Mail modal's non-dismissibility through Mirror is tracked but NOT
  chased past diagnosis in this slice — manual override at the VM is
  the sanctioned workaround. If the diagnosis makes the fix small, take
  it; if not, it lands in open-issues with what was learned.

Exit: both modals visible in the render with honest gaps at worst.
Dismissal via Mirror is a stretch goal, not a gate.

### Slice 4 — Guest walk hygiene (#3, and sweep trust)

The pointer-titles and `l=16555` rects are guest-side defects that
corrupt both hit-testing and every fidelity measurement taken over
them. In the guest walk (PPC, Carbon dialect — load
`classic-mac-carbon-ui` first):

- A title is validated at the source: length-checked Pascal string,
  control bytes rejected, or the field is omitted. An omitted title is
  honest; eight bytes of address is not.
- A rect outside the port's bounds is clamped or the row is marked
  unpositioned — never shipped as-is.
- Host-side `displayableTitle` STAYS as defence in depth, but the
  defect class is closed where it is created.

**NOW-68K is out of scope for this arc** (Michelle, 2026-08-06). The
symmetry rule still applies in its written form: the asymmetry is
declared, not silent — one line in
[contract-coverage.md](../contract-coverage.md) noting the PPC walk
gained title/rect validation and the 68K walk has not, so the gap is a
recorded decision rather than a surprise at a merge.

Exit: Memory control panel's scene carries zero pointer titles and zero
out-of-port rects; list-view selection works in the live app (this is
the hit-testing payoff, verified by driving).

### Slice 5 — Asset gaps priced, the cheap ones taken (#5, partial)

Not the fidelity-polish arc — just the gaps the sweep proves are cheap:

- Extend `tools/extract-assets-offline` to attempt theme tab art and
  the Charcoal NFNT strike. Time-boxed: if either is not extractable
  offline in a short investigation, document WHERE it lives (or that it
  is procedural, which plan 016's Appearance-answers route would serve
  instead) and stop. No heroics; missing edges render as honest gaps
  meanwhile.
- The desktop `ppat`: stop tiling pattern 16 unconditionally. Read the
  guest's actual desktop pattern if the scene can carry it cheaply;
  otherwise render the marked unknown. A plausible wrong purple is
  exactly what rule 1 forbids.

Exit: tabs either have edges or have stable marked gaps; the desktop
shows the guest's pattern or an honest one, never a guess.

### Slice 7 — The instrument must be able to see the defect (added 2026-08-07)

Not in the plan as drawn. Sweep A stated its own blind spot:

> this instrument renders a *settled capture*, twice. It never draws two
> consecutive live frames, so it cannot see the flicker Michelle saw.

Michelle's complaint #1 was flicker. Sweep A scored STABILITY **3** on
eight panels **because it only ever looked at settled state**. So Sweep
B, run as originally specified, would report "stable" whether or not
slice 1 fixed anything — the A/B this entire arc is bracketed by would
be hollow. **This slice blocks slice 6.**

- Capture **consecutive live frames** during a redraw-provoking action,
  and report instability quantitatively: frames until settled, distinct
  intermediate states, and — the flicker's real signature — whether a
  rectangle's OWNER changed between frames (P3 ink → unknown →
  semantic). Slice 2's ladder produces that owner map; it is the
  natural seam.
- It must run against **both** the current tree and the post-fix tree.
  A measurement that only exists after the fix proves nothing.
- **State hygiene.** Sweep A VOIDED Date & Time's entire row because
  pass 1 left its "Set Time Zone" modal open. Each target starts clean,
  and a target that cannot be returned to a clean state is reported as
  such rather than silently poisoning the next row.
- **Opening the Mirror is not reachable from the agent socket** — Sweep
  A had to use macOS accessibility scripting to click the button. A
  product gap wearing a rig costume: an agent can drive the guest but
  cannot open the window that shows it. Close it if small; document it
  precisely if not.
- **The three views are three phases on one boot**, not one instant,
  because the sweep tool and host app cannot share the wire. Fix or
  state inline in every report the tool writes. A limitation named in
  conversation and not in the artifact is one that will be forgotten.

### Slice 8 — Drivability: silent success and the unaddressable (added 2026-08-07)

Not in the plan as drawn. Sweep A surfaced a failure class the plan had
no row for, and it is the same disease as the render's plausible-wrong
answers, one plane over.

- **A command that succeeds and does nothing.** `as Buttons` dispatched
  cleanly **twice** and never produced button view. Silent success is
  the worst outcome for a driving agent — worse than an error, because
  nothing retries and nothing reports. A verb that cannot verify its own
  effect must say so rather than claim success.
- **The false negative, the same disease reversed:** `open "Mail"`
  reported `timedOut` after 18 s **having actually succeeded**.
- **Two targets are wholly unaddressable** — Appearance and Mouse both
  scored DRIVABILITY 0. (The Finder's DRIVE 0 belongs to slice 4, which
  owns item refs and coordinate spaces.)

Rule 1 generalises past pixels: **a refusal with a reason beats a
success that did not happen.** Verified by driving and watching the
guest change, never by a return code — the Mirror is tested by driving
it, and a green unit test for an act verb proves the wire, not the
effect.

### Slice 9 — The guest's real background (added 2026-08-07)

Michelle raised this and scoped it herself: **desktop PICTURES are out
of scope for now**, but a picture renders on top of a small repeated
pattern, so the pattern layer is what shows wherever a picture does not
reach — and getting it right is the durable half.

Lane C established the shape of the problem: **`ppat` 16 is a shipped
default that Appearance never updates**, so the renderer has been tiling
a factory resource with no relationship to the current desktop. On the
stage image the real desktop is an 800×600 picture drawn once at origin,
so the render is wrong twice — wrong art, AND tiled where the machine
does not tile. Lane C built the offline route (the pack manifest's
`desktop` object) and named its own limit: it is true only for a guest
booted from that image and unchanged since.

This slice closes that with the **live** answer: `GetTheme` with
`kThemeDesktopPatternTag` (CarbonLib 1.0+, inside our floor;
`LMGetDeskCPat`/`SetDeskCPat` are NOT available in Carbon), carried
through a verb serving both faces into the scene. Where it cannot be
obtained, the honest fallback is the marked unknown, never a guessed
pattern.

### Slice 10 — Drag as an act primitive (added 2026-08-07)

Michelle's vision is native drag between the two Macs: files on and off
the Mirror's desktop, targeting the desktop, a Finder window, an open
application or an app icon — plus ordinary intra-guest dragging to
rearrange or move files, and drag as the way scroll bars and sliders
actually work.

**Split deliberately.** This slice takes only the **act-plane
primitive** — sustained press → move → release — folded into slice 8's
lane because it is the same plane and the same honesty problem.

**Cross-machine FILE drag is held for its own plan**, for two reasons
worth stating so the deferral is not mistaken for disinterest:

- **It sits on geometry that is being repaired right now.** Dropping
  onto a thing means identifying that thing; desktop items were
  reporting screen coordinates while every other surface was
  content-local (fixed in slice 4), and list rows still report saved
  icon-grid positions. Building drop-targeting on that would encode
  today's bugs into a new subsystem.
- **It is an arc, not a slice** — file transfer, drag sessions, promise
  types, and the guest's own Drag Manager.

**And the primitive itself is sequenced behind slice 8's honesty
work.** `as Buttons` currently dispatches cleanly and does nothing; a
plane where a click can silently succeed will make a drag fail longer,
in more intermediate states, and far less visibly. Two hazards to
design against: a drag that dies mid-gesture must not leave the guest
holding a mouse-down, and the primitive must not fight a human's own
input at the machine.

### Slice 10.5 — Drag targeting and provisional presentation (added 2026-08-07)

Michelle broadened slice 10 the same day it was written. The primitive
alone is not the deliverable; **targeting and presentation are**.

**Targets, within the mirrored guest:** a Finder window, the desktop, an
application window, an application icon. **Same-app drags rearrange** —
dragging within a Finder window or on the desktop moves the item the
ordinary Mac way rather than becoming a no-op. Cross-machine file
transfer remains held for its own plan.

**The presentation contract, stated exactly as Michelle gave it:**

1. Do not wait for confirmation to begin showing the drag — the item
   moves with the pointer immediately.
2. Until the select is confirmed, the item is shown as **provisional** —
   a different style, or an alert glyph. Visible at a glance as not yet
   real.
3. Releasing before confirmation **snaps the item back home**.
4. A failed select response **also snaps it back home**.

This is the arc's governing rule one plane over: **show provisional
state marked as provisional**, rather than hiding it (feels dead) or
asserting it (a plausible wrong answer about what the guest did). A
provisional drag is never silently promoted to confirmed — the
confirmation must be a real response, which is the same honesty problem
slice 8 exists to fix.

**The visual language is not invented from scratch.** `UnknownVisual` is
already the single definition for "we do not know this yet", chosen to
read as unresolved rather than blank. Provisional-drag is its sibling:
extend it or place the style beside it in one definition. Two seams for
one decision is the defect slices 2 and 5 already had to merge away.

**Snap-back depends on geometry being repaired in this same arc.**
"Home" is only knowable if the item's position is trustworthy — slice 4
fixed desktop items reporting screen coordinates, and list rows were
still reporting saved icon-grid positions. Where home is not
trustworthy, **refuse the drag rather than guess a snap-back target**: an
item returned to the wrong place is worse than a drag that never began.

### Slice 10.6 — The cursor is ours, not the host OS's (added 2026-08-07)

Michelle:

> we currently get the select cursor from the host os over certain
> elements. ideally, we should integrate with the cursor behavior from
> the guest's element. for now id say: use the normal pointer everywhere
> and just focus on getting the text cursor over editable text areas.
> that should be a tight enough scope

**The same bug class as everything else in this arc.** The I-beam
appearing today is **the host OS deciding**, a side effect of what the
Mirror view is made of — it asserts "you can select text here" over
elements where you cannot. A confident wrong answer we did not author
and cannot explain.

Scope, deliberately tight: **arrow everywhere by default; I-beam over
editable text areas only.** Nothing else — no resize cursors, no
crosshairs, no watch, no guest cursor mirroring. Taking control and
defaulting to the arrow is the honest baseline; the I-beam then becomes
a claim made deliberately, from the scene's own semantics.

Driven from the **same rectangles the hit tester uses**, never a
parallel set — a second traversal of one truth is how two halves of a
rule drift, which this arc has now hit twice (the double-walk
contradiction in slice 4, and two copies of the unknown fill in slice
5).

Folded into lane D rather than given its own agent: it lives in the
Mirror view's pointer handling, the same file as the drag work, and a
separate worktree would collide at merge. Lowest priority within that
lane — it must not displace the honesty work.

**Not in scope, though it is the stated ideal:** integrating with the
GUEST's own cursor behaviour. The groundwork exists (the pack now
carries 43 extracted `CURS` resources) but it needs the guest to report
its current cursor — capture-side, and a contract change. A later
slice.

### Slice 11 — Procedures, not assets (added 2026-08-07)

A strategy call from Michelle:

> os9 does a lot of procedural runtime drawing. rather than trying to
> import these assets, we need to figure out what that procedure is,
> either through inference or when necessary re'ing, and implement it
> host side

Well-founded: Lane C's census of `Apple platinum` found **no tab bitmap
of any kind**. The theme file carries `tvar`/`tthm`/`scen`/`clut`
**parameters** that `DrawThemeTab`/`DrawThemeTabPane` draw from at run
time. There is nothing to extract, so "extract harder" is a dead end for
a whole class of chrome.

**Relationship to [016](2026-08-06-016-feat-platinum-from-the-source-plan.md),
which must be resolved rather than left ambiguous.** 016's thesis is
that Appearance *answers* — `GetThemeMetric`, theme colours, `DrawTheme*`
on the guest. This directive says derive the procedure and implement it
**host-side**. The likely synthesis: **ask the guest for the PARAMETERS**
(authoritative, small, cacheable) and **implement the PROCEDURE
host-side** (no per-draw round trip, works when the guest is quiet,
native speed). Whether 016 is amended, superseded or left alone is part
of this slice's deliverable.

**Scope: one procedure, proven end to end — the tab.** Sweep A confirmed
missing tab edges on Appearance and Energy Saver in both passes, Lane C
proved they are procedural, and it is small enough to finish. Inference
from parameters and observed pixels first; RE where necessary, saying
which route produced each conclusion. Validated against guest pixels
with deltas reported honestly, not by looking right.

**The durable output is the METHOD** — the procedure for deriving
procedures — as much as the tab itself. Deliberately NOT sprawling into
title bars, buttons and scroll bars: chrome is the best-scoring axis in
the sweep while other things render as one hatch.

Drawing code slots into the ladder as **rung 3, art addressed by
identity** — not as a new arbitration path. Where a thing cannot be
drawn faithfully, it renders the marked unknown.

### Slice 12 — Staged image discipline (added 2026-08-07)

Michelle, after the arc spent real time on a false alarm about the
oracle:

> we need to be more deliberate with the use of those staged imaged,
> especially where ext work is involved like, loud provenance, commit
> gates, instructions to get agents to be able to bake their own tmp
> imaged and have hooks to force resolution if anyone tries merging it in

**Four facts from today are the evidence base:**

1. **The shared oracle is uncertified.** `now-mirror-stage.qcow2` is
   sha `c466baa9…`; the newest receipt records `0785871a…`. The image
   was written at 01:58, **after** the 01:19 receipt, displacing a
   backup named `.bak-20260806-4-dirty`. AGENTS.md already tells the
   reader to check sha against receipt, and **nothing enforces it** —
   which is how it went stale in silence.
2. **The provenance is quiet enough that a careful reader got it
   wrong.** The coordinating session told Michelle the arc's
   measurements were suspect because the oracle was stale. A lane
   corrected it: `spin-up-ppc:82` defaults to `os91-runner.qcow2`, not
   the stage image, and stages this checkout's ext and app into the
   clone before cold-booting — so the resident under test is the tree's
   build. Both facts are discoverable; neither is loud. **Sweep A's rig
   table is the standard**: base, sha256, resident `sourceManifest` and
   `buildFingerprint`, and the sentence "was not used and is not the
   oracle for this sweep."
3. **The last bake wins while lanes run concurrently.** A bake mid-arc
   silently replaces the base under everyone else.
4. **A receipt can certify less than it appears to** — the 01:19 one
   carries its own correction saying so: `qemu-img check` cannot see the
   Macintosh filesystem inside the container, and a "guest-clean"
   shutdown means the sequence *started*.

**The four builds:** loud provenance on every run and in its artifacts;
the sha-vs-receipt check **enforced rather than remembered**; a
**per-agent throwaway bake** made the default for lane work, so
installing over the shared oracle becomes the deliberate announced act
rather than the easy one; and **merge-time forced resolution**, because
a clean textual merge of a receipt is no evidence at all — the same
defect as the derived tables in AGENTS.md that merged cleanly and
produced a lie.

**The binding constraint:** six lanes are committing right now. A gate
that refuses correct in-flight work would strand it, and uncommitted
work lost is this repository's most expensive lesson. Warn loudly where
the failure is informational; refuse only where a quiet pass lets a real
lie through; prove the in-flight branches still commit, by name.

### Slice 13 — Headless processes are a kind, not a failure (added 2026-08-07)

Michelle, on learning which processes were reporting
`ax_oracle_not_found`:

> ah right, headless apps. we should be aware of these and have
> contracts in place for them. we dont need them for the immediate
> render work but id rather account for them rather than just ignore
> them

**This arc's thesis one plane over.** A faceless background process
legitimately has no windows; reporting `ax_oracle_not_found` for it is
an **error word for a normal condition** — we assert a failure where the
honest answer is "this process has no UI by design." Six were observed
on a healthy boot: Control Strip Extension, DVD AutoLauncher, FBC
Indexing Scheduler, Folder Actions, tbt-appe, tbt-worker.

**It already costs a health signal.** Lane A traced the coverage claim
to `MirrorStateEngine.swift:163-172`, which settles on `partial` with
the reason *"visibility census did not uniquely cover every
application"*. On a healthy machine that pins at `partial` **forever**,
because the census can never cover processes that have nothing to
cover. So modelling headless processes plausibly converts a
permanently-false signal into a true one — to be **measured, not
assumed**.

The discriminator is the process's **own declaration**:
`ProcessInformationRec.processMode`'s `modeOnlyBackground`, from the
`SIZE` resource. **Never classify by "we saw no windows"** — that is the
exact inference that produced the false alarm, and it cannot tell "has
no UI" from "we failed to look."

**Refined the same day — it is three states, not two.** Michelle:

> we also need to be sure to distinguish apps with no open windows from
> truly headless app. im inclined to think that ax_oracle should see it
> all and be able to classify appropriately.

One error word is doing three jobs:

1. **Headless by declaration** — can never have windows. Normal,
   permanent.
2. **A UI application with no windows open right now** — SimpleText with
   every document closed. **Normal and transient**, and it changes from
   moment to moment on a healthy machine, so folding it into either
   neighbour is wrong half the time.
3. **A UI application whose windows exist but we failed to observe
   them.** The only genuine failure.

The gap between 2 and 3 is **absence KNOWN versus absence UNKNOWN** —
this arc's own distinction, moved from rectangles to processes. So the
walk must report *"I enumerated this process and found zero windows"* as
a **success**, distinct from *"I could not enumerate this process"* as a
failure with a reason. Today those are the same answer, which is why
nobody can tell them apart. Structurally identical to the question the
anchor counters exist to settle — *armed and capturing nothing* versus
*the filter never ran*.

The oracle's job therefore changes from *"find windows, or fail"* to
*"report what this process IS and what it HAS"*. An unclassifiable
process is reported as **unclassified with a reason**, never silently
folded into a normal state.

**The discriminator, from Michelle:**

> well importantly, truly headless apps dont appear in app switcher

The Application Switcher's membership list **is** the "has a face" set,
maintained by the OS itself — a truly headless app never appears there,
while SimpleText with every document closed still does. So it separates
state 1 from states 2-and-3 **directly**, from the system's own
bookkeeping rather than from an inference about window counts. And the
guest walk already traverses that menu: slice 4 was fixing the
app-switcher menu's own title the same day.

**But hook the SOURCE, not the menu.** Michelle, correcting the above
within the hour:

> idk about deriving them *from* app switcher, but whatever is
> populating app switcher on the carbon/toolkit end might be a good hook

The menu is a *rendering* of an underlying truth. Deriving from it means
depending on a UI artifact we must walk, with every failure mode that
implies — and one is already in the data: **Application Switcher is
itself a process**, and it was among the eight reporting
`ax_oracle_not_found` on the bad boot. Reading a menu to learn what a
process *is* puts an instrument in the path that can break independently
of the thing measured.

So find what populates it on the Toolbox end — most likely the Process
Manager's `GetNextProcess`/`GetProcessInformation` enumeration filtered
on `processMode` — and hook that.

**An open question that must be answered before any "corroboration"
claim is made:** is the switcher's population rule the **same bit** as
`modeOnlyBackground`, or a different one? If the same, the two are **not
independent signals** — one truth observed at two removes — and any
claim of independent confirmation here is false. A manufactured
confidence is worse than a single honest source. If the rule is wider
(there are other mode bits, and OS 8.5+ has both the Application menu
and the Switcher palette, which may not agree), the second signal is
real and the rule itself is the finding. Either answer is good; carrying
"two signals agree" forward without establishing whether they *could*
disagree is not.

Rendering anything for headless processes is explicitly out of scope;
so is any change to the ladder.

### Slice 14 — Scene control caps, then lazy delivery (added 2026-08-07)

Appearance scored DRIVABILITY 0 in Sweep A, and slice 8 found the cause
is **ours, not the machine's**: its control chain is **73 controls long
and `kNowSceneWalkMaxControls` is 48**, so the plane is correctly dropped
rather than shipped as a prefix. Nothing said so — `controls: []` read
identically for a dropped plane and an empty window. Slice 8 fixed the
silence (windows now carry a `walk_verdict`; `meta.errors` distinguishes
our bound from a chain that left the readable zones) and left the sizing
decision, correctly, because the budget is shared by every lane's
windows.

Measured: `sizeof(NowSceneControl)` 320 B; `NowScene` 147 KB today;
+10 KB per 32 pool slots; per-window cap must clear 73; the scene-wide
pool (96) wants ~133.

**Raise the caps** — ~147 → 170 KB to make a core control panel drivable
is a good trade under Michelle's framing, and it is reversible. Sized
from measurements across **several** panels, not fitted to Appearance's
73, with an honest statement about the **PowerBook 1400c** and not just a
512 MB emulator.

**Then, optionally but preferably, send lazily.** Michelle: *"can we
raise the cap and (optionally) send lazily?"* The cap exists only
because the scene is a **fixed-size struct shipped whole**; every
window's controls occupy the pool whether or not anyone looks. Lazy
delivery decouples how many controls a window has from how big every
scene is — a raised cap is a bigger number that will be too small again;
lazy delivery stops the argument.

Two constraints decide whether it works, both already paid for in this
arc:

1. **Unfetched is NOT empty.** A window whose controls have not been
   fetched reports **"not fetched"**, never `controls: []` — otherwise
   the defect slice 8 just fixed is recreated one level down. Same
   *absence known / absence unknown* distinction as slice 13, and the
   two must share vocabulary rather than each inventing a good word.
2. **A lazily-fetched list carries the generation it was captured
   under.** Otherwise the two-clocks defect slice 1 fixed in the content
   path returns in the control path — fresh structure paired with stale
   detail. `displayEpoch` is the precedent.

And it must not slow the common case: most windows are small, so an
eager-up-to-N, lazy-beyond-N shape is likely right, with N measured
rather than assumed.

### Not taken: window chrome — VETOED to plan 016 (2026-08-07)

Michelle proposed polishing title bars and their buttons. Declined as a
slice here and routed to
[016](2026-08-06-016-feat-platinum-from-the-source-plan.md), on two
grounds:

- **It is 016's exact mechanism.** Lane C's census found no tab bitmap
  anywhere in `Apple platinum` because `DrawThemeTab` draws them
  procedurally at run time. Title bars and their widgets are the same
  family — there is nothing to extract, and the answer is 016's
  "Appearance *answers*" route (`GetThemeMetric`,
  `DrawThemeTitleBarWidget`). A slice here would fork chrome work
  across two plans.
- **Chrome is already the best-scoring axis.** Sweep A: CHROME 3 on
  most targets, 2 on three of them — while Monitors and Finder icon
  view sit at 0 on PLACEMENT and REGIONS, and the Finder's entire
  interior renders as one hatch. Title bars are the most visible thing
  that is not broken.

**Amended the same day:** Michelle's answer to this veto was not to
insist on title bars but to name the deeper problem — procedural runtime
drawing — which became **slice 11**. Title bars remain out of scope
here; when slice 11's method is proven on the tab, they are the natural
next application of it, in 016 or its successor.

### Slice 6 — Sweep B and the verdict

Re-run the sweep, same spec, same targets, same machine-shape. Output:
`docs/fidelity-sweep-2026-08-07-b.md`, with the A/B table, regressions
named plainly, and the three-level verification status stamped per
claim. Update [open-issues](../open-issues.md) (append, never edit) and
[contract-coverage](../contract-coverage.md) if any verb or field
changed. End with the standard arc close: what shipped, what is still
unknown, what the next slice should be.

## The sweep — specification

One spec, run twice (slice 0 and slice 6). Scripted where possible
(`tools/fidelity-sweep.py` grows what it lacks); judgement calls are
allowed but must be written down.

### Targets

**Control panels (7):** Date & Time, Memory, Appearance (tabs!), Energy
Saver (tabs!), General Controls, Monitors, Mouse or Keyboard.

**Applications (4):** Finder — one window driven through icon, list AND
button views, plus the desktop itself; Sherlock 2; SimpleText with a
document open; NOW's own Workshop window.

**Modal forcers (2):**
- **Internet Explorer**, navigated to an https URL — the TLS failure
  modal is the point (the era's ciphers cannot negotiate; the modal is
  deterministic).
- **Mail, double-clicked from the desktop** — forces the broken modal
  (#4). This one cannot currently be dismissed through Mirror; the
  driver uses MANUAL override against the VM (QMP input or the SDL
  window) to clear it, notes that it did, and moves on. It must never
  block the rest of the sweep.

### What is captured per target

Three views of the same instant, or as close as the rig allows:

1. **The MCP/agent surface** — `mirror_read` snapshot + find over the
   target: window present? controls enumerated? titles real strings?
   rects sane? This is the data a driving agent gets, and it is scored
   separately because a window can render prettily and still be
   undrivable (#3 proved it).
2. **The Mirror's pixels** — the host render, via the app's own
   composition path (RenderShot or the live window).
3. **The guest's pixels** — QMP screendump. The truth.

Plus, per target, **perf notes**: time from action to settled render
(the metrics lane already reports cycle idle/request/decode/total —
record them), and any lane-depth growth or drain stalls. Perf is
recorded, not gated — but a regression between A and B is a named
finding.

### Scoring

Per target, the five-axis 0–3 rubric from
[fidelity-sweep-2026-08-06.md](../fidelity-sweep-2026-08-06.md)
(TEXT / PLACEMENT / CONTROLS / REGIONS / CHROME), **plus**:

- **STABILITY** (new, 0–3): open/act/close the target twice; do the two
  renders agree with each other? 3 = pixel-stable, 0 = different gaps
  each time. This axis is the plan's whole point.
- **DRIVABILITY** (new, 0–3): can the agent surface address what the
  pixels show? 3 = every visible control enumerable and hittable.

Free-text callouts per target, mandatory even when empty: hatching
present (where), broken controls, missing labels, missing assets,
redraw artefacts, anything the rubric has no row for.

### Rig discipline (all learned expensively; none optional)

- Own VM, own ports (`spin-up-ppc --port` on a quiet pair), never
  Michelle's stack. `--expect-build auto` on every capture;
  `requireTheBuildUnderTest()` before believing anything.
- Name the build, the image sha256 vs the bake receipt, and the
  guest's reported stamp in the report header.
- `touch now-guest-ppc/src/core/build_stamp.c` before building if the
  guest is rebuilt.
- A capture where another session's guest could have answered is VOID
  and rerun, not annotated.
- The sweep drives the guest; where the Mirror cannot (the Mail modal),
  manual VM override is sanctioned, recorded, and does not block.

### Where the artifacts live

Two runs × 13 targets × 3 views is a lot of PNGs and JSON, and this
repository just spent real effort getting bulk OUT of git. Sweep
artifacts (screendumps, renders, captured scenes, raw metrics) go to
the out-of-git store — the `tools/fixture-store` /
`~/Lab/Assets/now-mirror-assets` pattern — with sha256s recorded in the
report header so a score can be traced to its evidence. The docs carry
only the scores, the callouts, and small crops where a picture argues
better than a sentence. A capture worth turning into a permanent test
fixture graduates through `tools/fixture-store` deliberately, one at a
time, not by bulk copy.

## Orchestration — subagents, not chips, and how the lanes line up

This arc is executed with real subagents working in parallel where the
dependency graph allows, coordinated by the main session. An aside
worth doing is a spawned subagent task, not a suggestion chip.

### The dependency shape

```
Slice 0 (Sweep A) ─── alone, first, nothing else running
        │
        ├── Lane A (host render):   Slice 1 ──► Slice 2
        ├── Lane B (guest walk):    Slice 4 ──► Slice 3 guest fixes
        ├── Lane C (assets, offline): Slice 5 extractor probe   [DONE]
        ├── Lane D (act plane):     Slice 8                     [added]
        ├── Lane E (the instrument): Slice 7                    [added]
        └── Slice 3 DIAGNOSIS (read-only driving) — parallel with all
        │
Slice 6 (Sweep B) ─── alone, last, after integration + green gate
                      BLOCKED BY slice 7: without it, Sweep B
                      cannot see the defect slice 1 targets
```

Lanes D and E were added on 2026-08-07 from Sweep A's findings, not from
the original plan. Both are parallel with everything: D touches the act
plane, E touches the harness. E's one point of contact with lane A is a
small additive compositor hook for per-frame owner maps — kept cheap and
off by default, sequenced at integration.

Lane C completed first and handed lane A two things: the chosen
`UnknownVisual` definition for rung 4, and the desktop-picture manifest
contract (`ppat` 16 is a shipped default that Appearance never updates;
the real desktop is an 800×600 picture drawn once at origin, so the
current render is wrong twice — wrong art AND tiled). It also removed
tab art from this arc's scope entirely: there is no tab bitmap in
`Apple platinum` at all, so missing tab edges belong to plan 016's
Appearance-answers route.

- **Sweep A and Sweep B run alone.** A sweep taken while another agent
  is editing the tree or driving the guest measures nothing.
- **Lane A is sequential within itself**: the ladder (2) consults the
  epoch model (1), so 2 waits for 1. Nothing else waits for lane A.
- **Lane B is sequential within itself**: slice 3's guest-side fixes
  and slice 4 edit the same walk code; serialise them (4 first — it is
  smaller and slice 3's fixes want its validated-title groundwork).
- **Slice 3's diagnosis is read-only** (drive the guest, screendump,
  read the walk's output) and can run beside everything from the start.
  Its FIX lands in whichever lane the diagnosis names: capture gap →
  lane B; ladder bug → lane A after slice 2.
- **Lane C is fully parallel** (offline extractor work touches no
  shared source). The desktop-`ppat` renderer change is the one
  exception: it is a rung-3/rung-4 behaviour, so it lands through lane
  A's ladder, not from lane C.
- **The unknown-style mock** (slice 2's design decision) is a lane-C
  -shaped side task: spawn it early, it needs only a captured scene,
  and Michelle's pick should be back before lane A reaches rung 4.

### Rules for the parallel phase

- Each subagent works in its OWN worktree/branch off this one
  (`claude/<slug>`), commits early and often, never pushes, never
  touches main. The main session integrates lanes in dependency order,
  resolves conflicts, and owns the final `scripts/test-all`.
- Keep-both merges are the known trap: verify brace depth after any
  conflicted merge, and only `scripts/build-guests` catches guest-side
  truncation.
- One live VM per agent, own ports, `--expect-build auto` — two agents
  sharing a guest is how void findings happen. The Mirror-driving
  diagnosis agent and a sweep NEVER run at the same time.
- Contract changes serialise through the main session: if slices 1 and
  4 both need a field, one asyncapi.yaml edit, both consumers follow.
  Guests are rebuilt once per integration, `build_stamp.c` touched
  first; an `ext/` change triggers `scripts/bake-ext-image` and its
  receipt gate.
- Derived docs (contract-coverage, open-issues) are re-derived at the
  MERGE, not only at each lane's edit — a clean textual merge of a
  derived table is no evidence at all.

## What this plan does NOT do

- **Chrome fidelity from Appearance answers** — that is plan 016,
  untouched by this work except where slice 5's time-boxed asset
  probe reports findings into it.
- **Assets from the connected guest** — plan 017.
- **Chasing transient wire/perf errors** — recorded when seen, gated
  never. Michelle: core functionality over transient-error chasing.
- **Metal verification** — this arc is emulator-verified at best, and
  every claim says so.

## Risks, named now

- Slice 1 touches the frame pipeline the perf thread just optimised.
  The reconciled tree is the base; if coherent-pair rendering costs
  latency the perf work bought, the sweep's perf notes will price it
  and the trade goes to Michelle rather than being made silently.
- Slice 2 deletes working code (shape-matching) on the strength of
  birth-hooking evidence from ONE app family. The deprecation is
  contingent and reversible; the sweep decides.
- Slice 4 rebuilds the guest — the two-clock work (slice 1) may also
  need a contract field. Both mean cross-builds and a re-bake if `ext/`
  is touched (`scripts/bake-ext-image`; the pre-commit gate enforces
  it). Budgeted, not incidental.
