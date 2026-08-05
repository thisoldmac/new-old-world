---
title: The headless Mirror — NOW MCP as the Mirror's second client - Plan
type: feat
date: 2026-08-04
---

# The headless Mirror — NOW MCP as the Mirror's second client - Plan

## Goal Capsule

- **Objective:** Make the NOW MCP a complete headless client of the Mirror's
  state engine, so that everything a person can read off the Mirror window and
  every mutation they can drive through it is equally available to an agent —
  differing only in pixels and input method.
- **Authority:** `MirrorStateEngine` is the single source of published state.
  `MirrorActionExecutor` and the mutation broker are the single mutation path.
  Neither face may mint its own cache, its own addressing grammar, or its own
  settlement rule. `contract/asyncapi.yaml` still owns guest-wire meaning; none
  of this work adds a guest message.
- **Execution profile:** Additive projections inside the existing NOW MCP
  surface (`HostProjectionCatalog`). No second server, no new transport, no new
  executable, no MCP-only code path to the guest.
- **Stop conditions:** Stop if a slice requires MCP to reach the guest by a
  route the Mirror window does not use; if it requires a second scene cache; if
  it would settle a mutation on dispatch rather than observation; or if it
  needs a guest contract change (that is a separate arc, contract-first).
- **Tail ownership:** With MCP present or absent, the Mirror window behaves
  identically. Every projection added here reads or drives what the window
  already reads or drives.
- **Handoff status:** Slices 0–3 are implemented, gate-green and proven over
  a live socket against an emulated Power Mac G4. The first MCP-driven act,
  2026-08-05: `activate` against the published `process:process-ffc0941c`
  settled `confirmed` — waited 0 ms, dispatch 112 ms, settle 46 ms — and the
  Finder came front with its Macintosh HD window. It appears in
  `now_mirror_metrics` as `click Finder`, the same label and the same clocks
  the Mirror page's Acts card shows, which is the invariant this arc exists
  to establish.

  Slice 4 followed on 2026-08-05 and closed the mutate vocabulary and the
  remaining reads. `now_mirror_lifecycle` answered live with resident build
  `67d5ef434db7…`, `cap 15 requested 15 active 15`, and all four planes with
  their generations — the provenance that was invisible on the PowerBook. An
  MCP-driven activate then recorded `source=mcp outcome=confirmed` in
  `now_mirror_journal`, which is what makes the paired check readable at all:
  the executor had hardcoded `source: .human`, so every agent-driven act was
  recorded as a person's. Refusals were exercised too — an Apple menu row that
  is not on the machine, a dialog item that does not exist, and an unpublished
  window each refuse by name and say where to look.

  Slice 5 ran on 2026-08-05 and produced
  [the element gap ledger](../mirror-element-coverage.md): 62% of items carry
  no determined kind, a known `listBox` carries no cells, and dialog items are
  addressable 75/186 against controls at 96/122.

  Slices 0–5 are done. **Slice 5c is new**, from Michelle's drive against
  the merged build: settlement and lane defects, chief among them a
  Finder-open that predicts the Finder as the window's owner when a control
  panel opens as its own application — so every panel open times out for
  15 s having worked, and those timeouts stacked into a 51.8 s wait.

  **Still owed:** the paired hand-versus-MCP comparison (§ Verification);
  slice 1's page-versus-reply check, which was compared against a log sharing
  the same source; slice 2's `window.display` debt; and slices 5b and 6. Not
  yet driven live: `finderDeselect`, and `dialogItem` against an item that
  does something (the one exercised was a separator).

---

## Why this arc exists

Two things forced it, both on 2026-08-04.

A metal drive of the PowerBook 1400c produced ~45 acts, no confirmed
settlements, and no way to tell a working-but-slow act from one queued behind
an act that was going to time out. The measurements that answer this now exist
(`MirrorActClocks`, `MirrorCycleClocks`) but they were born visible only in
NOW's own Mirror page.

