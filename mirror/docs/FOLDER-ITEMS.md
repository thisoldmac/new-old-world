# Finder folder windows, as a model

**Date:** 2026-07-31. **Status:** landed on `lane/h2-folder-icons`.
**Code of record:** `host/MirrorKit/Sources/MirrorKit/FinderItems.swift`,
`ScenePoller.attachWindowItems`, `HitTester.windowItem`,
`Serve.actOpenWindowItem`; the `script` verb in `guest/app/src/mirrorverbs.c`.

A folder window was the last surface in the mirror rendered as **pixels** — an
island of captured bytes. That is not only a look: pixels cannot be addressed.
An agent could see a file in a folder window and had no way to name it, which
is why `mirror.act.open`'s `windowItem` was specified on day one and never
implemented. It is implemented now.

## The correction: `position` is not `fdLocation`

The previous attempt read the icon position out of the HFS catalog
(`fdLocation`, via the `list` verb) and concluded the Finder "does not expose
live window-item positions via AppleScript". It does. The two sources are
different facts:

| | `fdLocation` (catalog) | `position of` (the Finder) |
|---|---|---|
| what it is | the **saved** icon grid | where the Finder has laid the icon out **now** |
| coordinate space | folder-local, saved | window-content-local, live |
| follows a scroll? | **no** | **yes** — measured, exactly |
| good for | remembering a layout | clicking |

Measured on mac99 / OS 9.1, 2026-07-31, folder `Macintosh HD:TimBotTu` in a
window with content rect (13,47)-(417,265):

