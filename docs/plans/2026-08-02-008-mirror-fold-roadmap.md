# Folding Mirror's residents into the NOW Extension, then Mirror into NOW

**Date:** 2026-08-02 · **Status:** superseded historical roadmap ·
**Namespace:** `claude/` · **Branch under study:** `claude/mirror-subproject`

> **Superseded 2026-08-03.** Implementation authority moved to
> [the unified NOW Extension prerequisite](2026-08-03-002-feat-unified-now-extension-plan.md),
> followed by [NOW Mirror UX Completion](2026-08-03-001-now-mirror-ux-completion-plan.md).
> The prerequisite owns the resident ABI, P1-P4, legacy-runtime retirement,
> direct-input focused proof, and clean development image. Plan 001 resumes
> only after that prerequisite is complete. The work packages below remain as
> provenance for measurements and rejected paths; they must not be executed as
> a parallel implementation plan.

A snapshot of intent, per [README](README.md). Where this and the code
disagree, the code is right; where this and
[open-issues.md](../open-issues.md) disagree, the ledger is right.

**Relation to [2026-07-31-007](2026-07-31-007-feat-now-mirror-integration-plan.md):**
that plan described the in-repo re-implementation that was thrown away on
2026-08-01 (`archive/mirror-port-2026-08-01/`; the retraction is
open-issues' "The Mirror port was thrown away"). This plan supersedes its
M6 shape — but its guest-side work survived the throw-away and is the
reason this roadmap is smaller than it looks: the act verbs, the scene
family, and the NOW Extension planes it built are live on
`claude/mirror-subproject` today. 007 stays as the record of why they
exist.

## Where this starts from

Mirror lives vendored at `mirror/` — a working sibling: three 68K INITs
(AXPeek `'TBax'`, QDPeek `'TBqd'`, Portal `'TBpt'`), a faceless PPC agent
serving 31 verbs of line-JSON on guest port 1420, and a SwiftPM host stack
(MirrorKit / MirrorKitUI / MirrorApp). NOW's host page controls only its
lifecycle: it spawns MirrorApp as a child process and probes readiness.
Two wires, disjoint in every dimension — framing, direction, port,
encoding, process.

The intended end state, decided 2026-08-02:

1. **One system extension.** The TB* INITs retire; the NOW Extension's
   planes serve what they served. **Strict parity bar:** a TB* INIT
   leaves the staged image only when every capability it served is
   proven at parity on the NOW plane — differential or selftest numbers,
   not adjectives.
2. **Hybrid migration path.** Prove the NOW planes first; migrate the
   perceive plane first; act and content go **directly to NOW's wire**,
   served by the NOW guest, so the peek table never gains a second
   writing client (the charter's "the app writes only the arm cells" is
   singular on purpose). A temporary mirror-agent adapter for
   `NowPeekTable` is permitted only for perceive, and only if it buys a
   cheap differential gate.
3. **Host shape.** `now-host` consumes MirrorKit + MirrorKitUI as a
   local SwiftPM dependency; the mirror renders in a NOW window fed by
   NOW's wire. MirrorApp and port 1420 eventually disappear.

## What is already true (verified in tree, 2026-08-02)

The fold is a **reader migration, not an extension merge**. Three facts
make it much smaller than the framing suggests:

- `ext/` already re-implements all three Mirror INITs as planes of one
  INIT under the [resident-components charter](../resident-components.md):
  P1 anchors ≈ AXPeek, P3 content ≈ QDPeek, P4 act ≈ Portal.
  `now_act_guard.c` already carries Portal v4's hijack lessons
  (exact-target naming, click-point check); `content_table.h` is a
  superset of `qdshared.h` (COUNT/RECORD, `arm_expiry`, refusal
  counters).
- Mirror's verb surface is largely **on NOW's wire already**: `winact
  ctlact menuact textget textset elements activate actselftest mouseloc
  key script aesend qdtrace observe handle axtree axsnap` dispatch in
  `now-guest-ppc/src/commands/commands.c:1407-1495`, and
  `scene.request`/`scene.report` are contract channels served by
  `wire.c :: serve_scene`.
- P4's `actselftest` has run clean on the emulator
  ([staging-path.md](../staging-path.md), abi-agreed). "Never armed
  anywhere" is true only of P3.

What is genuinely missing, from the headers rather than from memory:

- **P4:** `PT_OP_MENU_GEOMETRY` (Portal op 1) has no act-cell
  equivalent in `contract/peek_table.h`. Its consumer is real —
  MirrorKit hardcodes `menuRowHeight = 16`, which upstream measured
  wrong.
- **P1:** AXPeek's assembly throttle (`axgne.S`: A5-change /
  WindowList-change fast path, 6-tick cap; the unthrottled version did
  ~1M updates during boot) has no `now_ext_gne.S` equivalent. NOW
  captures every GNE pass while armed — fine page-scoped, unproven for
  a continuously-armed mirror session. Always-on vs armed-only is a
  deliberate divergence to argue in writing, not silently port.
