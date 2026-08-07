# The fidelity sweep — standing specification

**Version 3, 2026-08-07.** Version 1 lived inside plan 018 and asked one
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

## What version 3 adds, and why

**Version 2 mostly LOOKS. Version 3 also DOES.** Michelle, asking for it:

> maybe even expanded to start to include more interactions on top of the
> current sweep spec

Version 2 already had a standing check reading *"a scrollbar scrolls. A
tab switches. A list row selects."* Sweep B took all three and they
passed — and that is exactly the limit being fixed here. Those are
**single presses**, and a single press asks only *does this control
respond*. The expensive defects are not there.

Three things sweep B measured say where they are instead:

- It timed **reads at 16–209 ms and settlement at 5–6 seconds**, and
  concluded the perf complaint *"is settlement, not dispatch"*. That gap
  is not felt while looking at a window. It is felt while **doing** things
  in one, and nothing in version 2 spends time there.
- Its list-row select **visibly worked and reported `timed-out`**. A
  single-press check that asks "did the control respond" scores that a
  pass on the pixels and never reads the act's own answer. A **false
  negative on a landed act** is invisible to version 2 by construction.
- Its tab switch was verified by the **tab control's value** moving
  `1 → 4 → 1`. That is the strip. Nobody looked behind it. A tab whose
  value moves and whose pane does not is a defect this instrument had no
  way to see.

So version 3 adds a fourth axis, below. It does not retire anything:
**everything in version 2 still binds**, and a ✗ on a standing check still
outranks any seam or any interaction finding.

## The four axes a sweep must cover

Version 1 covered only the first. Version 3 adds the fourth.

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

### 4. Interactions — the axis version 2 asked one press of

**A single press is not an interaction.** It is the smallest possible one,
and version 2's standing checks already take it. This axis is about what
sits between presses.

Three kinds, and a sweep should carry at least one of each. They are
scored and reported separately because they fail differently.

#### 4a. Sequences — because defects live between the steps

**Open a window, scroll it, select something, act on the selection, close
it.** Each step's precondition is the previous step's postcondition, and
that is the whole point: a step-2 that works from a rested world and fails
from step-1's world is invisible to any check that takes step 2 alone.

A sequence is reported **step by step, with the step that broke named** —
never as one pass/fail. A sequence that completes four of five steps has
told you more than one that completes five, and a sequence reported only
as "✗" has thrown that away.

Sequences worth standing (extend the list; do not shorten it):

- **Browse**: front a process → open a window → scroll it → select a row →
  read the selection back from the machine → close the window → confirm
  the window behind redrew.
- **Panel**: open a control panel → switch a tab → change a control on the
  new pane → confirm the guest's own value moved → switch back → confirm
  the first pane's state survived the round trip.
- **Modal**: open a window → raise a modal over it → dismiss the modal →
  confirm the window beneath redrew and is addressable again. Sweep B
  could not reach the last step (`ditemact` refused the reference) and the
  modal stayed up for its whole run — that is a sequence failing at step
  3, and reporting it that way is what makes it actionable.
- **Text**: focus a field → set text → read it back → confirm the render
  and the machine agree on what is in it.

**Re-run the sequence from a rested world if it fails**, and say which
attempt is being reported. A step that passes alone and fails in sequence
is a *better* finding than one that fails both ways; do not smooth it into
"flaky".

#### 4b. State-changing interactions — see the change where it is VISIBLE

An interaction that changes state must be confirmed **twice, in two
places**, and both are required:

1. **The machine's own value moved** — re-read it from the guest, not from
   our record of what we asked for. `textget` after `textset`; the control
   value after `ctlact`; the panel's own label after a list selection.
