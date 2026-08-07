# Scoping: the Mirror as a host module, detachable into a window

**Read-only scoping pass. No implementation.** Tree read at
**2026-08-07 ~01:50 EDT**, branch `claude/018-integration` at `461fa61a`
("docs(open-issues): the first watch of the integrated render"), several
lanes merging concurrently. Every line number below is that snapshot; a
merge that touches `NOWMirrorSource.swift`, `MirrorControlView.swift` or
`mirror/host/MirrorKit/Sources/MirrorKitUI/**` will move them.

---

## Verdict first

**The rendering half is nearly free. The lifecycle half is the job, and
one thing in it is a genuine trap.**

- The view→scene transform is **already** fully parameterised by the
  view's size (`GeometryReader` → `FitTransform`). A pane needs no
  coordinate work at all. This is the single biggest cost that is *not*
  there.
- Zoom is a `.frame()` around an existing view. `SceneRenderer` already
  scales the whole `GraphicsContext` by the fit factor, so 200% is one
  number.
- `RenderShot` is provably unperturbable — it takes its size as a
  parameter and reads no shared state.
- **The trap is `KeyCapture.swift:96-99`**: the mirror's keyboard view
  seizes first responder from whatever window it lands in, and
  `performKeyEquivalent` then swallows *every* ⌘ combination except
  ⌘Q/⌘W/⌘H and forwards it to the classic Mac. In its own window that is
  correct and deliberate. Inside NOW's main window it means selecting
  the Mirror module silently disables ⌘⇧M, ⌘0, ⌘/ and every other host
  shortcut, and steals focus from the sidebar. Fixing it means an API
  change in the **vendored MirrorKit package**, which is a separate gate
  (`scripts/test-mirrorkit`) and a sibling project's source.
