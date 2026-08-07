# Everything the Mirror module shows and does

This exists because a layout was designed without it. Three embedded-Mirror
candidates were rendered and reviewed on 2026-08-07 and the reviewer's
verdict was that the agent "didn't account for the actual content like the
event stream and the additional settings" — which was true, and was
possible because nobody had written down what the content *is*.

So: every control, every readout, every stream, every setting, grouped by
**what a person does with it** rather than by which subsystem it came
from. Grouping by subsystem is what made the first embedded version read
as a dump.

A row marked **absent** exists in the model and has no way to reach a
person. Those are the ones worth arguing about.

## Actions — a person does this

| | where | notes |
|---|---|---|
| Start / Stop the poll | toolbar | disabled when no Mac can be captured |
| Attach / Detach | toolbar | both directions go through `NOWMirrorWindow` |
| Show/hide the inspector | toolbar | persisted |
| Refresh the resident lifecycle | inspector header | |
| Cancel pending acts | `LiveMirrorView` status overlay | only drawn while the lane holds something |
| Click, double-click, drag, type | on the picture | the product |
| **Look once, with a content join** | **absent** | the pre-embed page's "Look Now / Look Again" — the only caller that joined the content plane on demand. There is now no way to ask for a scene without running the poll. |
| **Export evidence** | **absent** | `MirrorEvidenceExporter` writes a correlated PNG + projection and nothing invokes it |
| **Save a render screenshot** | **absent** | the standalone `MirrorApp` has the menu item; the module has none |
| **Open a recorded scene** | **absent** | `fileImporter` + provenance, retired with the old page |
| **Clear the scene** | **absent** | |

## Settings — a person sets this, and it is remembered

| | where | key |
|---|---|---|
| Zoom stop (Fit / 50 / 100 / 200 / 400 %) | toolbar `Picker(.menu)`; a second segmented copy in the detached window | `mirrorZoom` |
| Inspector shown | toolbar toggle | `mirrorInspectorShown` |
| Detached | toolbar button | `mirrorDetached` |
| Wants running | implied by Start/Stop | `mirrorWantsRunning` |
| **Plane policy**, per machine × plane | inspector Planes card | `mirror.policy.<machine>.<plane>` |

Plane policy is **the only true setting the module has** — the only switch
that changes what the other Macintosh is asked to do. Everything else on
this list is about this Mac's screen.

**And that is why there is no settings sheet.** A draft put the switches
in one and left the plane states in the inspector; it was rejected because
separated, "on, and the Mac is not sending it" becomes a correlation a
person has to perform across two surfaces. The switch and the state it
explains are one row, in the Planes card. A sheet holding nothing but a
machine name would have been a container with a heading in it.

Retired and **gated against return** by
`tools/mirror-gate-tests/test_legacy_mirror_retirement.py`: the agent port,
the QMP socket path, the MirrorApp path and "build from source before
launching". They are not missing; they are deliberately gone.

## Live readouts — these change while a person watches

| | where |
|---|---|
| The picture | the pane |
| Which Mac, and the run dot | toolbar |
| Ambient line + what is under the pointer | `LiveMirrorView` overlay |
| Keyboard ownership ("click to type" / "keyboard ↦") | same overlay, only while sharing a window |
| Lane depth ("1 in flight, 2 waiting") | Acts card / event drawer header |
| Asset-pack banner (procedural stand-ins) | overlay, while true |
| **Scene age ("scene from … ago")** | **absent** — nothing dates the picture |
| **Provenance banner (live vs replay)** | **absent** on the host side |

## The event stream — what happened, in order

| stream | capacity | shown |
|---|---|---|
| Acts (`MirrorActTimeline`) | 32 | *was* the last **8** as two-line cards; now every one of them, one row each, in the event drawer |
| Scene cycles (`MirrorCycleTimeline`) | 24 | the **latest of each of 4 walk kinds** in the inspector (the only like-for-like comparison the data supports), and all of them in time order in the drawer behind its filter |
| Operation journal (`MirrorOperationJournal`) | 128 | **nothing** — MCP only |
| Settlement evidence (`MirrorSettlementTracker`) | — | **nothing** |
| `acts.log` on disk | unbounded | **no viewer** |

Two things follow, and both are why "the event stream" was the missing
half of the layout question.

- **Acts and cycles are one history, not two summaries.** Displayed as
  cards they answer "what is the latest of each", which is the wrong
  question during a drive: an act that waited waited *behind* something.
- **The journal is not a third stream.** It is the same operations the act
  clocks are derived from, projected for MCP. Surfacing it would be the
  same events twice. Its one unique field is `reason`, which belongs on the
  act row.

## Diagnostics — a person looks this up when something is wrong

