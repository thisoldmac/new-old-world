# mirror — host-side live mirror of the guest OS 9 desktop

A mirror of the guest drawn from **semantic state** (not a framebuffer):
we render the *meaning* of the screen (processes, windows, controls,
menus) the guest tells us over the wire, with ported OS 9 UI assets, and
actuate it back through wire verbs. Named for Timbuktu, the remote-control
classic that hijacked QuickDraw and the Process Manager via an INIT —
inspiration, not gospel.

## Status: browser webapp RETIRED (2026-07-16) → home is the workshop

The browser webapp was the **spike vehicle**. It did its job — it proved
the thesis (semantic state + ported assets reads as a Mac, both the
`observe` process plane and the full `axtree` window/control/menu plane,
verified live on mac99), and driving it interactively **forced out the
entire verb surface**, which is the durable asset. As an interactive
*app*, though, a browser page fights a control surface (native selection,
coordinate scaling, an HTTP hop that agents don't need), and the
human-facing home already exists — the **workshop** two-plane host. So the
webapp is retired and the renderer moves there.

**Reusable core (stays here — workshop-bound):**
- `scene.py` — the **scene IR** + `scene_from_axtree`/`scene_from_observe`
  normalizers. The renderer-agnostic contract; the workshop renderer
  consumes these.
- `sources.py` — wire adapters (`ObserveSource`/`AxtreeSource`) + `act()`
  (axdo/key/click/activate) + `_drag()` (QMP closed-loop). The wire- and
  actuation-touching core.
- `qmp.py` — the emu QMP input driver (relative-mouse closed-loop drag).
- `CONTROL-SURFACE.md` — the perceive+act capability map (what works, gaps,
  closure). **The main hand-off doc.**

**Retired (`attic/`, reference for the workshop port):**
- `attic/web/` — the browser renderer (`platinum.css` encodes the Platinum
  look, derived from the guest `ui_theme.c`; `mirror.js` the draw + input
  logic to port).
- `attic/bridge.py` — the HTTP/SSE server + poll-loop + action-queue (the
  workshop has its own refresh loop; this is the pattern reference).

**The durable win beyond this prototype** is the guest **verb surface**
(on this branch in `harness/src/`): `axtree` control `value/min/max/checked`,
`axdo` count/mods/text, `click` mods, `key`, `mouseloc`. Those are wire
verbs any consumer (the workshop, or an agent over MCP) uses directly.

## Architecture — one seam (preserved for the workshop)

```
  guest wire ──▶ source adapter ──▶ scene IR ──▶ [renderer]
                 (sources.py)       (scene.py)    (was web/; → workshop)
```

The **renderer never sees the wire.** Every adapter emits the same *scene*
dict (schema at the top of `scene.py`), so the workshop renderer drops in
behind the same seam without touching the wire code.

- `scene.py` — the scene IR + `scene_from_observe` / `scene_from_axtree`
  normalizers. Rects, front-app selection, coordinate spaces, and z-order
  are reconciled here, once.
- `sources.py` — source adapters, all sharing `_WireSource` (the mirror's
  **only** wire-touching code — the one file that moves when the
  workshop/next wire consolidation lands):
  - `MockSource` — synthetic animated desktop; zero guest. The renderer
    dev target.
  - `ObserveSource` — polls `observe`: the real cross-process Process
    Manager list any stable Worker serves. **The live plane today.**
  - `AxtreeSource` — polls `axtree scope=all`: full window/control/menu
    trees. Needs a toolkit Worker + AXPeek (see below).
- `attic/bridge.py` *(retired)* — the HTTP/SSE server + poll-loop +
  action-queue that drove the browser. The workshop supplies its own
  refresh loop; keep this as the pattern reference.
- `attic/web/` *(retired)* — the Platinum browser renderer. `platinum.css`
  grays are the seven levels from the guest's own `ui_theme.c`; `mirror.js`
  is the draw + input logic (menubar, window chrome, dialogs, controls,
  process shelf, click→axdo / menu→key / drag) to port to the workshop.

## Running the retired webapp (reference only)

The webapp is retired (see status above); the sections below document its
behavior for the workshop port. To run it as a reference:

```
cd attic
python3 bridge.py --mock                                  # renderer, no guest
python3 bridge.py --observe --guest-port 1700             # process plane
python3 bridge.py --guest-port 1713 --scope all --qmp <sock>  # full + drag
```

## Fidelity planes (the Timbuktu spectrum)

| Plane | Source | Needs | Gives | Status |
|---|---|---|---|---|
| **process** | `observe` | any stable Worker | live process list, front app | **proven live** (mac99) |
| **window/menu** | `axtree scope=all` | toolkit Worker + AXPeek INIT | window rects, z-order, controls, menus, dialog text | **proven live** (mac99) |
| **content** | QD-op stream (`qdtrace`) where the app draws direct; **M3 pixel islands** (`capture` region) where it composites offscreen | toolkit Worker + QDPeek INIT | window *interiors* — a document's text as real glyphs; a Finder window's icons as real pixels | **proven live** (mac99, 2026-07-17) |

The `observe` plane mirrors *which* apps are running and which is front,
but cannot draw foreign windows/menus (`observe` is process-local — the
Window/Menu Managers keep per-process A5 globals, docs/41). The
**window/menu plane** fixes that via AXPeek + `axtree`, which return full
foreign trees with zero heap scan; `scene_from_axtree` + the renderer
consume them directly.

### One command (headed, end-to-end)

`prototypes/mirror/spin-up.sh` runs the whole dance below against a fresh,
isolated, **headed** mac99 clone — boot → stage AXPeek+QDPeek+worker → cold
reboot → **verify the INITs survived** → launch the worker. It picks a **free**
host-port pair (default 1700/1710, advancing by 2 if taken; override with
`MIRROR_ANCHOR`/`MIRROR_TOOLKIT`) and records it in `run-mirror/ports`, so a
second copy — e.g. another session — never collides with or silently attaches to
the neighbour's VM. `MIRROR_DISPLAY=1 spin-up.sh` also opens the live MirrorApp
window (front-scope, content plane on). `stop-mirror.sh` tears it down cleanly
(QMP quit, throwaway clone removed). Needs the three guest binaries built
(AXPeek/QDPeek in their `build/`, the toolkit worker in
`worker/build-ppc-toolkit/`). Constraints the scripts encode: this AXPeek build
surfaces the **front app only** (`scope=all` comes back empty — use `--scope
front`); **exactly one** MirrorApp per worker (a second client to the
single-connection worker resets it); and staged files only survive the cold
reboot with the **`FlushVol`** fix in the worker build — the script verifies each
INIT exists *after* the reboot and fails loudly if not
(`qdpeek-guest-staging-does-not-persist`). The manual recipe:

### Standing up the axtree plane (verified recipe)

1. Build `AXPeek.bin` — `axpeek/` (Retro68 68K, toolchain at
   `~/Lab/Tools/Retro68-build-68k`); ~51 KB INIT, code in the resource fork.
2. `push_stream` it into `System Folder:Extensions`.
3. Stage the prebuilt `dist/worker/latest/toolkit-worker-ppc.bin` + a
   crafted `worker.session` into a folder. The session **must** say
   `build:"toolkit"` (the toolkit build sets `TBT_WORKER_ROLE="toolkit"`);
   `created:0`/`deadline:2000000000` is reboot-safe (`now` is `TickCount`);
   copy the anchor's `safe-serial` `policyDigest` verbatim (checked against
   a compile-time constant); put `axtree` in `tools`.
