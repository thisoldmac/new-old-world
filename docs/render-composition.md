# How the planes compose into one picture

**Date:** 2026-08-07 · **Status:** the rule the renderer follows. Rewritten
around the provenance ladder (plan 018 slice 2); the history below the fold
is kept because every clause of the ladder was bought by one of its
incidents.

Five producers feed one image, and each was designed against a different
problem. That is a strength — they fail independently, and a window that
loses one still shows the others — but only if the picture they make
together is coherent. This page is the seam.

## The producers, and the question each answers

| Plane | Question it answers | Shape of its truth |
|---|---|---|
| **P1 structure** | what windows and processes exist, and where | exact addresses, rects, z-order |
| **P2 semantics** | what the controls and items ARE | typed rows: control kind, value, list cells, Finder items |
| **P3 content** | what the application actually DREW | an ordered op stream per port |
| **P3′ worlds** | which offscreen worlds exist and when | worldborn/worlddied + the blitsrc join |
| **P4 act** | what can be TARGETED | refs and hit rects |

P3′ is deliberately a sub-plane rather than a fifth: it adds no vocabulary
of its own. Every world it hooks produces ordinary P3 ops; its whole
contribution is that ops which could never be captured now are, and that the
join knows where to put them.

## THE LADDER — one owner per rectangle

Every rectangle gets **(source, epoch, confidence)** and one ordered rule
decides who draws. `MirrorKitUI.ProvenanceLadder` is the code; this is the
policy. Highest claim first:

| Rung | Claim | Evidence required |
|---|---|---|
| **1 — ink** | the machine drew this and we have the drawing | replayed P3 ops from the CURRENT epoch: text, primitives, and a composite that **joined** |
| **2 — semantics** | P2 carries enough to draw the whole rectangle | a typed control or DITL row that owns its display: a checkbox with a title, a popup with a value, a list with cells |
| **3 — named art** | something NAMED this rectangle | a DITL row typed `icon`; a control P2 typed. **By identity, never by size or shape** |
| **4 — the unknown** | nobody can account for it | nothing. Drawn by `UnknownVisual`, one style, everywhere |

Four things about that table are load-bearing and each cost something.

### Rung 1 beats rung 2, and that reverses the old rule

The precedence used to run the other way: P2 first, P3 where P2 was silent.
It was written when the only thing P3 could offer for a control was
"somebody blitted 14×14 here", and on 2026-08-06 it cost Date & Time its
date, its time, both group boxes and every field — twenty DITL rows silenced
the drawing that was the only thing anyone knew about those rectangles.

The reversal is safe because of what rung 1 excludes.

### An unjoined blit is NOT ink

A blit carries geometry and no pixels. Where it joined, it IS the machine's
drawing and outranks any description of it. Where it did not, it is not
evidence at all, and it drops to rung 3 or 4 — which is where the old
P2-first rule was really earning its keep.

That one sentence is what let five predicates collapse into one comparison.

### Rung 3 is addressed by IDENTITY, and that deleted a working feature

The replay used to answer any near-square blit between 12 and 36 points with
a generic DOCUMENT icon, and anything roughly control-shaped with a Platinum
plate. Sweep A priced the first: four wrong page icons in fifteen windows —
Mouse's three tracking pictures, Sherlock 2's nine channel buttons, the IE
TLS alert's stop sign, Set Time Zone's caution triangle — plus the Finder's
scroll arrows, which are 16×16 blits and were being painted as pages. Not
once did it fire on an actual document.

**An icon-sized blit of unknown identity is an unknown.** The plate
survives, and only where the semantic plane named the rectangle.

The numbers survive too, as `DisplayReplay.answeredInStreamOrder`, relabelled
as what they always were: a DRAW-ORDER rule. A small answer is drawn in
stream order so a composite's own opening erase does not wipe it; a
window-scale one is drawn ahead of everything so it cannot swallow text the
guest did report. `DrawnCellGridTests` caught the first wiring of rung 4
forgetting that, which is why the distinction is now spelled out in the
code.

