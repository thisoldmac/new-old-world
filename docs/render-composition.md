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
- Sherlock's channel grid is derivable (geometry, hit rects, selection
  — see open-issues.md) but nothing consumes that derivation yet: those
  cells still render as generic art rather than as the typed, targetable
  grid the measurement says they are. That is a P2 opportunity, and
  putting it in the replay would be exactly the drift this page exists
  to stop.