- **P3:** present, discoverable, never armed on any machine.
- **Host:** `NOWSceneDocument.Window` drops the guest-emitted
  `windows[].ref` on decode; five act projections declare
  `.appUI: .notReached`. This is the archived port's "a person cannot
  click," still open, and it is a host problem, not a guest one.
- NOW cannot see TB*/NWex residency over the wire (open-issues, "the
  Mirror page is a lifecycle now").

The archive's lesson binds every milestone below: its gates were green
off wire probes while the pane could not click. **Every slice ends with
a watched click or render on the emulator**, and archive files
(`MirrorSceneAdapter.swift`, `MirrorActionDriver.swift`) are references
to read, never code to resurrect wholesale.

## The agent surface converges the same way

Mirror has a second northbound surface NOW's page never uses:
`MirrorApp --serve` — fifteen `mirror.*` methods (attach/detach/status,
scene/find/shot/wait, act.control/menu/type/key/open/window/scroll, app)
over a framed-JSON unix socket, plus the ManagedServe readiness plane.
It retires with MirrorApp, so it must be accounted for, and the
accounting is **not a new milestone**: NOW's MCP is a client of the host
projection layer, never a third face
([command-parity.md](../command-parity.md)), so each slice that lands a
broker for the pane lands its projection rows in the same slice, and
[`MCPCoverageTests`](../mcp-coverage.md) gates the honesty of the join.

The mapping, method by method:

- `mirror.attach` / `mirror.detach` — dissolve; NOW's session model owns
  the connection, and single-client attach semantics have no equivalent
  worth porting. Written disposition, not silence.
- `mirror.status` — WP1's `mirror` verb, projected.
- `mirror.scene` / `mirror.find` / `mirror.wait` — WP2's scene broker,
  as projection rows beside the pane (find/wait are host-side joins over
  the same scene the pane renders; they answer from the same decode, or
  they are two implementations).
- `mirror.act.control/menu/window/type/key/open` and `mirror.app` — the
  act projections WP3 flips out of `.notReached`, plus the existing
  key/script/launch/activate reach. `mirror.act.scroll` follows the
  control path or gets a written refusal.
- `mirror.shot` — WP4's `capture.request` region change serves the pane's
  islands and this tool with one contract change.
- WP5 retires `--serve` and ManagedServe with MirrorApp, gated on every
  `mirror.*` method having a projection row or a written disposition in
  [mcp-coverage.md](../mcp-coverage.md).

Prior art: the `claude/mcp-mirror-gap-l6*` branches worked this join;
read them before re-deriving the mapping.

### The two surfaces must run in parallel (decided 2026-08-02)

The pane (human) and the MCP (agent) are **usable at the same time**;
neither pauses, breaks, or silently starves the other. Mirror today is
the counter-example — its agent serves one client serially, so NOW's
page must stop probing while a mirror runs. That property does not
survive the fold. The rule and its consequences, per layer:

- **One owner of the guest wire.** A single host-side broker owns the
  session's requests; pane and projections are both its clients. Two
  consumers never hold independent claims on the lane — contention is
  scheduled in the broker, where it can be fair and attributable, not
  on the guest, where it reads as a hang.
- **Scene is shared, not duplicated** (WP2). One poll cadence feeds one
  decoded scene; the pane renders it and `mirror.scene`/`find`/`wait`
  answer from it. Two pollers would double the walk load and halve the
  cadence — the broker's cache is the deliverable, and both consumers
  carry the same staleness stamp.
- **Acts are one queue with attribution** (WP3). The act cell is one
  mailbox; the broker serializes pane clicks and agent acts, and a
  refusal or timeout names whose request it answers. An agent act must
  never surface in the pane as a phantom click, and a pane click must
  never be blamed on the agent — attribution is part of the projection
  row and the pane's state, not a log line.
- **Content targeting has an owner policy** (WP4). One traced A5 at a
  time is a plane fact; if the pane mirrors app X while an agent asks
  to trace app Y, the second requester gets an honest refusal naming
  the holder (the `MetalMachineGuard` shape, applied to a plane), not
  a silent steal. Same-target requests share the drain.
- **Arm leases are counted, not flagged** (WP1). The P1 owner tracking
  in `peek.c` counts lessees — pane session, agent session, Processes
  page — and disarms on the last lapse, so one consumer's exit cannot
  disarm the plane under the other.
- **The gate:** WP2–WP4 watched verifications each add a parallel case —
  the pane visibly live while an agent drives the same guest through
  the MCP (and vice versa), with the collision behaviours above
  observed, not asserted.

## Milestones are tiers of integration, and every one of them works

Defined by Michelle, 2026-08-02, after past agents stopped mid-arc and
handed over broken builds. A milestone is **not** "this little piece is
done, but it doesn't work yet." A milestone is "**everything works**,
but we are not yet fully integrated." The tiers below differ in *how
much of the stack is NOW's*; they never differ in *whether the product
works*.

**Definition of done for every tier — all five, no exceptions:**

1. A **running VM** with NOW and Mirror running, connected to a host
   build.
2. The mirror **launches from the host** and all user-facing
   functionality works: clicks, window draw, menus — whichever stack
   currently serves them.
3. The **agentic surface is not crippled** — whatever agents could do
   at the previous tier, they can do at this one, in parallel with the
   human per the collision rules above.
4. **Deployable artifacts handed over** for manual metal testing: the
   host `.app` (Release), the guest `New Old World.bin` (an honest dev
   name if the tier is unlanded), the `NowExt.bin`, and the TB* INIT
   bins for as long as they are part of the staged image.
5. A **semantic, digestible report**: what was done, what is
   outstanding, in plain language — not a diff summary.

**No stopping between tiers.** The work packages inside a tier (the
WP-numbered sections below) are internal units — commit checkpoints
land continuously per the repository's checkpoint discipline, but a
work-package boundary is never a place to stop and report. If a session
dies mid-tier, the last *delivered* state is the previous tier, and the
next session finishes the tier before anything else. A broken build is
never a stopping point.

**The strangler-fig consequence.** Because every tier must carry full
user-facing functionality, the delivered mirror surface stays on
Mirror's own stack (MirrorApp, its wire, the TB* INITs) until NOW's
replacement surface reaches **full** parity — clicks, menus, draw,
interiors — and only then swaps in. There is no tier where the human
gets a mirror that renders but cannot click.

### The tiers

**T1 — Proven residents, same product** (work packages WP0 + WP1).
The product is exactly today's: MirrorApp spawned from the host page,
Mirror's wire, TB* INITs staged beside the NOW Extension. What changes
underneath: the NWpt planes carry proven numbers, the `mirror`
residency verb lands (the host page gains true residency — a visible
improvement), the arm-lease and throttle are in, `gestalt` refuses
unknown args. Agents keep everything they have today.

> **AMENDED 2026-08-02, after WP0 measured it.** T2 as written below
> assumes a clickable mirror is reachable once the host side is built.
> **It is not, today.** The act plane arms correctly inside a foreign
> application and the press it posts for itself is never consumed — the
> guest's own words are `act-not-taken: armed, and the application never
> called MenuSelect` (open-issues, "the act plane arms in a foreign app
> and its click is never taken"). Every click-driven verb rides that one
> step. So T2 cannot be entered as specified: either the press-delivery
> problem is solved first, as its own piece of work with its own number,
> or T2 is re-cut to deliver the perceive half as a tier of its own —
> which would be a mirror that renders and cannot click, and therefore
> needs Michelle's explicit say-so, because the milestone rule forbids
> exactly that shape by default.

**T2 — The mirror is NOW's window** (work packages WP2 + WP3 + WP4,
delivered together). The host launches a NOW-owned mirror window
(MirrorKit as dependency) fed by NOW's wire and the NOW Extension:
scene render, clicks, menus, window ops, text, interiors — all of it —
with the `mirror.*` projection rows landing beside their brokers so the
agent surface reaches everything the pane does. MirrorApp remains
available as the fallback surface during the tier's development and at
its delivery; the TB* INITs remain staged (differential evidence and
fallback). The tier is reached when the watched gates for scene, act,
content, and the parallel human+agent cases all pass on the NOW window.

**T3 — One extension, one wire, first-class module** (work package
WP5). Identical user-facing product to T2, now on the single stack:
TB* INITs out of the staged image under the strict-parity checklist,
MirrorApp / `--serve` / port 1420 retired with per-method dispositions,
the lifecycle page becomes the module page, docs closed out.

## Work packages (internal units — never stopping points)

### WP0 — the proving gate (emulator)

Turn "present and discoverable" into per-plane NOW numbers on a
session-private mac99 clone (`scripts/build-guests` →
`scripts/spin-up-ppc` → `tools/stage-ext.py` → hard reboot).

- Pre-arm audit first: diff live `ext/src/now_content.c` against
  `archive/mirror-port-2026-08-01/`'s copy for the record-mode
  tick-stamp fix (looks fixed; unverified).
- **P4:** `scripts/probes/nohijack-probe.py`, denominators ≥ 20, so the
  no-hijack criterion gets a NOW number beside Portal's 0/19. The
  `cross` case needs a second guest app; if it cannot be driven, record
  it open in [no-hijack-criterion.md](../no-hijack-criterion.md) rather
  than shrinking the table. Run the numbers against **both NOW's own
  app and the Finder**: the 2026-08-01 overnight arc
  (`claude/mirror-parity-overnight`) saw `actselftest` abi-agree
  against NOW's app while *refusing against the Finder* on the same
  build — suspected PPC-native trap dispatch bypassing the 68K patches
  — and its click-driven act family measured 0/10. If that split
  reproduces here it is an WP3-blocking platform fact and must be
  understood before any pane click is promised.
- **P3:** first arm ever — count then record against a scripted
  SimpleText stimulus; prove the refusal counters by a deliberately
  mis-addressed arm.
- **P1:** anchor coverage and the launch settle window, measured.
- **Differential gate** (instead of an agent adapter, unless this
  proves too coarse): `NOW_STAGE_MIRROR=1` stages both resident
  families on one clone; a probe asks mirror-agent (line-JSON, :1730)
  and NOW (scene/axtree over the wire) about the same machine state and
  diffs the inventories. Co-residency is itself a variable — both act
  planes patch the same six traps, and QDPeek skips ports that already
  carry custom grafProcs — so P3/P4 differentials need care about which
  family is armed when.
- Numbers land NOWBASE-style (build, clone, port beside every figure)
  in [mirror-parity-ledger.md](../mirror-parity-ledger.md), whose
  current numbers are all upstream's by its own admission — and whose
  "crossed" host rows cite archived paths; stale-mark them in the same
  pass.

### WP1 — residency verb, arm-lease, throttle

- Contract-first `mirror` verb serving `MirrorFacts` (the guest console
  face already computes it in `now-guest-ppc/src/mirror/mirror_probe.c`);
  closes the residency-visibility gap. Same commit: contract-coverage
  row, host projection, both faces per
  [command-parity.md](../command-parity.md), NOW-68K's answer decided in
  writing (expected: refuse). Sibling fix: `gestalt` refuses unknown
  args instead of ignoring them.
- **P1 arm-lease:** `scene.request` arms anchors with a lease deadline;
  the guest disarms on lapse or wire drop. Owner tracking lives in
  `peek.c` — the Processes page and a scene lease would otherwise fight
  over one `arm_request` bit.
- **Throttle port** from `axgne.S` into `ext/src/now_ext_gne.S`, built
  and proven as a throwaway dev-INIT (`tools/mb_rename.py`) on a clone
  before folding in; state the ≤10 Hz heartbeat consequence in
  `peek_table.h`'s liveness comment.
- Conformance fixture for the multi-snprintf `mirror` reply (the gate
  will demand it by design); new native tests into `scripts/test-native`'s
  manifest; mutation-verify the lease by removing the disarm.

### WP2 — perceive: MirrorKit renders NOW's scene in a NOW window

- `now-host/Package.swift` gains a local path dependency on
  `mirror/host/MirrorKit` — products MirrorKit and MirrorKitUI, never
  MirrorApp. Both build systems (`scripts/test-host` exists because
  they have diverged before).
- A broker adapter maps `scene.report`/`NOWSceneDocument` →
  `MirrorKit.Scene`, feeding `SceneView` directly; `ScenePoller` and
  `WireClient` (MacRoman line-JSON dialing 1730) are bypassed, replaced
  per-capability. Any MirrorKit edit is a recorded divergence from the
  standalone repo.
- `Window.ref` is decoded here; WP3 depends on it.
- Measure before choosing cadence: `serve_scene` already reports
  `walk_ms`; record walk + wire per poll and what a concurrent transfer
  does (`serve_scene` refuses while a stream owns the lane — that is
  NOW's shape of scene starvation). MirrorKit's default is 0.5 s; the
  0.7 s figure in circulation could not be located and is treated as
  stale. Staleness renders honestly.
- **Gate:** a human watches the NOW window track the emulator — launch,
  menu pull, window drag. This slice is read-only; clicks are WP3.

### WP3 — act: a person clicks the NOW mirror

- Gestures on the scene view → HitTester (alive, callerless today) → an
  action driver routing `MirrorAction` → NOW act verbs by **ref, never
  coordinate** (the 18/20 lesson). Flip the five `.notReached`
  projections with evidence.
- The `menugeom` disposition happens here, pane on screen: port
  `PT_OP_MENU_GEOMETRY` as an accretive act-cell op (`act_format` bump,
  guard, selftest, native tests — a foreign-MDEF call, the riskiest
  class) **or** measure row heights another way and retire the
  capability with a written argument. Strict parity blocks Portal's
  retirement on this either way. Sequence it early: pane-side menu
  hit-testing mis-targets while `menuRowHeight` stays wrong.
- **Gate:** watched clicks per op class (window close/zoom/drag, menu
  New Folder makes a folder, control click moves the live scrollbar,
  textset lands in a TE field) through the pane; nohijack numbers
  re-held over the wire; a stale ref fed to the driver gets its refusal
  named.

### WP4 — content: window interiors

- Host drives `qdtrace` over the wire: arm RECORD by A5 from `observe`,
  drain on cadence, re-arm on expiry (aging is the design working, not
  a bug). Content join feeds `MirrorKitUI.DisplayReplay` — the ledger's
  flagship wired-but-unreachable row.
- Pixel islands need a contract change: `capture.request` gains a
  region. Contract first, both halves, conformance fixture, coverage
  row, NOW-68K's answer in writing.
- Wire budget is the named risk: scene polls + drains + island
  refreshes share a one-transfer-wide lane. Measure the combined
  cadence before committing UI behaviour; interiors freeze during
  transfers and the pane says so.
- **Gate:** typed text appears in the mirrored interior and matches a
  screenshot; count-mode differential against QDPeek on the same
  stimulus; loss and refusal counters accounted for over 60 s.

### WP5 — strict-parity retirement

- Per-INIT checklist derived from the shared headers, not memory:
  AXPeek (oracle fields WP0/WP1, always-on-vs-lease equivalence argued in
  writing, throttle WP1); QDPeek (WP0 + WP4 differentials); Portal (WP0 +
  WP3 numbers, `menugeom` disposition).
- Retirement inventory: the mirror bundle in `tools/stage-ext.py`; the
  1420→1730 forward in `scripts/spin-up-ppc`; the host lifecycle page
  (`MirrorProduct` / `MirrorControlModel` / `MirrorControlView`),
  superseded by the mirror window; the guest Mirror page's TB* Gestalt
  reads (`src/mirror/`); docs — coverage rows in the same commits,
  ledger stale-marks, open-issues closures, README's what-works pair.
- **Gate:** one full spin-up **without** the mirror bundle, and every
  WP2–WP4 watched gate re-run green on the NWpt-only image. That run is
  the retirement evidence.

## Out of scope for this whole arc

No metal (attended, per-action ask; every claim tops out at
"emulator-verified" and says so). No deletion of `mirror/` (still the
vendored reference and standalone product) or `archive/`. No NOW-68K
mirror capability — its parity questions get written refusals as they
arrive.

## Carried unverified

- The live `now_content.c` fully carrying the archive's record-mode
  stamp fix.
- Whether one guest session multiplexes scene polls acceptably, or the
  mirror wants its own connection.
- MirrorKit seam cost: SceneView-direct vs adding a `SceneSource`
  protocol to the vendored package.
- The `cross` no-hijack case's drivability on the emulator image.
