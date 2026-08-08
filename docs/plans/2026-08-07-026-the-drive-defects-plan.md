# The drive defects — what Michelle found, and how to close it

**2026-08-07.** Michelle drove the round-9 and round-10 stacks and
reported fourteen symptoms. This is the plan for closing them. Evidence
and log correlation are in
[`the-drive-and-the-islands.md`](../the-drive-and-the-islands.md); this
is the work.

**Read [`docs/lane-context.md`](../lane-context.md) before starting.** It
is the standing rules and it is short.

## Status of the arc, so this is not re-derived

- `claude/024-integration-10` is the head. `main` is ~1,240 behind and
  has no `mirror/` tree — **never fork off main.**
- **Both census probes are fixed but unlanded**: `pccard` (crashed any
  machine without PC Card hardware — a Power Mac G4 has none, a PB1400c
  does) on `claude/024-census-crash`; `ata` (left `ataPBFlags` zero, so
  the ATA Manager never drove the data-in phase and left the device
  mid-command, corrupting the Shutdown Manager's final unmount write) on
  `claude/024-bake-volume-clean`.
- **The bake works again.** It had not, and that blocked every resident
  change.
- **`claude/024-items-arbitration` is in flight** on defect group A below.
- **Nothing here has been metal-verified.**

## What is NOT wrong, so nobody re-investigates it

- **The pixel islands were never active in NOW's host.** `now-host`
  constructs no `ScenePoller`, so `island` was always nil. They are
  removed and gated, but they explain **none** of these symptoms.
- **CarbonLib is installed and fine.** The "Please insert the disk:
  CarbonLib" alert is an unresolvable alias in Recent Applications from a
  `.smi` that was once mounted. NOW is a Carbon app; it launched.
- **The "Bitmap unavailable" hatches are the honest-unknown path working
  as designed** — the *loud* hatch is positive proof a drain happened and
  identity was unresolved. Their fix is asset resolution, not the plane.

## Group A — one mechanism, four symptoms *(in flight)*

**`win.items` does not arbitrate against the machine's ink.**
`SceneRenderer` has `semanticOwnsDisplay` for controls and
`dialogItemOwnsDisplay` for dialog items. There is no `itemsOwnDisplay`,
so a window with both draws both.

Closes: icons drawn twice (she can see the selected one underneath),
labels drawn twice, icons over list-view rows, and the decode cost —
**p99 3,152 ms, max 7,527 ms for 3 windows and 49 elements** while the
guest's own phase counters are in microseconds.

## Group B — the act plane has ONE request cell

Her log, nine times in ninety seconds: *"another act is already in
flight — this Mac's act plane has one request cell and it is taken.
Nothing was written."* **Interaction does not queue, it refuses.**

Closes: Finder windows slow to close, SimpleText slow to front, general
sluggishness under any rapid interaction.

**Also here, and distinct:** every `winact` reads
`dispatched-but-unconfirmed`. **Zero confirmations in 32 minutes.** That
is the KW-06 honesty fix behaving correctly — and it means the host never
learns an act landed, so **the pressed state's exit from *waiting* has no
input.** That is very likely why the pressed state never shows.

## Group C — the scrollbar thumb was never dispatched

Parts 20 and 21 (arrows) appear ~25 times in her log. Part **129**, the
indicator, appears **zero** times — `act_cmds.c:903` names it in a help
string and nothing sends it. `ctlact` is a click verb; a thumb needs
press-move-release, which is the drag vehicle's territory.

## Group D — reachability, each with a known wall

- **Extensions Manager's empty list.** Its rows live inside dialog item 4,
  a `userItem` spanning (14,65)-(458,265) that the application draws
  itself. No ControlRecord, no DITL row, so **no state exists to report by
  any current route.** Closing it needs the resident to find a list not
  behind a control *and* report per-row geometry — `NowPeekSemanticRecord`
  carries row/column/flags/text and **no rect**. That is
  `contract/peek_table.h` plus `ext/`, so a bake.
- **Icon drag: "nothing said where it is."** The `homeIsTrustworthy`
  refusal behaving correctly. The fix is upstream, in what makes a home
  trustworthy.
- **No I-beam over Sherlock's text field.** The cursor rule keys on
  `semanticKind == "editText"`; that field is almost certainly
  unclassified — the CDEF wall, where `GetControlVariant` cannot answer
  for a foreign control and both known routes are closed.
- **List rows selectable by icon, not by name.** Partly fixed already: the
  clickable field was bounded by every visible control, and column headers
  are wide-and-short like a bottom scroll bar, so the field computed to a
  bottom above its top. What remains is that `bounds of` answers the 16×16
  row icon and says nothing about where the text was drawn. **Do not widen
  to the Name column** — that guesses at the Finder's hit rule, and OS 9
  does not select from empty space after a short name.

## Group E — asset resolution

Control-panel icons, Set Time Zone's list, Sherlock's components — all
the loud hatch. Also **the MSIE TLS modal**, where the OK button is
briefly visible before a hatch replaces it, and clicking the hatch
dismisses it: that ordering suggests a race between the drawn button and
the unknown, and is worth its own look.

## Ordering, and the reason for it

**A → B → C → D/E.** A is one mechanism behind four symptoms and is
already moving. B is most of the felt sluggishness *and* probably the
pressed state. C needs the drag vehicle. D and E each need their own
mechanism and none of them blocks a drive.

**Anything touching `ext/` or `peek_table.h` owes a bake, and the shared
bake is Michelle's decision.**