### Two exclusions do most of the work in rung 3

- **A derived cell names nothing.** `DrawnCellGrid` derives Sherlock 2's
  channel grid from the drawing itself, so a cell's evidence IS the pixels:
  it can say where the cell is and which one is selected, and nothing about
  the art inside it.
- **A background names nothing.** `panel`, `placard`, `selectionBand`,
  `groupBox`, `userItem` routinely wrap most of a window. A background that
  claimed every blit inside it would be the `dialogItemOwnsDisplay` defect
  wearing a third hat.

### Furniture still draws last

P1 chrome — frame, title bar, grow box, and window FURNITURE such as
scrollbars — draws OVER display-owned content, exactly as the Control
Manager draws over application pixels on the real machine. That is not a
rung; it is the layer the ladder resolves underneath.

## ONE CLOCK — a frame is a (scene, content) pair

`Scene.Window.displayEpoch` (host-internal; frozen in `IRSchema` beside
`island` so it cannot reach the wire by accident) stamps the published ops
with the guest generation and display epoch they came off, the scene
sequence they settled against, and whether the guest has moved past them.

Three rules follow.

- **A frame is ONE repaint pass.** `displayEpoch` advances once per ARM and
  never per repaint, so a drain spanning several front/back cycles arrives
  as one identity carrying successive repaints end to end — and a later
  pass's window-spanning op lands on top of an earlier pass's content. The
  Sound panel's nine list rows are all present in its three-pass capture and
  painted over. `NOWMirrorContentPlane.lastRepaintPass` publishes the last
  pass alone, with the drawing state it inherited re-emitted in front of it.

  **An opener must REPLACE pixels.** A composite blit, or a paint/fill/erase
  covering the window. A FRAME does not: Date & Time closes each of its
  eleven passes by framing its own window rect, and cutting there published
  one rectangle outline and threw the panel away. Where an application's
  passes are separated by nothing destructive, this refuses to cut at all —
  a boundary we cannot prove is not a boundary.

- **A dead world retires the composite it built.** `worlddied` released the
  held source ops and said nothing to the window they had already been
  spliced into. The Finder disposes and rebuilds its interior GWorld on
  every view switch (it imports `NewGWorld`/`DisposeGWorld` and no
  `UpdateGWorld`), so that is exactly "the old view still drawn under the
  new one". Lineage is tracked through nested joins.

- **Superseded ink stops speaking for the window.** It is still the last
  coherent frame and is still drawn; what it loses is rung 1, so a semantic
  row may answer instead of being silenced by pixels describing a view that
  is gone.

### The degradation rule, which is the whole reason this is not a deadlock

**Coherence gating applies only to windows with a live P3 stream.** Content
is absent by design far more often than it is late — record mode off, an
application never armed, a window with no plane. A window with
`displayEpoch == nil` renders its semantics NOW, honest gaps and all.
"Hold the last coherent frame" must never become "hold forever waiting for
content that is not coming"; that would be a worse instability than the
flicker the gating exists to kill. Same family as "a resident component is
always optional".

### What `baseComplete` is not

Sweep A named `baseComplete == false` in every snapshot across ten minutes
as the strongest live lead. It is not a frame-assembly signal.
`MirrorReplicaReducer` requires every OBSERVED process's window coverage to
be `complete`, and the guest's walk is front-scoped — six background
processes report `ax_oracle_not_found` and coverage `unavailable /
not-observed` in sweep A's own scene JSON. It can therefore never be true
while the walk is scoped, which is always. Chased and closed offline; no
render change came from it.

## The desktop

`ppat` 16 is a shipped DEFAULT, not a setting: under Appearance the desktop
is chosen in a control panel that writes neither the System file nor a theme
file, so the System resource sits at its factory value forever while the
screen shows something else. Tiling it was wrong twice — wrong art, and
tiled where the machine draws a picture once at the origin.