4. **Cold-reboot** — INITs load only at boot. QMP `system_powerdown` is
   ignored by OS 9, so hard-quit and relaunch WITHOUT `-loadvm`, then
   dismiss the Disk-First-Aid modal with a QMP Return key.
5. `launch` the toolkit Worker (via the anchor); point the bridge at its
   forwarded port with `--scope all`.

Notes: AXPeek only samples an app once it pumps its event loop, so
freshly-launched/faceless apps show `ax_oracle_not_found` until then
(rendered honestly). The current canonical `os91-runner.qcow2` is Runner
0.4a (pre-AXPeek as *shipped*), but AXPeek is an INIT and runs fine once
installed onto a clone as above — a baked 0.5+ image would just skip the
install step.

## Driving the guest (interactive — live)

The mirror **actuates** the guest. Clicks in the browser POST to `/act`; the
bridge queues them onto the poll thread (so reads and writes share the single
Worker connection) and re-polls immediately, so the driven change shows up in
the next scene. Semantic-first:

- **Click a control** → `axdo <ref>` (fail-closed); double-click → `count:2`.
- **Click a menu item that shows a ⌘** → `key cmd+<keycode>`. The mirror carries a
  char→keycode map because Finder's `MenuEvent` matches the **keycode**, not the
  char (char-only silently no-ops in Finder). Verified: File→New made a document,
  New Folder made a folder.
- **Click a window title bar** → `activate`; **drag** it → the guest window moves.
- **Click window content / the desktop** → `click` at the mapped guest point.

Window **drag** (and shortcut-less menu drag) run via QMP `input-send-event` —
start the bridge with `--qmp <sock>`. This is **emu-only** (the mac99 mouse is
relative and needs closed-loop positioning against the `mouseloc` verb; metal
would need a VBL mouse-walker). Without `--qmp`, drag actions are unavailable and
the rest still works.