And taking the parity inventory ([mirror-mcp-parity.md](../mirror-mcp-parity.md))
turned up something worse than missing rows: the two faces do not share an
implementation. A person's gesture goes scene object → `MirrorActionExecutor` →
`InteractionPlan` → broker → typed settlement. An MCP act goes an opaque
`now-element-…` ref straight to the guest's command dispatch, settling for
nothing. **An agent benchmarking through MCP today measures a path no person
can take.** Adding rows on the current MCP side would deepen that split, which
is why the ordering below is not the obvious one.

## The invariant

> The Mirror window and the NOW MCP are two clients of one state engine. The
> only differences are pixels and input method.

Three consequences, and every slice below is one of them:

1. **Anything the renderer reads, MCP can read.** So an agent can pull the
   data, confirm the state is actually there, and only then implement the
   render — instead of inferring from pixels it cannot see either.
2. **Anything a gesture can do, a call can do**, through the same executor,
   returning the same operation record and settling the same way.
3. **Anything the page displays about itself** — planes, resident identity,
   the journal, the clocks — is readable headless.

## Slices

### Slice 0 — metrics · **DONE, proven live**

`now_mirror_metrics`: both clock families and the lane depth. Landed at
`cafa61e`. Metrics answer even when no scene has arrived (a declined or
timed-out walk is exactly when the numbers matter); an absent measurer is
`unavailable` rather than an empty list; and the read never constructs the
Mirror, or asking what was measured would create the measurer and return an
empty answer that reads like a quiet machine.

Answered over the agent socket from a live host on 2026-08-05, so this is
*works* and not merely *tested*.

### Slice 1 — prove the socket, and give the arc its harness · **DONE**

A small host-side client that speaks the agent unix socket
(`$TMPDIR/dev.newoldworld.now-agent-<uid>/host.sock`), so every later slice can
be verified headless rather than by eye. This is also the benchmark driver:
scripted, repeatable, and — once slice 3 lands — driving the same path a hand
does.

`tools/now-agent` landed at `ef955b3`; `now_mirror_metrics` answered from a
live host. It also found two things no test had: an empty answer could not be
told from a Mirror that never ran (hence `running`), and there was no way to
open the Mirror without a click, so a headless run could reach a state no call
of its own could leave (hence `--open-mirror`).

**Still owed, and not quietly closed:** the reply was compared against the
`NOWBASE` lines in `acts.log`, which derive from the same records — that is
testing one half twice. Confirming the Mirror PAGE shows the same numbers at
the same moment needs the screen.

### Slice 2 — the snapshot carries the renderer's whole input · **DONE, with debt**

Before this slice `now_mirror_snapshot` carried process and window *entities*,
coverage and the menu bar — and not window rects or z, controls, dialog items,
desktop items, or screen size. Those are exactly what the drive loop scores: a
field whose value is missing, a checkbox drawn as a push button, a label
truncated mid-word. So the render workflow in consequence (1) was impossible
for anything but windows and menus. Landed `2909299`; surfaces now carry
geometry, controls, dialog items and Finder items with the semantic `kind`,
`state` and `value`.

Projected from the same engine snapshot the renderer composes from, so the two
cannot disagree.

**Outstanding slice-2 debt, found twice after it was called done.** The claim
is "the renderer's whole input", and twice it has not been: `window.items`
(desktop icons and Finder rows, fixed `c596261`) and **`window.display` — the
per-window QuickDraw ops — which is still not projected.** The content plane
is live and busy (generation 1.6 M and climbing on the 2026-08-05 guest), so
the drawing IS captured; MCP simply cannot see it. Until it can, an agent
cannot answer "what did this custom control actually draw", which is the only
evidence that exists for the class slice 6 cares most about. Same omission
shape three times: the projection carries what a reader remembered rather than
what the model holds.

