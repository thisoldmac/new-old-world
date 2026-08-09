# Mirror as a native Swift applet, launched by the workshop — build spec

> **See [MIRRORKIT-PLAN.md](MIRRORKIT-PLAN.md) for the current canonical plan.**
> It settles the architecture (MirrorKit = renderer-free semantic core; the app
> and a future headless-MCP route are two heads on it; Swift-canonical) and the
> three-stage roadmap. This doc's component-level build details (scene-model
> port, renderer spec, input→verb mapping, reference table) remain a useful
> implementation reference.

The browser webapp is retired (see README). Decision (Michelle, 2026-07-16): the
mirror is a **standalone native Swift applet** — its own window/process — that the
**workshop launches per target**. No web, no Python GUI dependency, no renderer
inside the workshop's pane system (so no merge risk with the actively-developed
host-app). The Python `scene.py`/`sources.py`/`mirror.js`/`platinum.css` are the
**spec to port**, not runtime code.

## Architecture

```
  workshop (Swift host)                    Mirror applet (Swift, standalone)
  ── per target: "Open Mirror" ──▶ spawn/open window(host,port,machine,qmpSock)
                                            │
                                   wire client ─ poll axtree/observe ─▶ Scene
                                            │                              │
                                   input → verbs ◄── hit-test ◄── Canvas render
                                   (axdo/key/click/drag)          (Platinum)
```

- The applet is a **separate Swift package** (`prototypes/mirror/MirrorApp/`,
  suggested) — decoupled from `host-app/`. Workshop's only touch is a launcher.
- Workshop → applet is **language-agnostic process/window spawn** with the
  target's `host`, `port`, `scope`, `machine`, optional `qmpSock`. Either a
  separate app (`Process`) or a second `NSWindow` in the workshop process.

## Components to build

1. **Scene model + normalizers (port of `scene.py`).** Swift structs `Scene`,
   `AppRef`, `Win`, `Control`, `MenuDef`, `MenuItem`. Port the normalizers exactly
   — the sharp edges are all documented in `scene.py` + `CONTROL-SURFACE.md`:
   - rect order: **`axtree` = `[l,t,r,b]`** (content port; title bar sits above,
     add ~20px); `observe` own-windows = Mac `[t,l,b,r]`.
   - `axtree` shape: `apps[].process` nesting, per-app `menus`, per-app
     `error` (`ax_oracle_*`), front-app + cross-app z reconstruction.
   - controls carry `value/min/max/checked` + `role` (`scrollbar` when ranged);
     menu items carry `command`(→⌘ char) / `mark` / `enabled`.
   - filter garbage menus (non-printable title = AXPeek read past the list).
2. **Wire client.** A small self-contained newline-JSON socket client (the applet
   is a separate package, so it can't import `host-app/Wire.swift` — but mirror
   its shape: one connection per request, serialize, client closes). Poll
   `axtree {scope}` (toolkit + AXPeek) or `observe` (any worker) on a timer.
3. **Platinum renderer (port of `platinum.css` + `mirror.js`).** A SwiftUI
   `Canvas` (or custom `NSView`). Draw: desktop pattern, menu bar (Apple + titles
   + front-app + clock), window chrome (title-bar racing stripes for the active
   window, close/zoom/collapse boxes, inactive grayed), content area, controls
   (buttons with the default ring; **scrollbar thumbs positioned from
   value/min/max**; **checkmarks when `checked`**; disabled grayed), dialogs
   (`kind==2`), and the process shelf (observe plane). The 7 Platinum grays and
   the raised/recessed bevel rules are in `attic/web/platinum.css` (from the guest
   `ui_theme.c`); the per-element draw + layout logic is in `attic/web/mirror.js`.
4. **Input → verbs (port of `mirror.js` handlers + `sources.py::act`/`_drag`).**
   Hit-test clicks/drags against the drawn scene and send the same semantic
   actions:
   - control → `axdo <ref>` (double-click → `count:2`);
   - menu item with ⌘ → `key {code:<keycode>, char, mods:cmd}` — **the keycode
     matters** (Finder's `MenuEvent` matches the keycode, not the char; carry the
     char→keycode map, e.g. n=45);
   - title bar → `activate` (single) / **drag → window move**;
   - content/desktop → `click` at the guest point.
   - **Drag / shortcut-less menu-drag is emu-only** (QMP closed-loop against the
     `mouseloc` verb; see `qmp.py`/`sources.py::_drag`). The applet takes the QMP
     socket for emu targets; on metal, drag degrades (or a future VBL walker).
5. **Workshop launcher (the only host-app change — tiny).** A per-target "Open
   Mirror" affordance (menu item / button) that opens the applet with the target's
   coordinates. In-process `NSWindow` or `Process` spawn. No renderer, no pane, no
   parity impact.

## Reference material (everything the port needs is in-tree)

| Need | Source |
|---|---|
| scene IR + normalizers | `scene.py` |
| Platinum grays / bevels / chrome | `attic/web/platinum.css` (← guest `ui_theme.c`) |
| draw + layout + hit-test + actions | `attic/web/mirror.js` |
| actuation + emu drag | `sources.py::act`/`_drag`, `qmp.py` |
| capability map + gotchas (rect order, keycode, drag=emu-only, oracle errors) | `CONTROL-SURFACE.md` |
| guest verbs consumed | `harness/src/verbs.c` (this branch: `axtree` values, `axdo` count/mods/text, `click` mods, `key`, `mouseloc`) |

## Verification constraint (important for whoever builds it)

Host-GUI capture stays off-limits (hijacks the desktop, proven unreliable), but
the renderer is no longer human-only: **the app screenshots its own render**
(MIRRORKIT-PLAN decision 7 — the drawn Platinum scene, not the guest
framebuffer, not the host screen): offscreen `ImageRenderer` renders of fixture
scenes for agents, plus a live-snapshot affordance in the running app. The **data pipeline is log-verifiable** (wire → scene →
"drew N windows / front=X") and asserts in `swift test`; human eyes judge
Platinum *fidelity*, not existence.

## Sizing

- Scene model + wire client + workshop launcher: **small–moderate**, verifiable.
- Platinum Canvas renderer: **moderate** — verbose but mechanical from the
  `platinum.css`/`mirror.js` spec; needs human visual iteration.
- Input→verbs: **medium** — hit-testing is net-new, but the action set + keycode
  map + drag caveats are fully specified.
- No host-app merge risk (separate package; the launcher is a tiny host touch).
