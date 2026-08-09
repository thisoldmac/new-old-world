# Driving the guest from the mirror — control-surface map

What we can do **today** with the AX + input surface to drive the guest OS 9
UI from the host, where the gaps are, and whether we already know how to close
each. Motivated by making the [mirror](README.md) interactive (click the
rendered UI → actuate the guest), but the surface is general.

The loop is **perceive → project → act → re-perceive**: `axtree`/AXPeek read
the real UI into the [scene IR](scene.py); the renderer draws it; an actuation
verb reverses a rendered element back to the guest; the next poll confirms.
The key property is *symmetry* — every control we render carries the stable
`ref` we'd act on, and every element carries the global `rect` we'd click.

Evidence: `harness/src/verbs.c` (+ `axwalk.c`/`axmenu.c`/`axtext.c`/`axref.c`),
`axpeek/src/*`, `docs/46-agentic-accessibility-roadmap.md`, `docs/30`,
`docs/22-metal-safety-line.md`, `mcp-classic/timbottu_mcp_classic/{server,mordor,harness}.py`,
`data/workshop-parity.toml`. Status current as of 2026-07-16 (this spike proved
the two mac99 gates flagged below).

---

## Perceive — what the mirror can read

| Element | Fields exposed | Proven | Not exposed (gap) |
|---|---|---|---|
| **Window** | title, `kind`, visible, `rect[l,t,r,b]`, `z` (WindowList chain index), controls, **`display`** (QD ops), **`island`** (content as real pixels) | Rung A: q800+mac99+Q950; content plane + islands mac99 2026-07-17 | true cross-app z-order |
| **Control** | title, visible, enabled, `ref`, `rect`, **`value`/`min`/`max`/`checked`**, `role` (`"scrollbar"` when ranged, else `"control"`) | Rung A + values (this session) | precise *kind* (button vs checkbox vs radio) — the CDEF procID isn't in the record; needs Rung E adapters |
| **Menu** | id, title, left, enabled; items: index, title, enabled, **command** (⌘ char), mark, icon, style | Rung D: q800 + **mac99 (this spike)** | Q950 pending |
| **Dialog text** | text (≤1024), length, selection, active, truncated — **only `kind==2` Dialog windows** | Rung D: q800 + mac99 (this spike) | non-Dialog document bodies (TextEdit not rooted in a public DialogRecord) |
| **Fleet** | per-app tree *or* per-app oracle error, no focus change | Rung C: q800+Q950 + **mac99 (this spike)** | faceless/never-pumped apps → honest `ax_oracle_not_found` |

**The `ref`** is `ax2/<PSN-hi><PSN-lo>/window:<title>#<occ>/control:<title>#<occ>/node:<fnv32>`
— live-PSN, session-time, no pointer/coordinate. It survives redraws and window
moves (resolved by title+occurrence+fingerprint), and **fails closed** on
quit/relaunch (new PSN), front-app change, control-gone, or an identity change
(the node fingerprint is what makes reordered duplicate titles fail `ref_stale`
rather than silently retarget).

**Freshness:** AXPeek samples an app's UI roots only when it *pumps its event
loop* (the GNEFilter fires) — immediately on an A5-world/WindowList change, else
at 10 Hz; a host read demands a sample ≤2 s old (with a PSN-bound path for
aged-but-alive apps). A never-pumped/faceless app has no sample and is reported
as an error, not guessed. Cheap host change-detect *could* read the 8-byte
`AXShared` header (`seq`/`calls`/`ticks`) via `Gestalt('TBax')` — plausible but
not a documented consumer path yet.

**Read blind spots** (all deferred to designed-but-unbuilt rungs): raw-QuickDraw
/ custom-CDEF UI, list/table rows, and any control value — closure is Rung E
(calibrated per-app adapters), Rung F (bounded QuickDraw trace), Rung G
(per-node OCR pixels, "wiring"). No dedicated list/table plan is named.

**DESKTOP icons — semantic (closed 2026-07-16).** A desktop icon's position is
`fdLocation` in its Finder Info, which `list` already fetches via `PBGetCatInfo`;
emitting `loc`/`flags`/`creator` (done) gives desktop layout as clean semantic
state, no capture/OCR. Above-the-line (File Manager / Finder Info), metal-safe.
Desktop items are hand-placed, so `fdLocation` IS the on-screen position, and it
renders + clicks correctly. Mounted disks + Trash are NOT Desktop Folder catalog
entries (the Finder places them) — get those from the Finder: `position of disk`
works (used, `script`); `{0,0}` = auto-arranged/unplaced (not top-left). Drawing
the *right* per-type icon comes from each app's own bundle (BNDL/FREF/icl8, via
`extract-assets/iconpack.py`) keyed by `(creator,type)`; a generic bitmap by
kind is the fallback. Custom desktop-DB / alias-file icons still need `PBDTGetIcon`
(not in the Retro68 headers).

