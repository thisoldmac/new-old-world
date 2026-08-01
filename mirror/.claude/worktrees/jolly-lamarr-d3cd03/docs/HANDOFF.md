# MirrorKit — continue-fresh handoff

`corpus_impact`: none because this rewrites the stale handoff to the current
MirrorKit state (checkpoint/orientation); durable technical claims live in the
`host-desktop-mirror-spike` and `platinum-asset-extraction` findings.

Single entry point for picking this up. Everything below is **on `main`**
(branch `claude/mirrorkit-plan-review-7cecc6` is level with it).

## What it is now

A working, interactive **live mirror of an OS 9 guest desktop**, rendered
host-side from *semantic* wire state (windows / menus / controls / icon
positions) — not framebuffer pixels — and actuated back through the wire. It
reads as a real OS 9 machine: real Chicago/Geneva bitmap fonts, the real
"Mac OS Default" desktop pattern, real per-app icons, real Platinum window
chrome, working menus and window controls.

`MirrorApp --window --host H --port P --machine M --qmp SOCK` opens the live
window (see *Run it*). The renderer-free `MirrorKit` core is Swift-canonical
per `MIRRORKIT-PLAN.md` — the same code a future headless MCP route would use.

## Where we are against the plan (MIRRORKIT-PLAN.md)

- **Phase 1 (build the core + app): DONE and then some.** All the original
  slices (fixture corpus, scene IR + normalizers, wire client, poller,
  renderer, hit-test + action model, app shell) plus a lot past them: live
  NSWindow app, the full real asset pack (fonts / pattern / generics / real
  per-app icons dug from resource forks, all color-correct after the CLUT
  fix), desktop + mounted-disk icons, window raise/drag/resize with a
  tracking outline, calibrated window widgets, precise QMP clicks +
  double-click, guest-resolution auto-detect.
- **Phase 2 (workshop maturation, human-driven): this is where we are.** The
  app is being driven and hardened against a live guest — each session turns
  up a few actuation/coverage gaps and we fix them (the maturity signal is
  when that stops). The scene IR is still **unstable by design** (churns
  freely until the parity gate). "Mature" is being defined (IR shape-stable
  after the QD content plane lands + human end-to-end + reliable actuation +
  clean content boundary; emu-first, metal a later gate).
- **Maturity gate → Phase 3 (MCP parity): not yet.** Freeze IR v1, fixtures
  become the contract gate, add the headless adapter. Not started.

## Module layout (`prototypes/mirror/MirrorKit/`, a SwiftPM package)

- `Sources/MirrorKit` — the renderer-free core: `MirrorTarget`, `Scene` IR,
  `SceneBuilder` (normalizers, oracle-parity with `scene.py`), `WireClient`
  (ONE persistent connection — see gotchas), `ScenePoller`, `HitTester`,
  `WindowChrome`, `ActionModel`, `ActionDispatcher`, `QmpClient`.
- `Sources/MirrorKitUI` — the Canvas Platinum renderer (`SceneRenderer`),
  `SceneView` + `RenderShot` (render-screenshot), `LiveMirror` (poll loop +
  input), `BitmapFont`/`FontBook`, `IconAtlas`, `FitTransform`. Bundles the
  real assets under `Resources/{fonts,patterns,icons,appicons}`.
- `Sources/MirrorApp` — the CLI/app shell (`--window`, `--snapshot`,
  `--render-fixture`, `--act-*` for headless actuation, `--json`).
- `Tests` — 41 tests: fixture-oracle scene tests, hit/action, transform,
  scrollbar anatomy, and the MoveBits/pixel-island math.

## What works (perceive → act)