`DesktopPattern.answer(screen:)` reads the pack manifest's `desktop` key:
`picture` at exactly the screen size is drawn once, unscaled; a named
`pattern` with art in the pack is tiled; **everything else is the marked
unknown**, including a picture whose size is not the screen's, because OS 9
ships desktop pictures at three sizes and the alignment field that would say
what to do is unreadable offline. A plausible wrong purple is what rule 1
forbids, on the largest rectangle in the picture.

Limit carried rather than hidden: the manifest answer is true for a guest
booted from the image the pack came off and not changed since. Only
`GetTheme` with `kThemeDesktopPictureNameTag` on a running guest closes that
gap (CarbonLib 1.0+, inside our floor; `LMGetDeskCPat` is not available in
Carbon at all). It is not closed today.

## The owner map

`DisplayReplay.Coverage` records the ladder's decision per rectangle, in
draw order, as a by-product of the render rather than a second traversal —
because a parallel traversal reaching the same answers by a different route
is how two halves of one rule drift apart, and this file's own history is
the argument. It is opt-in: a caller that passes no `Coverage` pays nothing.

It exists because "the render was stable" and "the render was stable AND
every rectangle had the same owner both times" are different claims, and
only the second is what plan 018 promised.

## What is still disjointed, and named rather than hidden

- **The Finder's interior is still a gap when its world is not hooked.** The
  Finder composites offscreen and blits the whole interior in one op. When
  the world is hooked at birth the blit joins and the interior renders —
  `qdtrace-drain-blitsrc-finder` holds that case. When the world was born
  before arming, nothing names the blit, no ops were held, the scene carries
  no `finderItems`, and the honest answer is one marked rectangle. That is a
  CAPTURE gap, and the ladder's contribution is that it can now be stated
  rather than guessed at.
- **Truncating to the last pass drops what that pass did not repaint.** The
  Finder's last pass is `bits [0,0,404,203]`, which does not cover the
  horizontal scrollbar strip an earlier pass drew — so that strip is lost
  rather than stale. Keeping earlier ops the opener does not cover is
  arguable and was not built: it is a compositing guess, and this arc's
  whole rule is that a guess has no rung.
- **The Monitors panel emits nothing on its own window port.** Seventeen
  records, all on an offscreen port that never reaches the window, twice.
  There is no ink for the ladder to rank, its eighteen controls are all
  untyped, and eleven of fifteen DITL rows are too. A zero that survives the
  ladder, and capture-side.
- **Icon identity.** A composite's icons arrive as bits with no identity
  while their labels arrive as text. `PlotIconSuite`/`IconRef` interception
  is the standing item; until it lands, rung 3 can only be reached through
  the semantic plane.
- **The system font is a substitution.** Font id 0 is the system font, which
  under Appearance on 8.5+ is Charcoal; where the pack carries no Charcoal
  strike, Chicago answers and is wider, so an application's own clip cuts
  the last glyph. A pack gap, not a renderer bug.

---

# The history this page was written from

Everything below is kept verbatim from the pre-ladder page. Each section is
an incident that one clause above exists because of; none of it is current
policy.

## Where they legitimately overlap, and why that is not a bug

- **P2 and P3 both describe a control.** P2 says "checkbox, on"; P3 says
  "somebody blitted 14×14 here". Both are true. P2 wins where it is
  specific; where it only knows a rectangle exists, P3's drawing is the
  better answer.
- **P3 and P3′ both describe a composite.** The window port's blit and
  the offscreen world's ops are two halves of one repaint. The join is
  the rule that they are never drawn twice: whichever is placed, the
  other is dropped.
- **P2 and P4 share rects.** Deliberately: what you can see you can
  name. A drawn element without a ref is a defect, not an overlap.

