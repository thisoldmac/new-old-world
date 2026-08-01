# MirrorKit and MirrorKitUI, as ported into NOW

**Ported 2026-07-31** from this project's own prototype,
`timbottu/mirror`, `host/MirrorKit`, at the state its `main` was in after the
four lanes landed and the IR was frozen at v1. Phase 2.1 of
[`docs/roadmap-to-verified.md`](../../../docs/roadmap-to-verified.md).

**Why a port and not a rewrite.** The narrowed stop condition in
[the fold-in plan](../../../docs/plans/2026-07-31-007-feat-now-mirror-integration-plan.md)
splits the two things that were once conflated:

| | rule |
|---|---|
| **the wire** | **ours.** NOW's conventions, NOW's families. A transliterated protocol is the defect that stop condition exists to prevent. |
| **the archaeology** | **port it.** Rendering geometry, the IR decode, the scene model — expensive knowledge paid for once against a real Mac OS 9.1, and re-deriving it without a machine is waste rather than rigour. |

Michelle, 2026-07-31: *"the entire mirror repo was a test bed for something
destined for NOW anyway."* Mirror is not a third party. The precedent for this
crossing on the guest side is `now-guest-ppc/src/axwalk/`, and its header rule
applies here too: **the measured parts are evidence, not style.** Upstream's
metal proof does not transfer to this copy — the same code in different
surroundings is strong evidence, not a measurement of this binary.

## What crossed

- **`MirrorKit`** — the headless core: the scene model and its IR v1 freeze
  gate, the scene builder, hit testing, the action model, the Finder/desktop
  item layers, pixel islands, scrollbar geometry.
- **`MirrorKitUI`** — the Platinum renderer, its bitmap fonts, patterns, icon
  atlas and app-icon set, the fit transform, the display-op replay.
- **Both test targets, whole**, including the golden fixtures — raw guest
  replies beside their expected scenes, recorded off a live guest. That corpus
  is the most expensive thing in the crossing and the reason the port can be
  trusted at all: 101 + 6 cases came across green.

## What did not cross, and why

- **`MirrorApp`.** A standalone executable with its own `main.swift`, `Serve`,
  `ManagedServe` and battery. NOW's host app is the app; a second one would be
  a second front end for the same machine.
- **Nothing else was dropped.** No source file was trimmed to make the build
  pass.

## The transport crossed, was fenced with prose, and is now deleted

This section used to be titled *"What is here but must not be used as NOW's
wire"*, and it listed upstream's transport with an instruction not to use it.
That fence held for one day. It is recorded rather than typed over, because
**a rule in a README is not a property of a build**: the code it fenced was
still the only thing in this module that could reach a machine, and the module
read as connectable when it was not.

Deleted 2026-07-31, on `thread/gap-mirrorkit-wire`:

| gone | what it was | why deletion, not adaptation |
|---|---|---|
| `WireClient` | `{"proto":1,"id":n,"verb":…}` over TCP, reading `result` | the TimBotTu toolkit worker's protocol; a NOW guest speaks `command.request` and answers `output`. Reimplementing it against NOW's contract would be a second transport on a lane one transfer wide. |
| `ScenePoller` | the poll loop over `axtree`/`list`/`video`/`qdtrace` | the transport it polled over is gone, so this type is. **The loop itself came back** (2026-08-01): `MirrorModuleModel`'s watch loop asks `axsnap` — a control message — about twice a second and spends a bulk transfer only when the answer changes or the drawing ages past its ceiling. This row used to say a timer "would take the shared bulk lane at intervals nobody chose"; that argued against a *blind* poll and was written as though it argued against upstream's, which was fetch-on-change and measured at 1 fetch per 4 polls. Its measurements live on in `SceneGeometry` and `SceneIslands`. |
| `MirrorTarget` | host/port/scope/machine/qmp descriptor | NOW addresses a *connection*, not a host and port. Nothing it carried survives the crossing except `scope`, which the guest's own walk decides. |
| `QmpClient` + the `qmpClick`/`qmpDoubleClick`/`drag`/`menuDrag`/`thumbDrag` executors | emulator mouse events injected from outside the guest CPU | host-side cheating by this project's rule, and there is no emulator on the other end of a NOW connection by assumption. |
| `ActionDispatcher` | the thing that turned an act into one of the two above | with both planes gone it had nothing left to dispatch onto. |
| `LiveMirrorController` | the 0.5 s poll loop + wire-confined dispatcher | a second front end for the same machine, driving both deleted planes. |