- **Window interiors — M3 pixel islands (2026-07-17).** A window's content
  comes back as the guest's REAL pixels when it has no semantics to read:
  `WireClient.captureRegion()` (the W1 pager + PackBits/rgb555be codec,
  auto-tiled to the guest's resident buffer) → `Scene.Window.island` → drawn in
  the content rect. When an island is set it **is** the content (the renderer
  skips the op replay and controls — the island already shows the real ones);
  the chrome around it stays semantic, so it's still a Platinum window we drew.
  **Fetch on change, cached between:** a content-sized blit in the trace means
  the guest repainted; the rect is in the cache key so a move/resize re-fetches.
  A **MoveBits scroll** (same-size blit displaced with its src inside the
  content) moves the pixels we already hold and re-fetches only the exposed
  band. `--islands` turns it on; `--island "l,t,r,b"` fetches one rect standalone.
  This is what makes Finder windows render their icons at all — see the
  `finder-window-icons-are-offscreen-blits` gotcha below.
- **Perceive:** all open apps' windows at true geometry, front/z-order,
  per-app menus (guest-true positions), controls (values/scrollbars),
  dialog text, real per-app icons by `(creator, type)`, and desktop icons at
  their real positions — Desktop Folder items (`fdLocation`) + mounted disks
  (Finder-placed positions via `script`). **Window interiors render too**
  (2026-07-17): what an app draws directly comes back as semantic ops (a
  SimpleText document's text), and what it composites offscreen comes back as
  an M3 pixel island — a Finder window shows its real icons at true positions.
  See *Window interiors* above.
- **Act (emu, via QMP + wire):** click controls (`axdo`), ⌘-shortcut menu
  items via `key`, title-bar drag → window move, grow-box drag → resize,
  close/zoom/collapse widgets (guest-calibrated geometry), click-to-raise a
  background window, precise clicks (±2px closed-loop), double-click to open
  (real QMP double-click), type. Actions carry typed emu-only availability
  (decision 6). **Reliability is now checked, not assumed** — `MirrorApp
  --battery` drives the real perceive→hit→act→verify path through every gesture
  against a live guest and reports green/red (see *Actuation battery*).
- **The one weak primitive — shortcut-less menu items (QMP menu-drag):** an
  item with no ⌘ key (SimpleText's *Save As…*) can only be reached by pressing
  the menu title and dragging down the guest-drawn menu, open-loop (MenuSelect
  starves the Worker, so no `mouseloc` mid-drag). The landing is mouse-accel-
  sensitive and connection-state-dependent, so it lands on the wrong row often
  enough to matter — and a miss is **not** a no-op, it *selects whatever row
  the cursor lands on* (possibly Close/Quit). Treat it as experimental emu-only
  until it's either screendump-closed-loop or on the metal VBL-walker path. The
  battery runs it **last**, in isolation, so a misfire can't corrupt the other
  checks.

## Run it

The guest needs AXPeek + **QDPeek** (INITs) and a **toolkit** worker with a
generous scope. `prototypes/mirror/spin-up.sh` does the whole thing on a fresh
isolated clone (it picks a FREE host-port pair, stages, waits for OS 9's
periodic flush, cold-reboots, then VERIFIES the INITs survived).

Scope gotcha that costs an hour if you miss it: the session's `tools` must
include **`axdo`** (actuation), **`fetch`/`close`** (any pager verb — islands,
capture), and ideally `shutdown` (restart the worker without rebooting the
guest). A missing verb reads as `denied: verb not in this session's scope`,
which looks nothing like the feature it breaks.

```
swift build -c release --package-path prototypes/mirror/MirrorKit
prototypes/mirror/spin-up.sh                 # prints the ports it chose
# live window, content plane + pixel islands on:
prototypes/mirror/MirrorKit/.build/release/MirrorApp --window --display --islands \
  --host 127.0.0.1 --port <TOOLKIT> --machine mac99 --scope front \
  --qmp <repo>/run-mirror/qmp.sock --interval 0.7
```

**ONE MirrorApp per worker** — the toolkit worker serves a single connection, so
a second client to that port resets it. That also means you can't poke the guest
from a side script while the mirror holds it.

Rebuilding the guest worker (`ninja -C worker/build-ppc-toolkit`): you cannot
overwrite a RUNNING worker's app file (err -48). With `shutdown` in scope, stop
it and relaunch via the anchor; otherwise cold-reboot. Either way **re-verify
after a reboot** — staged writes go through the image's pre-FlushVol anchor, so
they need OS 9's periodic flush to reach the qcow2 first
([[qdpeek-guest-staging-does-not-persist]]).

## Actuation battery (the maturity signal)

`MirrorApp --battery --host H --port P --machine M --qmp SOCK` drives the guest
through every gesture via the **real** hit-test → action-model → dispatcher
path and verifies each by re-poll — the same code the live app uses, not a
side channel. It turns "each session we find another actuation gap by driving"
into a repeatable green/red suite; the maturity bar is when it's all green (bar
the emu-only frontier below).

Current state (mac99) — **deterministic 10 pass / 0 fail / 1 skip**, identical
over three consecutive runs:

| gesture | via | result |
|---|---|---|
| File▸New (⌘ menu item) | `key` (keystroke path) | ✓ |
| scroll a line | QMP click on the arrow | ✓ (`value 0→11 of 0…11`) |
| scroll by thumb drag | QMP drag, **unity** compensation | ✓ (lands on target) |
| grow-box resize | QMP drag | ✓ |
| title-bar move | QMP drag | ✓ |
| zoom widget | QMP click | ✓ |
| close widget (+ "Don't Save") | QMP click → `axdo` | ✓ |
| File▸Save As (shortcut-less) | QMP menu-drag | ✓ |
| Cancel the Save dialog | `axdo` | ✓ |
| double-click a desktop doc | QMP double-click | – skip when occluded |

The skip is honest, not a dodge: a window left over the desktop makes the
hit-test resolve to THAT window, so double-clicking proves nothing — occlusion
is a skip, never a pass.

**Three things the battery learned the hard way, all encoded now:**

1. **`axdo` must be in the worker session scope.** Without it the dialog-Cancel
   check fails as an "actuation bug" that is pure config (`denied: verb not in
   this session's scope`). Same class as `fetch`/`close` for the pager.
2. **Teardown must leave NO modal.** One left up starves the guest's event loop
   and the NEXT run finds every port dead — it wedged this VM until a reboot.
   Escape does not dismiss a classic modal, and with the worker starved there's
   no `mouseloc` to close-loop a QMP click onto the button, so the battery must
   not create the situation.
3. **A modified document prompts before closing** — the window count briefly
   goes UP (the prompt is a window). The close check answers "Don't Save".

The menu-drag now passes here, but treat that as this guest's current state,
not a promotion: it's still open-loop through mouse accel (see gotchas). It
runs last so a misfire can't cascade.

## Load-bearing gotchas

- **ONE WireClient per worker per process.** The toolkit worker serves a single
  connection; the poller and dispatcher SHARE one `WireClient` (both on the
  controller's serial queue). Two persistent connections to the same worker →
  the second is reset ("recv: Connection reset by peer"). This bit window drag.
- **Widget geometry is calibrated to the guest framebuffer**, not guessed —
  `WindowChrome` offsets (close `r.l+1`, box top `r.t+2`, etc.) match the real
  Platinum boxes so QMP clicks land. A mismatch = clicks miss silently.
- **Window raising** needs a real QMP click (guest `SelectWindow`);
  `activate`/SetFrontProcess only fronts the app, never a specific window.
- **A menu item's `enabled` bit is NOT authoritative — never hard-gate
  actuation on it.** Classic apps disable their menus at rest and only
  `AdjustMenus()` them at menu-down time, so a passive `axtree` read sees the
  resting state: SimpleText's whole File menu (New, Save As, Quit, all of it)
  reads `enabled:false` while the Apple/Help/keyboard menus — system-managed —
  read true. `menuSelect`/`menuItem` therefore ignore `enabled` (a truly
  disabled item just no-ops in the guest; the caller verifies by re-poll).
  Gating on it was the real bug behind "menu actuation randomly does nothing":
  it refused every File item, including the reliable ⌘-keystroke path. The
  renderer still grays a dropdown by this bit, so an open app menu previews as
  all-disabled — a known rendering-fidelity gap (real enablement needs a
  menu-open snapshot or the QD plane).
- **Finder windows** resolve their folder via `script` (`item of window`; the
  `Finder window` class and `target of window` both error — use generic
  `window` + `item of`; the arg key is `source`, output is source-form with
  outer quotes). `script` graduated to a published, approval-gated MCP op
  (`ba6fc61d`) + a workshop plugin — but the **wire verb is unchanged**
  (`{source, timeoutMs}`), which is what the mirror calls directly through
  the worker, so no swap needed; the mirror bypasses the MCP approval gate by
  design (consumer-not-deployer, talks to the worker).
- **Finder-window icon positions are NOT semantic — and NOT in the QD ops
  either (settled 2026-07-17).** The Finder composites its window icon views in
  an **offscreen GWorld and blits the whole composite in**: a 12-icon window
  emits *no* per-icon op and *no* label, just one content-sized blit
  (`dst[0,0,430,380]`, `src == dst`). Tried an update, a reflowing resize, and a
  fresh window open — all blits. The **desktop** is the opposite (plotted
  straight to the screen port: a 32×32 `bits` at the true `dst` + a label
  `text` at its pen), which is why desktop icons work. So window interiors need
  **M3 BITS pixel islands** (`capture_region` the blit's pixels), not geometry —
  QDPEEK-SPEC called this ("a GWorld app renders as semantic ops + pixel
  islands"); the Finder *is* that app. See finding
  `finder-window-icons-are-offscreen-blits`. Historical detail below:
  `fdLocation` for window items is a *saved logical grid* the Finder rescales at
  layout time (128px stored vs ~172px drawn), and AppleScript `position` works
  for disks/desktop items but errors for items inside a window. So
  `includeWindowItems` stays **OFF** — not "until QD lands" (that hope is dead
  per above) but for good: no semantic source describes the drawn layout. The
  resolve+`list` plumbing stays because the *contents* enumerate fine — it's
  identity, not position. Desktop + disk icons DO work (hand-placed →
  `fdLocation`/Finder-position = screen).
- **Guest resolution is auto-detected** from the `video` verb (main-device
  `gdRect`); do not hardcode 800×600.
- **Icons** come from each app's own resource-fork bundle (BNDL/FREF/icl8),
  extracted by `extract-assets/iconpack.py`, composited through the corrected
  system CLUT (`clut.py` — the tail off-by-one that darkened -4000 is fixed).
  Control panels are type **`APPC`** (not `cdev`). 3rd-party / `????`-creator
  items fall back to real generic bitmaps by kind. The hard-disk icon lives in
  ROM/Icon Services (no file) → drawn procedurally.

## Open threads & follow-ups

- **Content plane — LANDED (2026-07-17), see *Window interiors*.** The old plan
  here ("re-enable Finder-window icons with a one-line `includeWindowItems`
  flip once QD supplies positions") was **wrong twice over** and is retired:
  the Finder composites icon views offscreen, so QD supplies no per-icon
  positions at all, and `fdLocation` never described the drawn layout. Icons
  render because M3 islands carry the real pixels. `includeWindowItems` stays
  OFF and is now only a legacy path for targets without a content plane.
- **Scroll actuation — LANDED (2026-07-17).** A live scrollbar hit-tests to the
  REGION pressed (`HitTester.scrollbar` + `Scrollbar.part`), because arrows,
  page gaps and the thumb are three different guest actions. Arrows/pages are a
  QMP press-release (TrackControl is a tracking loop the wire can't drive, and
  `axdo` would hit the control's CENTRE — a page gap — whatever you pressed);
  the thumb is a drag. A wheel notch maps to the arrow the user would have
  clicked (OS 9 has no wheel driver — injecting wheel events would no-op).
  `--act-scroll down|up|pageDown|pageUp|thumb:V|wheel:N` drives it headlessly;
  the battery covers line + thumb.
- **Island cost** — ~1s per full-window fetch @ depth 16, fetch-on-change. A
  dirty-rect capture (the blit `dst` only) would cut both time and bytes;
  deliberately deferred. `islandBytesFetched` is the meter.
- **The canonical image's anchor predates the FlushVol fix**, so staging needs
  `MIRROR_FLUSH_WAIT` (spin-up does it, then verifies after the reboot). An
  image refresh retires the wait — [[qdpeek-guest-staging-does-not-persist]].
- **True per-app icons via the Desktop DB** (`PBDTGetIcon`) — not in the
  Retro68 headers; would need declaring the Desktop Manager traps. The
  resource-fork route we use covers the vanilla+ set; the DB would also catch
  custom alias icons (the `aplt` applet aliases collide on the generic applet
  icon today).
- **Maturity-gate criteria** (MIRRORKIT-PLAN) — define the trigger for IR
  freeze + Phase 3.
- **Shortcut-less menu-drag reliability** — the last red on the battery. The
  open-loop drop is mouse-accel- and connection-state-sensitive, and a miss
  *selects the wrong item*. The accel-immune fix is **screendump-closed-loop**:
  after pressing the menu, QMP `screendump` (reads emulated VRAM even while
  MenuSelect starves the Worker — that's how the calibration here was done)
  → detect the highlighted row → correct → release. Bigger than a one-liner;
  scoped but not built. Until then, prefer the ⌘-keystroke path; most items
  have a shortcut.
- **Dropdown render grays by the resting enable bit** — an open app menu
  previews all-disabled (see the enable-bit gotcha). Fix when a menu-open
  enablement snapshot or the QD plane lands; low priority (preview-only).
- **Metal degradation** — the QMP actions (drag/menu-drag/qmpClick/window-raise)
  are emu-only; a VBL mouse-walker is the metal path.

## Reference docs

- `MIRRORKIT-PLAN.md` — the canonical plan (posture, decisions, roadmap).
- `CONTROL-SURFACE.md` — the perceive+act capability map + gotchas.
- `ASSET-EXTRACTION.md` / `extract-assets/` — the asset + icon pipeline.
- Findings: `host-desktop-mirror-spike`, `platinum-asset-extraction`.
