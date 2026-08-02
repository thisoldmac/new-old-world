# Mirror → NOW capability parity ledger

**Date:** 2026-08-01. **Scope:** every capability in `timbottu/mirror` main
(`9536ca2`), reconstructed from `git log --oneline` and the files each commit
touched, classified against `timbottu/now` main (`7823df1`). Read-only lane —
no source was edited to produce this table.

**Nothing in this table has executed on a Macintosh.** Every crossed row is a
compiled/unit-tested claim; the emulator and metal gates for the act plane,
the content plane, and the reference layer are all still open (see
`docs/emu-readiness.md`). "Crossed" means *the code exists and something
calls it*, not that it has been run against a guest, emulated or real.

> **That sentence stopped being true on 2026-08-02 for the act plane.** The
> section [NOW's own numbers](#nows-own-numbers-2026-08-02) below records the
> first measurements this project has taken itself, on an emulated Power Mac
> G4. Every number above it is still upstream's, as the rest of this file
> says. **Two stale-path warnings** while you are here: several §7 rows cite
> `now-host/Sources/MirrorKit*` paths that now exist only under
> `archive/mirror-port-2026-08-01/`, because this file predates the port being
> thrown away by hours; and §5's `TEHandle` row is **closed** — the bound is
> in `ext/src/now_ext_act.c :: act_resolve_te`, which bounds the
> caller-supplied handle before any dereference and bounds `hText` again in
> `act_te_read`.

## NOW's own numbers (2026-08-02)

The rig, stated once so every number below inherits it: a **session-private
mac99 clone** (`scripts/spin-up-ppc`), Mac OS 9.1, guest build
`48cc16cc61da`, NOW Extension staged as type `INIT` creator `NOWx`, wire on
127.0.0.1:5251, Mirror's three INITs staged beside NOW's own so both resident
families were present. **Emulator-verified. No metal.** A mac99 number stays
a mac99 number, per this file's own provenance rule.

| Question | NOW | upstream, for comparison |
|---|---|---|
| **P4 no-hijack, menu case, N=20** | **0/20 hijacks, 20/20 clean chain-through** | Portal 0/19 after the guard was fixed; 18/20 before it |
| P4 stimulus calibration (baseline, nothing armed) | 0/3 hijacks, 3/3 chain-through | — |
| P4 trap ABI (`actselftest`, NOW's own app) | `abi-agreed` — answered `0x03E70007`, read back `0x03E70007` | — |
| P4 anchor settle window | first `actselftest` after a launch answers `no-such-process`; the identical call ~6 s later answers `abi-agreed` | — |
| P3 content plane | present and discoverable: format 1, length 65676, ring cap 65536, mode off | QDPeek v1 |

**What the menu number means, precisely.** An armed `menuact` request was live
against a decoy while a REAL mouse press — QMP, the emulated machine's own
hardware input — pulled the Apple menu and released on About This Computer.
The hijack oracle is a folder on disk (`untitled folder` on the Desktop, the
armed request's own effect); the chain-through oracle is the About window
opening. Twenty trials, the armed request fired on none of them, and the
user's own click did its own thing every time. This is the number NOW's
contract has been citing upstream for.

**Two harness defects were found and fixed before any of it counted**, both
in the oracle rather than the case, and both would have produced a *confident
zero*:

1. The Desktop oracle used upstream's absolute HFS path. NOW's `ls` resolves
   under the share and cannot express an ascent, so it asked for
   `<share>/Macintosh HD/Desktop Folder` and got "the File Manager refused" —
   which reads like a broken guest.
2. The window oracle read `windows` off the reply ENVELOPE; the contract nests
   windows under each PROCESS. That loop body could never execute on any
   machine. Measured before the fix: About This Computer open on screen,
   `observe` reporting it with a minted ref, and the harness calling it absent
   **5 times in 5**. A probe whose oracle is structurally blind reports zero
   hijacks and reads exactly like a guard holding.

The same wrong unwrap is still in `apple-event-probe.py`, `ctlinvoke-probe.py`,
`textops-probe.py` and `drive-sequence.py`; `oracles.observe_tree` now exists
for them to use. **Any number those four have ever produced about windows
should be re-taken.**

### The caveat that decides what 0/20 means

**A guard that held and a plane that cannot fire in that process at all
produce the same 0/20.** This has to be said beside the number, because the
same day's evidence points at the second reading:

- `actselftest` **abi-agreed** against NOW's own app and **refused**
  (`act-refused: the target refused the request`) with the **Finder**
  frontmost, on the same build, minutes apart. That reproduces the
  2026-08-01 overnight arc's split, whose suspected cause was PPC-native
  trap dispatch bypassing the 68K patches.
- The menu case drove the Finder. So its 0/20 says the armed request never
  fired during someone else's click — it does **not** establish that the
  request could have fired.

Upstream's number does not have this ambiguity: Portal measured **18/20
hijacks before its guard was fixed**, which proves the plane could act in
that process.

**The positive control was run, and it settles this the unwelcome way.**
Against the Finder, addressed by PSN and armed with a correct
`titleLeft`, `menuact` answers in the guest's own words:

> `act-not-taken: armed, and the application never called MenuSelect`

So the request **armed** — the resident's filter runs in the Finder's
context, the guard matched the target, and the plane posted its own
press — and the Finder never called `MenuSelect`. No `untitled folder`
appeared. `actselftest` against the same process refuses in the same
pass (`act-refused`), while abi-agreeing against NOW's own app minutes
earlier on the same build.

**Therefore 0/20 hijacks is not evidence that the guard held.** The
plane has never been observed completing an act inside the Finder, so
"the armed request did not fire on someone else's click" and "the armed
request cannot fire at all here" are not distinguished by that number,
and the second is now the better-supported reading. The honest statement
of the menu case is: *no stray actuation was observed in 20 trials of a
plane that has not been shown able to actuate in that process.*

**Repeated against SimpleText, with the same answer**, which moves the
suspect: a plain classic application, frontmost and anchor-bound, gives
`act-not-taken` for `menuact` and `act-refused` for `actselftest`. The
second matters most — `actselftest` needs no event dequeued by anyone,
because the resident calls `MenuSelect` itself in the target's context.
So the failure is **general to foreign applications and is not only
about the posted press**, and since the anchor pass in the same filter
demonstrably runs in those processes, the question is why the ACT pass
does not serve there. See open-issues for the reading order.

**What this costs the roadmap.** Every click-driven act verb
(`menuact`, `ctlact`, `winact`) depends on the target application
dequeuing a press this plane posts with `PPostEvent` from inside the
target's context. That is the step failing. It matches the 2026-08-01
overnight arc's 0/10 on the same family — a finding that lives only on
`claude/mirror-parity-overnight` and in no document until now. Until it
is solved, **T2's clickable mirror is not reachable by this route**, and
the tier's shape should be decided with that known rather than
discovered halfway in.

### P3's first arm, ever (2026-08-02)

The content plane had never been armed on any machine. It has now, twice:

| | result |
|---|---|
| arm against NOW's own app (Carbon) | `arms: 1`, `installs: 1`, `hookedPorts: 1`, `active.a5` = requested. **`ops.total: 0`** |
| arm against the **Finder** (classic) | same: armed, committed, one port hooked. **`ops.total: 0`**, ring `ticks` never stamped |
| arm against an A5 that is no process | **refused correctly**: `active` went to off, `uninstalls: 1`, and `refused.wrongContext` reached **360** in ~5 s |

So the plane's *machinery* works — it arms, commits in the right order,
installs a hook, retires cleanly, and its context guard refuses hundreds of
times a second rather than silently accepting. **What it has never done is
capture one drawing operation.** The ring's `ticks` field never moved, which
means no hook body ran at all, not that it ran and found nothing.

**A second observation, and the hypothesis it suggested is REFUTED by
reading the code.** After the plane had been armed against NOW's own
guest app and then stopped, that app **quit**, and relaunching it
produced a process frontmost with its menu bar and no window visible;
the machine was cold-rebooted to clear it.

The obvious suspicion was a stale-port dereference: the plane keeps
`CQDProcs` pointers to an armed app's window ports in a resident table
that outlives the process. **`ext/src/now_content.c` does not have that
bug.** `content_port_is_live` walks the CURRENT WindowList comparing
POINTER VALUES and never dereferences the stored port;
`content_forget_slot` drops a row by value with the same discipline
stated in its comment ("a row can outlive the heap its port lived in");
and `content_uninstall_context` requires live AND colour AND
`grafProcs == &gHooks` before it restores anything. That is upstream's
`qd_uninstall_owned` rule, already applied.

So **the cause of the app's death is NOT established**, and the ledger
should not imply it. What the file DOES state, as a known asymmetry
rather than a defect, is that disarming reaches a target only when that
target next pumps: "a target that is suspended, wedged, or gone keeps
its patch until it runs again — or forever." Whether a process dying
mid-arm is a leak that matters, and what actually killed the app, both
remain open. Worth re-running deliberately before P3 is armed in anger,
and worth noting the relaunch was observed ~25 s after launch, which is
not obviously long enough to call a missing window a hang.

Unknown, and now the content plane's other question: whether Color
QuickDraw on a PPC Mac routes through the 68K `CQDProcs` this plane hooks,
or past them. `hookedPorts: 1` while the Finder owns more than one window is
worth checking in the same pass. The stimulus was mouse movement, which the
Cursor Manager may draw outside `grafProcs` entirely — so a stronger
stimulus (a menu pull, a window open) should be tried before concluding
anything about the mechanism.

**What did NOT get a number, and why** — so the table above is not read as a
sweep:

- **`stale` case: attempted, no number.** The run died with the guest closing
  the NOW wire mid-case. Not attributed: two variables were introduced during
  it (Mirror's agent was launched on the same machine, and a MirrorApp
  instance was killed rather than quit, which the lifecycle code says leaves
  the agent's single client slot held). The guest's own dead-link rule is 65 s
  without inbound traffic and the case's gaps are ~16 s, so idle timeout does
  not explain it. Re-run needed with nothing else touching the machine.
- **`control`, `window`, `text`, `collide`: not run.**
- **A positive control for the act plane in the Finder.** See the caveat
  above: it is the measurement that decides what 0/20 means, and it is the
  most important thing owed here.

## How rows were classified

- **crossed** — the code is present in NOW's tree *and* reachable: I found a
  call site outside the porting module itself (Host/NOWAgentIntegration for
  host code, `commands.c`'s dispatch table for guest verbs), or a chain of
  such calls.
- **wired-but-unreachable** — the code is present, compiles, and is
  syntactically correct, but nothing in NOW's app or agent surface ever
  calls it. A file existing under the right name is not enough; I grepped
  for actual call sites and, where the immediate caller was itself unreached,
  followed the chain one more hop.
- **refused** — a written decision not to port it exists in NOW's docs, cited
  below.
- **open** — no code and no written decision.

## Counts

| Class | Count |
|---|---|
| crossed | 45 |
| wired-but-unreachable | 6 |
| refused (written) | 8 |
| open | 8 |
| **Total capabilities audited** | **67** |

(Recounted directly from the row-by-row tables below, section by section, after a first hand-estimate was wrong — the table is the source of truth, not this summary.)

---

## 1. Rendering (Platinum scene renderer)

| Capability | Upstream commit | NOW status | Evidence | Notes |
|---|---|---|---|---|
| Scene → Canvas draw path (one draw path for live view + offscreen shot) | `9552d9d` (Platinum assets), renderer built out through the fan-out (`b23dd07`) | crossed | `now-host/Sources/MirrorKitUI/SceneView.swift:29-34` calls `SceneRenderer(...).draw(in:size:)`; called from `now-host/Sources/Host/MirrorModuleView.swift:184` | Reachable from the actual app view |
| Window chrome (title bar, stripes, close/zoom/collapse boxes, grow box) | fan-out (`b23dd07`), hardened across `edbfcd0`/`cb79dbc` acceptance work | crossed | `now-host/Sources/MirrorKitUI/SceneRenderer.swift:708-732` calls `WindowChrome.widgetBox`/`growBox`; `SceneRenderer` reachable per above | |
| Scrollbar thumb positioned from value/min/max | `1f17c38` (folder windows acceptance touched scrollbar hit-testing) | crossed | `now-host/Sources/MirrorKit/Scrollbar.swift` consumed by `HitTester.swift` and `SceneRenderer.swift`; `HitTester` reachable at `now-host/Sources/Host/MirrorModuleModel.swift:462` | |
| Icon atlas (Finder item icons, app icon) | `9552d9d`, `f46861e` (desktop icons via fdLocation) | crossed | `now-host/Sources/MirrorKitUI/SceneRenderer.swift:225,371,415` call `IconAtlas.icon`/`.namedIcon` | |
| Bitmap font (Tier-2 Platinum glyphs) | `9552d9d` "real Platinum assets — Tier-2 bitmap fonts + desktop pattern" | wired-but-unreachable | `now-host/Sources/MirrorKitUI/BitmapFont.swift` has 0 callers outside `MirrorKitUI/DisplayReplay.swift`, and `DisplayReplay` itself is fed by content-plane data nothing on Host ever fetches (see content-plane row below) | Compiles; the only caller is itself unreached |
| Desktop pattern draw | `f46861e` | crossed | `PlatinumTheme` grays consumed by `SceneRenderer`; reachable via same `SceneView` chain | |
| Content-plane (QuickDraw pixel) draw of window interiors | `70a70f0` "carry the pixel plane — window interiors now render", `c3d2aff` "carry qdtrace + QDPeek" | **wired-but-unreachable** | `DisplayReplay.draw` is called at `now-host/Sources/MirrorKitUI/SceneRenderer.swift:619`, but nothing on the Host side ever issues the guest verb that would populate `Scene`'s display bytes — `grep -rn "qdtrace" now-host/Sources` finds only a contract-message comment (`ContractMessages.swift:226-228`), no call. The render path exists; its only producer does not | This is the "display plane" example named in the task brief |
| Fit-to-view transform (aspect-preserving guest→view mapping) | part of the renderer buildout | crossed | `now-host/Sources/MirrorKitUI/FitTransform.swift` used at `now-host/Sources/Host/MirrorPointMapping.swift:32,35` | |
| Pixel-island offscreen-blit capture (folder/window icon fields painted via `CopyBits`, not semantic draws) | `70a70f0`, `2002f4b` "island focus retention — a window keeps its last interior" | crossed | `now-host/Sources/MirrorKit/IslandStore.swift` consumed by `SceneIslands.swift`; `PixelIsland` rendered at `SceneRenderer.swift:953` (`cgImage`), reachable via `SceneView` chain | |
| Render-screenshot (offscreen `ImageRenderer` PNG of the drawn scene, for agents) | `1db904f`+ islands work; formalized in `MIRRORKIT-PLAN.md` decision 7 | crossed | `now-host/Sources/MirrorKitUI/SceneView.swift:41-60` (`RenderShot.png`); `now-host/Sources/Host/QuickCapture.swift` and `MirrorSceneProbe.swift` reference the render/observe surface | |

## 2. Desktop

| Capability | Upstream commit | NOW status | Evidence | Notes |
|---|---|---|---|---|
| Desktop icons via `fdLocation` (semantic, not pixel) | `f46861e` "desktop icons via fdLocation — the semantic route, not pixels" | crossed | `now-host/Sources/MirrorKit/FinderItems.swift`, consumed at `SceneRenderer.swift:635` (`FinderItems.iconArea`) and `HitTester.swift`; `HitTester` reachable per above | |
| Volume/disk icon on desktop | `90517b9` "disks appear on the desktop again", `3b76f79` "selection inverts rather than boxing; volumes get the disk icon" | **refused** | `docs/mirror-wave3-verdicts.md`; per `docs/mirror-foldin-inventory.md:103-105` | Written reason: NOW already answers this with `census volumes` (`PBHGetVInfo`), same underlying walk under NOW's own name |
| Desktop selection (invert, not box) | `3b76f79` | crossed | Selection state threaded through `SceneView`'s `selectedItem` param (`SceneView.swift:9,22`), consumed by `MirrorModuleModel.swift` selection handling | |
| Folder windows as a model (not a photograph) — Finder's own live item positions | `1f17c38` "folder windows are a model, not a photograph — 40/40", `f81a4f8`, `d232131` | crossed | `FinderItems.swift` + `HitTester.swift`, reachable via `MirrorModuleModel.swift:462` (`HitTester.hitTest`) | |
| Folder-item act (open a window item by identity) | `d232131` "folder items are addressable — hit-test, act.open windowItem, find" | crossed | `ActionModel.swift` `.click(on:)` reached at `MirrorModuleModel.swift:464` | |
| Item-refresh cache-poisoning fix (a failed refresh must not cache the failure) | `a5eaad6` | open | No equivalent cache layer found in NOW's `FinderItems.swift`/`SceneBuilder.swift` on inspection; not independently re-verified line-by-line, and no written decision found either way | Genuinely unexamined, not a deliberate refusal |

## 3. Menus

| Capability | Upstream commit | NOW status | Evidence | Notes |
|---|---|---|---|---|
| Menu bar render (Apple menu + titles + front-app + clock) | part of `65fc7c7` menubar work | crossed | `AppList.swift` (front-app/menu title state) consumed by `SceneRenderer.swift`; `MirrorModuleModel.swift`/`Session.swift` reference `mirror.app`/front-app state | |
| Application menu / app switcher | `65fc7c7` "a real Application menu — the app switcher" | wired-but-unreachable | `now-host/Sources/MirrorKit/AppList.swift` has 0 callers in `Sources/Host` or `Sources/NOWAgentIntegration` outside `MirrorKit` itself (grep confirms zero external hits) | File ported; no host UI wires it into a switcher affordance |
| Apple-menu items addressable by title | `79e867b` "Apple-menu items are addressable by title again" | crossed | Covered by the `axmenu`/menu reference layer; `now-guest-ppc/src/axwalk/` per `docs/mirror-foldin-inventory.md:67` — ported and natively tested | |
| `MENU_INVOKE` (menu command runs the app's own code, hijack closed 18/20→0/19) | `186c012` "feat(portal): MENU_INVOKE", `b4f1718`/`b212554` hijack closure | crossed, reshaped | Guest: `menuact` in `now-guest-ppc/src/commands/commands.c:1333`; `docs/mirror-foldin-inventory.md:90` records the rename (`menuinvoke`→`menuact`, takes scene-reported id not a reference) | The 18/20→0/19 no-hijack measurement itself is upstream's number, not re-run — see rig/method |
| `menugeom` (menu-drag release-point geometry) | folded into `8383019` menu-drag learning work, formalized later upstream | **refused, "not now"** | `docs/mirror-foldin-inventory.md:107-110,328-335`, `docs/open-issues.md` | Its only NOW consumer (`ActionModel.menuRowHeight = 16`) is a known-wrong constant, so the op is deliberately deferred, not dropped — verdict reversed once within 24h, recorded as the lesson |
| Menu hover state (highlight before selection) | render-side work under the `b23dd07` fan-out | crossed | `SceneView.swift:11,29` (`hoveredItem`), consumed by `SceneRenderer` | |

## 4. Windows

| Capability | Upstream commit | NOW status | Evidence | Notes |
|---|---|---|---|---|
| `WINDOW_ACT` — four window traps (close/zoom/collapse/drag-move), answered not dragged | `01ce214` feat, `98bef22` "WINDOW_ACT — 20/20 on all four ops" | crossed | Guest: `winact` in `commands.c:1317`; host: `now-host/Sources/NOWAgentIntegration/Projection/*` + `ActionModel.swift` act rows, per `docs/mirror-foldin-inventory.md:91` | |
| `FindWindow` patch answering at either stage | `6f3c228` "FindWindow answers at either stage, and the counters scope to the request" | open | No FindWindow-trap analogue found in NOW's guest C sources; NOW's act plane does not appear to patch traps for hit-testing the same way | Below-the-line guest mechanism; no written refusal found |
| Window act self-disarming / identity as the guard | `d9db2c4` "self-disarming was never the guard — identity is" | crossed (concept carried) | The identity-not-position rule is what `observe`/`handle` encode; see agent-surface section | Design finding, not a standalone artifact — folded into the reference layer |
| Window-item find/hit-test by live position | `f81a4f8`, `d232131` | crossed | Same `HitTester.swift`/`FinderItems.swift` evidence as desktop section | |
| Drag / shortcut-less menu-drag (emu-only, QMP closed loop) | `8383019`, `40aa89f`, `4cfe05b`, `48ea6fd` (nohijack drag-learning series) | **open** | No QMP-closed-loop drag mechanism found in `now-host/Sources`; `docs/input-plane-decisions.md` covers `click`/`key`/`menugeom` verdicts but not drag | Not written up as a refusal anywhere found — genuinely undecided |
| Window act made QMP-free | `98bef22` "QMP is OUT of the act plane" | crossed (by construction) | NOW's `winact`/`ctlact`/`menuact`/`textget`/`textset` are pure wire verbs in `commands.c`; no QMP dependency in that dispatch path | |

## 5. Controls and text

| Capability | Upstream commit | NOW status | Evidence | Notes |
|---|---|---|---|---|
| `CONTROL_INVOKE` — both halves of `TrackControl` | `2b26df2` wip, `8ab7d05` "CONTROL_INVOKE works — both halves of TrackControl, 20/20 each" | crossed | Guest: `ctlact` at `commands.c:1329`; host: `now-host/Sources/NOWAgentIntegration/Projection/ControlActProjection.swift`, `ActionModel.swift` | |
| `axdo` (upstream single verb: control-actuate + text-write) | throughout portal work | crossed, **split** | `docs/mirror-foldin-inventory.md:92` — split into NOW's `ctlact` and `textset` because actuating and writing are different reaches | Deliberate reshape, recorded |
| Documented `TrackControl` part codes were phantom numbers (bugfix) | `bb25a3b` "the documented part codes were phantom numbers" | crossed (fix carried forward implicitly) | NOW's `ctlact` implementation is a fresh port, not a copy of the old constant table — no phantom-constant reference found in `now-guest-ppc` control-act code | Not independently re-derived against Inside Macintosh in this pass |
| `TEXT_GET`/`TEXT_SET` — the app's own text | `26c6fd8` feat, `e55ebcf` "TEXT_GET/TEXT_SET — the app's own text, and two ops renumbered to land it" | crossed | Guest: `textget`/`textset` at `commands.c:1321,1325` | |
| `TEHandle` bound before dereference (bugfix) | `0dbe07f` "bound a caller-supplied TEHandle before dereferencing it" | open | No explicit bounds-check equivalent independently confirmed in NOW's `textget`/`textset` C source in this pass | Flag for a follow-up code-level check — this lane did not diff C logic line-by-line |
| `ParamCheck` — refuse unrecognized parameters on a mutating surface | `156b8ce` "an unread parameter is an error, not a default", `7dca17d` "every mutating method refuses parameters it does not know" | **wired-but-unreachable** | `now-host/Sources/MirrorKit/ParamCheck.swift` — 0 callers anywhere in `Sources/Host`, `Sources/NOWAgentCompanion`, or `Sources/NOWAgentIntegration` (confirmed by direct grep) | Named explicitly in the task brief as the flagship wired-but-unreachable example |
| `key` verb | act-plane build-out; keycode-vs-char finding is upstream `CONTROL-SURFACE.md` | crossed, narrowed | `commands.c:1361`; `docs/mirror-foldin-inventory.md:95` — crossed but **refuses `mods`**, because CarbonLib has no `PPostEvent` to stamp modifiers on the queue element | Matches this repo's own recent finding (`e80df9e5`, "PostEvent carries no modifiers") |
| Key verb leaks its event queue (measured defect) | `eca8198` "the key verb leaks its event queue" | open | No corresponding leak-fix or written note found for NOW's `key` implementation | Not re-verified |
| `mouseloc` | act-plane build-out | crossed | `commands.c:1357`; `docs/mirror-foldin-inventory.md:91` | |
| `click` (guest-side coordinate click) | throughout no-hijack test series | **refused** | `docs/input-plane-decisions.md`, cited in `docs/mirror-foldin-inventory.md:100,320` | A guest-side click would let a no-hijack probe forge its own evidence; NOW's h2 folder-item probes want identity via `script`, not coordinates |

## 6. App lifecycle and files

| Capability | Upstream commit | NOW status | Evidence | Notes |
|---|---|---|---|---|
| `launch` | `0733e5f` "the launch verb the MCP contract has always specified" | crossed | `commands.c:1283`; shared verb name per `docs/mirror-foldin-inventory.md:56` | |
| `quit` | throughout | crossed | `commands.c:1287` | |
| `apple_event`/`aesend` — `mirror.app {op:"quit"}` reaches a guest, narrowed to a closed vocabulary | `1415ee6` feat, `9536ca2` merge (mirror HEAD) | crossed, narrowed | `commands.c:1369` (`aesend`); `docs/mirror-foldin-inventory.md:93` — narrowed to a closed four-event vocabulary that refuses anything outside it | |
| `activate` | act-plane build-out | crossed, reshaped | `commands.c:1343`; `docs/mirror-foldin-inventory.md:94` — the host already sent this name and no guest answered it until now | |
| `actselftest` (upstream: `portalselftest`) | `7253e03` "a bypass switch — installed but inert on request" and portal-plane build-out | crossed, reshaped | `commands.c:1347`; `docs/mirror-foldin-inventory.md:89` — the plane had served the op since it landed and nothing could call it (now fixed) | |
| Build stamp is a hash over sources, not `__DATE__`/`__TIME__` | `3754750` "build stamp is a hash over the sources, not __DATE__/__TIME__" | open | NOW's own build-stamp mechanism (if any) was not located under `now-guest-ppc` in this pass | Out of scope for this read-only pass beyond flagging it |
| `list`/`stat`/`capture`/`hello`/`ping` — upstream verbs already answered under NOW's own spelling | throughout | crossed, under NOW's names | `docs/mirror-foldin-inventory.md:118-120` — `capture`→`screenshot`, `list`→`ls`, `stat`→the file family, `hello`/`ping`→NOW's own handshake | Never gaps, per the inventory doc's own accounting |
| `volumes` census walk | `90517b9`, `5166fa0` "carry list + stat" | **refused** | `docs/mirror-wave3-verdicts.md` | Same finding as the desktop-section volume row |
| `fetch` (a second bytes-puller) | build-out | **refused** | `docs/mirror-foldin-inventory.md:105` — "a second bytes-puller on a lane one transfer wide" | |
| `close` (upstream: not a window closer) | build-out | **refused** | `docs/mirror-foldin-inventory.md:106` | |
| `journalprobe` | `30e0d9f`-era journaling investigation | **refused** | `docs/mirror-foldin-inventory.md:99,106` — belongs to a closed investigation | Cross-reference `docs/mirror-journaling.md` |

## 7. Agent surface

| Capability | Upstream commit | NOW status | Evidence | Notes |
|---|---|---|---|---|
| `axtree`/`axsnap`/`observe`/`handle` — the reference layer (opaque, observation-minted references) | `d76be02` tests, `e859ec2` "all four ops actuate", reference-layer work through wave 2A per `docs/mirror-foldin-inventory.md:280-286` | crossed | Guest: `observe`/`handle`/`axtree`/`axsnap` at `commands.c:1383,1387,1391,1395`; host: `now-host/Sources/NOWAgentIntegration/Projection/ObserveElementsProjection.swift`, `MirrorObserveModels.swift`, called from `now-host/Sources/Host/MirrorSceneProbe.swift`/`AgentCompanionModel.swift` | The keystone wave; what makes every act verb addressable by identity, not position |
| MCP surface — `mirror.scene` carries `irVersion`, `mirror.app` gains `op=list`, plane enforcement | `36c8ff6` feat, `0b6a511` merge, `d2ae8f0` "mirror.app actually enforces the semantic plane it declares" | crossed | `now-host/Sources/Host/ContractMessages.swift`, `Session.swift`, `MirrorModuleView.swift` reference `irVersion`/`mirror.app`/`mirror.scene`-equivalent contract surfaces; `now-host/Sources/MirrorKit/IRVersion.swift` consumed by `Scene.swift` | NOW's contract naming differs but the capability (versioned scene + plane-enforced app ops) is present and wired |
| In-process agent — "our code runs INSIDE the target app" (Portal) | `a7499e1` "an in-process agent" | crossed (as the act plane) | This *is* the act plane (`ctlact`/`menuact`/`textget`/`textset`/`winact`), all crossed per sections 3-5 | Portal was the mechanism name; NOW's four-op split is the same in-process-agent design |
| Agent-facing surface drives the guest end to end (7/7) | `8049686` "the agent-facing surface drives the guest — 7/7" | wired-but-unreachable for the number itself | The 7/7 result is a measured upstream number (see `docs/mirror-wave3-verdicts.md` provenance); NOW has not run an equivalent end-to-end drive — the mechanism exists (act plane + reference layer), the *drive* is unrun | See rig/method: no emulator gate has run |
| `script` verb (the host has been calling all along) | `1212671` "the `script` verb the host has been calling all along" | crossed | `commands.c:1365` | |
| `qdtrace` | `c3d2aff` "carry qdtrace + QDPeek" | **wired-but-unreachable** | `commands.c:1376` dispatches it guest-side; zero callers anywhere in `now-host/Sources` (grep confirms) | Same underlying gap as the content-plane render row in section 1 — guest serves it, nothing on Host ever asks |
| Cache-poisoning fix on the agent-facing item refresh | `a5eaad6` | open | Same finding as the desktop-section row — not independently re-checked | |

## 8. Rig and method

| Capability | Upstream commit | NOW status | Evidence | Notes |
|---|---|---|---|---|
| No-hijack probe harness (`nohijack-probe.py`, ~50 KB, produced 18/20→0/19) | `a159081` "no-hijack measured — the CONTROL guard holds, the MENU guard LEAKS", full series `1495a40`..`3204fbc` | crossed (ported), **not re-run** | `now/scripts/probes/nohijack-probe.py` present; per `docs/mirror-foldin-inventory.md:140-157` it is ported and has **audited the guest** (found stale claims), but its 18/20→0/19 result is upstream's number, not reproduced on NOW's guest | Ported harness, unexecuted against NOW |
| `winact-probe.py`, `ctlinvoke-probe.py`, `textops-probe.py`/`textops-explore.py`, `apple-event-probe.py`, `g1-probe.py`, `drive-sequence.py`, `h2-items-probe.py` | measurement commits throughout (`8366b66`, `8cca1d6`, etc.) | crossed (ported) | All present under `now/scripts/probes/`, per `docs/mirror-foldin-inventory.md:140-142` | 9 harnesses total including `nohijack-probe.py` |
| Support modules (`nowwire.py`, `scene.py`, `tally.py`, `oracles.py`, `qmp.py`) + their own tests | throughout | crossed | `now/scripts/probes/nowwire.py`, `scene.py`, `tally.py`, `oracles.py`, `qmp.py` all present; `scripts/probes/tests/` per inventory doc | |
| Upstream result fixtures + `PROVENANCE.md` (comparability, not just quotation) | fixture-freeze work (`67c82dd`, `8e45d88`, `af4ecc5`) | crossed | Per `docs/mirror-foldin-inventory.md:146-148` — six upstream fixtures with a `PROVENANCE.md` beside them landed | |
| `mirror-service-e2e.py` / `agent-session.py` (service-lifecycle drivers against upstream's own deploy) | e2e/session work | **refused** | `docs/mirror-foldin-inventory.md:159-161` — both are lifecycle drivers against a deploy path NOW does not have; same judgement as the deploy tooling below | |
| Deploy tooling (`spin-up.sh`, `stage-agent.py`, `stage-mirror.py`, `stop-mirror.sh`) | tooling commits (`483d390` "staging a fresh clone died on a mirror.port that already exists", etc.) | **open** | `docs/mirror-foldin-inventory.md:176-189` — explicitly still open, judged the largest remaining item; NOW's `tools/` holds `fakeguest.py`/`mb_rename.py` and nothing that spins up a guest | Written as open, not refused — a decision is still owed |
| `extract-assets/` tooling | asset-extraction commits | crossed (output) | `docs/mirror-assets.md` records the extraction; `now-host/Sources/MirrorKitUI/Resources` + `assets/icons/` carry the output, per `docs/mirror-foldin-inventory.md:183-185` | The tool's *output* crossed; the extraction script itself was not independently re-verified as present in NOW's `tools/` |
| Scene IR frozen at v1, drift gate | `8e45d88` "freeze the scene IR at v1 behind a parity gate", `67c82dd` merge | crossed | `now-host/Sources/MirrorKit/IRVersion.swift`, `IRSchema.swift`, consumed by `Scene.swift`; IR versioning present in `ContractMessages.swift` | |
| Measurement method (rate cases, both halves scored) | `4b1dfa8` "test(ctlinvoke): rate cases for BOTH halves of TrackControl" | crossed (method), **not re-run** | `docs/mirror-measurement-method.md` ported as a document; the rate-case *methodology* is described but no NOW-side rate numbers exist yet | Documented, unexecuted |
| Ten-document knowledge fold-in (`CONTROL-SURFACE.md` et al., refactored by subject) | doc commits throughout | crossed | `now/docs/mirror-act-plane.md`, `mirror-content-plane.md`, `mirror-perceive-plane.md`, `mirror-knowledge.md`, `mirror-journaling.md`, `mirror-renders.md`, `mirror-assets.md`, `mirror-measurement-method.md`, `mirror-wave3-verdicts.md` all present, per `docs/mirror-foldin-inventory.md:199-208` | Each carries a provenance line attributing measurements to `timbottu/mirror`'s own guest, not NOW's |
| Rendered PNGs (the only record of "working" for UX comparison) | render commits (`f46861e`..`2002f4b` era) | crossed | `now/docs/renders/` has 12 PNGs present (a superset of the 9 catalogued upstream), per `docs/mirror-renders.md` | |

---

## Corpus impact

`corpus_impact: none` for this document's own production — this is an audit
of two checkouts (`git log` + `grep`), not a new measurement. It surfaces one
thing worth a finding if promoted: the content-plane/`qdtrace` row and the
`ParamCheck` row both show working, ported code with zero callers, which is
material for `now/data/findings/` — left unfiled here because this lane is
read-only on code and was asked to write the ledger, not a finding.

## Known gaps in this ledger

- Several "open" rows (§2 item-refresh cache fix, §4 `FindWindow`/drag,
  §5 `TEHandle` bounds check and key-verb queue leak, §6 build-stamp hash,
  §7 item-refresh cache fix again) were **not** diffed at the C-source line
  level against upstream — this lane read `commands.c`'s dispatch table and
  NOW's Swift call graph, not every guest C function body. A line-level diff
  of `now-guest-ppc/src/commands/` against `mirror/guest/app/src/` would
  sharpen these from "open" to a firmer verdict.
- The 8-section, ~60-row structure was reconstructed from `git log
  --oneline` (189 commits) and directory-level reading, not copied from a
  literal upstream "Part 5" document — no file by that name was found in
  `timbottu/mirror`. The closest existing prose synthesis on NOW's side is
  `docs/mirror-foldin-inventory.md` (verb-level, dated 2026-08-01), which this
  ledger cross-cites throughout and extends with host-side rendering/agent
  capabilities and explicit reachability checks that document does not
  perform.
