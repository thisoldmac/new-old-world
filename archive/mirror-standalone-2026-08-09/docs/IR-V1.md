# The scene IR, frozen at v1

> Compatibility status: v1 is still decodable, but it is approximate read-only
> input. Its required `controls[].role` forced partial producers to guess, so no
> v1 role may authorize an action. New producers emit v2; see
> [IR-V2.md](IR-V2.md).

**Date:** 2026-07-31. **Status:** landed on `lane/h1-ir-freeze`.
**Code of record:** `host/MirrorKit/Sources/MirrorKit/IRVersion.swift`,
`IRSchema.swift`, `Scene.swift`; gate in
`Tests/MirrorKitTests/IRFreezeTests.swift`.

## One number, two places

`irVersion` is a top-level key of the `mirror.scene` and `mirror.attach`
*results* — beside the payload, so a consumer can read the gate without
decoding the thing it guards. The scene body also carries `version`, the IR's
self-stamp, and that is the field the fixture corpus pins. **They are the same
number** (`IR.version`): `SceneBuilder` stamps the body, `Serve` copies it into
the envelope. They cannot diverge without editing source.

## What v1 means

| | |
|---|---|
| **Frozen** | the encoded field set, enumerated in `IRSchema.v1Frozen` (wire key paths) and `IRSchema.v1FrozenProperties` (declared `Type.property` pairs). |
| **Additive within v1** | a new field is recorded in `IRSchema.v1Additions`. `IR.version` stays `1`; old consumers ignore keys they do not know. |
| **Breaking** | removing or renaming a field moves `IR.version`, and the new major needs its own manifest. |
| **Consumer duty** | read `irVersion`, refuse an unknown major, *then* decode. `MirrorScene.decode(result:)` is written in that order. |

Two enumerations rather than one, because each covers the other's blind spot.
The wire-path list is the contract a consumer sees, but it can only observe a
field the probe scene populates; the `Mirror`-derived property list still sees
a field that was added and never filled in.

## Field-by-field, promote or drop

Every field below is **promoted into v1** except the two marked *dropped*.

| Field | Read by a consumer? | In the fixture corpus? | Call |
|---|---|---|---|
| `version`, `seq`, `capturedAt` | yes (`Serve` staleness, renderer clock, logs) | yes | promote |
| `source` | one log line only | yes | promote — it is the plane discriminator; an agent that cannot tell an `observe` scene from an `axtree` one cannot tell "no windows" from "windows not visible from here" |
| `screen.{w,h}` | yes (fit transform, hit test) | yes | promote |
| `apps[].{psn,name,front}` | yes | yes | promote |
| `apps[].error` | yes (`AppList`, `LiveMirror`, `Serve`) | yes | promote |
| `processes[].{psn,name,front}` | yes | yes (01) | promote |
| `processes[].signature` | **no consumer reads it** | yes (01) | promote — the creator OSType is the only app identity besides a display name, `IconAtlas` already keys art off the same fact, and it is corpus-covered. Carried-but-unread is a liability; carried-but-unread-and-identity-bearing is a shelf worth keeping |
| `menubar.app`, `menus[].{title,apple,left,id}` | yes (hit test, `ActionModel`, renderer) | yes | promote |
| `menus[].items[].{title,index,separator,enabled,mark,cmd}` | yes | yes | promote |
| `windows[].{id,app,psn,title,rect,front,z,visible}` | yes | yes | promote |
| `windows[].kind` | yes (dialog detection, `kind==2`, in ~15 places) | yes | promote |
| `windows[].controls[].*` | yes | yes | promote |
| `windows[].text.{content,active}` | yes | yes (05) | promote |
| `windows[].display[]` (`DisplayOp`, 17 fields) | yes (`DisplayReplay`) | **no** | promote — live, read, and deliberately shaped as *one* flat struct over every op family, so a new QuickDraw op adds a value to `op`, not a field. Freezing it costs little and the alternative (an unfrozen zone inside a frozen contract) is a contract that does not mean what it says. **Corpus gap, stated: no fixture exercises the content plane.** |
| `desktopItems[].*` (9 fields) | yes (hit test, renderer, `IconAtlas`, battery) | fixture 08 covers the *normalizer*, no `.expected` scene carries them | promote |
| `meta.{latencyMs,bytes}` | no consumer reads them | yes | promote — telemetry that distinguishes a slow poll from a stale scene, and it is already captured |
| `meta.errors` | yes (`main.swift`) | yes | promote |
| `meta.plane` | **no consumer reads it** | yes (01) | promote the **key**; its value is a freeform annotation (`"process-list (pre-AXPeek)"`) with no enumerated vocabulary, and that vocabulary is explicitly *not* frozen |
| `windows[].items` | renderer only, in-process | no | **dropped**, then **re-added additively** 2026-07-31 — see below |
| `windows[].island` | renderer only, in-process | no | **dropped** — see below |

