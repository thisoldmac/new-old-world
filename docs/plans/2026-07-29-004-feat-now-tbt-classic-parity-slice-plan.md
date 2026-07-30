# NOW ↔ TBT-classic capability parity — slice plan

**Date:** 2026-07-29 · **Status:** intent, nothing built · **Namespace:** `claude/`

A snapshot of intent, per [README](README.md). Where this and the code
disagree, the code is right.

## What this slice is

TBT's classic MCP (`timbottu-mcp-classic`, the agent workbench) exposes 29
product tools over the OS 9 harness. NOW's companion exposes 12. The
difference is not one gap but three, and most of it is **capability the NOW
guest already serves that no host face can ask for**.

**The work is closing that gap and building the gates that keep it closed.**
AppIntents/Siri is an additive feature that rides on the same projections
(W3); it is not the organizing principle and must not become one. If a
question is ever "what does the demo need next", it has gone wrong — the
question is "what is reachable from every face, and what proves it stays
that way".

**Focus is the PPC guest.** 68K gets changes that are genuinely cheap and
nothing more; where it is not cheap, the row is documented PPC-only and the
work stops.

Out of scope, named so nobody infers otherwise: streaming on 68K, reverse
resume, a general download policy beyond the transfer verbs already served,
the CodeKitten listener, and any change to TBT itself.

## Vocabulary note — "tier" is taken

[resident-components.md](../resident-components.md) already uses **Tier
A/B/C** for *residency* (application / background `'appe'` / extension).
This plan uses **W0–W4** for workstreams and leaves residency tiers their
existing meaning wherever they appear.

## The rule stack

Five rules, in precedence order. Every decision below is downstream of
these; when a task is ambiguous, resolve it here rather than inventing.

1. **The guest owns capability. The host is a remote.** One implementation
   in the guest, behind its two faces (console, wire) — the existing
   [command-parity.md](../command-parity.md) rule, unchanged.
2. **The host projection layer may address, authorize, bound, and render.
   It may not decide or answer.** Anything the host answers from its own
   state is a fact about the host, not about the machine. Host composition
   over data the guest just supplied is permitted — `now_launch_software`
   (list → exact-match → opaque ref → revalidate → `launch`) is the
   sanctioned precedent and the pattern later work copies.
3. **User-initiable where possible; strictly-headless surfaced as a log
   event.** MCP is an optional feature of NOW, and optional does not mean
   kneecapped — but a suite of agentic controls opaque to the person at the
   machine is not what NOW is.
4. **On 68K, degrade the ANSWER, not the message.** `software.list` is the
   model: serve the family, omit fields that cost too much, declare the
   bound in `note`, and let absence mean absence.
5. **Every candidate takes the cheapest residency tier that can carry it,
   and must say why the cheaper tiers cannot** — resident-components.md.
   Applied below, this removes most of the extension work W4 looks like it
   needs.

## Correction carried in from the analysis

An earlier read of this gap listed "semantic UI" (`observe`/`axsnap`) as a
major missing family. It mostly is not: TBT's `observe` walks **its own
process** — classic Mac UI managers are per-process, the metal-proven
finding `observe-process-local-ui` — and `axsnap` is `GetFrontProcess` plus
identity. There is no cross-app UI introspection to port. What is behind
that door is Apple Events and keystrokes (W4), plus frontmost-app identity,
which the guest **already answers on both ISAs** as the `front` flag on
`process.listing`. Projecting it is a rendering change.

## W0 — Seams and gates (leads everything)

The host has one real projection consumer today, so its seam has never been
under tension. Nine projections × three host faces is when it goes under
tension, and retrofitting is strictly worse than establishing it with one.
**This is the part of the slice that outlives it**: the gap closed once is
worth less than the gate that keeps it closed.

- **W0.1 — Extract the host projection layer** with rule 2 as its contract.
  Registration is **registry-driven**: adding a capability is one new file
  plus one row, following [adding-a-workshop-module.md](../adding-a-workshop-module.md)
  and TBT's duplicate-checked `tools/__init__.py`. This exists primarily so
  the wide phase can fan out without every agent editing one switch.
- **W0.2 — Host-face parity test.** `CommandParityTests` enforces the
  guest's two faces; nothing checks that the host's three (app UI, MCP,
  AppIntents) reach the same set. Add it, with the same escape hatch the
  guest side uses: divergence is legal when **declared with a reason**, à la
  `CommandRegistryTests.notOnThePowerPCGuest`.