- at rest, the two differed by a constant **(52, 25)**;
- after scrolling down 128 px (the vertical scrollbar's value moved −4 → 124),
  every `position` y moved by exactly **−128** and every `fdLocation` v did not
  move at all.

So `fdLocation` is not "a few pixels off". It is a different quantity, and it
is wrong by an unbounded amount the moment a window scrolls.

## What the Finder answers, and how each answer was checked

| Question | Answer | Check |
|---|---|---|
| `item of window i` | the folder's HFS path | resolves subfolders, disk roots, control panels |
| `position of` an item | live, window-content-local, scroll-compensated | see above |
| `bounds of` an item | `position … position + 32` | the icon box is 32×32 with its top-left at `position` |

An item's point on screen is therefore just:

```
screen = window content origin + position + (16, 16)
```

and **the oracle for that is not the arithmetic**. It is: click the computed
point, then ask the Finder which file is selected.

## The measurement

`tests/h2-trials.py`. Each trial clears the selection and confirms it is
empty, picks a target the previous trial did not use, then runs a **fresh
`MirrorApp` process** (`--act-window-item NAME`) that does its own poll,
hit-test and dispatch. The host computes the point; the harness never does that
arithmetic. The Finder's own `selection` is the oracle.

| Condition | Trials | Item selected was the item aimed at |
|---|---|---|
| window at rest | 20 | **20 / 20** |
| after scrolling 8 lines | 20 | **20 / 20** |
| **same code, positions taken from `fdLocation` instead** | 40 | **0 / 40** |

Run twice, the second time on the shipped build (after the refresh-caching fix
below): 40/40 both times.

### The agent-facing surface, separately

`tests/h2-serve-check.py`, because implementing `mirror.find` /
`mirror.act.open` and then measuring only the core beneath them is the kind of
half-truth this project keeps paying for. Live: `find {kind:"windowItem"}`
returned 15 items with 7 actionable and their type/creator; `act.open
{windowItem:"DevA"}` double-clicked it and DevA's window appeared in a freshly
polled scene; `act.open {windowItem:"no-such-file-xyz"}` was refused
`element_not_found`.

Two harness traps met on the way, both worth knowing:

- **The guest serves ONE connection.** Opening a second AppleScript client
  while MirrorApp holds its own reset the first, and a round of results was
  wrongly blamed on the act path.
- **`mirror.find` answers from the last scene it happens to hold**, with no age
  in the reply. It reported the pre-open window list and made a successful open
  look like a failure. The oracle has to be `mirror.scene` with `maxAgeMs: 0`.
  That `find` cannot say how stale it is looks like a real honesty gap, but it
  predates this lane and is left alone.

### A failure the cache could hold

Measured live: one busy-Finder script timeout marked the layout resolved
anyway, and that folder window then served **no items at all** for the rest of
the process's life — `find` returned 0 matches against a window full of icons.
The layout signature is now recorded only when the Finder actually answered.
Verified live; **not** covered by a unit test, because `ScenePoller` holds a
concrete `WireClient` and there is no seam to fail on demand.

The third row is the mutation that proves the fix: putting the old source back
collapsed the number to zero, and the run was repeated end to end. Its failure
mode is worth recording — the mutated build did not click the wrong file, it
**refused**, with `runner-next.log is at (1,192) … which the Finder has
scrolled out of view`. The clipping check and the re-hit-test caught a wrong
position before it became a wrong click.

## Design notes that are load-bearing

- **The chrome insets are derived, not written down.** The clickable icon
  field is bounded by the window's own scrollbar rects — the info bar ends
  where the vertical scrollbar begins. No phantom constants, and it tracks a
  guest whose chrome metrics we never measured.
- **An invisible item has no click point.** `FinderItems.clickPoint` returns
  nil for an icon scrolled out of the field, `find` reports
  `actionable: false`, and the act path refuses. Inventing a point for an icon
  the Finder is not showing is precisely how a click lands on the wrong file.
- **Positions are cached; the cache key includes scroll.** One `script` round
  trip through the Finder costs **1–2 s** (measured), far too much per poll.
  The snapshot is refreshed whenever any folder window's geometry *or scroll
  value* changes, and the act path forces a refresh before it aims: a cached
  position is fine to draw with and not fine to aim with.
- **Two windows with the same title get NO items** rather than each other's.
  A window name is the only key the Finder gives us here.
- **The island is now a fallback.** The renderer draws the model when a window
  has items and the poller stops capturing pixels for it — about a second a
  frame, on exactly the window islands were invented for.

## The IR

`windows[].items` re-entered **additively**: recorded in
`IRSchema.v1Additions`, still absent from `v1Frozen`, `IR.version` still `1`.
It was held out of the freeze because its values were known wrong, which is the
expensive half of a contract — see [IR-V1.md](IR-V1.md). `IRFreezeTests` went
red first (2 failures, both asserting items were off the wire); the assertions
were rewritten to state the new promise, and a new test pins all four clauses
of "additive".

## The guest gained a `script` verb

The host had been *calling* `script` since the desktop-disks work; the agent
had no such verb, so those requests returned `unknown_verb` and failed silently
into a `try?`. That is why mounted disks never appeared at their real Finder
coordinates either. The verb now exists, carrying the lab's hard-won OSA
lessons as facts (static scratch buffers, LF→CR before compiling, a `with
timeout` wrapper plus a yielding OSA active proc). PPC/CFM resolves the OSA
entry points through **AppleScriptLib**.

**The standing hazard is respected:** every script this feature sends is scoped
to a window the Finder is already showing (`window i`, `items of window i`).
None of them search. A whole-disk Finder search wedged a real machine for ~12
minutes (lab finding, 2026-07-05).

## What was NOT tested

- **Metal.** Emulator only, by the standing rule.
- **One folder, one window.** All 40 trials used `Macintosh HD:TimBotTu` (15
  items, 8 visible at a time) in a single window. A window in **list view**, a
  window with hundreds of items, and two windows open at once were not
  measured. List view is the notable gap: `position of` in a list view is
  either meaningless or different, and nothing here detects the view type yet.
- **The truncation cap.** `maxItemsPerWindow` is 60 and the `T|` marker is
  parsed and unit-tested, but no live folder exceeded it.
- **The item cache under a window MOVE.** The layout key covers it and the
  unit test pins it; a live move-then-click was not run.
- **Platinum fidelity.** A render-shot against the guest's own pixels agrees
  on which items, in which grid cells
  (`docs/render-2026-07-31-folder-items.png`). Whether it *looks* right is
  Michelle's call.

## Found and left alone

- **The info bar is not rendered.** The guest draws `15 items, 3.21 GB
  available` at the top of a folder window; the mirror draws the strip empty.
  The scene has no field for it, and adding one is another IR addition.
- **Icon art is generic.** `IconAtlas` keys off type/creator and folder
  windows now supply both, but custom icons (`tbt-runner`) still draw as the
  generic glyph.
- **`mirror.find` does not say how old its answer is.** It serves
  `lastScene ?? poll()`, so a caller cannot distinguish a fresh enumeration
  from a minute-old one. Everything else in the contract is careful about
  staleness; this is not.
- **`tools/stage-agent.py`'s `write` of `mirror.port` is not idempotent** — a
  re-stage onto a booted guest fails `exists: file exists`. Harmless (the port
  file is already correct) but it makes every agent redeploy look like a
  failure. `tests/h2-redeploy.py` works around it rather than changing a shared
  tool mid-fan-out.
