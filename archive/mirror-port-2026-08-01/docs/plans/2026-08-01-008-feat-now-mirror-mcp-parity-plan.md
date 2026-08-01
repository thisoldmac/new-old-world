# NOW Mirror + MCP parity plan

**Date:** 2026-08-01. **Status:** v2, executing — overnight session
authorized by the maintainer 2026-08-01 ("no punts, no deferrals; make
decisions, preferably ones that make mirror a more authentic mirror of the
guest rendered from data"). Work lands on an integration branch; `main` is
not touched without an explicit go (standing rule, reaffirmed after two
violations by a prior session).

**The row-by-row parity target is Mirror's
[CAPABILITIES.md](/Users/michelle/Lab/Code/timbottu/mirror/docs/CAPABILITIES.md)**
(~50 proven rows, each with its proving commit) — the maintainer named it
the list to check the port against. The morning report scores every row.
**Baseline:** the 2026-08-01 swarm audit and
[mirror-parity-ledger.md](../mirror-parity-ledger.md) (67 rows: 45 crossed,
6 wired-but-unreachable, 8 refused in writing, 8 open), plus the
maintainer's side-by-side screenshot of the running pane against the live
guest (2026-08-01, ~03:27 guest time): connected, chrome-only — menu bar
and window frames draw, every window interior is empty, the desktop is
bare, and the process shelf shows monogram tiles.

## What parity means here

A user or agent at NOW's host gets everything Mirror's **shipped** surface
gives — drawn, clickable, drivable — through NOW's own architecture: one
wire off `contract/asyncapi.yaml`, both faces per capability
([command-parity.md](../command-parity.md)), resident components optional,
no QMP in the act plane, no second front end. Parity is measured against
what Mirror ships (its `Serve.swift` dispatch and `mirror-service-ipc.toml`,
15 methods), not against every experiment in its harness — Mirror itself
does not ship `textget`/`textset` on its service surface, though NOW
already carries both as projections.

**Hard constraints (maintainer, 2026-08-01):** ONE wire and ONE resident
component. Changes to NOW's mirror, wire, and INIT implementations are
fine; sibling sprawl is not — any resident capability parity needs goes
into the existing NOW Extension (`ext/`), never a second INIT, and every
new verb rides `contract/asyncapi.yaml`, never a second transport.
Emulators are cheap and authorized: throwaway clones in parallel,
including Mirror's own stack as a reference oracle to validate against.

**Non-goals** (standing written refusals, not reopened by this plan):
guest-side coordinate `click`, `fetch`, `close`, `journalprobe`, a second
wire (`NoSecondWireTests` holds), copying Mirror files wholesale, the
`MirrorApp` front end, QMP-driven act mechanisms.

## Why the pane looks broken (one paragraph of diagnosis)

The renderer is at parity with Mirror's — newer, in one respect — and is
starved. `now-guest-ppc/src/scene/scene_json.c` emits processes, windows,
menus, controls, and texts, but no desktop items, no per-window folder
items, and no display bytes; `scene.h` leaves control `ref` empty so
`ActionModel.availability` gates most acts behind `.needsObservation`; and
`qdtrace start` refuses to run because it demands a host-supplied A5 while
NOW's own oracle (`peek_oracle.h`, `now_peek_anchor_a5_arm_trusted()`)
sits one call away on the guest. Every fix below is guest-side emission or
host-side wiring of code that already exists.

---

## W0 — Pane hygiene (do first, hours)

**W0.1 Move the process shelf out of the render.** `SceneRenderer.drawShelf`
(`now-host/Sources/MirrorKitUI/SceneRenderer.swift:907-931`) paints a
92-pt "LIVE PROCESSES" strip over the bottom of the scene canvas, occluding
the guest's own screen. Maintainer decision 2026-08-01: remove it from the
render; the data may live on as a control in the host app surface. Default
shape: delete `drawShelf`/`drawProc` from the renderer and surface
`scene.processes` as a section of the Mirror module's host-side chrome
(detail column beside/below the canvas, alongside the existing connection
controls), reusing the host's process models. Removal outright is the
fallback if the relocated section earns no keep.

**W0.2 Docs honesty pass.** Retract `docs/open-issues.md`'s stale "no
MirrorAction is ever built" entry and every repetition of "nobody has seen
the module"; record the screenshot observation (chrome-only, connected) as
the current runtime truth. Move `AUDIT_NOTES.md` and
`BUILDSTAMP_TEST_PLAN.md` from the repo root to `docs/local/`.

## W1 — Content plane: window interiors draw (small, highest visible value)

**W1.1 Contract first:** `qdtrace start` gains PSN-or-`front` addressing;
the `a5` parameter becomes guest-resolved. Declare on the wire that the
guest resolves A5 through its own peek oracle and reports which A5 it
armed (keeping A5 as the identity `ext/src/now_content.c` checks, so the
resident component's low-memory-only rule is preserved).

**W1.2 Guest:** `qdtrace_cmd.c` calls
`now_peek_anchor_a5_arm_trusted()` instead of refusing; refusal remains
for an oracle verdict that is not Ok.

**W1.3 Host:** `MirrorContentJoin` arms the plane for the front window and
drains as already written; `DisplayReplay` and `BitmapFont` (both
currently wired-but-unreachable) become reachable through the live path.

## W2 — Scene completeness: the desktop and windows have contents

**W2.1 Folder-window items.** `scene_json.c` emits per-window `items`
(name, position, icon identity, ref) from the Finder's own model — port
Mirror's *measurements* (`mirror/docs/FOLDER-ITEMS.md`, the
folder-windows-as-a-model design proven 40/40 by the Finder's own oracle),
not its files. Host `FinderItems`/`SceneRenderer` paths already exist.

**W2.2 Desktop items.** `scene_json.c` emits `desktopItems` via the
`fdLocation` semantic route. Disk/volume icons on the desktop: revisit the
written refusal — the refusal was of a duplicate *verb* (census answers
it), not of the *pixels*; plumb desktop volume rows from the census data
NOW already has rather than a new walk, and record the reversal in the
ledger with this plan as the cited reason.

**W2.3 Control refs.** ~~`scene.h`'s empty control `ref` fields are filled
from the reference layer (`observe`/`handle` mint them today), so
`ActionModel.availability` stops answering `.needsObservation` for acts
the guest can already serve.~~ **DONE before start (2026-08-01).** Window and
control refs now land in every scene: `scene.h:178-189` (NowSceneControl.ref,
NowSceneWindow.ref), `scene_walk.c:49-73` (name_window, name_control call
obs walk to mint tokens). `ActionModel.availability` already sees addressed
controls on the scene.

**W2.4 Icon identity end to end.** Scene process and item rows carry
creator/type identity sufficient to key `IconAtlas`'s per-app icons
(`Resources/appicons`, keyed creator+type), so app and item icons render
as bitmaps and the relocated process section shows real icons; monograms
remain only as the documented fallback for unknown creators.

**W2.5 Authenticity rows from CAPABILITIES §1–2** (the details that make
it read as the guest, not a diagram): render at the guest's real
resolution, auto-detected (`a9d1e01`); drag outline during window drags
(`9d274d6`); INVERT-style selection (`3b76f79`); icon hit rules — hit by
name, click at icon centre, label strip part of the target,
unplaced/invisible excluded, a window over an icon wins the point
(`89e8b84`); pixel islands as the fallback where no semantic source
exists, with hold-on-blur focus retention and occlusion-decided held
frames (`040144a`, `2002f4b`, `1db904f`) — NOW's `IslandStore` render
path exists; wire its producer through the one wire. Each row is checked
against NOW and either confirmed present, implemented, or refused in
writing with the ledger updated.

## W3 — Act plane: reachable, drivable, honest

**W3.1** Wire `ParamCheck` into every mutating surface (currently 0
callers — flagship wired-but-unreachable row).
**W3.2** Wire `AppList` into an application-switcher affordance in the
pane's menu bar (currently 0 external callers).
**W3.3** `key` verb: MCP face lands (pane face landed 2026-08-01). The
modifier refusal is **reopened, not declared**: upstream measured ⌘
keystrokes 20/20 on a CarbonLib-era guest (CAPABILITIES §5 `f5cf256`,
`f4b4742` — matched on key CODE not char, "a modified keystroke needs a
beat between its halves"). Study upstream's guest key implementation and
port the mechanism into NOW's `key`; only if the mechanism demonstrably
depends on something NOW's floor lacks does the refusal stand, rewritten
to cite that evidence instead of `PPostEvent`.
**W3.4** Resolve every remaining ledger `open` row — no row stays `open`.
Decisions (overnight mandate, favouring an authentic data-rendered
mirror): FindWindow two-stage answering — **adopt** (upstream ships it,
CAPABILITIES §4 `6f3c228`); `menugeom` — **adopt** (per-item MDEF
geometry is what makes dropdowns authentic — separators 6px vs items
16px, CAPABILITIES §3 `a7499e1`/`186c012` — and its NOW consumer constant
is known-wrong today); QMP-closed-loop drag — **refuse in writing**
(emulator-only mechanism, against NOW's metal-first act plane);
`TEHandle` bounds check diffed at C level against upstream `0dbe07f`;
key-verb event-queue leak checked against upstream `eca8198`;
item-refresh cache-poisoning fix checked against upstream `a5eaad6`;
build stamp becomes a hash over sources (upstream `3754750` — a
`__DATE__` stamp measured the old binary with confidence once, and NOW
has its own build-stamp staleness note in AGENTS.md).

## W4 — MCP parity

Mirror's shipped agent surface is 15 methods on one socket. NOW's is
per-capability projection tools on its own MCP server — keep NOW's shape,
close the capability gaps. Mapping and gaps:

| Mirror method | NOW today | Action |
|---|---|---|
| mirror.attach / detach / status | session health/capabilities projections | verify semantic parity (grants, planes, guest identity, irVersion in replies); document mapping |
| mirror.scene | no scene projection over MCP | **add**: versioned-IR scene tool (irVersion gate, refuse unknown major) |
| mirror.find | ObserveElementsProjection (partial) | **extend**: find-by-title/kind over the reference layer |
| mirror.shot | CaptureScreenProjection (guest screenshot) | **add**: render-shot of the drawn scene (RenderShot.png path exists host-side) |
| mirror.wait | none found | **add**: wait-for-condition (scene predicate, bounded) |
| mirror.act.control | ControlActProjection | parity check only |
| mirror.act.menu | MenuActProjection | parity check only |
| mirror.act.type | TextSetProjection / act path | parity check; document axdo→ctlact/textset split |
| mirror.act.key | none (planned) | **add** (W3.3), incl. ⌘ if the ported mechanism proves out |
| mirror.act.open | RevealItem/Launch projections | verify folder-item open-by-identity parity |
| mirror.act.window | WindowActProjection | parity check only |
| mirror.act.scroll | ControlActProjection (parts) | verify scroll-by-parts parity; position state |
| mirror.app | ListProcesses/BringToFront/RequestQuit + aesend | verify op=list/front/quit vocabulary parity |

Rules that bind every added tool: contract first; a console face in the
same change (`CommandParityTests`); `docs/mcp-coverage.md` regenerated by
its own derivation commands in the same commit; `MCPCoverageTests`
extended; mutating tools refuse unknown parameters (W3.1).

## W5 — The proof rig (the long pole, and the point)

Everything above tops out at "tested" without this.

**W5.1 Spin-up.** Close the ledger's "largest remaining item": a NOW
spin-up path that boots a throwaway emulator clone, deploys the current
guest build + NOW Extension, and connects the host — Mirror's
`tools/spin-up.sh` shape, NOW's own tooling (the parent's `tools/launch`
VM management is the bench). Never touches another session's VM; port
chosen per the metal-gate rules; `requireTheBuildUnderTest()` before any
result is believed.

**W5.2 E2E drive.** A `mirror-service-e2e`-equivalent driving every NOW
MCP tool in W4's table against a live spun-up guest, plus the pane's
gesture path. 7/7-style drive sequence re-scored as NOW's own number.

**W5.3 Re-run the ported probe harnesses against NOW's guest** so the
ledger's borrowed upstream numbers become NOW's: `nohijack` (target 0/N
hijacks), `winact` (20/20 all four ops), `ctlinvoke` (20/20 both halves),
`textops`, `apple-event`. Update the ledger rows from "upstream's number"
to measured.

**W5.4 Render evidence.** Side-by-side screenshot pairs (pane vs guest)
land in `docs/renders/` for: populated folder window, desktop with items,
menu pulled down, window drag mid-flight, text content. These are the UX
record; a claim without its pair does not close.

**W5.5 Metal.** One metal pass at the end, only with explicit per-action
maintainer authorization (deploy names, ports, machine availability per
[68k-metal-runbook.md](../68k-metal-runbook.md)); until then every claim
says "tested" or "emulator-verified", never "works".

---

## Acceptance criteria (exhaustive)

Verification levels per AGENTS.md: **builds** < **tested** <
**emulator-verified** (new intermediate used by this plan: the W5 rig
observed it against a live emulated guest) < **metal-verified**. Each AC
names its required level.

### Global / process (bind every workstream)

- **G1.** Nothing merges to `main`, full stop, this session. All lanes
  merge into the integration branch
  `claude/mirror-parity-overnight`; the morning deliverable includes the
  one-command landing (`git -C <shared checkout> merge --ff-only` or
  `git fetch . <branch>:main`) for the maintainer to run after review.
- **G1b.** One wire, one INIT: no new transport, no new resident
  component; `ext/` absorbs any resident parity need behind its existing
  versioned header contract.
- **G2.** Every behaviour change edits `contract/asyncapi.yaml` first, in
  the same or an earlier commit than the implementation, and states
  whether the opposite direction now differs.
- **G3.** Every capability change updates
  [contract-coverage.md](../contract-coverage.md) and
  [mirror-parity-ledger.md](../mirror-parity-ledger.md) in the same
  commit, by running their derivation greps, not by hand-editing from
  memory.
- **G4.** `scripts/test-all` green at every landing; new native tests are
  in `scripts/test-native`'s manifest; new guest-emitted messages have
  `GuestWireConformanceTests` fixtures.
- **G5.** Every new guard is mutation-watched: the bug is reintroduced
  once and the failing test output is quoted in the PR/commit body.
- **G6.** No new window in the guest (Workshop modules only); no second
  wire; no QMP in the act plane; `NoSecondWireTests` stays green.
- **G7.** Status vocabulary discipline: no artifact says "works" below
  metal-verified; every completion report names its level.
- **G8.** First commit within the first few tool calls of each lane;
  checkpoints labelled unverified when they are.

### W0 — Pane hygiene

- **AC-0.1** (tested) `SceneRenderer` contains no shelf/process drawing:
  `grep -n "LIVE PROCESSES\|drawShelf\|drawProc" now-host/Sources/MirrorKitUI/`
  returns nothing.
- **AC-0.2** (tested) `RenderShot.png` output of a scene with 9 running
  processes contains no shelf band: a render fixture asserts scene pixels
  reach the canvas bottom edge.
- **AC-0.3** (tested) Processes remain visible in the module's host
  chrome outside the canvas (or, if removal was chosen, a written note in
  the module doc records the decision); front-process highlight and count
  survive the move; the section never overlays the render.
- **AC-0.4** (n/a) `docs/open-issues.md` no longer claims the gesture path
  is unbuilt; no doc claims the module has never been seen; both root
  scratch files live under `docs/local/`; `git log` shows the retraction
  cites the screenshot observation.

### W1 — Content plane

- **AC-1.1** (tested) Contract: `qdtrace start` accepts `psn` or `front`
  and no longer requires `a5` from the caller; the reply names the armed
  A5 and its oracle verdict; both guests' dispatch either serves or
  refuses-by-name per [command-parity.md](../command-parity.md).
- **AC-1.2** (tested) Guest native test: `qdtrace start {front}` with a
  healthy oracle arms and returns Ok; with a failing oracle verdict it
  refuses with the verdict named; mutation-watch: breaking the oracle call
  makes the test name it.
- **AC-1.3** (tested) `MirrorContentJoin` arm-gap message is gone for the
  front-window path; join tests updated; torn frames still never draw and
  resync loss is still reported beside surviving ops.
- **AC-1.4** (tested) `BitmapFont` and `DisplayReplay` each have a
  reachable caller chain from the live app (ledger rows flip from
  wired-but-unreachable to crossed with call-site evidence).
- **AC-1.5** (emulator-verified) A SimpleText window's text on the guest
  is readable in the pane; screenshot pair in `docs/renders/`.
- **AC-1.6** (emulator-verified) Closing the traced window and arming the
  next front window works twice in one session (no one-shot arming).

### W2 — Scene completeness

- **AC-2.1** (tested) `scene_json.c` emits `desktopItems` and per-window
  `items` with name, rect/position, icon identity (creator/type or kind),
  and a mintable ref; contract rows added; conformance fixtures exist.
- **AC-2.2** (emulator-verified) Side-by-side: the guest's "Macintosh HD"
  window and the pane show the same item count, names, and icons ("10
  items" case from the 2026-08-01 screenshot is the canonical fixture).
- **AC-2.3** (emulator-verified) Desktop shows volume(s) and Trash with
  disk/trash icons at guest positions; ledger's disk-icon refusal row is
  rewritten as crossed-via-census with this plan cited.
- **AC-2.4** (tested) No scene-visible control has an empty `ref`; a
  native test fails if any control row is emitted ref-less;
  `ActionModel.availability` for `ctlact` on a scene-reported scrollbar
  answers available, not `.needsObservation`.
- **AC-2.5** (tested) Process and item rows carry icon identity;
  `IconAtlas` keying test covers creator+type hit and monogram fallback;
  the pane's app-menu/process affordances show bitmap icons for known
  creators.
- **AC-2.6** (emulator-verified) Item refresh that fails does not cache
  the failure (upstream `a5eaad6` case reproduced as a NOW test, then
  fixed — closes both ledger `open` rows that cite it).

### W3 — Act plane

- **AC-3.1** (tested) Every mutating projection and guest mutating verb
  rejects unknown parameters; `ParamCheck` has call sites on all mutating
  surfaces; a test feeds an unknown key to every mutating tool and asserts
  refusal (ledger row flips).
- **AC-3.2** (tested) The pane has an Application-menu switcher backed by
  `AppList`; clicking a process brings it front via the existing
  bring-to-front path (ledger row flips).
- **AC-3.3** (tested; ⌘ emulator-verified) `key` is reachable from all
  three faces — pane, console, MCP — with one implementation behind them;
  `CommandParityTests` covers it. ⌘ keystrokes work via the ported
  upstream mechanism (code-matched, beat between halves), measured
  against the live guest; if and only if the mechanism provably cannot
  work on NOW's floor, the refusal is rewritten citing that evidence.
- **AC-3.4** (n/a) Zero ledger rows remain classified `open`: each is
  crossed (with evidence) or refused (with a written reason in the ledger
  and its cited doc). Specifically resolved: FindWindow patch, QMP drag,
  `menugeom`, `TEHandle` bounds, key queue leak, build-stamp hash.
- **AC-3.5** (emulator-verified) From the pane alone: drag a window ≥100px
  (guest window moves), close/zoom a window, pull down a real menu and
  select an item that visibly acts, click a folder item open, type a
  sentence into the guest — each observed against the live guest, 20/20
  where the upstream measured 20/20 (W5.3 scores them).

### W4 — MCP

- **AC-4.1** (tested) Every row in the W4 mapping table exists as a NOW
  MCP tool or a written per-row refusal in `docs/mcp-coverage.md`; the
  five **add** rows (scene, find-extension, render-shot, wait, key) are
  present in `tools/list` output.
- **AC-4.2** (tested) The scene tool carries `irVersion` and refuses an
  unknown major from either side; a test asserts the refusal.
- **AC-4.3** (tested) Every new tool has a console face
  (`CommandParityTests` green) and appears in `docs/mcp-coverage.md`
  regenerated by its derivation commands (diff of regenerated vs committed
  file is empty in CI/gate).
- **AC-4.4** (tested) `MCPCoverageTests` enumerates the full tool list;
  count and names asserted; the `guest` selector semantics hold on every
  new tool (naming a non-driven machine is refused).
- **AC-4.5** (emulator-verified) One agent session over stdio MCP performs:
  session health → scene → find (a folder item by name) → act.open →
  wait (window appears) → render-shot → window close → app op=list —
  all green against a live spun-up guest (W5.2's drive).
- **AC-4.6** (tested) Docs state the deliberate shape difference from
  Mirror (per-capability tools vs single socket service; axdo split into
  ctlact/textset) in `docs/mirror-parity-ledger.md` §7 notes.

### W5 — Rig and proof

- **AC-5.1** (emulator-verified) One command spins up a throwaway clone,
  deploys the current guest build and extension, and the host connects —
  from cold to connected pane without manual steps; it refuses to touch a
  port another process holds (`MetalMachineGuard`-style check) and never
  targets a VM it did not create.
- **AC-5.2** (emulator-verified) The spin-up asserts
  `requireTheBuildUnderTest()`-style identity (build stamp) before any
  result is recorded; build stamp source-hash decision from AC-3.4 feeds
  this.
- **AC-5.3** (emulator-verified) E2E drive (AC-4.5's script) is a checked-in
  test entry (opt-in gate like the Metal suites: skips without
  `NOW_EMU` set, FAILS rather than skips with it set and no guest).
- **AC-5.4** (emulator-verified) Probe harnesses re-run against NOW's
  guest with NOW's numbers recorded in the ledger: nohijack 0/N, winact
  20/20 ×4 ops, ctlinvoke 20/20 both halves, textops at upstream rates,
  aesend vocabulary; any miss is a named defect, not a rounded-up pass.
- **AC-5.5** (n/a) `docs/renders/` gains the five screenshot pairs named
  in W5.4, each captioned with build stamp and date.
- **AC-5.6** (n/a — metal readiness, not a metal pass) Tonight produces:
  the canonical `New Old World.bin` built from the integration branch
  with a source-hash build stamp, staged nowhere; the deploy checklist
  per the runbook; and a written list of every mechanism that will behave
  differently on metal (emulator-only paths and how each refuses
  honestly). The metal pass itself is tomorrow, with the maintainer,
  under per-action authorization. Until it runs, all parity claims stop
  at emulator-verified.
- **AC-5.7** (n/a) [open-issues.md](../open-issues.md) updated at arc end
  with shipped-vs-still-unknown; durable findings promoted to the parent
  corpus per AGENTS.md.

### Exit criterion (the one-line test)

The 2026-08-01 side-by-side screenshot, retaken: the pane and the guest
show the same desktop — same windows, same folder contents, same icons,
same menus — and dragging, clicking, menu-selecting and typing in the pane
visibly happen on the guest; an MCP agent can do the same eight-step drive
blind. No process shelf over the render.

## Sequencing and effort

W0 (hours) → W1 (1 lane, small) and W2 (2–3 lanes, medium) in parallel →
W3 (medium, partly overlaps W2) → W4 (medium) → W5 (the long pole; start
W5.1 early since every emulator-verified AC depends on it). Suggested
order optimizes user-visible payoff per lane: W0, W1, W2.1–2.2 give the
screenshot-changing wins in the first three lanes.

## Decisions resolved under the overnight mandate

Per the maintainer's 2026-08-01 instruction ("no punts, no deferrals;
make decisions, preferably ones that make mirror a more authentic mirror
of the guest rendered from data"):

1. Process shelf: **relocate** to module chrome, out of the canvas.
2. Desktop disk icons: **do it**, plumbed from census data (AC-2.3).
3. FindWindow patch: **adopt** (upstream ships it). `menugeom`:
   **adopt** (authentic dropdown geometry). QMP-loop drag: **refuse in
   writing** (emulator-only; NOW is metal-first).
4. ⌘ keystrokes: **attempt the upstream mechanism** before any refusal
   stands (W3.3).
5. Spin-up: **NOW-owned throwaway clones** on the parent's `tools/launch`
   bench, session-private ports, never another session's VM. Mirror's own
   stack may be spun up as a reference oracle.
6. Metal: **prepared tonight, run tomorrow** with the maintainer (AC-5.6).
7. Landing: **integration branch only**; `main` untouched until an
   explicit go (G1).

## Overnight execution architecture

- **Swarm throughout** (maintainer instruction): waves of narrow
  subagents via the Workflow engine, each lane in its **own git
  worktree** branched off `claude/mirror-parity-overnight`; the
  orchestrator merges lanes as they land and resolves conflicts once.
- **Shared files are orchestrator-owned.** `contract/asyncapi.yaml`,
  `commands.c`'s dispatch table, `scene_json.c`'s emitter spine, `ext/`
  headers, and the test manifests take registrations from lane reports
  in single orchestrator edits (defer-registration), so six lanes never
  contend on one registry.
- **Grounding loop.** After every merged wave: `scripts/test-all`, then
  an emulator validation pass against the session's own spun-up guest,
  then a screenshot pair into `docs/renders/` (working states) or
  `docs/local/` (investigation states). A wave is not done until the
  screenshot exists. Mirror's stack is the reference oracle when a
  behaviour question needs the upstream answer observed, not remembered.
- **First-commit deadline** per lane (a stub or notes file within the
  first few tool calls); checkpoints labelled unverified; lanes report
  structured returns, never prose dumps.
- **Documentation as we go.** Each wave updates the ledger and
  contract-coverage in the merging commit; investigation notes go to
  `docs/local/`; the morning report
  (`docs/local/2026-08-01-overnight-report.md`) scores every
  CAPABILITIES.md row (done at which verification level / refused with
  reason / missed with what remains), lists every screenshot pair, and
  ends with the one-command landing and the metal checklist.
- **Sanity anchors.** Build stamp checked before believing any emulator
  result; `requireTheBuildUnderTest()`-style identity on every wire
  assertion; no result quoted from `fakeguest.py`; another session's VM
  is never touched, and the maintainer's running VM least of all.