- **W0.3 — Audit-event gate.** Rule 3's second half, made mechanical: a
  command invoked by a non-user face emits an audit event. NOW already
  emits these for stage cleanup; extend and gate.
- **W0.4 — `docs/mcp-coverage.md`**, derived from `NOWMCPServer.swift` and
  the contract the way contract-coverage.md is derived from guest source,
  **with the test that document admits it lacks**. This is what would have
  caught the present drift, and it is the deliverable that makes the next
  drift visible without anyone asking out loud.

## W1 — Projections of what the guest already serves

No new guest capability, no contract change. Each is: guest (exists) → host
command → app affordance → MCP tool → intent where sensible → log event.

| # | Capability | Contract | ISAs | User-facing home |
|---|---|---|:--:|---|
| 1 | Screen capture (+ `capture.cancel`) | `capture.request` | both | button |
| 2 | Hardware census | `census.request`, 14 probes | both | machine pane |
| 3 | Software listing | `software.list` | both | pane (today: internal to launch only) |
| 4 | Transfer guest→host | `file.get` (PPC) / `put` (68K) | both | Files page |
| 5 | Bring to front | `process.front` | both | click a row |
| 6 | Frontmost app | `front` flag on `process.listing` | both | machine pane |
| 7 | File mutation | `file.move`/`.trash`/`.restore`/`.mkdir` | PPC | Files page — its missing verbs |
| 8 | Transfer cancel | `file.cancel` (PPC) / `cancel` verb (68K) | both | transfer UI |
| 9 | Tail a file | `tail` verb | PPC | log viewer |
| 10 | Machine facts | `gestalt` verb | PPC | machine pane |
| 11 | Catalog search | `catsearch` verb | PPC | Files page |
| 12 | Reveal in Finder | `reveal` verb | PPC | Files page row action |
| 13 | **Diagnostics module** | `vprobe` (both), `shotdiag` (68K), `putstat` (PPC) | both | **a Diagnostics module of its own** |

**Items 10–13 were added 2026-07-29**, after `docs/mcp-coverage.md` derived the
gap table and found that this list had been written from a hand analysis that
undercounted. Nine of the ten gaps it classed *unnoticed* are served by a guest
right now with nothing in the repo arguing for their absence; `gestalt` is the
largest — one PPC verb answering CPU, memory, OS, network and hardware,
reachable from no face at all. That is the case for deriving a list rather than
composing one, and it is why W0.4 shipped with a test.

**#13 is a decision, not a projection.** `vprobe`, `shotdiag` and `putstat` are
diagnostics — framebuffer read cost, staged-capture provenance, transfer
statistics. They could have been declared deliberate gaps on the grounds that
an agent does not need them; the call (2026-07-29) is that they get a **home**
instead, as a Diagnostics module. Rule 3 is the reason: a diagnostic an agent
can read and a person cannot is exactly the asymmetry this slice exists to
close, and `shotdiag` is the verb that found the 180c addressing defect —
precisely the thing someone standing at a misbehaving machine wants.

**Still undecided:** `stream.start`/`.stop`/`.refresh` (PPC only). Real feature,
much larger than a projection, and it is either its own workstream or an
explicit deferral with a reason. Not in W1 until that is settled — an
undecided row is worse than an absent one.

**#1 is the template, and it landed 2026-07-29. Its measured cost is 22
files, not two** — finding `now-four-face-capability-cost`.

The four faces were nearly free, exactly as W0 promised: **app UI 0** (the
Screenshots pane's Capture button already existed), **MCP 0** (falls out of
the registry loop), **audit 0** (falls out of the dispatch), AppIntents not
built. The row itself was **2 files** — one projection plus one catalog line.

What is not free is **a capability that needs a new client verb**: 7 files
for the verb's serialization alone, 4 for the host capability owner, 2 to
extend the seam for a non-JSON answer, 5 for gates, 2 for docs. So the real
estimate for the remaining items splits in two:

- items already served by an existing client verb → near the 2-file claim
- items needing a new verb → assume ~20 files and a serialized edit

That distinction, not the count, is what should size Phase 2.

