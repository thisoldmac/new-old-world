# Fidelity sweep, 2026-08-06 — the host render against the guest's own pixels

## WHICH BUILD THIS TABLE DESCRIBES — read this before quoting a score

Scores age badly and silently. This table is a **deliberate baseline**,
taken immediately *before* the icon asset pack landed, and it is only
meaningful against the exact tree named here.

| | |
|---|---|
| **Renderer tree** | branch `claude/fidelity-sweep-2026-08-06`, forked from `claude/gworld-interior-host-render-98ddd5` at `eb952325`. Every render in this document was produced from a working tree whose only differences from that fork point are `tools/fidelity-*.py`, this file, the new fixtures, and the render-list entries that name them. |
| **Asset pack** | the **OLD** one: `MirrorKitUI/Resources/appicons` carries **186** per-app icons and `Resources/icons` carries **5** generic System-file icons (`application`, `disk`, `document`, `folder`, `system-folder`), one size only. |
| **Guest build** | `1bff0bd2ca39 2026-08-06T20:04:32Z`, asserted by `--expect-build auto` on **every** capture — no foreign guest answered this listener. |
| **Guest machine** | QEMU `mac99`, Mac OS 9.1, 800×600, run `nowvm-fsw1`. Nothing here touched metal. |

**The asset pack changed on another branch while this sweep was running**
— 186 → 914 per-app icons, 5 → 127+10 System-file icons, and 16×16 art
shipped beside 32×32 so the renderer picks by size instead of
downsampling. That change regenerated all nine of the previously
committed capture renders. **None of it is in the tree above**, which was
confirmed by counting the resource directories rather than by reasoning
about branch order, so no row here mixes two asset packs. Every ICON
observation below is therefore a statement about the OLD pack and is
expected to move; the A/B is the point.

Axes other than icon art — TEXT, PLACEMENT, CHROME, and the hatch
question under CONTROLS — do not depend on the asset pack, and those
rows should survive the A/B unchanged. If one of them moves, that is
itself a finding.

## What this is

**Status: SURVEY.** Nothing here is a fix. Every row is a judgement about
one window, made by looking at two images of the same moment: the host's
render of a capture, and a QMP screendump of the machine taken while that
window was front. Nothing here touched metal — the guest is a QEMU
`mac99` running Mac OS 9.1.

The sweep exists because the mirror's gates prove that *strings cross*.
They do not prove the window **looks** like the window. `docs/mirror-renders.md`
said so plainly a week ago — "fidelity is unjudged" — and every capability
added since has been gated on presence, not appearance. This is the first
pass that puts a number on appearance, and its deliverable is the RED LIST
at the bottom.

## How to reproduce it

    tools/fidelity-sweep.py --port <wire> --qmp <run>/qmp.sock \
        --anchor <anchor> --vm <run> --expect-build auto \
        --outdir /private/tmp/fsweep-out \
        --target "Memory=Macintosh HD:System Folder:Control Panels:Memory"

Each target leaves `<label>.json` (a drain in fixture shape, carrying
`provenance`), `<label>-scene.json` and `<label>-guest.ppm`. The fixtures
that earned a row here are committed under
`now-host/Tests/HostTests/Fixtures/qdtrace-drain-sweep-<label>.json`, and
the renders come from

    NOW_RENDER_DIR=/private/tmp/renders swift test --filter testRenderEveryCapture

Two rig rules the sweep encodes rather than documents, both paid for
earlier the same day: the tool refuses a guest whose build is not this
checkout's (`--expect-build auto`), because every QEMU guest on this Mac
dials 10.0.2.2 and another session's VM will answer your listener; and a
target whose window comes back without an address is reported SKIPPED with
the window list, because the scene walk goes stale over a long session and
a miss that reads as an absence manufactures findings.

## The rubric

Five axes, 0–3 each, judged from the render/screendump pair. A score is
about **this window**, not about the mirror in general.

| Axis | 3 | 2 | 1 | 0 |
|---|---|---|---|---|
| **TEXT** | every visible string present, none duplicated or truncated | one or two minor strings missing | many strings missing, or systematic truncation | no text, or text belonging to another window |
| **PLACEMENT** | text and art within a pixel or two of the guest | small local drift | a whole region offset (the join-translation signature) | content in the wrong window or wildly displaced |
| **CONTROLS** | drawn as real controls | neutral plates where the stream did not say which control | plates where a real control was identifiable | "Bitmap unavailable" hatches over ordinary themed controls — a FALSE CLAIM of missing data |
| **REGIONS** | nothing absent | one minor region empty | a list, picker or pane entirely blank | the interior is empty |
| **CHROME** | frame, title bar, scroll bars and grow box right shape and size | minor size drift | wrong furniture for the window kind | no chrome, or chrome from a different window |

**A hatch is worse than a blank.** `DisplayReplay` already knows this —
`controlSized` exists because "Bitmap unavailable" was the wrong claim
for most of what a control panel blits. A hatch over a themed control is
scored 0 on CONTROLS wherever it appears, not 1.

**Renderer-side versus capture-side.** Every failure is one or the other,
and the distinction decides who fixes it:

- **Renderer-side** — the guest sent it and the mirror drew it wrong.
  The evidence is in the fixture: the string, the rect or the blit is in
  `ops` and the render disagrees with it.
- **Capture-side** — the guest never sent it. The evidence is the same
  fixture: nothing in `ops` covers that region. This is a plane or
  resident problem, not a renderer one. `desktopItems` is the shape.

A row cannot be judged without opening the fixture. "It looks empty" is
not a finding; "the fixture has no ops on that rect" is.

<!-- TABLE -->

<!-- REDLIST -->