**This slice will expose, not cause, a Mirror-side defect:** `Scene.Control.ref`
is empty from NOW's producer. The window hides it behind positional resolution;
an agent will be able to see a control it cannot name. Record it, do not paper
over it — slice 3 depends on it.

### Slice 3 — one executor behind both mutation faces · **DONE, proven live**

`now_mirror_act` builds an `Interaction` against scene-object identity, runs it
through `MirrorActionExecutor` and the broker, and returns the `MirrorOperation`
— id, outcome, reason. Settlement arrives from a later observation exactly as
the window's does; the caller polls for the settled record (the existing
`now_mirror_wait` shape, or an operation-scoped sibling). Async submit, same
answer the UI gets.

A dispatch still may not claim an effect. That rule is older than this arc and
survives it.

### Slice 4 — the remaining rows · **DONE, proven live**

Cheap once slice 3 exists, and mechanical:

- mutate: `keystroke`, `typeText`, `dialogItem`, `applicationVisibility`
  (Hide / Hide Others / Show All), `openAppleMenuItem`, `finderSelect` /
  `finderOpen` / `finderDeselect`, `activateWindow` as one operation
- read: plane policy and the capability/requested/active bits, resident
  identity and build fingerprint, the operation journal

Resident identity is worth its own line: on 2026-08-04 a PowerBook with an old
`Now Extension` beside the new `NowExt` answered from the stale one, every act
refused as *the anchor plane is absent or not armed*, and the host knew the
resident's build the whole time without saying it.

### Slice 5 — the control-panel corpus, and the gap ledger · **DONE**

**Parity is a floor, not a ceiling, and this is the slice that says so.** The
renderer and MCP read the same IR; if the producer never captured a list's
cells, both faces are equally blind and perfect parity hides it. The walls this
project keeps hitting — lists, custom draws, whole classes of element — live
one layer BELOW both faces, and no amount of slice 1–4 work reaches them.

Open roughly ten control panels and capture each one three ways, at the same
moment:

- the **guest framebuffer** (QMP screendump) — what the machine is showing;
- the **MCP snapshot** — what the IR carries;
- the **oracle memory read** — what is actually in the heap.

Two diffs fall out, and they answer different questions. Screendump against
snapshot says *what we fail to show*, which is the UX gap the drive loop has
been scoring by eye. Snapshot against memory says *which layer lost it* — the
structure existed and the producer dropped it, or it was never there. Without
the second diff an enumeration is a list of complaints; with it every row
arrives already assigned to producer work, honesty work, or deferred-forever.

Control panels are the sample for the reason rung 3 gives: they are identical
on every OS 9 machine, so a captured scene is a permanent regression fixture in
a way "whatever was open that day" never is. Capture them **garbage and all** —
Mirror's corpus rule is explicit that a corpus of only healthy scenes tests
nothing.

**Ran 2026-08-05** with `tools/mirror-corpus`; the ledger is
[mirror-element-coverage.md](../mirror-element-coverage.md). Ten captures, 308
items across seven distinct panel windows, and it falsified two of this plan's
own claims — see that document's "Two claims of mine the corpus falsified".
Known limits of the run: captures are cumulative (panels were left open), two
panels never launched, and no memory-discovery pass has happened.

Pick for **variety of control class**, not for ten panels: Extensions Manager
(the best real list on the machine), Monitors and Sound (lists and sliders),
Appearance (tabs, colour swatches), TCP/IP (multi-character tab-linked fields),
Date & Time (radios, steppers, and rows already scored red), File Sharing
(fields, a list, live state), Keyboard (popups), Memory (radios, sliders),
Internet (many fields, tabs).

Three rules the capture tool must enforce rather than ask anyone to remember:

- **One moment.** The machine moves between reads, and a diff across two states
  is noise wearing the costume of a finding. Same discipline as the paired
  screendump rule.
- **Target frontmost.** Occlusion is a skip and never a pass; the structure read
  does not care, the pixel comparison does.