| | where |
|---|---|
| Resident lifecycle, version, plane bits, build fingerprint | inspector |
| Per-plane state, purpose, format, generation, explanation | inspector |
| `NOWBASE` cycle baseline lines | inspector, selectable |
| **Window / program / menu counts, scene IR version, coverage claims, errors the Mac noted** | **was absent** — the pre-embed footer; restored as `MirrorSceneFactsCard` |
| **`contentNote` / `refusalNote` / `liveNote`** | **absent** — three captions for the exact failures the content plane still has |

The scene facts matter more here than the equivalent would in most
products: **a sparse scene is normal.** A window drawn as empty chrome is
the expected picture when the guest reports no QuickDraw content, and
without a count beside it a person cannot tell that from a rendering
failure.

## What is absent — capabilities, not layout

These exist in the model and can reach nobody. **An inventory that lists
what exists and stays silent about what does not is half an inventory**,
and this list is the half that steers the next arc rather than this one.
None of it is a container problem; putting a drawer around a thing that
does not exist would not create it.

**Actions with no way in:**

- **Fetch one scene on demand, with a content join.** The pre-embed page's
  "Look Now / Look Again" was the only caller that joined the content
  plane because somebody asked rather than because a timer fired. There is
  now **no way to ask for a scene at all without running the poll** — the
  poll is the only observer. This is the sharpest of the eight.
- **Export evidence.** `MirrorEvidenceExporter` writes a correlated frame
  PNG beside its projection artifact, and **no menu item, button or panel
  invokes it.** The capability is complete and unreachable.
- **Save a render screenshot.** The standalone `MirrorApp` has the menu
  item (`Save Render-Screenshot`); the embedded module has no equivalent.
- **Open a recorded scene document**, and with it the provenance banner
  that told a replay from this Mac right now.
- **Clear the scene.**

**Readouts with nothing to draw them:**

- **Scene age** — "Scene from 40 seconds ago". Nothing dates the picture,
  so a stalled poll and a live idle desktop are the same image.
- **`contentNote`** — what became of the last content join. An empty
  window interior has at least six causes and a blank rectangle is the
  same picture for all of them; this line is where they stopped being the
  same picture.
- **`refusalNote` / `liveNote`** — a refused ask said out loud while a
  good scene is still on screen, and why the loop is backed off or
  stopped.

**Deliberately NOT surfaced, so nobody re-adds it:** the operation
journal. It is the same operations the act clocks are derived from,
projected for MCP — a panel for it would list every event twice. Its one
field the act row lacks is `reason`, and the right repair is to put
`reason` on the act row, not to open a third stream.

## What the offscreen renderer can and cannot see

Not content, but it constrains every layout built out of it, and it is why
round one's pictures were misread: three candidates were compared against
frames whose inspector column was **blank**, and the blankness was read as
"the cards have no data in them". That was true and was not the whole
story.

**The instrument built so an agent could review its own layout could not
see the parts of a layout that hold content.** Measured 2026-08-07 with
`ImageRenderer` at scale 1, offscreen, on macOS 27:

| furniture | offscreen |
|---|---|
| `VStack`, `HStack`, `Divider`, `Text`, `Image` | draws |
| `Button`, `Toggle`, `LabeledContent` | draws |
| `DisclosureGroup` | draws |
| `Form` | draws |
| `Picker(.menu)` | draws |
| `Picker(.radioGroup)` | draws |
| `GeometryReader` | draws |
| **`ScrollView`** | **draws NOTHING — silently, no placeholder** |
| `List` | prohibited placeholder |
| `TabView` | prohibited placeholder |
| `VSplitView` | prohibited placeholder |
| `Picker(.segmented)` | prohibited placeholder |
| `Menu` (bordered / borderless) | prohibited placeholder |

`ScrollView` is the dangerous row. Everything else at least *shows* you a
yellow prohibition sign; a `ScrollView` renders as though its content were
not there, and every panel in this module lives inside one.

Two rules follow.

- **A component the renderer cannot see is an argument against choosing
  it**, because choosing it means this module can never be reviewed again
  without somebody sitting at the machine. That is why the drawer's filter
  is a `Picker(.menu)` and not a `Menu`, why the panel switcher became a
  disclosure and not a segmented control, and why the event drawer is a
  fixed height and not a `VSplitView`.
- **Where scrolling is genuinely required, make the CONTAINER reviewable
  rather than the design unscrollable.** `MirrorScrollBox` is a
  `ScrollView` in the product and a bounded stack under review, behind an
  environment flag only the render test sets. It is a rig affordance
  living in production code and should be read as one; the alternative was
  a design constrained by an instrument, which is the wrong way round.

And the guard that follows from both: `MirrorPanelRenderTests` renders
each panel **alone**, at the width it actually gets, because
`assertHasContent` over a whole candidate passes a frame holding a
Macintosh and an empty column — which is exactly the defect that shipped.
