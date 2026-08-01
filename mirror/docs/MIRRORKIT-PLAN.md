# MirrorKit — plan

`corpus_impact`: none because this reshapes the mirror plan's posture (human-
first maturation, gated MCP parity, emu-only typing, self-screenshot) without
new technical findings; durable claims live in `host-desktop-mirror-spike`.

**What it is.** MirrorKit is the canonical semantic layer for *perceiving and
manipulating* a guest OS 9 UI. It turns the raw `axtree`/`observe`/`axdo`/… wire
surface (landed on main) into a clean, versioned **scene IR** plus a semantic
**action model**, and it is the one implementation that both a human GUI and a
headless agent use — so what a person sees and what an agent sees are literally
the same code.

**Posture: human-first maturation.** The surface is proven out *user-focused in
the workshop* — humans driving real guests — and matures under that use. MCP
parity is a deliberately **later, gated phase**: the agent route arrives when
the surface is mature, and inherits it whole. (This is the workshop charter's
parity principle run in the opposite direction — human surface leading.)

Grew out of the desktop-mirror spike (`README.md`, `CONTROL-SURFACE.md`). The AX
verb surface it sits on is already on main; this is the layer above it.

## Architecture: one brain, two heads

```
                         ┌──────────────── MirrorKit (Swift) ────────────────┐
   guest wire            │  MirrorTarget · wire client                        │
   axtree/observe ──────▶│  scene IR  (sceneFromAxtree / sceneFromObserve)     │
   axdo/click/key/…◀─────│  hit-testing · action model (element → verb)        │
                         │  *** RENDERER-FREE — headless-capable ***           │
                         └───────┬───────────────────────────┬────────────────┘
                                 │                            │
                        ┌────────▼────────┐          ┌────────▼─────────────┐
                        │ MirrorApp (GUI) │          │ headless MCP adapter │
                        │ Canvas Platinum │          │ (agent route, no UI) │
                        │ + render-shot   │          │  parity phase        │
                        └─────────────────┘          └──────────────────────┘
```

**The renderer is the only app-exclusive part.** Scene-building, hit-testing,
and the action model are headless-capable. That is the whole design.

## Decisions (locked)

1. **Standalone app, source-agnostic instantiation.** The mirror is a standalone
   Swift app *intended to be* launched by the workshop, but bootstrappable by any
   caller (agent, user, another app, a script). The contract is one typed
   descriptor:
   ```swift
   struct MirrorTarget: Codable { host, port, scope, machine, qmp? }  // qmp = emu drag socket
   ```
   Every launch surface just constructs a `MirrorTarget`. **CLI for v1**
   (`MirrorApp --host … --port … --machine … --scope all [--qmp …]`); a
   `mirror://open?…` URL scheme and JSON-on-stdin come later.
2. **Consumer, not deployer.** The app assumes AXPeek + a toolkit worker are
   already live at `host:port`. Standing them up is the *caller's* job — the
   workshop's value-add. This keeps the app source-agnostic and cleanly splits
   failure classes: *deploy/transport* problems (e.g. q800 `-23009`) belong to
   the launcher; *render/act* problems belong to the app.
3. **Swift-canonical.** The scene normalizer lives **once**, in Swift MirrorKit.
   The parity-phase headless MCP route invokes MirrorKit (not a parallel Python
   implementation), so human and agent run identical code. The Python `scene.py`
   from the spike **retires** — kept, if at all, only as a golden-fixture cross-
   check (`axtree-JSON → expected-scene-JSON`) that the Swift port must pass.
4. **Renderer-free core from the first commit.** MirrorKit (logic) and the Canvas
   renderer (`MirrorKitUI` / the app) are separate modules. The seam is what
   keeps the maturation phase agent-buildable (everything below it asserts in
   `swift test`), and it is what makes eventual MCP parity "add an adapter to a
   proven core," never a refactor of the mature app's guts.
5. **The scene IR is version-stamped from day one, but UNSTABLE until the
   parity gate.** During maturation the IR churns freely — that churn is the
   point of human-first proving. The **fixture corpus** (captured `axtree` JSON →
   expected scene JSON, checked in) exists from slice 1 as *regression tests*
   that keep the normalizers correct while the shape moves. At the parity gate
   the IR freezes to **v1**, the fixtures harden into the **contract gate**, and
   changes become additive-only. Contract-freeze is the *entry ritual* to the
   parity phase, not a founding act. The IR composes above raw `axtree`/`axdo`,
   which stay as the substrate + low-level fallback.
