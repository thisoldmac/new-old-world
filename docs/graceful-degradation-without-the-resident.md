# What the Mirror should be without the resident

**Michelle, 2026-08-08.** A design, not a plan for now — she was explicit
that the tree is too broken to go down this road yet. Filed so it stops
competing for attention with the crash.

> the graceful degredation should be just showing the guest's desktop and
> rendering our own finder windows. to open applications on the guest's
> screen. a useful and coherent degredation. and a switch to turn on/off
> the extension in the guest's control panel.

## Why this is the right shape

Today, with the NOW Extension removed, the Mirror shows a frozen and
decaying picture and names nothing. That breaks the promise in
[resident-components.md](resident-components.md) that a resident
component is always optional and **the product degrades honestly without
it**.

The instinct that produces the current behaviour is to show as much as
possible of the full experience and let the missing parts go quiet. That
is precisely backwards, and this repo has a name for the result: the
quiet hatch, an unmarked stale image, the failure the provenance ladder
exists to prevent.

Michelle's version is not a reduced Mirror. It is a **different, complete
thing**: the guest's desktop, with our own Finder windows drawn on top,
used to launch applications on the guest's screen. Every pixel in it has
an honest source — the desktop is the guest's, the windows are ours and
say so — and it does something a person actually wants. Nothing on screen
is pretending to be a live capture of a foreign application's interior,
because nothing is being captured.

That satisfies the standing rule about where pixels may come from: the
guest's pixels are used only where they are ours to use, and everything
else is drawn host-side from assets we own.

## What it is made of

- **The guest's desktop**, which needs no resident.
- **Our own Finder windows**, rendered host-side from structure and
  semantics — both of which come from the application's walk, not the
  resident.
- **Launching applications on the guest's screen** as the thing this mode
  is *for*. Degraded mode is a usable product, not a waiting room.
- **A switch in the guest's control panel** to turn the extension on and
  off, so a person can move between the two modes deliberately instead of
  by dragging files out of the System Folder and rebooting — which is
  what tonight's bisect required.

## Two things this must not become

- **A full Mirror with holes in it.** If the resident is absent, do not
  show foreign interiors at all — not hatched, not stale, not last-known.
  The mode is defined by what it honestly has.
- **A silent fallback.** The switch between modes is a state a person can
  see and name. "No content plane, structure only" said out loud is the
  entire fix to today's dishonesty, and it is worth shipping even before
  the rest of this design exists.

## Two defects that are NOT this

Tonight's resident-less run also showed the render never updating and
degrading over time. Neither needs the resident, so both would be broken
with the extension installed too. They belong to the Mirror proper, not
to this mode, and fixing this design would hide rather than fix them.
See [mirror-crashes-now-on-metal.md](mirror-crashes-now-on-metal.md).

## Status

Design only. Not scheduled. The crash comes first — Michelle: *"runs on
metal is a bare minimum for landing main."*