**The act vocabulary survived.** `MirrorAction` is the hit tester's output and
each case is a real thing a person does to a Macintosh; deleting cases would
have left a person clicking a title bar and getting silence. What changed is
that `ActionModel.availability` now answers NOW's question — *does the
contract declare a command for this, and can a scene address it* — instead of
upstream's *does this target have a QMP socket*. Three answers, all typed:

| act | answer |
|---|---|
| `menuInvoke`, `activate` | `.available("menuact")` / `.available("activate")` — a scene carries the whole target |
| `axdo` | `.needsObservation("ctlact"/"textset")` — addressed by an opaque reference only an observation mints, and NOW's scene producer emits controls with `ref` empty |
| `key`, `type`, `click` | `.unavailable` — NOW's contract declares no keystroke and no positional click. A **hole**, not a rule. |
| `drag`, `thumbDrag`, `qmpClick`, `qmpDoubleClick`, `menuDrag` | `.unavailable` — injected mouse motion. `winact`'s move/resize is the shape NOW would use, against a window reference. |

`NoSecondWireTests` holds the property rather than the prose: no socket API,
no request envelope, those files stay deleted, and every command name checked
against `contract/asyncapi.yaml`'s `x-commands`.

## The one behaviour changed on the way over

**`Scene`'s non-optional collections now decode if present.** Full reasoning is
in `Scene.swift`'s header; the short version is that upstream's synthesized
decode *required* `windows[].controls`, and NOW's guest omits any plane it did
not walk, so a document our own producer legitimately writes was undecodable.
Six fields were relaxed — `apps`, `windows`, `menubar.menus`,
`menubar.menus[].items`, `windows[].controls`, `meta.errors` — and each gained
a `…Present` flag so that **absent**, **empty** and **populated** stay three
distinguishable claims rather than two. The flags are declared but never
encoded; they are recorded in `IRSchema.v1AdditionalProperties` and the wire
freeze (`v1Frozen` / `v1Additions`) is untouched.

The version gate was not weakened. `MirrorScene.decode` still reads
`irVersion`, refuses an unknown major, and only then decodes — in that order,
which is the contract and not a style choice.

## What a follow-up needs to put this on screen

This phase stops at *compiles and tests*. Nothing here is wired to a NOW
module, and nothing has run against a Macintosh — emulated or metal.

1. **A module pane** in `Sources/Host` (`ModuleRegistry` + a `…ModuleView`),
   which is deliberately untouched here to avoid colliding with the module
   work in flight.
2. **A bridge from `NOWSceneDocument` to `Scene`.** NOW's decoder is the one
   that reads our guest's bytes; `MirrorKitUI` renders `MirrorKit.Scene`.
   Those are two models of one IR and the seam between them is one adapter —
   the point at which NOW's optional planes become this model's
   `value + …Present` pairs. That adapter is the natural home for the
   three-state mapping, and it does not exist yet.
3. **A decision about `SceneRenderer`'s inputs that this port did not make.**
   The renderer draws from a `Scene`; whether the pane renders live guest
   scenes, replayed fixtures, or both first is a product call.
4. **A guest that fills more planes.** Today NOW's producer omits `menus`,
   `controls`, `text` and `kind`, so a rendered scene would be chrome and
   titles. The renderer handles that (it is what the empty content rect is
   for), but nobody should be surprised by it.

## Addendum, 2026-07-31 — items 1–3 above are done

The follow-up landed the same day, on `thread/p2-mirror-module`:

1. **The module pane** is `Host/MirrorModuleView.swift` + `MirrorModuleModel`,
   registered as `mirror`.
2. **The bridge** is `Host/MirrorSceneAdapter.swift`. NOW's optional planes
   become this model's `value + …Present` pairs, all three states tested per
   plane.
3. **The input decision**: replayed scene documents, not live scenes — nothing
   on the host asks for one yet, and the pane names its provenance so a replay
   never reads as this Mac now.

**One file was added to this target**: `SceneFactory.swift`, public static
factories over the internal memberwise initializers, because the adapter lives
outside this module and could not otherwise construct a `Scene`. `Scene.swift`
is untouched; the reasoning for factories rather than public inits is in that
file's header.

Item 4 stands: NOW's guest now fills `menubar`, `controls`, `text` and `kind`
conditionally (Phase 1.3), and still no `display`, `desktopItems` or `items`.
