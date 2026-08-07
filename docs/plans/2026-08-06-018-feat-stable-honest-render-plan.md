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
(STRUCTURE / TEXT / CONTROLS / ART / CHROME), **plus**:

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