- **Provenance on every capture** — guest build, resident build and plane bits,
  snapshot id and generations. Slice 4's read rows exist to supply exactly this,
  which is why they come first.

The output is a ledger with a fixed vocabulary per gap, or it will not survive
being read a week later: **which layer** (producer / IR / client), **which
class** (readable structure, custom-drawn, composited art), and **the honest
interim behaviour**. That last column is what makes the follow-up metal-friendly
work rather than a wish list: a gap with no reading path still has a correct
answer, which is to say so in the data rather than draw something plausible.

One finding is already in hand and shapes the ledger's first rows.
`Scene.Semantics` carries `listCells` and `listTotalCount` today — the IR has
had a place for list rows all along, so for lists the producer is the whole
problem and layer 2 is fine. And `knowledge` (`known`/`unknown`/`truncated`/
`stale`) plus `completeness` already exist, so a producer that admitted "I saw
a control here and could not determine its kind" would make the coverage gap
visible in the data instead of inferred from a bad-looking render. That is the
cheapest move in this whole arc and it introduces no new mechanism.

### Slice 5b — the event tail: what memory cannot hold · **HALF BUILT**

**Memory answers "what is"; events answer "what happened",** and a class of
thing has no answer to the first question at all:

- **Immediate-mode drawing.** A window painted by QuickDraw calls and never
  stored — the calls ARE the content. No memory walk however good recovers a
  structure that was never written, which is most of the custom-draw class.
- **On-demand construction.** A menu populated when it is pulled down; list
  cells rendered by a custom `LDEF`. The structure is empty until the moment
  it is not.
- **Causality.** An Apple Event carries what an application was ASKED to do —
  semantics that exist nowhere as state, only as a message in flight.

Underneath all three sits a sampling problem worth naming on its own: **a
~2.2 s poll cannot see anything shorter than 2.2 s.** An alert that appears
and is dismissed, a progress state, a menu flash, a window opened and closed
between walks — invisible, and invisible in a way better memory reading cannot
fix. That is not a producer gap, it is a sampling gap, and it is the likely
explanation for a recurring symptom: an act that worked while the Mirror never
showed it.

**Status 2026-08-05.** The mechanism is built and gated: contract
(`contract/event_tail.h`), the ring in a system-heap block behind one
appended table word, the resident writer, the guest's reader, and a fifth
`transitions` plane reported end to end. **The delivery half is not:**
nothing arms the plane, no contract message carries records, the host
consumes none. So the ring stays empty on any drive, and a cold boot
proves the INIT loads and publishes — not that the tail works.

A caution recorded because it nearly shipped as "done": the guest reader
was written, native-tested and cross-build-green while being **absent from
the guest's CMakeLists**. Nothing compiled it into a guest binary. A
cross-build is green about the files it builds, and adding a file to a
directory does not add it to a build.

**Narrowed 2026-08-05:** the tail is NOT the answer to unclassified controls —
qdtrace already captures the drawing and the content plane is live. Its
argument is the sampling one above, which stands on its own: no amount of
draw-op capture fixes a poll that cannot see a dialog raised and dismissed
between walks.

So the guest grows an **event tail**, and the QuickDraw stream ends up doing
three jobs off one mechanism — invalidation (what changed, for cheap delta
walking), content (what was drawn, the existing P3 plane), and transients and
causality (this). One hook, three consumers, rather than three narrow hooks.

Apple Events get their own line because they are the cheap win: a documented,
first-party observation path that is **metal-safe with no emulator dependency
at all**, which is rare in this project.

Two constraints, both before anything is built:

- **The cost is the risk, and it is worst on the machine that matters.** An
  invalidation bitmask is O(1); an event LOG is unbounded. A tail recording
  every drawing op is a firehose on a 1400c — CPU tax on every application
  whether or not anyone is mirroring, and a memory problem besides. Ring
  buffer, ARMED rather than always-on, and **overflow reported rather than
  silently dropped**. A tail with a gap that does not say it has a gap is
  worse than no tail, by the same rule that prints an absent settle as `-`
  and never `0`.