**WINDOW icon-view positions — NOT semantic AT ALL; solved with pixels
(2026-07-17).** Inside a Finder *window*, an icon's `fdLocation` is a SAVED
LOGICAL grid the Finder rescales at layout time — verified live: stored 128px
steps vs ~172px drawn, and the `v=0` row wasn't where `fdLocation` claimed. And
AppleScript `position` works for disks/desktop items but ERRORS for items inside
a window. So window icon-view layout is not recoverable from the catalog or
scripting.

The obvious next hope — take each icon's position from where the Finder
`PlotIcon`'d it, via the QuickDraw content plane — **is also dead.** The Finder
composites its icon views in an offscreen **GWorld** and CopyBits the finished
composite into the window: a 12-icon window emits *zero* per-icon ops and *zero*
labels, only one content-sized blit with `src == dst`. Confirmed three ways
(update, reflowing resize, fresh window open — all blits). The desktop is the
opposite (plotted straight to the screen port: a 32×32 `bits` at the true `dst`
+ a label `text` at its pen), which is why desktop icons work. Finding:
`finder-window-icons-are-offscreen-blits`.

**What actually renders them: M3 pixel islands** — fetch the content rect's real
pixels (`capture` region) and composite. QDPEEK-SPEC scoped exactly this for "a
GWorld app"; the Finder *is* that app, so islands are a prerequisite for window
interiors, not an optimisation. Live on mac99 the Macintosh HD window renders
all 12 icons at true positions in colour. (Folder *contents* still enumerate
fine via `list` — only their live *positions* were the gap.) List/column views
likewise don't use `fdLocation` (computed layout).

**Superseded for icon views, 2026-07-31 (lane H2).** The live-position gap was
a wrong *source*, not an unanswerable question: the Finder answers `position
of` an item of a window, which is window-content-local, live, and
scroll-compensated — a different quantity from the saved `fdLocation` grid, and
the one the Finder actually draws from. An icon-view folder window now renders
from **named items**, with the island as its fallback; a click computed from an
item's reported position selected that item 40/40 (0/40 with `fdLocation`).
`bounds of` an item confirms the icon box is 32×32 with its top-left at
`position`. **List and column views are still unaddressed** — nothing detects
the view type yet, and `position` in a list view was not measured.
[FOLDER-ITEMS.md](FOLDER-ITEMS.md).

**Finder window → folder path (the "which folder is this window?" gap, closed
2026-07-16).** A Finder window's title is ambiguous (nested folders), and the
axtree/WindowList record carries no path. The Finder *does* know, and is
scriptable: `script` with `item of window i` returns the shown folder's HFS
path — for subfolders, disk roots, and Control Panels alike. So the mirror
resolves EVERY open Finder window (not just mounted volumes) with one enumerate
script per new/navigated window (`name of window i` + `item of window i`), then
`list`s each path for its `fdLocation` items. OS 9 Finder terminology gotchas
(verified live): the `Finder window` *class* fails (`script_error`) — use the
generic `window`; `target of window` fails — use `item of window` (or
`folder`/`container`); `count Finder windows` fails but `count windows` works.
Read-only, no `activate`, so it doesn't steal focus. Above-the-line (Finder AE),
so metal-portable (subject to the script-verb time cap).

---

## Act — the actuation verbs

Two families. **Above-the-line input** is in every harness build and "drives emu
and metal identically" (verbs.c comment); **toolkit/Mordor** (`axdo`) is
`-DTBT_MORDOR`-only. All input goes to the **front app**, so `activate` first.

| Verb | Args | Mechanism | Space | Plane | Emu | Metal |
|---|---|---|---|---|---|---|
| **axdo** | `ref` | resolve ref → front-app recheck → one left-click at control center | semantic (by ref) | toolkit | needs toolkit worker | proven in harness era (docs/46 q800+mac99+Q950); workshop re-build pending (parity rung-17) |
| **click** | `x,y`, count 1–3 | `PPostEvent(mouseDown/Up)` + `LMSetMouseLocation` | **global screen** | above-line | ✓ | ✓ identical |
| **key** | `code`, `char`, `mods` (cmd/shift/opt/ctrl) | `PostEvent`/`PPostEvent(keyDown/Up)` + mod stamp | semantic keycode | above-line | ✓ | ✓ |
| **type** | `text` (ASCII) | `PostEvent` per char | focus | above-line | ✓ | ✓ |
| **launch** | `path` | `LaunchApplication` → PSN | — | above-line | ✓ | ✓ |
| **activate** | `serialHi/Lo` (PSN, not name) | `SetFrontProcess` | — | above-line | ✓ | ✓ |
| **apple-event** | `event=quit\|oapp\|odoc\|pdoc`, PSN/path | `AESend` (quit = `kAEQuitApplication`) | — | above-line | ✓ (quit live; doc-events rung-11) | ✓ |
| **script** | `text` (AppleScript) | `OSADoScript` (`tell app … activate`/menu) | app-scriptable | above-line | ✓ | ✓ (time-capped) |