## The rule for anyone adding a placeholder

A placeholder is a CLAIM about the machine, and the claim must be no
stronger than the evidence:

- "This is missing" is only honest for content nobody could reach.
- "This is a control" is honest for a control-shaped blit, and drawing
  it as an untyped plate says exactly that and no more.
- Never type a placeholder more precisely than the stream allows —
  field-or-button is P2's to know, and where P2 knows it, P2 draws it.
- **A placeholder never paints over content another plane already
  drew.** "Visual unavailable" over pixels the replay has just put down
  is not a weak claim, it is a false one: the visual was available and
  is underneath.

That fourth rule was added on 2026-08-06 after a screenshot of the live
host, and the reason it took a screenshot to find is worth keeping. The
replay reported ONE Bool for a whole window — "something was drawn" —
so no caller could ask about a rectangle, and the DITL placeholder
branch had no way to know it was covering anything. `DisplayReplay`
now collects `Coverage`: the rectangles it actually inked.

**An erase is not ink**, and that is the load-bearing half. A composite
repaint opens with a full-window erase, so counting erases would mark
every rectangle of every window as covered and silence every
placeholder everywhere — the same defect inverted, and harder to see.
Only operations that add something a person can look at are recorded.
The replay's own unavailable-bitmap marker counts as covered: it has
already said the honest thing about that rectangle and a second hatch
states nothing new.

### The two gates a rectangle passes, and why they are not one gate

They are separate questions and conflating them cost this project both
of its 2026-08-06 render defects:

1. **May this row SILENCE P3 underneath it?** Controls have always
   answered through `semanticOwnsDisplay`. Dialog items had no
   equivalent at all, so every visible DITL row excluded the drawing
   beneath it whether or not the host drew anything in its place — Date
   & Time's twenty rows took its date, its time, both group boxes and
   every field. `dialogItemOwnsDisplay` is the missing half. `panel`,
   `placard` and `selectionBand` are deliberately excluded from it:
   they are backgrounds, they routinely wrap most of a dialog, and a
   background that swallowed every op inside it would be this defect
   wearing a different hat.
2. **May this row DRAW over P3 on top of it?** Answered by `Coverage`,
   above.

A row can legitimately answer yes to one and no to the other. A DITL
row typed `icon` is the example: the guest has said an icon is there
and named it, so the generic hatch is a false claim (rule 4) — but the
stub the host draws for it is weaker than the guest's own art, so it
yields wherever P3 carried that art. Fifteen of NOW's own Workshop
sidebar rows rendered as fifteen hatches until this was separated.

## What is still disjointed, and named rather than hidden

- The placeholder grading lives in `DisplayReplay` (MirrorKitUI) while
  the join lives in `NOWMirrorContentPlane` (Host). Both are correct
  where they are, but the *rule* they implement is this page, and there
  is no test that holds them to it together.
- The panels' field CONTENTS are still absent — Date & Time and Memory
  draw their values through CopyBits rather than DrawText, so a plate is
  the most this pipeline can honestly say about them today. Whether
  those values are reachable at all is unanswered.

  **Answered 2026-08-06, and it was never the pipeline.** With the
  NewGWorld trap patch those values DO cross — the drain carries the
  date, the time and every field as ordinary text ops — and the renderer
  was throwing them away at the last step, under the two gates above.
  The paragraph stood for a day as a statement about the machine when it
  was a statement about our own drawing order. When a plane looks silent,
  check what the renderer did with it before concluding the data is not
  there.

- **The system font is a substitution, and the guest's own clip exposes
  it.** Font id 0 means "the system font", which under the Appearance
  Manager on Mac OS 8.5+ is **Charcoal**; the pack carries no Charcoal
  strike, so `DisplayReplay.strike` answers Chicago, which is wider.
  Where the application clips its own text — Date & Time sets
  `clip [40,195,210,217]` around a group-box title and then draws
  "Use a Network Time Server" — the extra width pushes the last glyph
  past the guest's own clip and the mirror renders "…Time Serve". The
  machine's pixels have the whole word. It is a pack gap, not a renderer
  bug, and the fix is an extractor run for Charcoal.