### What was dropped, and why

Both remain declared properties (the renderer keeps its shelves) and are
excluded from `Codable` via an explicit `CodingKeys` on `Scene.Window`.

- **`windows[].island`** — it has never been on the wire. `Serve.sceneMethod`
  nils every island before encoding, because island pixels ride their own W1
  pager, not the scene. Freezing it would put a base64 RGBA blob into an
  interchange contract that no consumer has ever received.
- **`windows[].items`** — dropped because `ScenePoller.includeWindowItems`
  shipped `false`: Finder folder-item positions were **not guest-accurate**,
  and freezing a field whose values are known wrong is the expensive half of a
  contract — it obliges us to keep serving the wrong number.

  **It came back the same day.** Lane H2 (2026-07-31) found that the wrong
  number came from the wrong *source*, not from an unanswerable question: the
  positions were read from the saved `fdLocation` grid rather than from the
  Finder's own live `position of`, which is window-content-local and
  scroll-compensated. Measured 40/40 by clicking a computed point and being
  told the right file was selected ([FOLDER-ITEMS.md](FOLDER-ITEMS.md)). So it
  re-entered exactly as this section said it would: recorded in
  `IRSchema.v1Additions`, still absent from `v1Frozen`, `IR.version` still `1`,
  no major bump. `testWindowItemsReEnteredAdditively` pins all four clauses.
  A fixture still does not cover it — that gap stands.

## How the gate was proven

Every assertion was watched failing under a deliberate mutation, then reverted.

| Mutation | Result |
|---|---|
| add `Scene.Window.probe`, wired into `CodingKeys` | 8 red — both freeze tests plus 6 fixtures |
| add `Scene.Window.probe`, **not** in `CodingKeys` | 1 red — the property list only, which is exactly why it exists |
| remove `ProcessRef.signature` and every call site | 3 red — both freeze tests ("frozen … disappeared") plus fixture 01 |
| `IR.supportedMajors` widened to `0...99` | 6 red — the consumer accepted majors 0, 2, 3, 99 and the attach gate |
| gate moved to *after* the decode | 1 red — `testVersionIsCheckedBeforeThePayload` |
| version stamp regressed to `0` | 9 red — all 7 fixtures plus the stamp assertions |

`swift test`: 78 tests, 0 failures (68 before this lane).

## What is still provisional

- **No fixture exercises `windows[].display`.** The content plane is frozen on
  the strength of its design and its live use by `DisplayReplay`, not on
  captured evidence. A fixture pair for a traced window is the missing proof.
- **`meta.plane`'s value vocabulary is not frozen** — only the key is. A
  consumer must not branch on its string.
- **`v1Frozen` is final by convention, not by mechanism.** A developer *can*
  delete a line from it and go green. What the gate guarantees is that drift is
  never *silent*: the deletion appears in the diff as a removed promise instead
  of as nothing at all. A digest pin would only move the same manual step one
  file over.
- **The corpus pin is the `.expected.json` `version` field only.** No `.raw.json`
  was touched — those are captured guest reality; `version` is the Swift side's
  own stamp (see the `FixtureTests` header).
- **This lane never ran a VM.** Everything here is fixture- and suite-driven.
  The live `mirror.scene` / `mirror.attach` replies were not re-measured, so the
  claim "the envelope key and the body stamp agree in flight" rests on reading
  `Serve.sceneMethod`, not on a captured reply.