- **It lives in the resident**, by the family charter: trap patches and AE
  handlers execute in a foreign context, so they are resident-only and
  optional, and the product degrades honestly without them.

This turns the corpus capture from a MOMENT into a TRANSACTION: arm the tail,
perform the action, capture the moment, read the tail. Strictly better — it
records how a window came to look that way rather than only how it ended up,
which is exactly the evidence a producer gap and a sampling gap are told apart
by.

### Slice 5c — the settlement defects a drive keeps finding · **NOT STARTED**

Michelle's 2026-08-05 drive against the merged build, read from the journal
and clocks rather than the screen. These are SETTLEMENT and LANE defects, not
rendering ones, which is why they are their own slice rather than part of
6: nothing here is about what the Mirror draws, and none of it waits on the
corpus.

**1. A Finder-open predicts the wrong owner, so every control panel times
out while succeeding.** `MirrorActionExecutor` builds
`windowNamedPresent(owner: Finder, title: item)` for a Finder-open, but a
control panel opens AS ITS OWN APPLICATION — a live snapshot shows the Date
& Time window owned by a process named `Date & Time`, not by the Finder.
The postcondition can never match, so the act burns its whole 15 s timeout
having worked. It only holds for FOLDERS, whose windows the Finder does own.
The item's kind is already in the snapshot (`finderItem` carries
folder/file), so a principled fix can predict a window for a folder and a
PROCESS for an application rather than guessing one shape for both.
Measured cost: four `open "AppleTalk"` attempts, 15 s each.

**2. The 15 s timeout is an amplifier, and the queue is where it is felt.**
From the same drive, waits behind the lane: 15 611 ms, 22 207 ms, 22 106 ms,
37 391 ms, 51 786 ms, 49 281 ms. One click waited **51.8 seconds**. Taussig's
fix ended the lane hold for refusals that never reached the machine; a
TIMEOUT still holds it for the full period, and defect 1 manufactures
timeouts. Fixing 1 removes most of the fuel, but the amplifier is its own
problem — a settled-by-eviction act blocks work that has nothing to do with
it. Worth asking whether the FIFO must be one lane, or one lane PER TARGET.

**3. Hide times out on a route that is refused, and the route it should
use is untried.** Hiding an application plainly WORKS on a Macintosh — a
person does it from the Application menu. What the census arc measured is
narrower: setting `visible` through the Finder's AppleScript object model
is refused (`-10000`, `-10006`), and this drive shows a third error,
`osaErr -1753`, so even the refusal text is stale. That is one mechanism
failing, not a capability the machine lacks, and calling it "impossible"
was an overstatement of somebody else's measurement.

**Driven 2026-08-05, and the candidate route fails too.** The Application
menu was read live — `Hide Date & Time`, `Hide Others`, `Show All`, all
present and enabled at menu `-16489` — and driving row 1 through
`now_mirror_drive --gesture menuItem` returned `dispatched` and changed
nothing: the paired screendump shows Date & Time still frontmost with its
window up. `InteractionPolicy` already says why, and I re-derived it the
slow way: visibility is kept typed precisely so it "cannot fall back to
commanding menu -16489, the route that reported success without changing
the machine."

So BOTH known routes fail, each in its own way — AppleScript refuses, and
the menu command dispatches without effect. What remains untried is
delivering a real CLICK to that menu through the act plane rather than a
`MenuSelect` command, which is the one thing a person does that neither
route reproduces. Until something is watched working, Hide is unbuilt
rather than broken, and it should refuse by NAME immediately rather than
burn 15 s of the shared lane rediscovering a route already known to fail.

**4. A modal alert still refuses interaction.** Opening Mail raises its
"is this computer set up for Internet access" alert; the Mirror could not
answer it and it had to be dismissed on the machine. This is rung 4 of the
drive loop, unchanged, and it BLOCKS the application while it is up — so it
is also a queue problem.

