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
| Acts (`MirrorActTimeline`) | 32 | the last **8**, as two-line cards |
| Scene cycles (`MirrorCycleTimeline`) | 24 | the **latest of each of 4 walk kinds**; the other ~20 are invisible |
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

## What the offscreen renderer can and cannot see

Not content, but it constrains every layout built out of it, and it is the
reason round one's pictures were misread. The table lives in
`now-host/Sources/Host/MirrorReviewRendering.swift` beside the workaround.
The short version: **`ScrollView` renders as nothing at all**, and `List`,
`TabView`, `VSplitView`, `Picker(.segmented)` and a bordered `Menu` all
return the prohibited placeholder. `DisclosureGroup`, `Form`,
`Picker(.menu)` and `Picker(.radioGroup)` draw.

A component the renderer cannot see is an argument against choosing it,
because choosing it means this module can never be reviewed again without
somebody sitting at the machine.