**#4 is worth a note** because it inverts the usual expectation: the two
guests serve it by *different* mechanisms. Per
[contract-coverage.md](../contract-coverage.md)'s verb table, `file.get` is
**PPC ✅, 68K ❌**, while `put` (guest-initiated send) is a wire verb on
**68K ✅** and console-only on PPC. One host capability, two guest answers —
rule 2 working as intended.

Deliberately excluded: `process.shot` (PPC-only, no consumer) and the
`exec.*` console plane — rule 3, a shell is not user-initiable in any
meaningful sense, and it is the one thing `agent-integration.md` is right to
keep out.

Items 4, 7 and 8 were **not** withheld on authority grounds — confirmed
2026-07-29, simply unbuilt. They stop being an MCP question and become a
Files-page question.

## W1.5 — The codec defects (added 2026-07-29, in scope by decision)

W0.3 found two defects in `now-host/Sources/NOWAgentIntegration/AgentIntegrationLocalProtocol.swift`
while building the audit gate. Both are on `main`, both were untested, and both
were independently confirmed before being taken seriously:

- **`guestSelector` is absent from `decodeRequest`'s `allowedKeys`**, which is a
  *strict* object check. Any request that actually names a machine is rejected
  as invalid. The encoder writes a field the decoder refuses, so guest
  addressability — the machine-id / session-id scheme landed 2026-07-28, the
  whole point of local schema v7 — cannot work through this path at all.
- **`notAddressed` is absent from `decodeResponse`'s `allowedKeys`**, so the
  `now-guest-not-addressed` refusal reaches the companion as
  `now-host-invalid-response`: a real refusal wearing a protocol error.

Originally scoped out as main-line bugs with their own tests. **Folded in by
decision** — a slice about capabilities being reachable from every face cannot
coherently leave the addressing layer broken underneath it, since every
projection takes an optional `guest`.

Worked on a branch off **`main`**, not off this slice, so it can land
independently rather than waiting for the slice; it merges here afterwards. Two
omissions of one shape also justify an audit of every allowlist against the
fields it admits, in both directions, rather than fixing these two and assuming
the rest are fine.

## W2 — Guest gaps

- **`gestalt` on 68K** — deferred by the PPC focus, kept on the list only
  because it is unusually cheap: `now-guest-68k/src/ui/health.c` already
  samples identity, CPU, System version, VM, MacTCP, geometry and RAM,
  cached with strings pre-built. contract-coverage.md calls it closer to a
  rendering job than a measurement one. Take it if an agent finishes early;
  do not schedule it.
- **`process.shot` / streaming on 68K** — expected outcome is a documented
  PPC-only row, not an implementation. Investigation budget only.

## W3 — AppIntents / Siri (additive)

An additional face over the same projections, not a driver of them. It earns
its place in this slice for one reason: rule 3 wants a user-facing initiator
for every capability, and an intent is often cheaper than a pane. It should
consume W1's output and add nothing to W1's scope.

- **`GuestMachine: AppEntity`** — `id` is the schema-v7 machine id
  ("whatever is connected to that Mac now, follows a reconnection"), the
  display name is already in `hello`, `EntityQuery` is the connected roster
  from `now_session_health`. **Session ids are deliberately not entities**:
  they are ephemeral, and Siri holding one is the exact staleness the v7
  contract exists to prevent.
- **`GuestApplication: AppEntity`** — per-machine, opaque, revalidated
  against a fresh catalog before use, and *not* aggressively donated to
  Spotlight (a machine that is off must not offer its apps).

What it can demonstrate, in escalating order, as the underlying projections
land — a showcase of parity work, not a scope input:

1. *open TeachText* — W1 #3 plus one intent. Zero guest work.
2. *type a haiku about the first PowerBook into it* — W4a + W4b, plus a
   confirmed front process (W1 #5/#6). The haiku is composed host-side and
   is not a guest capability at all.
3. *save it, copy it here, open it in TextEdit* — W4c, W1 #4, and
   `NSWorkspace`. Only the save leg is new work.

Machine choice is not load-bearing for rungs 1 and 2. **It became
load-bearing for rung 3** once the probe landed: the save leg is `Cmd-S`, and
modifier injection is app-tier on the 68K guest but needs the extension plane
on the Carbon PPC guest. So rung 3 is either cheap on a 68K machine or
gated behind resident work on a PPC one. That is a scheduling fact about the
showcase, not a reason to reorder parity work — see the stop condition.

Two hazards to design against rather than discover:

- *An AppIntent is not proof a human is present.* A Shortcuts automation can
  fire one unattended. AppIntents is a legitimate high-authority surface for
  W1, but **W4 stays behind the grant regardless of which face asks**, and
  the grant itself is app UI — never an intent.
- *Siri will not wait 32 seconds.* A cold catalog sweep on a PowerBook runs
  ~4s; launch settles unacknowledged at 32s. The honest short answer is the
  one NOW already gives: the machine was **asked**. Never that it opened.

## W4 — Granted control

This is TBT-parity work in its own right: `run_script`,
`send_application_event`, `type_text`, `press_key` and `click` are five of
the classic surface's 29 tools and the largest remaining functional gap
after W1. It is gated rather than omitted because rule 3 and NOW's existing
trust boundary both refuse an opaque agentic control plane.

- **W4a — the session grant.** App-UI-minted, per-guest, expiring,
  revalidated, audited — the same shape as the existing transfer approval
  receipt, which is the pattern to copy rather than reinvent. Independent of
  W0/W1; can start immediately.
- **W4b — text injection.** Application tier on **both** guests; measured,
  see the probe below.
- **W4c — modifier/menu keys.** **Splits by ISA, and not the way this plan
  originally assumed.** Application tier on the 68K guest via `PPostEvent`;
  on the Carbon PPC guest the cheap tier does not reach it at all, and the
  home is **one plane on the existing NOW Extension**, armed by the app, off
  the jGNE filter already chained in its frozen core. Per
  resident-components.md: developed as a throwaway INIT under an honest name
  (`tools/mb_rename.py`) on a QEMU clone, folded into NOW Extension only
  after its ladder passes. No second extension, no sibling INITs.
- **W4d — AppleScript / Apple Events.** PPC only, and last: the expensive
  one, and nothing else in the slice waits on it.

### The de-risking probe — ANSWERED 2026-07-29, emulator-observed

Finding: `data/findings/postevent-modifiers-need-ppostevent.md`. Measured on
q800 / Mac OS 8.1 with a **separate** poster and observer process, so no half
of it tests itself. Nothing here is metal-verified.

- **`PostEvent` carries no modifiers** — confirmed. It delivers `mod=0x0080`
  (`btnState` alone); there is no argument for a modifier and none appears.
- **`PPostEvent` does.** It returns the queue element, and
  `qel->evtQModifiers |= cmdKey` survives to the receiver's `GetNextEvent`.
  An injected `Cmd-S` was byte-identical to one typed on the keyboard, and
  two modifiers carry equally. Cooperative scheduling means nothing runs in
  the post-then-amend window, so there is no race.
- **Plain cross-process typing needs no residency**, on either guest.
- **`MenuKey` is not the discriminator** and will mislead anyone who uses it
  as one: it resolves on the character and never inspects the event, so a
  bare `S` also "matches". What decides is the target's ordinary
  `if (modifiers & cmdKey)` gate — which is the bit measured present.

**The consequence inverts this plan's ISA posture for W4c.** `PPostEvent`
and `GetEvQHdr` sit inside `#if CALL_NOT_IN_CARBON` — CarbonLib does not
export them — while `PostEvent` is CarbonLib 1.0 and later. The NOW PPC
guest **is** Carbon (`#include <Carbon.h>` throughout
`now-guest-ppc/src/core/`, CarbonLib 1.6 required). So the cheap path exists
on the guest this plan de-prioritised and is absent on the one it focuses on:

| | text injection | modifier/menu keys |
|---|---|---|
| 68K guest (non-Carbon) | app tier | **app tier** — `PPostEvent` |
| PPC guest (Carbon) | app tier | **extension plane** — no app-tier route |

This does not change the PPC focus for W0–W1, which is where the bulk of the
slice is. It does mean W4c on PPC is resident work, and that the plane's
requirements are now known rather than speculative: an arm cell naming
process and modifiers for one event with self-disarm, a bounded lifetime so
a wedged host cannot leave Command stuck down, and a capability bit keeping
it dark until metal.

Also inherit rather than re-pay for: keyboard-first over clicking, never
`tell` an unverified app, never a whole-disk Finder search from a script
verb (it wedges), installers hang unless the guest handles the quit Apple
Event, and the OS 8.1 OSA `-1757` failure has a known cause. And never type
into a process that is merely `kProcFrontUnconfirmed` — the guest already
distinguishes *asked* from *confirmed frontmost*
(`now-guest-ppc/src/processes/proc_actions.h`), which is precisely the
precondition injection needs.

## Fanout strategy

Parity-led. The barriers are real dependencies, not caution.

```
Phase 0   seams (W0) .................  3 agents  BARRIER
          ∥ PostEvent probe .........  1 agent   (gates only W4c)
Phase 1   W1 #1 capture end-to-end ...  1 agent   BARRIER (template proof)
Phase 2   W1 #2–#9 ∥ W4a ∥ W3 entities up to 11 agents
Phase 3   W4b/W4c granted control ....  2 agents
Phase 4   W4d ∥ W2 opportunistic .....  2 agents
Phase 5   metal ......................  serialized on the human
```

**Phase 0 — barrier, 3 agents, plus 1 in parallel.** W0.1 / W0.2 /
W0.3+W0.4 all touch the same seam, and Phase 2 cannot fan out until the
registry exists. The `PostEvent` probe runs alongside because it is cheap
and answers a Phase-3 cost question early; it blocks nothing here.

**Phase 1 — barrier, 1 agent.** W1 #1 end-to-end through the new seam:
guest (exists) → host command → app affordance → MCP tool → log event.
Whatever it costs is the per-capability price of the other eight, measured
before eight agents are committed to it. **Do not fan out against an
unproven template.**

**Phase 2 — wide.** W1 #2–#9, one agent each, worktree-isolated; W4a; W3's
entities once #3 exists.

**Phase 3.** Granted control, behind the grant.

**Phase 4.** W4d on PPC; W2 only if an agent is idle.

**Phase 5.** Metal — serializes on the human by definition.

**Every phase ends with an adversarial verification agent.** AGENTS.md is
explicit that a test you have not watched fail proves nothing: verify each
guard by mutation, reintroduce the bug, see it named. Phase 0's specific
question is whether the host-face parity test actually fails when a face is
removed. If it cannot be made to fail, it is decoration.

### Collision hazards — the part that decides agent count

Three of these have already bitten this repo; none is hypothetical.

1. **The agent socket is per-uid, not per-process.**
   `dev.newoldworld.now-agent-<uid>/host.sock`, dir `0700`, socket `0600`.
   **Two NOW host apps as the same user collide.** Exactly one agent at a
   time holds the *host app + companion + paired guest* integration lane.
   Build, unit and native tests fan out freely; integration verification
   **queues** on that lane as a token.
2. **Guest port collision.** Every QEMU guest sees the host as `10.0.2.2`,
   the human's own app may hold the default port, and another branch's guest
   can answer your listener — `Metal68KSendTests` once passed its refusal
   case against a foreign guest, because "unknown command" is also a refusal
   with a reason. Each agent boots on a port nothing else dials, passes the
   matching `NOW_METAL_PORT`, and asserts a capability only the build under
   test has (`requireTheBuildUnderTest()`).
3. **Metal machines are singletons and attended.** `MetalMachineGuard` plus
   `NOW_METAL_MACHINE` before anything binds. Two sessions once shared one
   PowerBook and produced a stall at 606208 bytes nothing could attribute
   afterwards. Never reboot or power-cycle a physical machine without asking
   first.
4. **Shared files that serialize edits.** The `NOWMCPServer.swift` tool
   enum, `contract/asyncapi.yaml`, the `scripts/test-native` manifest, and
   `contract-coverage.md`. W0.1's registry removes the first; the rest get a
   **single owning agent per phase**.
5. **`AgentIntegrationLocalProtocol.swift` is the real serialization point,
   and this list originally missed it.** W0.1 removed the tool-enum switch,
   which made it look as though the shared-file hazard was solved. It was
   displaced: every capability needing a new client verb must add an
   operation case, a result case, a response field and init parameter, and a
   strict-decode branch — all in that one file, at the tails of three lists.
   Those three tails have now conflicted on **every** merge that touched
   them (the audit gate, the codec fix, its harvest, and the capture
   template), always trivially and always needing a human decision.
   **One owning agent per phase for this file**, and prefer batching the
   verbs a phase needs into a single edit over one agent per capability.
6. **Four hand-maintained capability lists survive W0**, so "one file plus
   one row" is true of the *row* and not of the *capability*:
   `HostProjectionRegistryTests`' known-names set, `NOWAgentCompanionTests`'
   approved-tool list, two exhaustive-switch fixtures, and — worst — a
   `MCPCoverageTests` assertion that matches a doc heading naming the tool
   *count* literally, so every new capability renames a heading and a test
   string. Individually trivial; eight times over it is a serialized edit on
   shared test files. Worth fixing before the wide phase, not during it.
5. **The extension is one file by charter.** Any plane work is one agent,
   serialized, developed as a throwaway honest-named INIT first. Two agents
   editing NOW Extension is the failure the one-file rule exists to prevent.
6. **Xcode.** `NOWAgentIntegration` is a local SwiftPM package, so files
   under `Sources/` need no `project.pbxproj` edit. New *app-target* files
   do, and that file merges badly — route them through one agent.

### Per-agent discipline

- Branch in **its own worktree** off this branch, `claude/<slug>`; the
  shared checkout stays on `main`.
- `git -C <absolute path>`, never `cd`. Stage explicit paths, never
  `git add -A`.
- `scripts/test-all` is the gate. A new native test **must** be added to the
  `scripts/test-native` manifest or the run fails — the point of it.
- `GuestWireConformanceTests` fails on any new guest message built across
  several `snprintf` calls until given a fixture. Deliberate; the failure
  text says so.
- Report **builds / tested / metal-verified**; never write "works" for the
  first two. Guest-side work lands metal-pending and waits for the human.

## Stop conditions

- **The demo starts driving scope.** W3 consumes W1; it never adds to it. A
  capability whose only justification is a rung of the showcase is out.
- **The projection layer starts answering from host state.** Capability is
  migrating out of the guest. Stop and redesign.
- **A W1 item needs a contract change.** Then it was never W1 — reclassify
  into W2 and re-cost rather than growing the phase.
- **Siri latency pushes toward caching guest answers host-side.** Stop.
  Rule 2. The answer is guest-side or the intent is honest about waiting.
- **A capability wants a second extension, or resident protocol/logging/UI.**
  Stop — resident-components.md's "what is never resident" is the line, and
  foreign-memory *following* stays in the application.
- **68K work exceeds its budget.** Document the PPC-only row with its reason
  and move on. The focus is PPC; grinding a 4 MB 68030 is how this slice
  becomes a quarter.
- **The parity test cannot be made to fail by removing a face.** Fix the
  gate before any Phase 2 agent starts — every later coverage claim rests on
  it.

## Where this slice ends (decided 2026-07-30)

It grew past one slice. W1 went from nine items to thirteen once the gap
table was derived rather than composed; W1.5 arrived by decision; the
diagnostics module became a product decision rather than a projection. Held
together as one unit, "the slice" would mean four different things and none
of them could land.

**So it ends here, at W0 + W1.5 + W1 #1.** That is a coherent thing: the
seam, four mechanical gates, a live bug fixed, and the first hardware
evidence the agent surface has ever had. It is worth landing on `main` on
its own — the codec fix alone is, since guest addressability had been broken
since 2026-07-28.

What is deliberately **not** in it, and why the split falls here:

| Follow-on | Why separate |
|---|---|
| The remaining twelve projections | Each is now costed rather than guessed; they fan out against a proven template and need no design |
| W3 AppIntents | An additional face. Wants the projections it would consume to exist first |
| W4 granted control | Its own authority model — the session grant is a design question, not a projection |

Sequencing constraint that outlives this plan: **do the two one-off cleanups
before the twelve.** The four hand-maintained capability lists and the
`AgentIntegrationLocalProtocol.swift` serialization chokepoint are costs that
every subsequent item otherwise pays again — twelve times over, on shared
files, with one integration lane.

Status does **not** live here. Per [README](README.md) this file is intent
and goes stale by design; what is verified belongs in
[open-issues.md](../open-issues.md) and what the system does belongs in
[status.md](../status.md).

## Corpus impact

The `PostEvent` probe has landed:
`data/findings/postevent-modifiers-need-ppostevent.md` (emulator-observed,
not metal-verified). It answered the W4c residency question and inverted this
plan's ISA assumption for that one item; both are recorded above.

Still unmeasured, and the reason Phase 1 exists: the per-capability cost of
the four-face pattern. Phase 1's capture template produces it.