```
python3 bridge.py --guest-port 1713 --scope all --qmp /path/to/qmp.sock
```

The full map of the actuation + perception surface — what works, the gaps, and
whether we know how to close each — is in **[CONTROL-SURFACE.md](CONTROL-SURFACE.md)**.
Reading *inside* content landed 2026-07-17: apps that draw directly replay as
semantic ops; apps that composite offscreen (the Finder) come back as pixel
islands. The open track is now scroll *actuation* — scrolled content is visible,
but nothing drives a scroll yet (no scrollbar-drag or wheel handler).

## Asset-pack contract (for the parallel porting agent)

`web/platinum.css` is the `mock-platinum` pack: real ui_theme.c grays,
but **stand-in fonts** (system font substitutes for Chicago/Charcoal/
Geneva) and no real icons/patterns. The ported pack — extracted from the
guest System file via the fs family (res-carve) — should deliver:

- **Bitmap fonts**: Chicago 12 (system), Charcoal 12, Geneva 9/10/12 as
  sprite sheets + a metrics JSON (per-glyph advance/rect). These are
  `NFNT`/`FOND` resources.
- **Icons**: `icl8`/`ICN#` sheets keyed by creator+bundle, for the
  process shelf and (later) Finder icon views.
- **Patterns**: the desktop `ppat` tile + standard `ppat`/`PAT ` fills.
- **Cursors**: arrow/watch/ibeam (`CURS`/`crsr`).

Platinum window *chrome* (frames, buttons, scrollbars) is **not** a
bitmap asset — the Appearance Manager draws it procedurally. Our port of
that is `ui_theme.c`'s spec, already reflected in `platinum.css`; keep
those in sync rather than trying to extract chrome bitmaps.

## Known approximations (v0)

- **Island cost** — a window interior the guest composites offscreen is fetched
  as pixels (~1s per full window @ depth 16), fetch-on-change rather than per
  poll. A dirty-rect capture would cut it. Interiors an app draws directly
  (text/primitives) are semantic and free.
- **Global z-order** — `axtree scope=all` gives per-app z; cross-app
  stacking is reconstructed as "front app first, then process order"
  (`scene.py`). True global order needs WindowList cross-links.
- **Default button** — the wire doesn't carry defaultness yet; the first
  button in a dialog is assumed default.
- **Rect order** — calibrated: `observe` uses Mac `(t,l,b,r)`; `axtree`
  serializes `(l,t,r,b)` and its window rect is the content port (the
  renderer adds a title bar above it). Controls arrive global and are
  converted to content-local in `scene.py`.
- **Title-bar height** — a fixed 20 px (`TITLEBAR` in `scene.py`), not
  read from the wire.

## Wire-stress notes (measured, mac99 emu, `observe` plane)

| Plane | Poll rate | Polls | Errors | Latency mean / min / max | Payload |
|---|---|---|---|---|---|
| observe | 0.5 s | 69 | 0 | 1.2 / 0.96 / 7.3 ms | ~1.4 KB |
| observe | 0.2 s | 147 | 0 | 1.2 / 0.90 / 9.1 ms | ~1.4 KB |
| axtree all (2 win, 9 app) | 0.5 s | 383 | 0 | 4.9 / 3.0 / 346 ms | ~12 KB |
| axtree all (2 win, 9 app) | 0.2 s | 123 | 0 | 4.6 / 4.1 / 16.8 ms | ~12 KB |

Emu latency; metal (Q950 MacTCP) pays ~32 ms/request and `axtree`
measured 307 ms median front-scope there (docs/46). Payloads stay small.

**Optimization ledger** (for the parallel wire worktree):
- **Change-detect verb.** The AXPeek `AXShared` table already carries a
  seqlock (`seq`) + `ticks`, header-read by the Runner (`runner/
  components.c`). A verb returning just `{seq,ticks}` (or a `peek` of the
  36-byte header) lets the poller check one integer and pull the full
  tree only on change — turning 5 Hz of full trees into 5 Hz of 8-byte
  reads plus occasional trees.
- **scope=all paging / compaction.** Cap + page broad fleets; drop empty
  sections; short field keys.
- **Menus-only-on-change.** Menus rarely change; hash and re-send only on
  delta.
- **Batch/pipeline.** One connection, pipelined requests (the transport
  already supports it) instead of connect-per-poll.
- **Single-connection Workers.** The 0.4a anchor resets a second
  concurrent connection; the poller must own its connection (it does) and
  any driver must serialize or use a separate session Worker.
