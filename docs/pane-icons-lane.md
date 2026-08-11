<!-- now-doc-provenance: generated reviewed=false -->

# The Mirror pane: icons and windows you can click

Branch `audit/pane-icons`, 2026-08-01. Closes the audit's rows **2** (desktop
icons are click targets) and **4** (window ops from the pane), and carries row
**6**'s refresh-after-act because an act you cannot see is the same as no act.

**Nothing here has run against a Macintosh.** There is no emulator and no
hardware on this bench: what follows *builds*, and its host-side decisions are
unit-tested. Every claim about what a real Finder or a real application does
with these requests is upstream's measurement, cited, not re-made here.

---

## What the pane now does

| Gesture | Target | What leaves |
|---|---|---|
| click | desktop icon | `finderSelect(item:container: .desktop)` |
| double click | desktop icon | `finderOpen(…)` |
| click / double click | folder-window icon | the same, `container: .window(title:)` |
| click | close box | `winact close` |
| click | zoom box | `winact zoom` |
| drag | title bar | `winact move`, as the new **content origin** |
| drag | grow box | `winact resize`, as the new **content size** |
| click | bare desktop | nothing, and the page says a coordinate names nothing |

The icon rules are upstream's, ported exactly and asserted in
`MirrorPaneIconsTests`: hit **by name**, carrying the icon's own reported
position; the click resolves to the icon's **centre** rather than to where the
pointer landed; the **label strip** is part of the target; **unplaced and
invisible** items are not targets at all; a **window over an icon** wins the
point.

Selection is presented the way the Finder presents it — darkened *through* the
icon's own pixels with `.multiply`, black label patch, white text — because the
guest's real selection lives only in Finder's pixels and is reported nowhere.
It is feedback for a gesture, **not a reading of the machine**, and the model
says so where it is stored. A selection made by the person sitting at the
Macintosh does not appear here.

One divergence from upstream's renderer, deliberately: an **invisible** desktop
or folder item is no longer drawn. Upstream drew it and nothing could be
clicked anyway; here the hit tester refuses it, and an icon drawn in a pane
that silently is not a target reads as a broken click plane rather than as a
hidden file.

### Act, settle, look once

A dispatched act forgets the probe's baseline (as before) **and** asks for one
scene after `WatchPolicy.settleAfterAct`. The wait is a **guess** and is marked
as one in the source: nothing measures how long a classic application takes to
reach its event loop and redraw. An under-guess is bounded by the refresh
ceiling; a fetch already in flight declines rather than queueing.

This is also what surfaces a **save alert on a dirty close**. `winact close` is
destructive by the contract's own words, an application may put up a dialog
nothing on this wire can answer, and the pane does not suppress or pre-empt it
— the next scene draws it. That is the whole handling: it is the application's
question to its own user.

---

## The refusals, in writing

These are the paths that cannot address their target. Each says which half is
missing, in the sentence the person reads.

**1. There is no `script` lane on this host, so an icon click reaches
nothing.** The vocabulary is right and the route is the ruled one: NOW declares
no positional click on purpose, and the actuation the ruling names is the
Finder's own `select item "X" of window "Y"` through `script`
(`docs/input-plane-decisions.md` §2; `mouseloc`'s contract row). The guest
serves `script`. What does not exist is the host's local operation for it —
`AgentIntegrationLocalClient` carries the five acts and no script op.

I did **not** substitute something that does exist, and the argument is worth
recording because `reveal` looks like the answer: it selects an item in the
guest's own Finder by name. It resolves a bare name by a **whole-volume catalog
search** and would happily select an identically-named item somewhere else
entirely, and a scene's desktop item **carries no path** to make that exact
(`Scene.DesktopItem` has name, kind, type, creator, position, and no path). A
select that lands on the wrong file is worse than a refusal, and it would be
invisible.

Two ways to close it, both outside this lane: a `script` op on the local
protocol (small, and the driver's switch arm is already the only place to
change), or a `path` on the scene's desktop items, which would also make
`reveal` exact.

**2. There is no `elements` lane, so a window act has no reference to send.**
`winact` is addressed by an opaque `now-window-…` that only an observation
mints, and this host has no observation lane: `ObserveElementsProjection`
exists, `AgentIntegrationLocalClient.observeElements` does not.

Here I *did* build the seam, because the ask is cheap and page-local:
`MirrorWindowResolver` sends the `elements` command on the control plane and
reads three fields of the reply, exactly as `MirrorSceneProbe` sends `axsnap`.
When the observe lane lands, this should become a caller of it — the decode in
that file is a page-local reader, not a second definition of `x-axTree`.

The resolver refuses in four ways rather than guessing, and the refusals are
the point: a resolution that succeeds at the **wrong** window closes the
neighbouring document, silently. It refuses an unparseable process serial
without asking the Mac anything; it forwards a machine that will not be
observed; it refuses a title the walk did not see; and it refuses an ambiguous
identity, naming the count. It can never resolve to "the frontmost window" —
that value cannot be spelled in this vocabulary.

The occurrence arithmetic is the load-bearing part of that match, and it is
copied from the guest rather than invented: a window's occurrence is its index
among the same-titled windows of the same process, in window-chain order
(`now-guest-ppc/src/observe/obsmint.c`, `locate_window`). Counting any other
way would mint a number that resolves to a neighbour.

**3. Raising one window is not expressible.** A click on a background window's
title bar still maps to upstream's `qmpClick`, which reports itself unavailable
with the QMP sentence. `activate` fronts an **application**, not a window, and
never reorders same-app windows — substituting it would be this side deciding
the two acts are alike. There is no `winact select`. Owed, not faked.

**4. The windowshade box sends nothing.** `winact` has four actions and
collapse is not one of them. An act naming `zoom` for it would be a guess about
two different behaviours.

**5. A drag that begins anywhere but a title bar or a grow box is inert, and
says so.** Dragging an icon is the ordinary way to arrive there; NOW has no
verb that moves a Finder item, and silence would read as the Mac ignoring the
person.

**6. A gesture that leaves the drawing is refused, not clamped.** A drag whose
end lands in the letterbox reports the off-screen sentence rather than being
pinned to the nearest edge: a window moved to an invented place is worse than a
window not moved.

---

## What a person still has to judge

No test here can settle these, and the emulator is where they get settled:

- whether the settle interval is long enough that the scene after a click shows
  the click's effect rather than the state before it;
- whether the drag outline tracks closely enough to feel like DragWindow;
- whether the invert-style selection reads as *selected* on a real scene with
  real icon art, rather than as a rendering fault;
- whether a `winact close` on a dirty document actually produces the save
  dialog in the next scene, which is the row-4 acceptance a host cannot
  self-certify.

## Owed elsewhere

`MirrorActProjections`' note says the five act rows' `.appUI` face is
`notReached` because "the Mirror page passes it no gestures yet". As of this
branch the page passes gestures to `winact` through the driver. That row's face
is about the projected AGENT surface rather than about this pane, so the
declared data is left alone here — but the sentence is now half true and wants
a re-read by whoever owns the face parity table.

## Gate

`swift build` and `swift build --build-tests` are clean in this worktree. The
suite was **not run**: one `swift test` may run on this Mac at a time and this
lane was one of nine, so a local green would have been either a collision or a
false one. The `MirrorKitTests` assertions that changed with the route
(`DesktopHitTests`, `FinderItemsTests`, `HitActionTests`, `NoSecondWireTests`)
were edited with the reason written beside them, not deleted.