**5. An act that legitimately did nothing still costs 15 s.** Driving
`finderOpen "Date & Time"` against the DESKTOP container (where it does not
live) correctly opened nothing — and still burned the full timeout rather
than the Finder answering "no such item". A null result that costs the same
as a hung one teaches a caller nothing.

Explicitly NOT in this slice: window contents. Michelle's drive confirms
they are unchanged, which is expected — that is slices 5/6's territory and
no MCP work was ever going to move it.

### Slice 6 — close the gaps, metal-first · **NOT STARTED**

**Re-ordered 2026-08-05 by what the corpus actually said.** The honesty bullet
this slice used to open with is void: the producer ALREADY emits
`knowledge: unknown` and `role: unknown` for all 190 undetermined items. The
honesty is there and the coverage is not, so there is no cheap first move of
that kind.

**Step one is a measurement, not a build: split the 190.** An undetermined
kind means the walk could not resolve the control's defProc, and that is two
populations wearing one number:

- a **standard Toolbox CDEF** — button family, scrollbar, popup — whose
  resource ID sits in the control record and is documented. A known ID means
  we already had the answer and dropped it: a producer bug fixed by reading a
  field, with no drawing involved.
- a **genuinely app-owned CDEF**, where nothing static says anything and the
  drawing is the only evidence there will ever be.

Reading those IDs is a lookup rather than an inference, it is small, and it
probably collapses a large fraction of the 190 — which decides how much of
everything below is even needed. Do it before building anything.

**Then split the remainder by GOAL, because mixing the two is where this turns
dishonest:**

- **To RENDER a custom control, do not classify it — replay its ops.** That is
  what P3 is for, and a faithful replay cannot be wrong about what the thing
  looks like, where a classification can.
- **To DRIVE one, classification is unavoidable** — this is a checkbox, its hit
  region is here, its part code is that — and it is heuristic pattern-matching
  over draw ops. A widget guessed from a `FrameRect` and a `DrawString` is
  exactly the plausible lie rung 5's honesty bar forbids. Drawing a control
  correctly and declining to click it is a coherent product state; drawing a
  guess is not.

So classification is owed only where drivability is owed, which is a far
smaller set than 190.

Remaining work, by the ledger's classes:

- **Readable structures the producer does not walk** — `ListRec` cells (the
  Monitors resolution list is a known `listBox` with no cells and the text
  "Selected value unavailable"), `TERec` bodies, popup menu contents.
  Ordinary work: read a documented structure, fill a field the IR already
  has.
- **Unclassifiable by any static read** — refuse to drive, by name, and render
  from the replayed ops.
- **Custom-drawn and composited art** — deferred as PIXELS, and stays
  deferred. But the event tail changes what "cannot be read" means for some
  of it: a custom control that draws its own frame and label emits drawing
  ops naming both, and text drawn with `DrawString` is content even when
  nothing retained it. Rung 5 still holds QuickTime Player to the honesty
  bar; the bar just moves once the tail exists.

**Two oracles, two jobs, and the split is load-bearing.** QEMU memory reading
DISCOVERS layout — one-off, when nobody yet knows what a structure looks like
on this OS version, or whether one exists at all. That "does a structure exist
here" question is what decides between a walk and an honest refusal, and it is
the highest-value thing the emulator can answer. A guest-side probe SURVEYS
coverage — what the resident found, interpreted, and could not read — over the
wire, on metal, with no emulator involved. Surveying must not depend on QEMU or
the coverage question becomes unanswerable on the PowerBook, which is the one
machine where it matters.

And the oracle is an instrument, so it is the first suspect: a two-byte width
error in a probe's own filter once produced two opposite wrong conclusions from
one bug in this project's history. Cross-check anything it reads against the
guest's own view of the same window before an offset reaches a walk.

## What the first human drive taught (2026-08-05)