2. **The rectangle that should have changed, changed** — checked per
   rectangle, exactly as the render is (see "per rectangle, never a
   whole-window score"). And the rectangle is the one a **person** would
   look at, not the one the act names.

The second is not redundant, and sweep B is the proof: it verified a tab
switch by the **tab control's value** and never looked at the pane behind
the strip. **A tab whose value moves and whose pane does not is a passing
check and a broken product.** Same shape for a checkbox whose mark moves
and whose dependent controls do not enable; same for a scroll whose
thumb moves and whose content does not.

State-changing interactions to stand: typing into a field and reading it
back; toggling a checkbox and confirming the guest's own value moved;
switching a tab and confirming **the pane behind it** changed; scrolling
and confirming the **content** moved, not only the thumb.

#### 4c. Refusals — and a refusal with a reason is a PASS

The act plane was rebuilt this arc specifically so that a verb **cannot
claim a success it did not verify**. That property is only real while
something tests it, and nothing does unless a sweep poses the cases.

**A refusal with a reason is a pass. A silent success is the failure.**
Version 2 says this once, at the bottom of the standing checks; version 3
makes it a class of interaction with its own cases, because the cases have
to be *posed* and posing them takes setup a looking-only sweep never does.

Cases to pose, each of which must refuse **and say why**:

- A press at a control **whose position cannot be established**.
- An act on a **stale reference** — take a reference, close or move the
  window, then act.
- A **drag with no trustworthy home** — a drag whose start or end cannot
  be attributed to a rectangle.
- An act on a window that has **gone away** between the scene and the act.

**A refusal case that cannot be posed is itself a finding, and it is
reported as one.** Sweep B found this: *"a press aimed at a menu whose
position is unknown is refused, not armed at x=0"* has **no reachable
case**, because `menuact` refuses first for a missing serial and once the
serial is supplied the position is known by construction. A check with no
reachable case reads green forever and guards nothing. When a sweep finds
one, say so on the row and propose a case that *can* be posed, or propose
the line's deletion.

**The inverse failure is the one nobody sees.** A refusal on an act that
actually landed is a **false negative**, and it is worse than a false
positive because the pixels agree with the caller and only the act's own
answer disagrees. Sweep B found exactly one (`Settlement: timed-out` on a
list-row select that demonstrably worked). **So every interaction records
the act's own verdict beside the observed outcome**, and the four
combinations are distinguished:

| act said | machine did | verdict |
|---|---|---|
| success | it happened | ✓ |
| refusal, with a reason | nothing | ✓ — this is the plane working |
| refusal / timed-out | **it happened** | **✗ false negative** — the expensive one |
| success | **nothing** | **✗ the failure the act plane was rebuilt to prevent** |

#### Timing every interaction — attempts-to-land beside time-to-settle

Version 2 asks for these as separate columns. Version 3 makes them
**per interaction step**, because that is where the split is felt and
where it will be fixed. Report, per step:

- **attempts to land** — how many tries, and what each refusal said.
- **time to dispatch** — the act's own round trip.
- **time to settle** — until the machine's value re-reads changed.

Sweep B's numbers are the baseline to beat and to compare against:
dispatch 16–209 ms, settlement 5–6 s. **An interaction whose dispatch and
settlement are not reported separately has not measured the thing this
project already knows is its worst number.**

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

**Every check below is a check of AGREEMENT WITH THE MACHINE, never of
expected appearance.** Two drafts of this list got that wrong in two
different places — "fronting a process makes its windows appear" (plenty
have none) and "icons resolve to art, not a blank plate" (a document with
no creator gets the generic icon on a real Mac). **Any check phrased as
"the render should look like X" has legitimate exceptions and will send
somebody chasing a defect that is not there.** If a line below reads that
way to you, read it as *"matches the guest's pixels"* and say so in your
report — the line is the bug.

Take each **where the target affords it**, and record ✓ / ✗ / n/a:

- **A scrollbar scrolls.** A tab switches. A list row selects. **Each
  confirmed where it is visible, not only in the control's value** — the
  content moved, the pane behind the strip changed, the panel's own label
  re-read. (Version 3; version 2's form of this line passed a tab switch
  on the strip alone.)
- **A menu item lands where it was named.** ~~and a press aimed at a menu
  whose position is unknown is *refused*, not armed at x=0~~ — **the
  second half is struck: sweep B found it has no reachable case.**
  `menuact` refuses first for a missing serial, and with the serial
  supplied the position is known by construction. It was a check that
  could only ever read green. The refusal property it meant to guard is
  now posed properly under axis 4c, against a *control* whose position
  cannot be established. **Left visible rather than deleted**, because
  the useful part of this line is the record that it was unposeable.
- **An interaction SEQUENCE completes, or names the step it broke at.**
- **A refusal names its reason** — and an act that landed is never
  reported as refused or timed out (axis 4c's false-negative row).
- **A window opens, closes, and the one behind it redraws.**
- **Fronting a process makes it OBSERVABLE**, and `cycle` populates an
  undriven machine. **Not "makes its windows appear"** — an earlier draft
  said that and it was wrong in a way that would have cost somebody an
  hour. **Plenty of applications legitimately have no windows**, and the
  two every agent meets first are among them: the Finder with nothing but
  the desktop open, and NOW's own Workshop before its window is up.
  <br>The check is the **distinction**, not the count: after fronting, a
  process must answer its window list — and **zero windows reported as
  `empty` is a pass**, because that is a fact about the machine. Only
  `unknown` is a failure, because that is a fact about us. An agent that
  reads "no windows" as "acquisition failed" will chase a defect that
  is not there.
- **The desktop shows its icons**, and one can be selected by name.
- **Text is what the machine drew** — no glyph the guest truncated, no
  glyph the guest drew missing.
- **An icon renders what the machine drew** — including a plain or
  generic one where that is what the machine drew. **A document with no
  creator gets the generic document icon on a real Mac**, so a
  blank-looking plate is a **pass** when the guest's pixels show the same
  plate. The failure is our *unknown* wearing art's clothes, or art
  replaced by our unknown. Where we genuinely could not resolve an icon,
  the unknown must be legible as unknown at 32×32.
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

### The state no driving instrument can observe: REST

**Anchor leases are 10 seconds.** Every rule above exists to keep a
capture out of the acquisition hole — front it, cycle it, discard the
warm-up. All of them work by **driving the machine continuously**, and
that means a sweep run correctly is structurally incapable of seeing what
the product does when nobody is driving it.

Michelle saw a window that had been sitting show **an empty interior and
`Content: Requested`**, and it cleared on its own. Every instrument in
this tree would have missed it, because every instrument arms and captures
inside one lease.

So, standing, from version 3:

- **Establish whether the resting state of an undriven Mirror is empty.**
  Arm, then **stop driving** for longer than a lease — 15 s, 30 s, 60 s —
  and capture *without* re-fronting or re-cycling first. Then drive once
  and capture again.
- **Report the resting state as its own row.** If an undriven Mirror rests
  empty and refills on the first act, that is a **product defect nobody
  has characterised**, and its whole significance is that it is invisible
  to the instruments. If it rests full, that is worth writing down too,
  because it retires a live suspicion.
- **This measurement is deliberately taken in violation of the warm-up
  rules above**, and must say so on the row. The rules exist so a capture
  measures the render; this one is measuring the lease.

A sweep that never stops driving has answered every question except the
one a person asks by walking away from the machine and coming back.

## The guest's pixels are the truth — and how much to check

Michelle, on the dose:

> maybe not obsessively, but enough to check sanity and validate that the
> mirror is showing what it should be showing how it should be showing it

**The failure this guards against is not the render looking broken. It is
the render looking RIGHT and being wrong** — self-consistent, confident,
and diverged from the machine. That has already happened here twice:

- The render printed **"Capture and stream"** where the guest had drawn
  **"Capture and stre…"**. It looked like an improvement. It was a
  divergence, and nobody would have filed it as a bug.
- Group-box frames appeared to cross their own labels. Three people read
  it as a chrome defect. It was **Chicago standing in for Charcoal and
  overrunning a band the machine had sized for a narrower face** — a
  render confidently drawing something the machine never drew.

**A render nobody checks drifts toward plausible rather than true**, and
each drift is individually defensible. That is why this is a standing
rule and not a phase.

The dose:

- **Every target gets at least one guest/render pair actually looked
  at.** Not scored — *looked at*, side by side, by something that will
  say what is different.
- **Every claim gets its own rectangle checked.** If a lane says the tabs
  draw, check the tabs. If it says the panel face is grey, sample the
  face. A claim and the pixels that would falsify it.
- **Not** an exhaustive pixel diff of everything. That is the obsessive
  end, it buys little, and a whole-window similarity score is the *worst*
  form of it — **it cannot see a one-pixel error**, which is how a line
  defect survived in every window since the renderer's inception.

When the render and the machine disagree, **the machine is right and the
render is the defect** — even when the render looks better. Especially
then.

## Scoring

Per target, the 0–3 rubric: **TEXT / PLACEMENT / CONTROLS / REGIONS /
CHROME**, plus:

- **STABILITY** — the same target twice; pixel-identical or the
  difference named.
- **DRIVABILITY** — can the agent surface address what the pixels show?
- **INTERACTION** (version 3) — of the sequences this target affords, how
  many completed, and did the changes show where a person would look?
  **Scored separately from DRIVABILITY**, which asks only whether the
  surface can *address* what the pixels show. A target can be perfectly
  addressable and still fail every sequence: sweep B's Appearance had
  73/73 controls with references (DRIVE 3) and could not complete a single
  round trip, because nothing checked behind the tab strip.

**Reliability and latency are separate columns.** They moved in opposite
directions once already ("most things are at least landing on the first
or second try… perf is still meh"), and an average that mixes them hides
both. Record attempts-to-land beside time-to-settle — and from version 3,
**per interaction step**, not per operation class.

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

**Copy artefacts out BEFORE reclaiming the lane block.** `lane-ports
reclaim` deletes the run directory, and a lane lost its screendumps that
way. Artefacts live out of git in `~/Lab/Assets/now-mirror-assets/` with
sha256s in the report header.

**An interaction changes the world, so hygiene is part of the rig, not a
tidy-up.** Version 2's sweeps were mostly read-only and could afford a
best-effort tidy; version 3 deliberately moves controls, sets text and
opens modals. Two consequences:

- **Record the world's state before and after each sequence**, and if the
  sequence could not restore it, say which target inherited the mess.
  Sweep B's contamination was found by a human reading a screendump.
- **A hygiene routine must not GUESS at a dismissal.** Sweep B's pressed
  DITL item 2 as "Cancel by convention"; on a modeless control panel that
  was **"Set Time Zone…"**, so the cleanup step opened the modal it then
  failed to close and contaminated every target after it. **A cleanup that
  can act is more dangerous than one that leaves the world dirty**,
  because its damage reads as the next target's own defect.

## Reporting

A new dated document per sweep; **earlier sweeps are never edited** —
they are the record of where things stood. Cross-reference forward so
nobody quotes a stale score as current, and **say plainly where the
method changed**, because a changed method makes rows incomparable and
that is not a failure as long as it is declared.

**Name the pain points to steer work still in flight.** That is what a
sweep is for. A sweep whose findings arrive after everything has landed
has measured history.

**Report interactions step by step.** A sequence is a table of its own
steps, each carrying what the act said, what the machine did, attempts to
land, dispatch and settle. A sequence collapsed to one verdict has thrown
away the only thing this axis was added to capture: **which step**.

## Version history

| Version | Date | What changed |
|---|---|---|
| 1 | inside plan 018 | *Is this horribly broken?* Targets only. |
| 2 | 2026-08-07 | Seams, states, the standing checks, per-rectangle pixel comparison, the two honesty rules (agreement with the machine; zero is a pass). |
| 3 | 2026-08-07 | **Axis 4, interactions**: sequences, state changes confirmed where visible, refusals as a posed class with the false-negative row, per-step timing. Plus the **REST** measurement, an **INTERACTION** score column, hygiene promoted into rig discipline, and the unposeable menu-refusal check struck with its record kept. |

**A version bump makes rows incomparable, and that is fine when
declared.** Say per row where the method changed.