## P2 derived from P3's own evidence (2026-08-06, later)

Sherlock's channel grid was the first case where one plane could answer
another's silence with SEMANTICS rather than with a shaped placeholder,
and the decision it forced is worth stating as a rule.

The grid is derivable from the drawing alone — cells, hit rects, and
which one is selected — and the replay is where it would have been
easiest to put. That would have been the drift this page exists to stop:
a grid with hit rects and a selected index says what the region IS, which
is P2's sentence, not P3's. So `MirrorKit.DrawnCellGrid` derives it in
the renderer-free core, `NOWMirrorContentPlane` attaches the cells beside
the display they were derived from, and the renderer sees ordinary typed
controls. `HitTester` picks them up for free, which is the point: what
you can see you can name.

Two rules came out of doing it, and both generalise:

- **A derived control is marked as derived and claims no action.** Its
  provenance is `drawing-derivation`, it carries no `action`, so
  `authorizesAction` is false and no act plane can press it by
  reference. The mirror can say where the cell is and that it is
  selected; it cannot say what pressing it does, and the type system
  says so rather than a comment.
- **It draws OVER the display, never instead of it.** The evidence for a
  derived control IS the drawing beneath it, so `semanticOwnsDisplay`
  stays false and it joins the scrollbars in `isWindowFurniture`. It
  paints frames and the selection — the two facts P3 could not state —
  and leaves the cell's own art and its icon intact. A derived control
  that clipped its own evidence would be erasing the reason to believe
  it.

The rule for anyone deriving the next one: **draw only the difference
between what P3 said and what you know.**

## What is still disjointed here

- The channel ICONS are generic stubs. Each is its own offscreen world
  with a stable per-session port identity, but the pixels come from
  resources by a route the bottlenecks do not show, so the cells are
  titleless and their icons are placeholders. That is the standing
  icon-identity item, not a gap in the derivation.

## Drawing against our own canvas, and knowing when a box is a guess (2026-08-06, later)

Two changes to the replay landed together because they look like the
same defect — an interior the mirror does not draw right — and are
opposite in kind. Naming that difference is why they are on this page.

**Invert was OURS.** `DisplayReplay` skipped GrafVerb 3 for years under
the note "invert needs destination pixels we do not carry", and that was
true of a renderer whose job was to place a pixel island. It stopped
being true the moment the host started compositing its own canvas: the
pixels under an invert are pixels this replay just drew, so the
operation is a difference blend against the layer. Nothing about the
contract had to change; the note had simply outlived its renderer.

The generalisable part: **a deferral written against one architecture is
a claim with an expiry date**, and nothing expires it automatically. The
sentence "we do not carry those pixels" was load-bearing and stale, and
the only thing that found it was reading the deferred-op counter.

**Regions were THEIRS**, and the honest move was to say so rather than
to draw better. The contract sends a region's bounding box and no shape,
so a rectangle was the only thing available — and the mirror had no way
to tell a rectangular region (where the box is exact) from an irregular
one (where it is a guess). Sending the shape was refused on measured
grounds: regions are unbounded, the ring is the limit. So the guest
sends a discriminator — the region's own `rgnSize`, in a payload field
that was already there and already zero — and the renderer's pixels do
not change at all. What changes is that the deferred-op counter can now
separate exact from approximate from never-asked.

**The rule this leaves behind:** when a plane cannot draw something, ask
first whether the drawing is unavailable or merely unmeasured. If it is
unmeasured, the cheapest true thing to add is usually not the data — it
is the one number that says whether the approximation is right. Paint
the doubt only where a capture exists to grade it against; the replay's
worst habits all came from placeholders graded against nothing.