`axdo`'s fail-closed gates: `bad_ref`, `ref_stale`, `ref_not_found`,
`not_actionable` (hidden/covered/invisible/disabled/degenerate), `ref_not_front`
— nothing is posted unless every gate passes. `click`'s `button` arg is parsed
but discarded (left-only); `count` gives single/double/triple.

---

## What you can do TODAY, end-to-end

Composable from the verbs above, no new code:

- **Click a rendered control** → `axdo <ref>` (fail-closed, semantic) — the
  natural mirror action for buttons/scrollbars/standard controls.
- **Click any point** → `activate` target, then `click x,y` (global coords the
  mirror already knows from rects) — the escape hatch for anything without a ref.
- **Type text** → `activate`, focus a field (`click`/`axdo`), then `type`/`key`.
  Text entry is *already available* to the front app.
- **Menu items that have a ⌘-shortcut** → `key` with the Cmd modifier. **The
  mirror already renders each item's `command` char**, so New/Open/Save/Quit/
  Copy/… actuate today via `key cmd+<char>` — no menu verb needed.
- **App lifecycle** → `launch` / `activate` / `apple-event quit`.
- **Scriptable apps** → `script` for anything AppleScript can drive.

So a first interactive mirror is richer than "axdo clicks": **axdo for controls,
click for points, type/key for text, key+⌘ for shortcut menus, activate/launch/
quit for lifecycle.**

---

## Closed 2026-07-17 (verified live on mac99)

- **Window interiors render.** The content plane (`qdtrace`) replays what an app
  draws directly — SimpleText's text lands as real Geneva glyphs at their pen
  positions. What an app *composites offscreen* (the Finder) can't be replayed
  at all, so **M3 pixel islands** fetch the content rect's real pixels
  (`captureRegion` → `Scene.Window.island`) and composite. Islands are
  fetch-on-change (a content-sized blit = the guest repainted; measured at one
  fetch per four polls), and a **MoveBits scroll** (same-size blit displaced,
  src inside the content) moves already-held pixels and re-fetches only the
  exposed band. When an island is set it IS the content; the chrome stays
  semantic, so it's still a Platinum window we drew.
- **Menu actuation.** A menu item's `enabled` bit is **not authoritative** —
  classic apps disable menus at rest and only `AdjustMenus()` at menu-down, so a
  passive read sees SimpleText's whole File menu (New, Save As, Quit) as
  disabled while the system-managed Apple/Help menus read true. The action model
  no longer gates on it (the guest's own MenuSelect/keystroke dispatch is the
  authority; verify by re-poll). Gating on it was silently refusing every File
  item — including the reliable ⌘-keystroke path.
- **Actuation is measured, not assumed.** `MirrorApp --battery` drives the real
  hit-test → action-model → dispatcher path and verifies each gesture by
  re-poll: deterministic **7 pass / 1 fail / 1 skip**. The red is the
  shortcut-less QMP menu-drag — open-loop through mouse accel, and a miss does
  not no-op, it *selects the wrong row*, so the battery runs it last in
  isolation.

## Closed 2026-07-16 (this session, verified live on mac99)

Four cheap gaps closed by extending the toolkit verbs; all tested against a live
guest (SimpleText / Graphing Calculator / a real Save dialog):

- **Control sub-state read** — `axwalk` now reads `contrlValue`/`min`/`max`
  (@18/20/22); `axtree` controls carry `value`, `min`, `max`, `checked`, and a
  `role` of `"scrollbar"` when `max-min>1`. Proven: GraphCalc sliders read
  `value=100 min=0 max=1000`; a push button reads `checked=false`; a Save dialog
  reports Cancel/Save enabled vs Desktop/Eject disabled.
- **Modifiers + right-click on `click`** — `mods` (shift/cmd/opt/ctrl) stamped on
  the queued events; `button>=2` folds into Control (the contextual-menu gesture).
- **`count` + `mods` on `axdo`** — double-click and modifier-click *by ref*
  (fail-closed gates unchanged). Proven: `axdo count=2` on a dialog control.
- **Type-into-a-resolved-control** — `axdo {ref, text}` clicks to focus then
  queues the keystrokes. Proven: typed " [typed by ref]" into a SimpleText doc.

## Gaps, and whether we know how to close them