6. **Engineer through metal from the gate — no load-bearing emu-only
   mechanisms.** Emu is the iteration bench (test/drive there first while
   ironing things out), but nothing the design *depends on* may exist only on
   emu. Anything emu-only (the QMP socket, closed-loop `mouseloc` drag,
   shortcut-less menu-drag) is **explicitly typed as emu-only in the action
   model** and degrades honestly on metal — never assumed, never silent.
7. **Render-screenshot: the app captures its own drawn output, for humans and
   agents alike.** This is a screenshot of **the render** — the Platinum scene
   MirrorKitUI draws — NOT the guest framebuffer (that's the existing
   `capture`/`snap` plane, a different thing) and NOT the host screen
   (off-limits: hijacks the desktop, proven unreliable). Two forms:
   - **Offscreen render**: scene JSON → Canvas → PNG with no window at all
     (`ImageRenderer`), the agent path for renderer verification against
     fixtures.
   - **Live snapshot**: the running app writes its currently drawn Canvas to a
     file (menu item + CLI-triggerable), the shared human/agent affordance.
   Both rasterize only what MirrorKitUI drew. Comparing a render-screenshot
   against a guest `snap` of the same moment is a *cross-check we get for
   free*, not the mechanism.
8. **Package home: `prototypes/mirror/MirrorKit/` through maturation.** A
   maturing prototype belongs in prototypes. Promotion to a top-level `swift/`
   tree happens at the parity gate, when the MCP-facing story becomes real.

## Invariants (hold in every phase)

- **Symmetry**: every rendered element carries the semantic `ref` it acts
  through and the global `rect` it occupies. The render path can never grow
  private knowledge the headless head lacks.
- **Hit-testing and action dispatch live in the headless core**, not the
  renderer. The renderer maps pixels→elements only via core hit-testing.
- **Action availability is a typed, per-target property of the action model.**
  The GUI grays what a target can't do; the headless head reports it as typed
  data. Emu-only actions (decision 6) are the first users of this.

## Roadmap

**Phase 1 — build MirrorKit core + MirrorApp (standalone).**
- **Fixture corpus first**: capture real `axtree`/`observe` payloads off the
  live guest (SimpleText, GraphCalc sliders, a `kind==2` Save dialog, multi-app
  with an `ax_oracle_*` error, an observe-plane payload) → checked-in
  fixtures. Everything below hangs off these.
- `MirrorTarget` + scene model + `sceneFromAxtree`/`sceneFromObserve` + fixture
  tests (agent-verifiable). *Renderer-free.*
- Wire client (small newline-JSON socket) + minimal app shell + live polling —
  **early**, so human visual iteration happens against live guests, not
  fixtures. (Named debt: this is a third Swift wire client after the workshop's
  `Wire.swift` and TBTKit's; consolidate into a shared wire package at
  promotion time.)
- Canvas Platinum renderer (`MirrorKitUI`) **with render-screenshot from the
  first drawing pass** (decision 7) — agent-inspectable via offscreen fixture
  renders; human eyes judge Platinum fidelity.
- Hit-testing + action model + live actuation (control→`axdo`, menu-⌘→`key`,
  title-bar→`activate`, point→`click`, drag→`mouseloc`+QMP *typed emu-only*).

**Phase 2 — workshop maturation (human driving = the proving ground).**
- Workshop deploys a target (AXPeek + toolkit worker) and launches the app with
  a `MirrorTarget` (CLI/Process, like it spawns anything). No host-app coupling
  beyond a launcher affordance.
- Humans drive real guests through it. Emu first while ironing out; **metal
  early**, so the emu-only typing and honest degradation get exercised by real
  use, not asserted.
- The IR and action model **churn freely** here; fixtures keep the normalizers
  honest through the churn.

**Maturity gate (the trigger for parity, not a vibe).** Proposed criteria —
confirm before enforcing:
- A human completes real end-to-end tasks through the mirror on **emu and
  metal** without dropping to raw verbs or the framebuffer.
- The scene IR has gone multiple sessions of real use without a shape change.
- Metal degradation is honest everywhere (no silent no-ops in real use).