- **The second cost is a policy conflict Michelle's own framing exposes.**
  "Stop when backgrounded" and "one model per session, both containers
  observing it" are in tension with the MCP face: `now_mirror_drive`,
  `now_mirror_status` and the whole fidelity sweep read
  `HostAppState.mirrorSource` **regardless of any window**, and every one
  of them refuses when `running == false`
  (`NOWMirrorSource.swift:1647-1650`, "The Mirror has no pinned Mac.
  Start it before acting."). If switching to the Console page stops the
  poll, an agent drive that worked a second ago starts refusing with no
  visible cause. See Q2 for the recommendation.

Size: **~38 edit places** across 22 files, of which 9 are compile errors
if missed and 11 fail a test, and 6 fail nothing at all. Detail below.
That is bigger than the 21-place `host.show` lane, but the extra bulk is
docs and label churn rather than new mechanism.

---

## The seven questions

### Q1 — Is the view→scene transform parameterised by the view's size?

**Yes, completely. Confirmed. This is not the work.**

- `mirror/host/MirrorKit/Sources/MirrorKitUI/FitTransform.swift:15-20` —
  `init(logical: CGSize, view: CGSize)`. Both sides are arguments;
  nothing global, nothing window-derived.
- `mirror/host/MirrorKit/Sources/MirrorKitUI/LiveMirror.swift:128` —
  `GeometryReader { geo in`. Every input path takes `geo.size`:
  `guestPoint(_:scene:size:)` at `:253-257`, `mouseGesture(scene:size:)`
  at `:259-260`, `point(_:_:_:)` at `:358`, the hover resolver at
  `:161`, and the dropdown hit at `:180-183`.
- `mirror/host/MirrorKit/Sources/MirrorKitUI/SceneRenderer.swift:63-73` —
  `draw(in:size:)` builds the **same** `FitTransform` from the passed
  size and applies it as a CTM (`translateBy` / `scaleBy`). One
  definition, used both ways, exactly as the header comment claims.
- `mirror/host/MirrorKit/Sources/MirrorKitUI/SceneView.swift:25` —
  `Canvas { ctx, size in }`. The size comes from the layout system.

**Today's two changes are both in guest coordinates and are unaffected:**

- `mirror/host/MirrorKit/Sources/MirrorKit/FinderItems.swift:308-323`
  (`clickPoint`) works entirely in guest units — `HitTester.targetSize`,
  `item.x/y`, `contentOrigin(win)`. No view size appears.
- `HitTester` likewise takes `(scene, x:, y:)` in guest units.

**The only window-bounds assumptions in the whole path are in
`NOWMirrorWindow.swift`**, and they are all window *policy*, not
geometry the renderer needs:

| file:line | assumption | fate in a pane |
|---|---|---|
| `now-host/Sources/Host/NOWMirrorWindow.swift:77` | `controller.sizingOptions = []` | n/a |
| `:81-82` | `setContentSize(screen × scale)` | becomes the zoom stop |
| `:87`, `:171-172` | `contentMinSize = screen/2` | becomes the 50% zoom floor |
| `:88` | `setFrameAutosaveName` | detached window only |
| `:154-179` | `fitToGuestScreen()` — bounded 10s poll for the first scene, then `contentAspectRatio` | replaced by "fit" as the default zoom stop; **`contentAspectRatio` has no pane equivalent — `.aspectRatio()` inside the ScrollView is the substitute** |
| `:192-203` | `ensureOnScreen` | detached window only |

One layout consequence worth naming now: `HostRootView.swift:45` gives
the detail column `minWidth: 480, idealWidth: 820`. An 832×624 guest at
**100%** does not fit a default-width main window. That is the exact
objection `NOWMirrorWindow.swift:8-14` raises against a pane — and the
zoom slider with a "fit" stop is the answer to it, provided **fit is the
default** and 100%+ scroll inside the pane.

### Q2 — Where does the poll's lifecycle live, and what breaks on restart?

**It is tied to the window today, in four places, all in
`NOWMirrorWindow.swift`:**

| file:line | |
|---|---|
| `NOWMirrorWindow.swift:100` | `show()` → `source.start()` |
| `NOWMirrorWindow.swift:113` + `:135-144` | `retryStart()` — the bounded ~10s retry, 40 × 250 ms |
| `NOWMirrorWindow.swift:206` | `close()` → `source.stop()` |
| `NOWMirrorWindow.swift:239` | `windowWillClose` → `source.stop()` |

The race you remembered is documented in place at `:48-61` and
`:101-113`: `start()` **refuses** when `cycleIO.activeKey()` is nil
(`NOWMirrorSource.swift:422-425`), and `--open-mirror` fires on the first
connection change, before the listener has an active key. Under the new
model that retry loop is a property of the **running axis**, not of the
window, and must move with it — otherwise "Start" from the module page
inherits the same one-shot refusal the window learned to survive.

**What survives a stop-and-restart (checked):**

- **The state engine and the scene.** `MirrorStateEngineRegistry` keys
  engines by `GuestKey` and never removes on stop
  (`MirrorStateEngineRegistry.swift:9-14`). `start()` re-fetches it and
  seeds `scene` from its snapshot
  (`NOWMirrorSource.swift:427-429`). So the pane does **not** blank on
  restart — it shows the last scene while the first new one arrives.
- **The Finder icon cache** (`icons`, `iconLayout`,
  `NOWMirrorSource.swift:332-333`) — never cleared by `start()` or
  `stop()`. Free.
- **The act and cycle timelines** (`:355-356`) — deliberately survive a
  guest change, so certainly survive a stop.

**What does NOT survive, and what the user sees:**

1. **The content plane (P3) is torn down and re-armed.**
   `stop()` calls `cycleIO.disableContent` (`NOWMirrorSource.swift:475`)
   → `NOWMirrorContentPlane.disable` (`:172-186`) → `qdtrace op=stop` on
   the guest, then `guestChanged()` which wipes every settled display,
   every draw op, and `armedAt` (`:149-168`). On restart the interiors
   come back only on the next successful `join`. **The user sees window
   interiors go empty for one to two cycles** (~1.5s at
   `interval: 0.75`, `NOWMirrorSource.swift:383`).
2. **P1/P2/P4 leases lapse.** The comment at `NOWMirrorSource.swift:470-474`
   is explicit: they are ten-second resident leases that retire by not
   being renewed. A stop shorter than ~10s keeps them; a longer one
   costs a re-arm. **The anchor lease is in this group** — so a stop
   longer than ten seconds means every act refuses
   `element-not-found: the anchor plane is absent or not armed` until
   the restart re-arms it (the failure `NOWMirrorSource.swift:886-892`
   describes).
3. **`stop()` schedules a lifecycle refresh eleven seconds later**
   (`:493-496`), so the Mirror page's plane card lies about the plane
   state for up to 11s after a restart unless that task is cancelled.

**And one real defect that a Start/Stop button makes routine:**

`NOWMirrorContentPlane.disable`'s completion calls `self?.guestChanged()`
at **`NOWMirrorContentPlane.swift:183` with no generation guard.** Both
call sites in `NOWMirrorSource` guard *their own* completion
(`:480-484`, `:665`), but the plane wipes itself *first*, inside its own
closure. A stop→start inside the `qdtrace` round trip therefore clears
content the **new** run has already accumulated. Today that sequence
needs a deliberate Close-then-Open double click; with a Start/Stop
toggle it is one impatient user. Effect is a one-cycle content flash,
not a permanent break — but it is invisible in review and looks like a
render defect.

**Recommendation on backgrounding.** Do **not** stop the poll when the
module is backgrounded. Three reasons, in order of weight:

1. `HostAppState.swift:335-353` binds `bindMirrorDriver` to
   `mirrorSource` with no window involved, and comments explicitly that
   a drive must not be refused "because nobody had opened a window yet."
   Every `now_mirror_*` projection and the whole fidelity sweep depend
   on the poll running while nobody is looking at it.
2. Stop costs a P3 teardown and, past ten seconds, the anchor lease —
   so backgrounding is not cheap, and the cost lands on the *next*
   interaction, where nothing explains it.
3. `HostRootView.swift:166-219` is a `switch` in a `ViewBuilder`, so the
   pane's view is destroyed on module switch anyway. The rendering cost
   of backgrounding is already zero without touching the poll.

Michelle's instinct was right that pause is the two-clocks problem; the
honest third option is **neither** — leave the poll to its own explicit
axis, exactly as she framed it, and let backgrounding do nothing. If a
cost lever is wanted later, the cheap one is lengthening `interval`
while backgrounded, which no clock depends on.

### Q3 — Where does the model live, and what would "keyed by the session key" mean?

**It already lives on `HostAppState`, as one lazy per app process:**

- `HostAppState.swift:102-122` — `private(set) lazy var mirrorSource`,
  with `madeMirrorSource` (`:100`) guarding against a metrics read being
  the thing that constructs it.
- `HostAppState.swift:123` — `private(set) lazy var mirrorWindow =
  NOWMirrorWindow(source: mirrorSource)`.

**It is not keyed by session, and it does not need to be — the keying
already exists one level down and is better placed there:**

- `MirrorStateEngineRegistry.swift:7` — `[GuestKey: MirrorStateEngine]`,
  "exactly one engine for one live GuestKey/session. A reconnect has
  another key and therefore cannot inherit the prior replica
  accidentally."
- `NOWMirrorSource.pinnedGuestKey` (`:377`) is the source's binding to
  one session, set in `start()` (`:426`) and compared against
  `listener.activeKey` before every act (`:1649-1655`) and every cycle
  publish (`:651`).

So "one model per session, both containers observing it" is **already
true**: one `NOWMirrorSource`, pinned to one key, holding the engine for
that key. Both containers would render the same `@ObservedObject`. There
is nothing to build here.

**`NOW_PREFS_SUFFIX` is a different axis and does not interact.**
`ProductIdentity.swift:26-33` scopes the *UserDefaults suite*, not the
session — it separates two host **processes** on one Mac so they do not
overwrite each other's saved page selection and port. The new persisted
state (running / detached / zoom) goes through the same `defaults`
`HostAppState` already holds, so it inherits the suffix for free and
needs no code. The pattern to copy verbatim is
`SidebarPreferences.swift:19-49` — `@Published var x { didSet {
defaults.set(...) } }`, keys as private statics, sanitisation as a pure
static so it is testable without a suite.

**One thing that will bite and is a one-word fix:**
`NOWMirrorSource.swift:313` is `private(set) var running`, **not
`@Published`**. `NOWMirrorWindow.isOpen` (`:23`) *is*, which is why the
current Open/Close button updates. A Start/Stop button bound to
`source.running` will render its label once and then never change.

### Q4 — Where is image sampling configured, and can it be nearest-neighbour?

**Yes — settable, per image, at eight sites. Nowhere else.**

The renderer draws every bitmap through
`GraphicsContext.draw(Image(decorative: cgImage, scale: 1), in: rect)`.
`GraphicsContext` has **no** context-wide interpolation property, so
there is no one place to set it; but `Image.interpolation(_:)` returns
an `Image`, so `ctx.draw(Image(decorative: x, scale: 1)
.interpolation(.none), in: rect)` is the minimal edit at each site:

| file:line | what |
|---|---|
| `MirrorKitUI/SceneRenderer.swift:175` | desktop picture |
| `MirrorKitUI/SceneRenderer.swift:187` | desktop pattern tile (in a tiling loop) |
| `MirrorKitUI/SceneRenderer.swift:263` | desktop item icon from `IconAtlas` |
| `MirrorKitUI/SceneRenderer.swift:436` | menubar / front-app process icon, 16×16 |
| `MirrorKitUI/SceneRenderer.swift:692` | the guest pixel island |
| `MirrorKitUI/SceneRenderer.swift:1417` | generic document-icon stub |
| `MirrorKitUI/DisplayReplay.swift:365` | replayed icon blit |
| `MirrorKitUI/BitmapFont.swift:116` | **the glyph sheet — every character of system and app text** |

`MirrorKitUI/UnknownVisual.swift:112` uses
`.fill(Path(frame), with: .tiledImage(tile))`, which takes no
interpolation parameter at all. It is the one site that cannot be set
without restructuring into explicit `draw` calls.

**The existing `shouldInterpolate: false` flags are not enough**, and
this is the part that makes your instinct correct. They are set only on
hand-built CGImages — `SceneRenderer.swift:1752` (pixel islands),
`UnknownVisual.swift:149`, `MirrorApp/main.swift:307`,
`now-host/Sources/Host/CaptureDecoder.swift:215`. Everything loaded from
the asset pack through `CGImageSourceCreateImageAtIndex` — the
`IconAtlas` icons (`IconAtlas.swift:54-64`), the **BitmapFont glyph
sheet** (`BitmapFont.swift:42-43`), the desktop picture and pattern
(`BitmapFont.swift:249-255`) — arrives with `shouldInterpolate`
defaulting to **true**. At 200% that smooths every glyph in the mirror.

The precedent for the fix already exists in this repo:
`now-host/Sources/Host/ScreenshotsModuleView.swift:332` —
`.interpolation(.none)` with the comment "nearest-neighbor keeps the
classic pixels crisp at any scale". `StreamRecorder.swift:158` sets
`interpolationQuality = .none` on its CGContext for the same reason.

**Two things to decide rather than assume:**

1. At the **"fit"** stop the scale is fractional, and nearest-neighbour
   there is a real trade: correct for 1-pixel chrome, noticeably harsher
   on the desktop picture. Setting it unconditionally is the honest
   choice (a blurred hairline is a *wrong* picture; an aliased desktop
   picture is an ugly one), but it is a choice.
2. It changes **RenderShot output at non-1:1 sizes**. Most render tests
   run at logical size where scale is exactly 1 and nothing moves, but
   `now-host/Tests/HostTests/MirrorMenubarRenderTests.swift:73,87,103`
   pass an explicit `CGSize(width: 800, ...)`. Check those before
   assuming the pixel gates are unaffected.

**Vector drawing is unaffected either way** — 115 `.fill`/`.stroke`
calls against 8 image draws. But by *pixels*, text and the desktop
backdrop are bitmaps, so those two sites carry most of the visible
consequence.

### Q5 — How does this interact with the open-Mirror work that just landed?

**Of the 21 places, 15 are untouched, 4 change meaning, and 2 change
text.** The mechanism — contract, wire, guest button, console verb, MCP
verb — all survives, because every one of them ends at
`HostAppState.showMirrorWindow()` and that function keeps its job.

**Untouched (contract and wire, all of it):**
`contract/asyncapi.yaml:305-306, 1019-1051, 1052-1070, 1298-1303,
1759-1773, 1774-1800`; `ContractMessages.swift:92-93, 114-117, 122-127,
1424-1427, 1569-1570`; `Session.swift:81, 216, 262, 560-567`;
`GuestListener.swift:843-845, 2738-2741`;
`HostSurfaceService.swift:24-95`; the whole
`AgentIntegrationLocalProtocol.swift` / `Client` / `Server` set; guest
`wire.c:3495-3590, 6436-6438, 6832` and `wire.h:405-425`. A `host.show`
still means "the person at the classic Mac wants to see the Mirror on
the host", and it still is.

**Changes meaning (4):**

1. **`HostAppState.swift:126-165 showMirrorWindow()`** — the one
   implementation. Under the new model it must resolve **both** axes:
   *make sure it is running* **and** *put it where it can be seen*
   (raise the detached window if detached; select the Mirror module if
   attached). Today it does the second only, because opening implied
   starting. If it does not gain the first, `showmirror` from a stopped
   Mirror reproduces exactly the 2026-08-06 defect
   (`docs/open-issues.md:525`, "`--open-mirror` could leave a window
   over a stopped poll") through a different door. **This is the single
   most important edit in the whole job.**
2. **`App.swift:175-187 @objc func showMirror()`** — its refusal
   fallback is already `show(moduleID: "mirror")` (`:186`). In the
   attached case that stops being a fallback and becomes the primary
   action.
3. **`NOWMirrorWindow.swift:45-66 openIfLaunchAsked` / `MirrorLaunchOptions.swift:16-20
   --open-mirror`** — "open the window" now means "start, and detach".
   The headless sweep wants *start*; the detach is incidental. Consider
   whether `--open-mirror` should mean start-only now.
4. **`NOWMirrorWindow.swift:205-209 close()` and `:237-240
   windowWillClose`** — both call `source.stop()`. Under start/stop
   these must **not**: closing the detached window re-attaches, it does
   not stop the machine. Leaving `source.stop()` in `windowWillClose` is
   the most likely single bug in the implementation, because the
   docstring at `:236-240` argues for it convincingly and the argument
   was correct under the old model.

**Changes text (2), and the labels' honesty:**

5. **`MainMenu.swift:280`** — `item("Show Mirror", actions.showMirror,
   "m", modifiers: [.command, .shift])`. **"Show Mirror" stays true**
   under the narrower meaning; it is the right verb for "bring it into
   view" and it already covers both containers. Keep it. Gated by
   `MainMenuTests.swift:173-190` (title, selector, key, modifiers) —
   don't rename it casually, and if you do, `MirrorStateProjections.swift:274-278`
   holds the literal `item("Show Mirror", actions.showMirror` as a face
   claim that `HostFaceParityTests.swift:157-167` greps for.
6. **`MirrorControlView.swift:65`** —
   `Button(mirrorWindow.isOpen ? "Close Mirror" : "Open Mirror")` is the
   one label that becomes a **lie** and must be replaced by two
   controls: Start/Stop (bound to `source.running`) and
   Detach/Attach (bound to the presentation state). Two tests assert the
   old string: `MirrorPlaneDomainTests.swift:316` and
   `tools/mirror-gate-tests/test_legacy_mirror_retirement.py:51`.

**The guest's button: `now-guest-ppc/src/mirror/mirror_show.c:7` reads
`"Show Mirror on Host"`.** It stays **true and should not change.** From
the classic Mac's chair the ask is "make the Mirror visible on that Mac"
— it names an outcome on the host, not a window, and the host is now
free to satisfy it by selecting a module instead of opening a window.
The host's *answer sentence* is the part that stops being true:
`HostAppState.swift:162-164` says "Opened the Mirror on \(name)" /
"The Mirror was already open; brought it to the front." Both name a
window. Those two strings cross the wire into
`mirror_module.c:63-70` and are drawn in the guest's status line
(`mirror_module.c:162-163`), so a guest user reads them verbatim. They
need rewording; the guest C needs no change to receive the new wording.

### Q6 — Does `ModuleRegistry` accommodate a live poll and a detach?

**The registry itself: yes, trivially, and the module already exists.**
`ModuleRegistry.swift:100-105` already declares `id: "mirror"`, and
`HostRootView.swift:177-182` already draws `MirrorControlView` for it.
No registry row is added, no rename table entry
(`ModuleRegistry.swift:44`) is needed, `SidebarPreferences.sanitised`
already handles it. This is the cheapest part of the job.

**Its summary line is now wrong, though**:
`ModuleRegistry.swift:104` reads *"Run Mirror against the connected Mac,
and see if it is ready"*, and the comment above at `:96-99` says
explicitly "this page owns whether that Mac is ready for it and one
instance's lifecycle, **not the drawing**." That comment becomes false
the moment the page draws.

**No existing module does either thing, and here is the cost:**

- **No module owns a live poll.** The only repeating timers in the host
  outside the Mirror are `FilesModuleView.swift:18` (a 1s UI tick) and
  `GuestStatus.swift:151`. Every other module is request/response. So
  the "a module that keeps working while you are not looking at it"
  posture has no precedent, and `HostRootView.swift:166-219` being a
  `ViewBuilder` switch means the *view* is destroyed on every module
  switch. The model surviving that is fine (all models are `lazy var`s
  on `HostAppState`) — but any `@State` inside `LiveMirrorView` is not:
  `openMenu`, `hoveredItem`, `selectedItem`, `lastClick`, `dragOutline`,
  `dragMode` (`LiveMirror.swift:96-115`) all reset on every module
  switch and on every attach/detach. A menu the user left open closes;
  a desktop selection the mirror was drawing itself vanishes. That is
  acceptable but it must be a decision, not a surprise.
- **No module detaches.** There is no host precedent for a pane that can
  become a window, so the container abstraction is new code, not a
  pattern to copy. Keep it small: one `ObservableObject` holding
  `isDetached` + `zoom`, one `if` in the module view, and the existing
  `NOWMirrorWindow` reduced to the detached case.
- **`ModuleRegistryTests.swift:83-91`** (`testEveryModuleHasADetailPane`)
  reads `HostRootView.swift` as text looking for `case "mirror":`. It
  keeps passing; just don't restructure the switch away from that
  literal form.

### Q7 — What does `RenderShot` need to stay unaffected?

**Nothing. It is already immune, and I can say why rather than assert
it.**

`RenderShot.png` (`MirrorKitUI/SceneView.swift:41-62`) takes every input
as an explicit parameter — scene, openMenu, hoveredItem, selectedItem,
size — and reads no ambient state:

- `SceneView.swift:47` — `let size = size ?? SceneRenderer(scene:
  scene).logicalSize`, i.e. the guest's own `scene.screen.w/h`
  (`SceneRenderer.swift:41-45`). At that size
  `FitTransform(logical:view:)` computes `scale == 1, offset == .zero`
  (`FitTransform.swift:16-19`), so the `ctx.scaleBy` at
  `SceneRenderer.swift:71` is a no-op and every pixel is 1:1.
- `SceneView.swift:53` — `renderer.scale = 1`, so no Retina 2× resample.
- `SceneRenderer`'s stored properties are five `let`s
  (`SceneRenderer.swift:17-28`). Neither `SceneView` nor `SceneRenderer`
  holds an `@Environment`, `@State`, `@AppStorage`, or observable-object
  reference. There is **no channel** through which a UI zoom could reach
  them.
- All the mirror's mutable UI state is `@State` on `LiveMirrorView`
  (`LiveMirror.swift:96-115`) and is passed down by value.

**Therefore the one rule the implementation must not break: put zoom in
the container, never in `SceneView` or `SceneRenderer`.** A `.frame()`
(or `.scaleEffect`) applied by `MirrorPaneView` around the existing
`SceneView` cannot reach `RenderShot`. A `zoom:` parameter added to
`SceneView` or `SceneRenderer` immediately can, and would be a
compile-visible change at all 20-odd `RenderShot.png` call sites — so
even the wrong choice fails loudly. Good.

Callers that must keep working, for the record:
`MirrorApp/Serve.swift:250,498-507` (`mirror.shot` over MCP);
`MirrorApp/main.swift:154-157,188,231,334,602,644,366-370`;
`mirror/tests/mirror-service-e2e.py:156`; `mirror/tests/agent-session.py:144`;
and the pixel suites `SceneRenderTests`, `LiveShapedRenderTests`,
`NOWMirrorContentCoverageTests`, `NOWMirrorContentPlaneTests`,
`AlertItemTests`, `DesktopPlaneCrossingTests`, `DrawnCellGridTests`,
`MirrorMenubarRenderTests`.

**One thing that does break and is easy to miss:**
`NOWMirrorWindow.exportEvidence` (`:214-231`) captures pixels from
`self.window?.contentView` via `bitmapImageRepForCachingDisplay`. When
the Mirror is **attached**, `window` is nil and evidence export throws
`emptyFrame` — silently, from the caller's point of view, since the
error names an empty frame rather than a missing window. That path
should move to `RenderShot` (same pixels by construction, per
`SceneView.swift:5-6`) or the exporter must refuse by name.

---

## The edit list

22 files. **L** = compile error if missed. **T** = a test fails. **S** =
nothing fails.

### A. Containers and presentation state (new code)

| # | file:line | edit | |
|---|---|---|---|
| A1 | `now-host/Sources/Host/MirrorPaneView.swift` (new) | the attached container: zoom control, `ScrollView` + `.aspectRatio`, `LiveMirrorView(controller: source)` | L (unbuilt file) |
| A2 | `now-host/Sources/Host/MirrorPresentation.swift` (new) | `ObservableObject` with `isDetached` + `zoom`, persisted via `defaults`, pattern of `SidebarPreferences.swift:19-49` | L |
| A3 | `HostAppState.swift:123` | `mirrorWindow` gains the presentation object; add `lazy var mirrorPresentation` beside it | L |
| A4 | `HostRootView.swift:177-182` | `case "mirror":` composes controls + pane (keep the literal `case "mirror":` — `ModuleRegistryTests.swift:83`) | T |
| A5 | `MirrorControlView.swift:53-77` | `productCard` becomes Start/Stop + Detach/Attach; delete the `mirrorWindow.isOpen ? "Close Mirror" : "Open Mirror"` ternary at `:65` | T |
| A6 | `MirrorControlView.swift:8` | `@ObservedObject var mirrorWindow: NOWMirrorWindow` → the presentation object | L |
| A7 | `MirrorControlView.swift:58-60` | the two sentences about "the native Mirror window" | S |
| A8 | `NOWMirrorWindow.swift:68-133` | `show()` narrows to detach-and-raise; drop `source.start()` (`:100`) and `retryStart()` (`:113`) | S — **it compiles and quietly starts nothing** |
| A9 | `NOWMirrorWindow.swift:205-209, 237-240` | `close()` / `windowWillClose` must **stop calling `source.stop()`** and instead re-attach | S — **the most likely single bug in the job** |
| A10 | `NOWMirrorWindow.swift:135-144` | `retryStart()` moves to whatever owns the running axis | S |
| A11 | `NOWMirrorWindow.swift:154-179` | `fitToGuestScreen` keeps working for the detached window; the pane needs its own "fit" | S |
| A12 | `NOWMirrorWindow.swift:214-231` | `exportEvidence` — nil window when attached; route through `RenderShot` or refuse by name | T (`MirrorEvidenceExporter` suites) |

### B. The running axis

| # | file:line | edit | |
|---|---|---|---|
| B1 | `NOWMirrorSource.swift:313` | `private(set) var running` → `@Published private(set) var running` | S — **the button label freezes** |
| B2 | `HostAppState.swift:126-165` | `showMirrorWindow()` must start-if-stopped as well as show; rename it (`showMirror()`) since it no longer necessarily means a window | T (`MirrorOpenTests.swift:41,61`) |
| B3 | `HostAppState.swift:160-164` | the two outcome sentences that name a window — they are drawn in the guest's status line | S |
| B4 | `HostAppState.swift:291` | `openIfLaunchAsked` call site | S |
| B5 | `MirrorLaunchOptions.swift:8-20` | decide whether `--open-mirror` means start-only | T (`MirrorLaunchOptionsTests.swift:4-11`) |
| B6 | `NOWMirrorContentPlane.swift:183` | guard the `guestChanged()` in `disable`'s completion against a newer arm | S — **one-cycle content wipe, reads as a render defect** |
| B7 | `NOWMirrorSource.swift:493-496` | the 11s deferred `lifecycleDidChange` should be cancellable on restart | S |
| B8 | `NOWMirrorSource.swift:1647-1650` | the "Start it before acting" refusal already uses the right verb — confirm it still names the new control | S |

### C. Zoom and sampling (vendored MirrorKit — separate gate)

| # | file:line | edit | |
|---|---|---|---|
| C1 | `MirrorKitUI/SceneRenderer.swift:175, 187, 263, 436, 692, 1417` | `.interpolation(.none)` on six `Image` values | T (pixel suites) |
| C2 | `MirrorKitUI/DisplayReplay.swift:365` | same | T |
| C3 | `MirrorKitUI/BitmapFont.swift:116` | same — the glyph sheet, the highest-traffic one | T |
| C4 | `MirrorKitUI/UnknownVisual.swift:112` | `.tiledImage` takes no interpolation; decide to restructure or accept | S |
| C5 | `scripts/test-mirrorkit` | must be run — `mirror/` has its own suite and it is stage 2 of `test-all` for exactly this reason | T |
| C6 | `MirrorMenubarRenderTests.swift:73, 87, 103` | the only render tests at a non-logical size; re-check after C1–C3 | T |

### D. Keyboard focus (the trap)

| # | file:line | edit | |
|---|---|---|---|
| D1 | `MirrorKitUI/KeyCapture.swift:96-99` | `viewDidMoveToWindow` → `window?.makeFirstResponder(self)` unconditionally. In a pane this steals focus from the whole main window on appear | S — **focus theft, invisible in review** |
| D2 | `MirrorKitUI/KeyCapture.swift:103-114` | `performKeyEquivalent` consumes every ⌘ combination except q/w/h and forwards it to the guest. Attached, that eats ⌘⇧M, ⌘0, ⌘/ and the rest of the host's menu | S — **silently disables the host's own shortcuts** |
| D3 | `MirrorKitUI/LiveMirror.swift:135-146` | `LiveMirrorView` needs a way to say "do not seize focus" (or "only while I am the focused pane"), which is a new MirrorKit API surface | L once D1/D2 change signature |
| D4 | `MirrorKitUI/KeyCapture.swift:83` | `hostReserved` = `["q","w","h"]` — attached, this set must be much larger, or focus must be click-to-enter | S |

### E. Faces, gates and docs

| # | file:line | edit | |
|---|---|---|---|
| E1 | `NOWAgentIntegration/Projection/MirrorStateProjections.swift:37-38` | `.appUI: .reached(file: "NOWMirrorWindow.swift", symbol: "LiveMirrorView(controller: source)")` — if the pane becomes the primary UI face, this file/symbol pair is stale | T (`HostFaceParityTests.swift:157-167` greps the named file for the literal symbol) |
| E2 | `MirrorStateProjections.swift:274-278` | `MirrorOpenProjection`'s face names `MainMenu.swift` + `item("Show Mirror", actions.showMirror` — only if the menu item changes | T |
| E3 | `MirrorPlaneDomainTests.swift:316` | asserts `"Open Mirror"` in the control view | T — loud |
| E4 | `tools/mirror-gate-tests/test_legacy_mirror_retirement.py:51` | asserts `"Open Mirror"` | T — loud, and outside `test-host`; **check whether `test-all` reaches it** |
| E5 | `MainMenuTests.swift:173-190` | keep passing (recommendation: don't rename the item) | T |
| E6 | `ModuleRegistry.swift:104` | summary "Run Mirror against the connected Mac, and see if it is ready" | S |
| E7 | `ModuleRegistry.swift:96-99` | the comment "this page owns ... **not the drawing**" becomes false | S |
| E8 | `docs/mcp-coverage.md:106` | the `now_mirror_open` row's prose describes a window-only lifecycle | T (`MCPCoverageTests.swift:62`, table-vs-registry — the row survives; the *prose* is ungated) |
| E9 | `docs/command-parity.md:103` | the `showmirror` row's explanation of what the host's own faces are | T-paired (`CommandParityTests.swift:238`) |
| E10 | `README.md:45` | the capability row, currently "emulator-verified 2026-08-06" against window semantics | S |
| E11 | `docs/open-issues.md:428-472, 525` | the ledger entry and the "window over a stopped poll" defect — the new model changes what that defect *is* | S |
| E12 | `docs/contract-coverage.md:192, 1007, 1019-1026` | counts are **unaffected** (no message added); re-derive at the merge anyway per AGENTS.md | T |

**Not needed, confirmed:** any contract change; any guest C change
(`mirror_show.c`, `mirror_module.c`, `wire.c`, `console_model.c` all
survive as-is); any new `ModuleRegistry` row; any `renamedIDs` entry; any
`HostSurface` case; any new agent operation; any change to `RenderShot`.

---

## Loud versus silent

**Fails at compile (9):** A1, A2, A3, A6, D3, plus the four
`HostSurfaceOutcome` / `Operation` exhaustive switches at
`HostAppState.swift:324`, `App.swift:498`,
`AgentIntegrationLocalProtocol.swift:1532`,
`AgentIntegrationLocalClient.swift:236` **only if** a new surface or
operation is introduced — which this design does not require.

**Fails a test (11):** A4, A5, A12, B2, B5, C1–C3, C5, C6, E1–E5, E8,
E9, E12. Of these, E3 and E4 are the friendly ones — a string literal
assertion that names itself. E1 is the subtle one: it fails naming a
*file*, and the fix is to decide which file is now the app's face for
the Mirror, which is a design question wearing a test failure's clothes.

**Fails nothing, in rough order of how much it will cost you (10):**

1. **A9** — `windowWillClose` keeps calling `source.stop()`. Closing the
   detached window silently kills the poll and every agent drive with
   it. The existing docstring argues *for* the old behaviour.
2. **D2** — every host ⌘ shortcut silently forwarded to the classic Mac
   while the Mirror pane has focus. Nothing errors; ⌘⇧M just stops
   working.
3. **D1** — the Mirror pane seizes first responder from the main window
   on appear.
4. **B1** — `running` not `@Published`; the Start/Stop button renders
   once and freezes.
5. **A8** — `show()` no longer starts the poll, so `showmirror` from the
   guest brings up a Mirror that shows a frozen scene. This is
   `docs/open-issues.md:525` returning through a new door.
6. **B6** — the ungated `guestChanged()` at
   `NOWMirrorContentPlane.swift:183`; a quick Stop→Start wipes the new
   run's content for a cycle and looks like a render bug.
7. **B7** — the 11s deferred lifecycle refresh reporting a stale plane
   state after a restart.
8. **C4** — `UnknownVisual`'s tiled shading stays smoothed while
   everything around it is crisp.
9. **A11** — the pane has no `contentAspectRatio` equivalent; if "fit"
   is not implemented as an aspect-preserving frame the letterbox band
   comes back, and `FitTransform` will keep the coordinates exact so
   nothing *breaks* — it just wastes a band the user keeps clicking in.
10. **E7** — a comment in `ModuleRegistry.swift` that now says the
    opposite of the truth, which is how the next reader learns something
    false.

---

## Cheaper than expected

- **The transform. Entirely.** I expected this to be the job and it is
  already done: `FitTransform` takes both sizes as arguments,
  `LiveMirrorView` is wrapped in a `GeometryReader`, and
  `SceneRenderer.draw` applies the same fit as a CTM. A pane and a
  window are the same code path with a different number.
- **Zoom is `ctx.scaleBy`.** Because the renderer scales the whole
  graphics context (`SceneRenderer.swift:71`), 200% is one frame size
  and every stroke, glyph and icon follows. There is no per-element
  scaling work.
- **The module already exists.** `ModuleRegistry.swift:100-105` and
  `HostRootView.swift:177` are already there. No registry row, no
  rename-table entry, no sidebar-order migration.
- **Session keying is already correct.** `MirrorStateEngineRegistry` is
  keyed by `GuestKey` and `pinnedGuestKey` enforces it on every act.
  "One model per session" is the state of the code, not a change to it.
- **The scene survives a restart for free.** `start()` seeds from the
  engine's snapshot (`NOWMirrorSource.swift:429`), and the Finder icon
  cache is never cleared — so Stop→Start does not blank the pane, which
  is the thing that would have made stop-instead-of-pause feel bad.
- **`RenderShot` needs nothing.** Provably, not hopefully.
- **The persistence pattern is written and tested.**
  `SidebarPreferences.swift` is a complete worked example including
  sanitisation-as-a-pure-static, and `NOW_PREFS_SUFFIX` scoping comes
  free through the `defaults` `HostAppState` already holds.
- **The whole `host.show` mechanism survives.** Contract, wire, guest C,
  console verb, MCP verb — 15 of the 21 places don't move.

## Dearer than expected

- **`KeyCapture` is a window-shaped component, and it is in someone
  else's package.** `viewDidMoveToWindow` → `makeFirstResponder(self)`
  and a `performKeyEquivalent` that eats all but three ⌘ combinations
  are exactly right for a dedicated window and exactly wrong for a pane
  in a document window. Fixing it is an API change to
  `mirror/host/MirrorKit`, which per the repo's own rule is a sibling
  project with its own testbench — so it is a MirrorKit change, a
  MirrorKit test, and `scripts/test-mirrorkit` in the loop.
- **"Stop when backgrounded" collides with the headless faces.** It is
  the one place where Michelle's stated decision and the MCP surface
  disagree, and the disagreement is invisible until an agent drive
  refuses. Recommendation in Q2: let backgrounding do nothing.
- **Nearest-neighbour is eight edits, not one.** `GraphicsContext` has
  no context-wide interpolation setting, `shouldInterpolate: false` is
  set on the wrong half of the images (the hand-built ones, not the
  asset-pack ones), and one site (`UnknownVisual.swift:112`) cannot be
  set at all.
- **A pane at 100% does not fit the default window.**
  `HostRootView.swift:45` gives the detail column `idealWidth: 820`
  against an 832×624 guest. "Fit" has to be the default stop or the
  first impression is a scrollbar.
- **`LiveMirrorView`'s `@State` dies on every attach/detach and every
  module switch** — open menu, drawn selection, in-flight drag. The
  drawn desktop selection in particular is the mirror's *own* model
  (`LiveMirror.swift:99-106`), unrecoverable from the guest, so it is
  genuinely lost rather than re-derived.
- **`exportEvidence` captures an `NSWindow`'s content view.** It has no
  attached-mode answer today and fails as `emptyFrame`, which names the
  wrong cause.
- **Two labels the user reads are wrong in the guest's own window.**
  `HostAppState.swift:162-164`'s outcome sentences are drawn verbatim in
  the guest's Mirror page status line via `mirror_module.c:63-70`. Host
  wording is guest-visible text here, which is easy to forget.

---

## Recommended shape (not an implementation)

If this is built, the cheapest correct decomposition looks like:

1. **Split the axes first, change no UI.** Move `start()`/`stop()` off
   `NOWMirrorWindow` onto an explicit owner; make `running`
   `@Published`; make `showMirrorWindow()` start-if-stopped. Ship that
   with the window unchanged and verify `showmirror`, ⌘⇧M,
   `now_mirror_open` and `--open-mirror` all still work. This is the
   half that can break the sweep, and it can be proven alone.
2. **Then the pane**, with the window still the only container — i.e.
   render `LiveMirrorView` in the module and keep the window too, just
   to find out what focus does. **D1/D2 will show up here**, and finding
   them with everything else still working is worth a whole slice.
3. **Then detach/attach and persistence.**
4. **Then zoom, and only then sampling** — sampling last, because it is
   the one change that moves pixel-test output and you want the pixel
   tests otherwise quiet when it lands.

Sampling is worth its own slice for the reason Michelle gave: a
similarity score cannot see a blurred hairline, so that change must be
watched by a human at 200% on a window with a 1-pixel Platinum frame in
it, not scored.
