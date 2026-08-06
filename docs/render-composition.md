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

## What is still disjointed, and named rather than hidden

- The placeholder grading lives in `DisplayReplay` (MirrorKitUI) while
  the join lives in `NOWMirrorContentPlane` (Host). Both are correct
  where they are, but the *rule* they implement is this page, and there
  is no test that holds them to it together.
- The panels' field CONTENTS are still absent — Date & Time and Memory
  draw their values through CopyBits rather than DrawText, so a plate is
  the most this pipeline can honestly say about them today. Whether
  those values are reachable at all is unanswered.
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
