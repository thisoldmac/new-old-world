# How the planes compose into one picture

**Date:** 2026-08-06 · **Status:** the rule the renderer follows, written
down after the renderer started acquiring it by accident.

Five producers now feed one image, and each was designed against a
different problem. That is a strength — they fail independently, and a
window that loses one still shows the others — but it is only a strength
if the picture they make together is coherent. This page is the seam:
what each plane owns, where they legitimately overlap, and who wins.

It exists because the renderer was drifting. Rules like "an icon-sized
blit gets a stub" and "a control-sized blit is a plate" are correct, and
both were added *inside the replay*, where they read as arbitrary local
heuristics rather than as one plane's answer to another plane's silence.

## The producers, and the question each answers

| Plane | Question it answers | Shape of its truth |
|---|---|---|
| **P1 structure** | what windows and processes exist, and where | exact addresses, rects, z-order |
| **P2 semantics** | what the controls and items ARE | typed rows: control kind, value, list cells, Finder items |
| **P3 content** | what the application actually DREW | an ordered op stream per port |
| **P3′ worlds** (2026-08-06) | which offscreen worlds exist and when | worldborn/worlddied + the blitsrc join |
| **P4 act** | what can be TARGETED | refs and hit rects |

P3′ is deliberately written as a sub-plane rather than a fifth: it adds
no vocabulary of its own to the picture. Every world it hooks produces
ordinary P3 ops; its whole contribution is that ops which could never be
captured now are, and that the join knows where to put them. Treating it
as its own plane in the renderer would be the first wrong turn.

## The precedence, stated once

For any rectangle of a window's content, the renderer draws the most
specific truth available, in this order:

1. **P2 semantics**, where the control is typed AND carries its value.
   A typed checkbox with a title beats every drawing operation crossing
   its rect. This is `semanticOwnsDisplay`, and its exclusions matter:
   a container, a value-less popup or an empty list does NOT own its
   rectangle, because clipping it would erase the drawing that is the
   only thing anyone knows about the interior.
2. **P3 ops**, replayed in guest order. Text, primitives and state are
   the guest's own drawing and are authoritative wherever P2 is silent.
3. **P3 ops re-homed through a join**, which is the same authority one
   coordinate space removed. A joined composite REPLACES the blit that
   revealed it — the blit is not content, it is the pointer to content.
4. **A shaped placeholder**, when a blit cannot be joined. This is the
   layer that must be graded, and getting it wrong is what made the
   panels read as broken:
   - icon-sized → the extracted generic icon, at its true position;
   - control-sized → a Platinum plate, because a themed control drawn
     by CopyBits is chrome the host can draw, not missing data;
   - anything larger → the honest hatch, because at that size an
     unjoined blit really is content nobody reached.
5. **P1 chrome**, always: frame, title bar, grow box — and window
   FURNITURE such as scrollbars, which draw OVER display-owned content
   exactly as the Control Manager draws over application pixels on the
   real machine.

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

## A derived element that draws what the stream withheld (2026-08-07)

`DrawnCellGrid`'s move has a second instance, and it stretches the rule
in a direction worth naming.

Sherlock's grid derived SEMANTICS from drawing. `DrawnTabStrip` derives
**a procedure**: the Appearance Manager's tab, whose label box, three-row
top bevel, colours and title all arrive as ordinary ops and whose slanted
end caps do not. `PlatinumTab` draws the caps and the join where the
front tab interrupts the pane's frame line — and clips the label box OUT
before it fills anything, so the guest's own bevel and title survive.

Same rule, said again because it is the one that keeps this honest:
**draw only the difference between what P3 said and what you know.** The
method for finding that difference for the next element is
[deriving-a-drawn-procedure.md](deriving-a-drawn-procedure.md).

Two things it adds to this page:

- **A derived PROCEDURE is parameterised by the capture, not by a
  constant table.** Every colour and distance the tab drawer uses comes
  out of the stream it was derived from, including a metric nothing
  reports (`kThemeMetricLargeTabCapsWidth`, recovered as half the gap
  between neighbouring tabs). `Appearance.h`'s constants appear only as
  an acceptance test — a run of equal-height boxes is a common shape and
  calling it a tab strip needs a reason.
- **A one-pixel systematic error is invisible to a similarity score.**
  The replay stroked every 1px line centred on an integer coordinate, so
  each landed half in two rows; every frame and bevel in every window was
  two rows of mid grey where the machine draws one row of black. It
  survived the entire life of the renderer and was found by cropping
  thirty rows and printing them as characters. Grade an edge by WHERE it
  is, per row, not by how much of the picture matches.
