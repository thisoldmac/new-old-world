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

- **Accretive, per-plane versioning.** The prelude has the extension's
  major (exact match required) and a length; each plane has its own
  format word. A reader requires its plane's format and
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

The four production planes are Structure (P1, required while Mirror is open),
Semantics (P2), Content (P3), and Interaction (P4). P2-P4 are optional user
policy claims, independently armable for diagnosis. A disabled plane cannot
clear another plane or another owner's claim. Capability, declared length,
format, freshness, and owner lease must all agree before a plane is trusted.

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

  **Attend the first metal boot, and more so than for P1.** This is the
  first plane that can *write* into another process rather than only
  read low memory in its context.

## Charter amendment

AGENTS.md's "what this is" grows one sentence, and this note is its
long form: *NOW may ship optional resident components on the guest,
each behind a versioned in-memory contract stated once in a shared
header; foreign-context execution lives only in resident components,
foreign-memory reads live only in the application, and a resident
component is always optional — the product degrades honestly without
it.*