Michelle drove the Mirror by hand for eight minutes against the slice-4 build,
and the instruments were read afterwards instead of the screen being watched.
Findings, and where each one went:

- **`actmeta` earned its keep on its first outing, against me.** I called the
  "anchor plane is absent or not armed" refusals false negatives, from a
  lifecycle read taken AFTER the drive (`requested 15 active 15`). The
  `actmeta` lines beside the acts said `requested 7 active 7` — the
  interaction bit really was clear while she drove. A measurement without its
  premise recorded is a confident, meaningless number, and the premise line
  is what caught the error. Corollary: some of the 2026-08-04 PowerBook
  diagnosis likely needs re-reading against its own premise lines, which that
  log does not have.
- **The interaction plane has never published** — generation 0 against
  structure at 613 025 and content at 1 522 260, while every host toggle
  reads on. Every `settlement=unknown` in the drive is downstream of it.
  Dispatched as its own task; guest/resident-side, too large to fold in.
- **The visibility census lands on 0 of 8 applications**, so
  `processVisibility` postconditions are STRUCTURALLY unable to settle —
  the Workshop hid on the machine and the Mirror put it back. Hypothesis:
  the `sequence == replica.lastSequence` guard loses a race against the
  ~2.2 s cycle. Dispatched as its own task.
- **Retries stack behind corpses, measured from real hands**: three attempts
  at one close box — `timedOut` holding the lane 15 s, the second click
  waiting 8 615 ms behind it, the third confirming from evidence 19 s later.
  The clocks made the friction attributable; nothing to fix in this arc
  beyond what the queue display already shows.
- **The instrument had the producer's blind spot.** All 60 cycles measured
  `elements 0` against a desktop showing seventeen icons: the snapshot
  projection and the cycle counter both skipped `window.items`. Fixed in the
  arc (`c596261`), with the general lesson: a meter built from the same
  model it measures cannot see what the model omits — which is the argument
  for slice 5's three-way pairing being independent captures.
- **Decoding nothing costs ~315 ms** (median across 60 zero-element cycles;
  request median 92 ms, idle 783 ms). A fixed host-side term, separable from
  the Mac entirely, and the first concrete optimisation target the cycle
  clocks have produced. Belongs to the performance thread, not this arc.
- **Selection timing is wrong at the input layer**: a real Mac selects on
  mouse DOWN; the Mirror acts on mouse up. Mildly wrong today, load-bearing
  for click-and-drag. Dispatched as its own task.

## Ordering, and why it is not the obvious one

Metrics first because they are the point of a headless round and cost least.
The snapshot before the executor because it is what makes MCP a *mirror* rather
than a summary, and because it surfaces the ref gap the executor needs closed.
The rows last because every one of them is a day's work on the current split
surface and an hour once the executor is shared.

Slices 5 and 6 come after all of that and are a different KIND of work: 1–4
make the two faces one product, and 5–6 widen what either face can see at all.
They are appended rather than woven in because they depend on the whole of
1–4 — the corpus's provenance comes from slice 4's read rows, its structure
comes from slice 2's surfaces, and opening ten panels to capture them is
slice 3's drive path doing the opening.

## What would make this arc wrong

- Any slice that gives MCP its own way to reach the guest. Then the two faces
  diverge again and every measurement taken here describes the wrong product.
- Settling a mutation on dispatch to make the headless path feel responsive.
- Treating the emulator's numbers as metal's. Behaviour transferred from
  emulator to metal on 2026-08-04; timing did not, and one metal run is one
  machine's anecdote until it is repeated
  ([mirror-measurement-method.md](../mirror-measurement-method.md), rules 1–2).

## Verification

Each slice: focused host tests, watched fail by mutation, plus one headless
call proving the row answers live. Slice 3 additionally needs a **paired**
check — the same mutation driven once by hand through the Mirror and once
through MCP, producing the same operation record and the same settlement.
That pairing is the proof the two faces really are one implementation, and it
is the only test in this arc that cannot be automated away.
