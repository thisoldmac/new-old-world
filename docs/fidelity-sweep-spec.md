# The fidelity sweep — standing specification

**Version 2, 2026-08-07.** Version 1 lived inside plan 018 and asked one
question: *is this horribly broken?* It still asks that. But the answer
is now mostly "no", and an instrument that only detects gross failure
stops earning its cost the moment the product clears that bar.

Michelle, setting version 2's purpose:

> we've raised our high water mark high enough that these can start to be
> about finding the seams

**So: a sweep hunts seams.** A seam is where two things meet and disagree
— two producers of one answer, two paths to one capability, a state
nobody has observed, a transition between states nobody has watched. Every
expensive defect this project has found lived in a seam, and none of them
would have been caught by asking whether a window looked broken.

**A sweep does not require a person.** An agent runs it alone and the
result stands on its own. A human co-drive is *additional* signal — it
catches what a rubric has no row for — and is scheduled when convenient,
never as a precondition.

## The three axes a sweep must cover

Version 1 covered only the first.

### 1. Targets — more, and weirder

The bundled control panels and applications, **plus** the ones that
behave unlike the others. A sweep of seven well-mannered panels measures
seven instances of the same thing.

Deliberately include: an application that draws its own everything
(Sherlock); one that is mostly text (SimpleText); one that is mostly a
list; one with a tabbed panel; one with a modal that cannot be dismissed
normally; one that opens a document window separate from its main
window; **and at least one target nobody has swept before.** Rotate that
last slot every sweep and say which it was.

### 2. States — the axis version 1 missed entirely

**More states per target is worth more than more targets.** The chrome
lane found that **five of seven `ThemeTabStyle` states had never been
observed by anyone**, because the corpus contained exactly two tabbed
panels and both were active and front. That is the template: enumerate
the state space, then find the unvisited cells.

Per target, where applicable:

- **Front and behind.** Most captures are of a front window; a window
  behind another is a different drawing.
- **Active and inactive** controls; a control at its **minimum and
  maximum** (a scrollbar with nothing to scroll is not a scrollbar with
  something to scroll).
- **Empty and full** — an empty folder, a list with one row, a list that
  scrolls.
- **Resized**, including narrow enough to truncate a label; **moved**,
  including to a screen edge.
- **A modal over a window**, and the window after it closes.
- **Long and awkward content** — a very long filename, a name with
  high-MacRoman characters, an empty name.

Record which cells you visited and **which you could not reach, with the
reason.** An unvisited cell is a finding, not a gap in the report.

### 3. Seams — the point of version 2

Where two things should agree, **check that they do**:

- **Two producers of one answer.** The console, the wire and the scene
  should describe one machine identically. They have disagreed: a control
  walk and a dialog-item walk once reported contradictory titles for the
  same refs, each honest about a different moment.
- **Two readers of one rectangle.** `windows[].rect` had three
  derivations inside the scene plane alone.
- **Two paths to one capability.** MCP versus the agent socket versus the
  console.
- **The render against the machine, per rectangle** — not per window.
  **A whole-window similarity score cannot see a one-pixel error**, which
  is how a line-drawing defect survived in every window since the
  renderer's inception. Assert edges and positions, and report a
  percentage only as colour.
- **The same target twice** — pixel-identical, or the difference named.

## The standing checks — woven in, not a separate phase

Version 2 hunts seams. It **also still asks whether anything is horribly
broken**, because the high water mark rising is exactly what makes a
regression easy to miss: the eye goes to the new thing.

Michelle, correcting an earlier draft of this spec that had dropped it:

> the sweeps should have a checklist of things to go through to validate
> that they're still green, havent regressed etc … like "while im here in
> an app with a scrollbar, let me make sure it works" kinda stuff

**So these are opportunistic, not a pass of their own.** When a target
affords a check, take it. It costs seconds and it is the only thing
standing between a fixed defect and its quiet return.

**The rule that keeps this list honest: a landed capability adds a
line.** Every entry below is something this project did not have until
somebody built it, which is precisely why each is now a regression
candidate. When a lane lands a capability, it goes here.

Take each **where the target affords it**, and record ✓ / ✗ / n/a:

- **A scrollbar scrolls.** A tab switches. A list row selects.
- **A menu item lands where it was named** — and a press aimed at a menu
  whose position is unknown is *refused*, not armed at x=0.
- **A window opens, closes, and the one behind it redraws.**
- **Fronting a process makes its windows appear** (anchor acquisition),
  and `cycle` populates an undriven machine.
- **The desktop shows its icons**, and one can be selected by name.
- **Text is what the machine drew** — no glyph the guest truncated, no
  glyph the guest drew missing.
- **Icons resolve to art**, not to a blank plate; unknown regions are
  legible as unknown at 32×32.
- **No hatching where the machine drew** — every hatch traceable to a
  rectangle nobody could attribute.
- **Panel faces are the guest's grey**, not white.
- **Window stacking matches the guest**, including two windows of the
  *same* process.
- **The Mirror opens** from the menu item, the agent verb, and the
  guest's own button.
- **An act that cannot verify its effect says so** rather than reporting
  success.

A ✗ here outranks any seam. **A regression in something that worked is
worse than a seam nobody has found yet**, because somebody has already
paid for the first one.

## What is captured, per target

1. **The agent surface** — what a driving agent gets. Scored separately,
   because a window can render beautifully and be undrivable.
2. **The Mirror's render**, through the app's own composition path.
3. **The guest's own pixels** — QMP screendump. The truth.

**Discard a warm-up scene.** The planes arm as a *result* of the first
`scene.request`, so a first-on-connection capture returns every role
`unknown` and is **indistinguishable from a real defect**. Confirm your
captures are steady-state and say how.

**Front or `cycle` each target first.** A process acquires an anchor slot
only while it is itself pumping events with the plane armed, so an
undriven machine hands you the anchor defect and you will report it as a
render defect.

## Scoring

Per target, the 0–3 rubric: **TEXT / PLACEMENT / CONTROLS / REGIONS /
CHROME**, plus:

- **STABILITY** — the same target twice; pixel-identical or the
  difference named.
- **DRIVABILITY** — can the agent surface address what the pixels show?

**Reliability and latency are separate columns.** They moved in opposite
directions once already ("most things are at least landing on the first
or second try… perf is still meh"), and an average that mixes them hides
both. Record attempts-to-land beside time-to-settle.

**Mandatory free-text callouts per target, even when empty**: hatching
and where, broken controls, missing labels, missing assets, redraw
artefacts, anything the rubric has no row for. **Version 1's most
valuable findings all came from this field**, not from the scores.

## Rig discipline

Own VM via `tools/lane-ports`, `--expect-build auto` on every capture,
`requireTheBuildUnderTest()` before believing anything. Name the build,
the image sha against its receipt, and the guest's reported stamp in the
report header. **Shut the guest down guest-clean** — never QMP `quit`,
which is a power cut. A capture another session's guest could have
answered is **void**, not annotated.

## Reporting

A new dated document per sweep; **earlier sweeps are never edited** —
they are the record of where things stood. Cross-reference forward so
nobody quotes a stale score as current, and **say plainly where the
method changed**, because a changed method makes rows incomparable and
that is not a failure as long as it is declared.

**Name the pain points to steer work still in flight.** That is what a
sweep is for. A sweep whose findings arrive after everything has landed
has measured history.