| Gap | Workaround today | How to close | Effort / plane | Hazard |
|---|---|---|---|---|
| **Menu items WITH a shortcut** | **solved** — `key cmd+<char>` (mirror shows the ⌘) | — | — | — |
| **Control sub-state** (checked / value) | **closed** — `value`/`min`/`max`/`checked` | — | — | — |
| **Right / contextual click** | **closed** — `click button=2` / `mods` | — | — | — |
| **Double-click / modifier by ref** | **closed** — `axdo count/mods` | — | — | — |
| **Type into a resolved control** | **closed** — `axdo {ref,text}` | — | — | — |
| **Menu item WITHOUT a shortcut** | none clean | needs a mouse-*tracking* mechanism (see below), OR `script` for scriptable apps | **not** a simple verb | coordinate menu-drag on metal has a wedge history |
| **Drag / press-hold / mouse-move** | none | a mouse-tracking mechanism (see below) | **not** a `post_click_at` split | — |
| **Precise control *kind*** (button vs checkbox vs radio) | `value`/`min`/`max` hints | Rung E calibrated adapters (the CDEF procID isn't in the record) | designed rung | — |
| **Custom-drawn / raw-QuickDraw UI, lists, content interiors** | **CLOSED (mac99)** — semantic ops where the app draws directly (text/primitives), **M3 pixel islands** where it composites offscreen (the Finder) | shipped: `qdtrace` content plane + `Scene.Window.island` | — | island fetch ~1s/window; fetch-on-change |
| **True cross-app z-order** | chain index (paint order within a process) | compose fleet trees by WindowList layer | small | — |

### Drag and shortcut-less menus — SOLVED via QMP closed-loop (emu)

These hit **cooperative-multitasking starvation**: when an app takes a
`mouseDown` and enters its own tracking loop (`DragWindow`, `TrackControl`,
`MenuSelect`), it spins reading `Button()`/`GetMouse()` and the Worker never
gets CPU to move the mouse or release the button — a Worker-thread drag
deadlocks. A menu *is* a drag (`MenuSelect` tracking), same problem.

**Closed 2026-07-16 via QMP `input-send-event`** — the emulated mouse advances
from *outside* the guest CPU, so it moves while the app spins. Two facts made it
work: (1) the mac99 mouse is **relative-only** and OS 9 accel distorts open-loop
moves, so positioning is **closed-loop** against a new `mouseloc` verb (reads the
guest cursor) — it converges to ±5 px in ~7 iterations despite accel; (2) the
grab is a real hardware button-down at the positioned point, so the app's
`FindWindow`/`DragWindow` path runs normally. `prototypes/mirror/qmp.py` +
`sources.py::_drag`; the bridge takes `--qmp <sock>`. Verified: dragging a window
title bar in the browser moved the guest window (+89,+47 for a +90,+50 drag).
Emu-only (no metal QMP); the metal path remains a VBL mouse-walker. The
`menudrag` kind uses the identical mechanism for shortcut-less menu items.

**Read of the map:** the interactive surface is essentially closed. Clicking
controls, double-clicking, contextual-clicking, typing (positional and by-ref),
menus (shortcut via `key`, shortcut-less via QMP menu-drag), window drag, and
reading control values all work. What's left is **reading inside content**
(lists, canvases, document bodies) — the content-plane track headed for the
QuickDraw worktree — and porting drag/menu to **metal** (a VBL mouse-walker,
since QMP is emu-only).

### Gotcha: menu shortcuts need the KEYCODE, not just the char

`key {char:'n', mods:cmd}` opened New in SimpleText but **silently no-op'd in
Finder** — Finder's `MenuEvent` matches on the virtual **keycode**, not the
char. Fixed by sending the real keycode (e.g. 45 for 'n'); the mirror carries a
char→keycode map. This was the real cause of the earlier "activate doesn't raise
windows" symptom — Finder *was* front with the Desktop active; only the key
match was wrong.

## Recommended order (updated)

1. ~~`axdo` controls, `key cmd` menus, `type`/`activate`, control-value read,
   right/contextual click, double-click & type by ref~~ — **done 2026-07-16.**
2. ~~**Wire the mirror to use them**~~ — **done 2026-07-16.** Browser `/act` →
   queued on the poll thread → `axdo`/`key`/`activate`/`click`; verified File→New
   in the mirror created a guest window. (Renders `checked`/`value` too.)
3. ~~**Drag + shortcut-less menu** via QMP `input-send-event`~~ — **done
   2026-07-16** (closed-loop on the `mouseloc` verb; emu-only).
4. **Content plane** (lists/canvas/doc bodies) — the QuickDraw worktree.
5. **Metal** drag/menu — a VBL mouse-walker (QMP is emu-only); other verbs
   already run on metal.