**Phase 3 — MCP parity with the mature surface.**
- Freeze scene IR **v1**; fixture corpus becomes the gated contract.
- Expose MirrorKit headlessly to the MCP (no app): agents get the scene IR +
  "act on this element," powered by the *same* Swift core the app uses.
  Packaging (one-shot CLI the Python MCP shells out to vs long-running service)
  is decided **here**, with real polling-latency data from phase 2 in hand.
- Classify the surface in the docs/30 matrix; give it a workshop-parity row.
- Promote the package to `swift/`; consolidate the wire client.
- Becomes the ergonomic default for agent view+manipulate; raw `axtree`/`axdo`
  remain the substrate.

## The scene-IR contract

Current shape + the normalization gotchas are documented in `scene.py` (the port
source) and `CONTROL-SURFACE.md`. What MUST be baked into the Swift normalizer:
- **rect order**: `axtree` = `[l,t,r,b]` (content port; title bar sits above);
  `observe` own-windows = Mac `[t,l,b,r]`.
- `axtree` shape: `apps[].process` nesting; per-app `menus`; per-app `error`
  (`ax_oracle_*`); front-app + cross-app z reconstruction.
- controls carry `value/min/max/checked` + `scrollbar` role; menu items carry
  `command`(→⌘)/`mark`/`enabled`; filter garbage (non-printable) menu titles.
- dialog `textEdit` for `kind==2` windows.
Version-stamped from day one; unstable until the parity gate, then v1 +
additive-only (decision 5).

## Module layout (a Swift package)

- `MirrorKit` — renderer-free core: `MirrorTarget`, scene model, normalizers,
  wire client, hit-testing, action model. **The canonical layer.**
- `MirrorKitUI` — the Canvas Platinum renderer + render-screenshot (app-only).
- `MirrorApp` — the standalone app shell (`CLI → MirrorTarget → window`).
- (parity phase) a headless adapter exposing `MirrorKit` to the MCP.
Location: `prototypes/mirror/MirrorKit/` (a local SwiftPM package); promoted to
a top-level `swift/` tree at the parity gate (decision 8).

## Build order (first slices)

1. **Fixture corpus** captured off the live guest → checked in. ← start here
2. `MirrorKit`: `MirrorTarget` + scene model + normalizers + fixture tests.
   Fully agent-verifiable.
3. Wire client + minimal `MirrorApp` shell (CLI parse → window) + live polling —
   live guest on screen early.
4. `MirrorKitUI`: Canvas Platinum renderer from the `platinum.css`/`mirror.js`
   spec, **render-screenshot in the first pass** — agent-inspected via
   offscreen fixture renders, human-judged for fidelity.
5. Hit-testing + action model + live actuation (emu-only actions typed as such).
Then phase 2, then the gate, then phase 3.

## Verification (why renderer-free + self-screenshot matter)

Host-GUI capture is off-limits (and was unreliable anyway) — the mirror is
never verified by screenshotting the host desktop. Instead:
- **Everything below the renderer** — scene model, normalizers, hit-testing,
  action dispatch — asserts against captured `axtree` JSON in `swift test`.
- **The renderer itself** is inspected through decision 7 (a screenshot of the
  *render*, not the guest): an agent renders fixture scenes to PNG offscreen
  and reads the result; the running app's live snapshot gives humans and
  agents the *same* pixels to discuss.
- **Human eyes** remain the judge of Platinum *fidelity* (does it feel right),
  but no longer the only way to see the render at all.

## Open questions

- **Action → ref resolution:** the action model reuses the `ax2` ref scheme; nail
  down how "click the Save button" resolves to a fresh `axdo` ref (fail-closed).
- **Multi-instance:** one app per target (mac99 + q800 side by side) — target
  registry / window titling.
- **Maturity-gate numbers:** how many tasks / sessions-without-IR-change count
  as mature (criteria proposed above; confirm before enforcing).
- **Metal drag:** the VBL mouse-walker that replaces QMP closed-loop drag on
  metal — parity-phase-adjacent, tracked in `CONTROL-SURFACE.md`.

## Relationship to existing docs

- Supersedes the shell/architecture question in `WORKSHOP-FOLDIN.md` (standalone
  confirmed; workshop = one launcher). WORKSHOP-FOLDIN's component build details
  remain a useful implementation reference.
- `CONTROL-SURFACE.md` is the perceive+act capability map.
- `scene.py` is the port source → retires (or becomes the golden-fixture oracle).
- Consumes the AX verb surface landed on main (`axtree`/`axdo`/`click`/`key`/
  `mouseloc`, control values).
