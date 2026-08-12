<!-- now-doc-provenance: generated reviewed=false -->

# Resident components

NOW's charter says two applications and one wire contract. This note
adds the third thing the product will ship: **optional resident
components** on the guest — boot-time code that exists so the
application can see what a normal process cannot. It is the family
charter: what may be resident, what never may, and the conventions
every member follows. The first member is the NOW Extension
([processes-and-peek.md](processes-and-peek.md) is its feature ladder);
the rules here outlive it.

The prior art is the parent project's AX workstream (AXPeek, QDPeek,
Portal, the Worker, the mirror spike). Its source, fixtures, and measurements
are retained as an isolated differential oracle, but **none of those components
is a production dependency**. Mechanisms may be reimplemented behind NOW's
single contract only after their user outcome and safety bounds are accounted
for in [the derived retirement ledger](mirror-foldin-inventory.md#legacy-runtime-capability-disposition).

## The three tiers

Every candidate feature gets the cheapest tier that can carry it, and
must say why the cheaper tiers cannot.

**Tier A — the application.** The default home for everything. The
wire terminates in the app, so anything that only matters while NOW is
running belongs here — including "the host launches an app on this
Mac", which is a contract verb plus `LaunchApplication`, no residency
required. Boot presence for the app itself is the Startup Items
folder, not code.

**Tier B — a background-only app (`'appe'` in Extensions).** The
platform's sanctioned service shape: boot-launched, full Process
Manager context, real networking, an event loop, a safe lifecycle.
This tier earns its place only when something must answer the wire
while the application is closed (launch-on-demand, crash watchdog).
**Deferred**: no current feature needs it. Its known lesson, when it
comes: an `'appe'` starts before the TCP stack is up, so a failed bind
is never fatal and autostart waits.

**Tier C — the extension (INIT).** Reserved for the one thing nothing
else can do: executing inside other processes' contexts. Classic Mac
OS keeps Window/Menu/Control state per process (finding
`observe-process-local-ui`, metal-proven); the only ways across are a
resident hook that runs in every context, or Apple Events to the
narrow scriptable tier. Trap patches and draw-time hooks also live
here or nowhere.

## One extension, not a family of files

tbt shipped sibling INITs (AXPeek, qdpeek) to isolate failure domains
and let experiments evolve independently. NOW ships **one file — the
NOW Extension** — and keeps what the sibling shape bought by internal
discipline instead:

- **Boot-minimal frozen core.** The only code that runs at boot: a
  chained jGNE filter, the shared table, one Gestalt selector. It
  reaches done at M0 and then changes rarely; it is the part whose
  failure needs a shift-boot, so it stays small enough to audit
  exhaustively.
- **Planes, dormant until armed.** Every capability beyond the core is
  a plane: code that executes only after the application writes an arm
  request into the table, with the filter — already in the target's
  context — performing any in-context installation, and disarm working
  the same way. The failure boundary is *which code has run*, not
  which file shipped. A machine that never opens the mirror never
  executes a draw hook.
- **Planes talk only through the core.** Separate translation units,
  no cross-plane calls. Review enforces what separate binaries used
  to.
- **Dev builds are their own INITs.** An unproven plane is developed
  as a throwaway extension under an honest name on the QEMU clone
  (`tools/mb_rename.py` gives a build its chip name *inside* the
  MacBinary header, where the decoded name actually comes from), and
  folds into NOW Extension only after its ladder passes.

Why one file: one installer checkbox, one restart story, one Gestalt
probe, one version — and "drag NOW Extension out, reboot, does it
persist?" is a one-step support diagnostic. Version skew between
planes never exists.

The production invariant is stronger than packaging: the normal host, guest,
staging path, and development image must not require AXPeek, QDPeek, Portal,
`mirror-agent`, `mirror.port`, or port 1420. They may exist in source and in an
isolated archival comparison image. Installing them beside NOW Extension is a
named coexistence experiment, never the default proof environment.

## The table is a contract, stated once

The extension publishes one table in the system heap; the Gestalt
selector answers with its address. The layout lives in **one header,
[`contract/peek_table.h`](../contract/peek_table.h)**, compiled by the
68K extension, the PPC application, and the host `cc` (for the native
test) — the in-memory analogue of `asyncapi.yaml`, under the same
rule: a limit is stated once, where every reader reads it.

Three compilers sharing a struct is exactly where silent packing drift
bites (m68k gcc aligns 32-bit fields to 2 bytes; PPC to 4), so the
header is designed to need **no padding under any of them** — every
field 32 bits, or 16-bit fields in adjacent pairs — and static asserts
pin every offset. The native test watches the asserts fail before
trusting them.

Rules the table carries:

- **One resident release identity, plus accretive per-plane versioning.**
  [`contract/resident_version.h`](../contract/resident_version.h) owns the
  major/minor release tuple reported by both the table and the resident's
  liveness connection. Development builds may share it and are distinguished
  by deterministic build fingerprint; the commit and `main`-ref gates prevent
  rollback. The prelude's major remains the exact-match compatibility boundary
  and its minor is the human release sequence. New fields ride on table length,
  while each plane carries its own format word. A reader requires its plane's format and
  `length >=` what it reads — the prefs-record rule, applied here.
- **Capabilities are bits, never inferred from versions.** A plane can
  ship dark in a binary before it has earned metal verification.
- **Freshness is per-slot and honest.** Anchors are captured when a
  process pumps its event loop, so a faceless or wedged app has an
  absent or stale slot — distinct states, both rendered truthfully by
  every consumer up to the mirror. Slots carry a ticks stamp; readers
  judge staleness, the extension never guesses.
- **Ownership is per cell, not merely per process.** The extension writes
  observations and active state. Canonical New Old World writes request cells
  through one named-owner/lease union and is the sole production `NWex` writer;
  differently named development apps use a separate development selector or
  remain read-only. A writer heartbeat/nonce and resident-echoed owner epoch
  make crash expiry and replacement explicit. No content or action helper may
  bypass that aggregator with a direct arm-bit write.

The five production planes are Structure (P1), Semantics (P2), Content (P3),
Interaction (P4), and Transitions (P5). Their host projection remains
independently selectable, but the guest also owns four safety domains which do
not pretend to be plane bits: passive structure observation, automatic Finder
complements, content tracing, and explicit foreground discovery. Both the
guest gate and the host's per-machine policy must permit work before it starts.
A disabled domain cannot clear another plane or another owner's claim.
Capability, declared length, format, freshness, owner lease, and guest policy
must all agree before a plane is trusted.

P3 transports bounded structured drawing and explicit visual-exception bounds,
not framebuffer bytes. Bitmap, PICT, CopyBits-only, or manually drawn regions
remain declared placeholders until the later pixel roadmap; pixel transport is
never load-bearing for an otherwise normal application.

## What is never resident

**Foreign-memory reads live in the application.** The extension
publishes anchors (addresses it read from low memory in the proper
context); *following* them into another process's heap — partition
validation, bounded record chains, fail-closed resolution — is
application code, where a bug is fixed by copying a file instead of a
reboot, and where the blast radius is one app, not every drawing
process. This is the single most important line in this note.

Also never resident: protocol, logging, UI, allocation on the hot
path, anything that can be polled from the main loop instead.

## Discovery and degradation

`now-guest-ppc/src/peek/peek.h` is the application's view; the four states exist
because an installer needs all four legible:

| state | evidence |
|---|---|
| active | Gestalt answers, major matches, length suffices |
| not installed | no Gestalt, no file |
| installed, needs restart | file in Extensions, no Gestalt (INITs load at boot only) |
| wrong version | Gestalt answers, major differs — disabled, never partially trusted |

Every page renders these honestly (the Processes page's group box is
the pattern), and features gate on capability bits, not on state
alone. The `'appe'`, when it exists, joins the same discovery scheme.

Identity decisions, fixed now so nothing squats them: Gestalt selector
**`'NWex'`**, table magic **`'NWpt'`**, extension file name **"NOW
Extension"**, file type `'INIT'`, creator `'NOWx'`. Not `'TBax'` /
`'TBqd'` — those are tbt's.

### A fifth state the table has and this list did not: no writer

The four states above describe whether the RESIDENT is there. They say
nothing about whether this application is allowed to *drive* it, and that
is a separate gate with its own failure mode.

Only one process may write `arm_request`, and it must prove itself:
`peek.c :: current_app_identity` requires process creator `'NOWo'` **and**
the exact process name **"New Old World"**. Fail either and
`maintain_writer` returns 0 — "dev-named app: read-only NWex" — so
`publish_claims` never writes the word, no plane is ever armed, and every
act refuses.

This is deliberate: a stray build must not seize six trap patches in
another process. But it degrades **silently, and not honestly**, which is
what the rest of this page forbids. The resident is genuinely active, so
discovery reports `active` with full `cap`; the application shows a healthy
extension and an empty Mirror, and nothing anywhere says the word "writer".
Measured 2026-08-05: one build, one resident, one host — renamed
`now-guest-ppc` → `New Old World` — took `requested` from **0 to 15**.

Two consequences worth stating plainly. A **side build cannot be
plane-tested under its own name**, which collides with the deploy rule that
an experiment goes up as its own name; plane work is the exception, and the
canonical name is part of the test rig. And the honest-degradation
requirement is currently **unmet here** — a page that renders the four
states above still cannot tell a person why a live resident is doing
nothing for them.

## Target contract and verification

Floor and ceiling: **Mac OS 8.6–9.2.2, PowerPC** (the application's
CarbonLib 1.6 range; the extension itself is 68000-code, runs under
emulation, and must not touch CarbonLib — it is not a boot-time
dependency). System 7+ floor means no `sysz`. Size: AXPeek proved a
~51 KB INIT loads at 9.1; the core stays far under that regardless,
and the 8.6 loader's ceiling is a probe.

The evidence ladder (the INIT skill's, abbreviated): compiles ≠ links
≠ packages ≠ loads ≠ callbacks run ≠ survives boot/shift-disable/
removal cycles. Say which step a claim sits on. Gates, in order:

1. **QEMU clone first** (`tools/launch` in the parent) — free, and it
   catches structure. The cold-boot recipe matters: OS 9 ignores a
   soft power-down and INITs load at boot only. A QMP `quit` is a power
   cut; dismissing the Disk First Aid modal hides an invalid setup rather
   than completing this gate. The scoped OS 9/mac99 image currently has no
   qualified automated clean-shutdown route, so record this gate blocked
   instead of substituting a hard stop.
2. **PB1400c at 9.1, attended** — the metal authority. The filter runs
   under 68K emulation there, so the hot path's early-out is measured,
   not assumed (AXPeek's envelope: 0–1 tick on a 33 MHz 68040).
3. **8.6 gate: the 3400c**, once its screen is repaired. Until an 8.6
   machine boots the extension, every 8.6 claim is header-level and
   says so.

Recovery is always in place before an install: shift-boot disables
extensions on this whole range, and the QEMU clone is disposable by
construction. Coexistence next to era-typical third-party residents
gets at least one deliberate boot before "verified" is claimed.

## The planes, as foreseen

- **P0 — core** (extension M0): residence, chaining, Gestalt,
  heartbeat. Exists to run the ladder end to end and to flip
  `peek.h` to "active" for the first time.
- **P1 — anchors**: per-process `CurrentA5`, `WindowList`, `MenuList`,
  ticks stamp. First payoff: front-window bounds, cropped captures.
- **P2 — semantic assist**: whatever tree-walking needs beyond
  anchors; may be empty (tbt's Worker built full trees from anchors
  alone).
- **P3 — content**: QuickDraw bottleneck hooks, the full Timbuktu
  move. The riskiest class we would ever ship; dark until the mirror
  needs interiors better than pixel fill, **armed per-target and
  per-port within it**, separate failure domain in everything but the
  file.

  *Wired 2026-07-31.* It is in the extension now — `now_content_boot`
  between `anchor_count` and `magic`, so no reader can see a valid table
  without the content cap while the plane is present, and
  `now_content_gne` from the jGNE applier, because only the process
  pumping can say whether it is the A5 world a request named. It is
  **compiled and dark**, which is the same state P4 is in and for the
  same reason: capabilities are bits, never inferred from a version, so
  a plane ships in the binary before it has earned metal verification.
  Its capability bit is `1u << 3`, **not** the `1u << 2` its own header
  asked for while it was written — P4 already held that, and the two
  lanes could not see each other. An offset collision would have failed
  the compile; that bit collision would have armed six trap patches in
  another process while the caller believed it had armed a QuickDraw
  reader. Both numbers now live in `contract/peek_table.h` with asserts.

  *Amended 2026-07-31.* This said "armed per-port", which is necessary
  and not sufficient — it bounds how much gets instrumented and says
  nothing about **whose**. A sibling project measured the same shape in
  its actuator: disarming after one use meant the patch fired once and
  fired on **whichever call arrived first**, so an armed request rode the
  user's own press 18/20, while the variant that required the request to
  name its exact target hijacked 0/20. The general rule, and it is the
  one to carry into any future plane: **a bound on count or duration is
  not a bound on scope.** The spike
  ([prototypes/qdprobe](../prototypes/qdprobe/README.md)) now names its
  target and refuses an unscoped request rather than reading it as "all".

- **P4 — the act plane** (2026-07-31): the first plane that does not
  read. It lets the application ask a foreign process to *do* something,
  which is the only reason a semantic scene is worth more than a
  screenshot — the structure earns its cost when the host can address an
  **element** instead of a coordinate. Ported from the sibling Mirror
  project's Portal INIT, which is metal-proven there; none of that
  transfers here.

  Two shapes. The text ops are served outright in the hook, because a
  TERec and a dialog's item list are per-process memory: unreachable
  from outside and ordinary from inside. The menu, control and window
  ops arm a **guarded trap patch**, so the application's own
  `MenuSelect` / `TrackControl` / `FindWindow` is answered with the
  value the request names and the application then runs its own
  handler. Nothing simulates a user, and no mouse **motion** is injected
  anywhere — which is what keeps the plane off the emulator and inside
  the no-host-side-cheating rule.

  It is the plane that makes the amendment above concrete, and it obeys
  it: every op names its target (a `ControlHandle`, a `WindowPtr` plus
  an exact click point, or — for a menu, which carries no handle — the
  press itself), and the identity check lives in a Toolbox-free file
  (`now-guest-shared/src/now_act_guard.c`) that the host `cc` compiles
  and mutates. The resident half performs effects and decides nothing.

  Three things it does differently from the planes above, each for a
  reason worth carrying:

  - **The arm bit is also the bypass switch.** It is the word the
    *application* writes, so turning the plane off is immediate and does
    not need the target process to be alive or pumping. Disarmed, all
    six trap patches chain straight through.
  - **Patches go in on the first armed pass and never come out.**
    Unpatching is worse than patching: a patch that vanishes while a
    caller is inside it is a jump into freed code.
  - **The resident half posts its own press.** The application is
    Carbon and `PPostEvent` is not, so it cannot queue an event whose
    `where` it controls — and `where` is the identity check. Posting
    from the target's own context also closes the gap between armed and
    pressed during which a user's click could arrive first.

  **A stale resident is an unguarded patch**, and this is the plane
  where that stops being theoretical: an older extension has no room for
  the request cell, so writing one would corrupt the shared block *and*
  leave the caller believing a guard was armed. The refusal uses the
  discipline already in the table rather than a second version number —
  `act_format` plus `length` covering the cell, checked in that order,
  because a gate whose first act is the unsafe read is not a gate.

  *Amended 2026-08-04.* P4 format v2 appends correlation and identity after
  the original cell rather than moving it. The resident owns only monotonic
  mechanism evidence: requested, accepted, armed, fired, refused, or expired.
  The normal-context application owns the outcome. It retains sixteen
  correlations, joins a fired request to a later scene and an exact
  postcondition, and preserves a timeout when the effect appears later. The
  host may display success only for that application-owned `confirmed` state;
  a trap firing or command reply is never promoted on its own. PSN remains an
  echoed correlation field. Resident safety still comes from the canonical
  writer epoch, target A5, deadline, and operation-specific object guard.

  **Attend the first metal boot, and more so than for P1.** This is the
  first plane that can *write* into another process rather than only
  read low memory in its context.

- **P7 — drag** (2026-08-07): a mouse button that stays **down** across a
  gesture, and a resident that lets go whether or not anybody asks.

  Its own plane, and not a ninth op on P4, for a structural reason worth
  restating here because it constrains anything else that wants to act
  while an application is busy: **P4 serves everything from the jGNE
  filter, and the filter is not entered during a tracking loop.** The
  moment the button goes down the application is inside `DragGrayRgn` or
  `TrackControl` and has stopped calling `GetNextEvent`, so motion and
  release cannot be delivered the way every other act is. P7 is therefore
  a **Time Manager task** — the same vehicle P6 uses, for the same
  reason: it fires regardless of who is being scheduled.

  It installs **no trap patches at all**, which makes its blast radius
  much smaller than P4's six; everything it does is four low-memory mouse
  globals and a deadline.

  **The dead-man is the charter-relevant part.** This is the first plane
  that can leave the machine in a state the host cannot undo — a guest
  holding the button sits in a tracking loop forever, and the host's only
  channel is the cell the wedged application has stopped reading. So the
  release is not something the host is trusted to send: the resident
  carries two deadlines, clamps both itself so a caller cannot switch
  them off, and releases whether or not asked. That generalises past
  drag: **a resident capability whose failure mode is unreachable from
  the host must carry its own undo**, and must clamp any parameter of it
  that a caller could get wrong.

  *Unverified.* Cross-compiles; the decision layer is tested and was
  watched failing by mutation; the vehicle has never fired on a machine.
  Attend its first boot the way P4's was attended.

- **P8 — cursor** (2026-08-07): the guest's **drawn** cursor follows what
  the plane acts on. The smallest plane in the family and the one with
  the most direct claim on a person's experience of the machine: before
  it, every act happened somewhere the arrow was not.

  **It is here because a documented technique did not work, and finding
  out why is the durable part.** P4 and P7 both moved the pointer by
  writing `MTemp` / `RawMouse` / `MouseLocation` and copying `CrsrCouple`
  into `CrsrNew`, which is Inside Macintosh's recipe. Everything the
  Toolbox *reads* followed. The sprite never moved. Read from outside the
  guest, every precondition was met and `CrsrNew` came back consumed — the
  cursor task ran and declined to draw. **On Mac OS 8/9 the Cursor Device
  Manager owns the sprite**, and the low-memory globals are downstream of
  it. So the plane calls `CursorDeviceMoveTo`, which is what a mouse
  driver's own interrupt handler calls, and keeps the low-memory writes
  because they are what a tracking loop reads.
  [docs/cursor-follow.md](cursor-follow.md) carries the evidence.

  **The charter-relevant part is that this plane can annoy a human.** P7
  introduced the first capability whose failure the host cannot undo;
  this is the first whose *success* a person sharing the machine can feel
  — we move their pointer. So it carries a rule that generalises: **a
  resident capability that competes with a person for a shared control
  must be able to lose, must lose by default, and must count the times it
  did.** P8 declines to move the sprite for a second after any motion it
  did not cause, keeps making the position writes so an act still lands
  where it says, and reports `yielded`. A courtesy nobody can observe is
  indistinguishable from a bug.

  It also states the second half of "optional": the capability bit is
  published only if the manager answered with a device, and the fallback
  to the old recipe is **reported as its own route**. A plane that
  silently degrades to the thing that does not work looks exactly like
  one that works.

  *Emulator-verified.* See docs/open-issues.md for what was watched and
  what remains unwatched on metal.

## What each plane costs at rest

The charter says a resident component is **always optional — the product
degrades honestly without it**. An extension that cannot stand down is
not optional in the sense that matters, so this section answers the
question directly: *with NOW not running and nothing armed, what does
this component still do?*

It is here rather than in a session note because it is the section that
rots. Every new plane adds a line, and the line it adds is the one a
reviewer should ask for first.

### The two gates that already exist

Two mechanisms, both already in the tree, do most of the standing down:

- **The arm bit.** No plane beyond the core executes its payload until
  the application writes `arm_request`. This is the charter's "planes,
  dormant until armed".
- **The writer lease** (`now_ext_writer_lease_valid`,
  `kNowPeekWriterLeaseTicks` = 180 ticks). The application must renew a
  heartbeat in the table every three seconds. When it does not — it
  quit, it crashed, it was never launched — `now_ext_gne_apply` forces
  `request = 0` for the whole pass. **This is the important one**,
  because it means standing down does not depend on the application
  getting a shutdown right. A machine whose user never launches NOW has
  never had a valid lease, so every lease-gated plane has been dark
  since boot.

The lease covers P1, P2 and P4 (read in `now_ext_gne_apply`) and P3 (read
again in `now_content_gne`, via `resident_owner_epoch`). It does **not**
cover P6, and that is the finding below.

### The census

Read as: what is installed at boot, what executes per event-loop pass
while resting, and whether the plane is genuinely at rest.

| plane | installed at boot | per resting pass | at rest? |
|---|---|---|---|
| **P0** core | jGNE filter chained; Gestalt selector; table in system heap | the filter body itself: `LMGetTicks`, one store, the lease check, four not-taken bit tests | **irreducible** — see below |
| **P1** anchors | nothing | one not-taken bit test | **yes** |
| **P2** tree | nothing | one not-taken bit test | **yes** |
| **P3** content | ten UPPs; **~64 KiB system-heap block, unconditionally**; *no port hooked, no trap patched* | `now_content_gne`: two low-memory reads, eight block loads, the verdict call, `content_uninstall_context` (which loops zero times when `gPortCount == 0`) | **yes for hooks; no for memory** |
| **P4** act | nothing | one not-taken bit test | **yes** — patches go in on the first *armed* pass only |
| **P5** events | small system-heap block | `now_event_pass`: three low-memory reads, the should-record call, three stores | **yes** |
| **P6** liveness | *was*: Time Manager task primed at 5 s unconditionally and forever; `.IPP` opened and a stream created on the first pass of every boot. *Now*: the task is queued and **not primed**, and no transport is touched | one call that returns on the endpoint check | **yes, since 2026-08-07** |

### The measurement

Emulator, private bake of this checkout's resident, cold-booted so the
INIT loads, guest asked for itself with no plane armed. The guest's own
`buildFingerprint` equalled this tree's build, so it is this build
answering and not another lane's VM — the rule from AGENTS.md's metal
section applies to the emulator for the same reason.

**Read the counters as a record of the window before the reader
arrived.** They are cumulative and the reading is taken at first contact,
so a counter still at zero when the host connects is a counter that
stayed at zero for the whole boot — which is the resting window, since
connecting is itself what starts P6.

Build `918116752a12`, `capabilities 127`, a ~127-second boot
(`heartbeat 7633`):

| | reading | what it proves |
|---|---|---|
| `gnePasses` | **380** | the filter ran, continuously, across the whole window |
| `livenessTicks` | **0** | the Time Manager vehicle never ticked once before contact |
| `requested` / `active` | **0 / 0** | every plane inactive; every anchor and content counter zero |
| `channelSends` | **0** | nothing was put on the wire by the resident |

Under the previous build the same boot would have opened MacTCP's `.IPP`
on the *first* filter pass and accumulated roughly twenty-five liveness
ticks by this point. It accumulated none.

An earlier run of this branch, read before the connection had triggered
the transport probe, showed the resting word directly:
`restState 9` = `kNowPeekRestGNEFilter | kNowPeekRestContentBlock`, with
`transportProbe 0` (untried) across **1174** filter passes. That is the
resting state in one number: the event hook and the content block, and
nothing else at all.

**The denominator is the whole point.** A resting resident and an
extension that never loaded produce identical readings on every other
counter in this table, and that indistinguishability is the exact
negative this project refuses to accept as proof. 1174 passes beside a
column of zeroes is a resident *proven to be running* and *proven to be
doing nothing*, which is a different and much stronger claim than a
screenful of zeroes.

The control is the same code one commit earlier: over the same
~57-second boot it opened the driver on the first pass and would have
accumulated roughly eleven liveness ticks. It accumulated none.

**And the same word distinguishes rest from use, which is what makes it
worth having.** A later run of the same resident, read after the
application had connected and armed a plane, returned `restState` **47** —
`GNEFilter | LivenessTicking | Transport | ContentBlock | ActPatched`.
Same binary, same table word, two honest answers. The `ActPatched` bit in
that reading is the durable one: it was set by an arm that had already
been released by the time of the read (`requested` was back to 0), which
is exactly the fact a person is owed and exactly the fact no capability
bit or arm bit could have carried.

What this does **not** measure is the cost of the filter body itself in
microseconds. That needs a 33 MHz 68030 and `NOW_METAL`, and it is
recorded as unmeasured in [open-issues.md](open-issues.md) rather than
estimated here.

### The premise, corrected

The worry that prompted this section was that the extension "hooks every
app draw and app state even when Mirror isn't running". Both halves are
worth stating precisely, because one is false and the other is true in a
place nobody named.

**Draws: false.** No `grafProcs` is installed into any port, and no
QuickDraw trap is patched, until the content plane is armed for a named
A5 *and* a named window. `now_content_boot` builds the hook table and
allocates the block; it installs nothing. `content_qdext_install` runs only
under `kNowContentVerdictArmed` and only in explicit probe mode. Ordinary
record mode installs the exact requested window's `grafProcs` and nothing
offscreen. A machine
that never opens the Mirror never executes a draw hook — which is
exactly what "planes, dormant until armed" promised, and it is kept.

**App state: false in the sense meant.** Anchors are captured only under
the arm bit, which the lease already forces off.

**What is actually always-on is P6, and it is more than a hook.** On
*any* machine with this extension installed, whether or not NOW is ever
launched:

- a Time Manager task is installed at boot and re-primes itself every
  five seconds, forever;
- on the first event-loop pass after boot, the resident opens MacTCP's
  `.IPP` driver (`PBOpenSync`) and creates a TCP stream with a receive
  buffer (`TCPCreate`).

Neither is arm-gated and neither is lease-gated. The *dialling* is
correctly gated — `published_endpoint()` returns NULL until the
application publishes an endpoint, so a resting machine's tick reaches
`want == NULL` and idles — but the driver open, the stream, and the
5-second interrupt are unconditional. That is the real cost, and it is
the one that touches a shared system resource rather than only CPU.

### The verdict, per plane

The question was whether each plane can be switched off dynamically, or
whether it needs a restart to apply. **No plane needs the restart to
stand down.** One needs it to fully *undo* itself, and that one is
genuinely forced rather than merely difficult.

| plane | verdict | why |
|---|---|---|
| P1 anchors | **already resting** | arm-gated and lease-gated; costs one not-taken bit test |
| P2 tree | **already resting** | same |
| P5 events | **already resting** | same, plus a small block held from boot |
| P3 hooks | **already resting** | nothing is installed into any port until armed for a named A5 *and* window |
| P3 memory | **restart-free, deferred** | ~64 KiB held from boot; lazy allocation is possible and specified below, not foreclosed |
| P4 act | **dynamic bypass; removal is restart-only** | the one genuinely forced case — see below |
| P6 liveness | **dynamic, and now implemented** | a Time Manager task has a sanctioned stop that a trap patch does not |

### Why P4 is the one that cannot fully undo, and why that is acceptable

This is the case the brief asked to be ruled out rather than assumed, so
the reasoning is here where a reviewer can check it.

**The constraint is real and it is not about difficulty.** `NSetTrapAddress`
puts our address in the dispatch table and we keep the incumbent to chain
to. If another extension patches the same trap *after* us, its saved
"previous" is our shim. Restoring the incumbent over the top then removes
the middle link of a chain whose next link still points at us — and any
caller already inside our shim returns into code we have just orphaned.
Neither hazard is detectable from inside our patch: there is no way to
ask the Trap Manager who is chained behind you, and no way to know
whether a call is in flight.

**But un-patching is not what standing down requires.** The arm bit is
the plane's bypass switch, the writer lease force-clears it within three
seconds of the application going away, and a disarmed trampoline chains
straight through. So the machine behaves exactly as it would with no
extension present; what remains is six trap dispatches that fall through,
paid only by a machine that has actually armed the plane, and never by
one that has not.

**A patch that returns immediately is not the same as a patch that is
absent — and here it is good enough.** What it is not is *invisible*,
which is why `kNowPeekRestActPatched` exists and never clears until
reboot. A person deciding whether to keep this extension installed is
owed the fact that their trap table has been modified, and that fact
should not live only in a source comment.

**The contrast with P6 is the useful half.** P6 sits in the Time Manager
queue, and nothing is chained behind our entry there — so declining to
re-prime genuinely stops it, with no orphaning and no in-flight problem.
The two planes differ in what they can undo because of *which OS
structure each lives in*, not because of how hard anyone tried. That is
the general rule to carry into the next plane: ask what is chained behind
you before assuming a hook can be withdrawn.

### How P6 stands down, and why not with `RmvTime`

The obvious mechanism is `RmvTime`, and it is the wrong one. This task
re-primes itself at the end of every tick, so an `RmvTime` called from
the filter can land between a tick's body and its own `PrimeTime` and
re-arm an entry that has just been pulled out of the queue.

So the task is `InsTime`'d at boot and **never primed there**; starting
it is a bare `PrimeTime` from the jGNE filter; and stopping it is the
tick *declining to re-prime*. Exactly one context touches the Time
Manager queue after install, which means the race cannot be constructed
rather than being merely unlikely.

Note what the decision deliberately does **not** consult: the
three-second writer lease. P6 exists because a modal starved the
application for ninety seconds, and a starved application cannot renew a
lease — gating the vehicle on it would retire the vehicle at the exact
moment it became the only thing still running. Ten minutes of silence
stands it down instead, which is eight minutes after the host has already
declared the guest gone, so it costs nothing real while still stopping a
*crashed* application from leaving an interrupt behind forever. Both
facts are pinned by tests in `now_ext_core_logic_test.c`, because the
lease is an inviting simplification.

### P3's block: the deferral, decided rather than forgotten

~64 KiB of system heap is held from boot so that arming never has to
allocate inside a foreign process, where allocation is illegal. The
lazy version is possible and this is what it would take, recorded so
nobody has to rediscover it:

allocate on the first filter pass that sees a valid writer lease — which
is non-interrupt time, and is exactly where P6 already does its own
allocation — and publish `content_block` only once it exists. The cost is
not the allocation: it is that `content_block` and the capability bit
stop arriving together, so the application has to gate on the pointer
rather than the bit, and that is a two-step discovery on the other side
of the contract.

**Deferred**, because 64 KiB is not what the landing question was about
and the contract change is larger than the saving. `kNowPeekRestContentBlock`
reports the block so the cost is visible while it stands.

## Charter amendment

AGENTS.md's "what this is" grows one sentence, and this note is its
long form: *NOW may ship optional resident components on the guest,
each behind a versioned in-memory contract stated once in a shared
header; foreign-context execution lives only in resident components,
foreign-memory reads live only in the application, and a resident
component is always optional — the product degrades honestly without
it.*
