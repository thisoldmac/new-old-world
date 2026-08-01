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

## What is here but must not be used as NOW's wire

These crossed because the tests and the geometry depend on them, **not**
because NOW should speak them. They are upstream's transport, and the stop
condition above puts them out of bounds for NOW's families:

- **`WireClient`, `ScenePoller`, `MirrorTarget`** — Mirror's own JSON-over-TCP
  client and its polling loop. NOW's guest dials out over the multiplexed wire
  the host already owns; a scene arrives as a NOW family, decoded by
  `NOWSceneCodec`. Read `SceneBuilder` for the *shape* it produces, not
  `WireClient` for how it got there.
- **`QmpClient`, and the `qmpClick` / `qmpDoubleClick` / `drag` / `menuDrag` /
  `thumbDrag` arms of `ActionDispatcher`** — emulator-only mouse injection.
  NOW's rule is blunter than upstream's: *no host-side cheating*, solve it
  through the guest. Upstream itself removed QMP from its act plane once
  `WINDOW_ACT` could answer the application's own `FindWindow`. Treat these as
  history, kept so `ActionModel`'s availability logic and its tests stay whole.

`ActionModel`'s `availability` vocabulary, by contrast, is worth keeping and
already agrees with NOW's typed unavailability: every act says what mechanism
it used and degrades honestly instead of silently.

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
