---
title: Liveness below the application - Plan
type: feat
date: 2026-08-05
---

# Liveness below the application - Plan

Continues [011, A Mirror that survives being driven](2026-08-05-011-feat-a-mirror-that-survives-being-driven-plan.md),
and is subordinate to [001, NOW Mirror UX Completion](2026-08-03-001-now-mirror-ux-completion-plan.md),
which still owns the destination. Where they disagree about status this one
is newer, and [open-issues.md](../open-issues.md) beats all three.

## Why this exists

011 § A bounded the mutation lane and it worked: driving a deliberate
wedge on 2026-08-05, five acts issued across it answered in **2.1 s
total**, none blocked, and the wedged act's ceiling was 30.3 s. No 87.5 s
stack recurred.

**And the session still died.** Not from the lane — from the guest going
silent. The Finder's *"could not find the application program that
created the document"* alert starved **every process on the machine**,
including `tbt-worker`, a background-only application on its own TCP port
with no code in common with NOW, for **more than 90 seconds**. The host's
`idleTimeout` is 75 s and the host never pings by contract, so the wire
died of *"Connection lost (no traffic)"* against a healthy Macintosh
holding an open socket.

So the binding defect is not in the lane and cannot be fixed there:
**liveness is currently answered by the application, and a modal is
exactly what takes the application away.**

## What the code already provides, and what it does not

Three findings from reading rather than reasoning, because each one
changes the shape of the work:

- **The keepalive already exists and is guest-driven.**
  `contract/asyncapi.yaml`: *"the guest sends `ping` after 30 s of wire
  silence; the host answers `pong` and initiates no pings of its own."*
  So this slice does not invent a liveness message — the starvation
  simply stops the application sending the one that is already there.
- **The staleness signal already exists.**
  `NowPeekWriterLease.heartbeat_ticks` is the application writer's
  publish-last commit word, and the resident already reads it to decide a
  writer is dead. How long the application has been starved is therefore
  free to compute.
- **The resident has no way to run while the machine is starved.**
  `ext/src/now_ext.c` installs its vehicle at `LMSetGNEFilter` — a
  system-wide `jGNE` filter tail-chained onto `GetNextEvent` — and the act
  plane's trap patches fire only when a trap is called. **Every execution
  context the extension has today is application-driven**, so during the
  exact starvation this plan addresses, the resident does not run either.

That third point is the real size of this work. It is not "add a ping to
the extension"; it is **the extension's first interrupt-time context**,
with the discipline that implies.

## Goal Capsule

- **Objective:** the host can tell a **starved** guest from a **gone**
  one, and says which to the person driving — so an ordinary modal costs
  a pause rather than a session.
- **Authority:** unchanged. `contract/asyncapi.yaml` is the wire meaning,
  `contract/peek_table.h` the in-memory meaning, `MirrorStateEngine` the
  single published state.
- **Non-goal:** making a starved guest *serviceable*. It cannot answer;
  this plan makes that legible and survivable, not absent. Breaking the
  starvation itself is a later question.
- **Stop conditions:** 011's stand. One more: **stop if the resident's
  liveness channel could corrupt the application's wire** — see § A.

## The decisions taken before writing code, and their arguments

### A — the resident dials its OWN connection, not the application's

The smaller-looking option is for the resident to send the existing
`ping` frame on the endpoint the application already owns: same message,
same stream, no listener change. **It is wrong, and the reason is
framing, not safety.**

The application may be mid-`OTSnd` on a multi-page scene transfer when the
resident decides to ping. The frame codec has no provision for two
writers on one stream, and the contract's own rule is that a host which
cannot decode a frame **drops the connection**. A resident ping could
therefore *cause* the exact disconnect it exists to prevent, rarely and
unreproducibly — the worst failure shape this project collects.

So the resident registers as its own Open Transport client and holds its
own connection. That costs a listener change and a contract addition, and
it is the only version that cannot corrupt the application's wire.

### B — the channel is ALWAYS present and carries NOTHING

Not "ping only when the application looks stale": once the resident holds
its own connection it must keep that alive regardless, so a conditional
send does not arise.

**Corrected 2026-08-05, while writing the contract change.** This section
said the channel should carry the application's staleness —
`heartbeat_ticks` age — as data. It should not, because **the receiver
already knows it**: the host's own `health.lastTraffic` is how long the
application has been silent, and it is what drives the silence window in
the first place. Putting it on the wire would be a second account of a
fact the reader holds, which is the shape this project already paid for
when the control-frame cap lived in three places.

So the channel carries its own existence and its pings, and nothing else.
It licenses exactly one inference: **traffic here means the machine is
alive**, so a silent session for that machine is *starved* rather than
*gone*. That deletes a whole message family from the contract addition and
leaves one optional `hello` field.

The resident's own view of `heartbeat_ticks` is still interesting later —
it distinguishes "the app is starved" from "the app is running and its
wire broke" — but nothing needs that distinction yet, and it can be added
without re-shaping anything.

### C — PPC/OT first, and the 68K asymmetry is DECLARED

The extension is 68K and shared by both guests; the **stack** is not.
Mac OS 9 is Open Transport, System 7.1 is MacTCP, and their call
discipline at deferred-task time is not the same. Build the OT path,
state the MacTCP gap in `docs/contract-coverage.md` in the same commit,
and do not let it read as an oversight (AGENTS.md: declare asymmetries,
do not just leave them missing).

## The work

### 0 · The contract, because a behaviour change starts there · **DONE**

One optional `hello` field, `role: [session, resident]`, absent meaning
`session` — which is every connection that has ever existed. Additive, no
revision bump.

Writing it surfaced a blocker the plan had missed: **identity is the
name**, and the contract refuses *"a dial repeating the name of a LIVE
session"* as busy. The resident shares its machine's name by design, so
without a declared role it would be refused busy **by its own
application**. The role field is therefore not decoration; it is what
makes the channel possible at all, and the exemption is stated where the
busy rule is stated.

### 1 · Host first — the policy, with no guest at all · **START HERE**

The whole liveness policy is testable today with `FakeGuest`, which
already speaks the frame codec in `swift test`. A fake that stops
answering commands while still emitting `ping` proves the host
distinguishes deaf-but-alive from dead:

- the session **survives** — no `sessionChanged`, `isConnected` stays true;
- acts refuse **attributably** — "the Mac is not answering", never a
  silent timeout, and never a claim the act was sent;
- 011 § A3's dead-guest notice keeps firing for a genuinely gone guest and
  **stops** firing for a starved one, which is the regression this pairs
  with.

This does not fall into `two-halves-never-met-in-a-test`: `ping` is an
existing message both guests already emit, not a shape invented in a
test.

**Done when:** a guest that goes application-silent for three times
`idleTimeout` keeps its session, and one that stops at the wire level
loses it, with the two told apart by tests that have been watched to
fail.

### 2 · The Mirror says which state it is in

A third state on the face: connected, **not answering**, gone. A wedge
that renders as a healthy connection is how a person concludes the Mirror
is broken; a wedge that renders as a disconnection is a lie. The status
line already carries the lane's depth and the cancel affordance from 011
§ A — this joins them.

### 3 · The resident's interrupt-time context · **BUILT, DISARMED, UNPROVEN**

The Time Manager task exists (`ext/src/now_liveness.c`) and **does not
install**: armed, it hung a cold boot — empty menu bar, no Finder, no
worker, unreachable after five minutes. Two defects one behind the other,
both found only by running it, both in
[open-issues.md](../open-issues.md): a tick that fired once (arbitrary A5
at interrupt time, so this component's statics are somebody else's
memory), and — with that fixed, so it fired every 5 s — the boot hang.

Its deliverable was to PROVE the vehicle runs while applications are
starved. That is unproven in the strongest sense: it cannot be left
running. `liveness_ticks` and its `livenessTicks` report are built and
correct; nothing has made them climb.

### 3 (original text) · The resident's interrupt-time context

The new thing, and the one to build slowly. A Time Manager task, a
deferred task for anything that touches OT, no allocation, and OT client
registration **deferred past boot** because OT is not loaded at INIT
time. `classic-mac-init-platform` is the skill; the charter is
[resident-components.md](../resident-components.md).

Its first job is only to exist and tick: prove the vehicle runs while
every application is starved, before it is asked to carry a wire.

### 4 · The liveness channel · **BLOCKED — answered by the linker**

OT's 68K libraries are CFM/SLM fragments; this extension is a flat 68K
code resource. They do not link (`__SLM11FuncDispatch`,
`__gOTClientRecord`, …) across four library combinations. § C's metal
question, answered without a machine.

**The next attempt is MacTCP's `.ipp` driver through the Device
Manager** — the only route that keeps the resident an INIT, drivable
from flat 68K with `PBControl` and completion routines, and still
provided by OS 9's OT for exactly these callers. CFM fragment and OT
module are the fallbacks.

### 4 (original text) · The liveness channel

Registration, dial, and the periodic report of § B. The contract gains
the message family first, per the rule that a behaviour change starts
there.

### 5 · The wedge instrument — `tools/guest-wedge` · **BUILT AND RUN 2026-08-05**

**Run on a fresh spin-up, with the modal screendumped mid-run.** Three
results, and the third is why § 3 can proceed:

| mode | process-level work | reading |
|---|---|---|
| `spin` | **starved the full 20 s** | a non-pumping loop denies every other application time |
| `modal` | **never starved**, 71 s | a modal SITTING there starves nothing; `ModalDialog` pumps and that is enough |
| `scan` | **never starved**, 71 s | sync File Manager work yields; not the mechanism |

**The "modal sitting there" hypothesis is dead**, and so is "ordinary
synchronous file work". The mechanism behind the original 90 s is still
NOT established: the real Finder alert silenced even `hello`, and a spin
wedge does not, so it reaches deeper than a busy application loop. That
remains open and `scan` as written does not reach it.

**But the premise § 3 and § 4 rest on is now MEASURED on this guest:**
`hello` kept answering right through a spin wedge that `stat` could not
survive. Something answering below the application keeps answering while
applications are starved — which is the whole bet of the resident
channel, and it is no longer an argument from the scheduling model.

**The instrument was wrong twice before it was right**, both times as
rule 2e describes: a swallowed launch reported "nothing happened" as "no
starvation", and a probe (`hello`) answered below the application could
not see application starvation at all. Fixed by making the launch a
positive control that raises, and by probing with `stat`.

### The original § 5 text

Built and cross-compiling; **never yet run on a machine**, which is the
whole of what it is for, so it proves nothing until it has been. Two
things changed while writing it:

- **No `DebugStr`.** The first draft announced the run through it. On a
  machine with no debugger installed — which is every machine this runs
  on — `DebugStr` raises a system error, so the instrument whose entire
  justification is that it *lets go again* would have had a failure mode
  needing a person to dismiss a dialog. That is the wedge it exists to
  replace. The run is announced by the applet's NAME instead, which the
  process list already carries.
- **The name is the argument.** It is launched by name through the anchor
  worker and there is nowhere else to put one, so `NOW Wedge spin 30`
  carries both mode and duration, and one staged binary serves every
  experiment.

The original text follows.

A staged applet and a sibling of `tools/guest-shutdown`, which is already
exactly this pattern: a small guest applet built by `build-guests`,
staged onto the dev clone, launched through the anchor, and never
shipped. Three properties, each learned from the 2026-08-05 drive:

- **Bounded and self-releasing.** Block for N seconds, then exit
  cleanly. The manual wedge left the guest unreachable and dirtied the
  staged image; a harness that cannot release itself costs a rig per run.
- **Selectable mode**, because these are not one experiment: `spin` (a
  busy loop that never calls `WaitNextEvent` — deterministic total
  starvation), `modal` (a real modal, which tests whether `ModalDialog`
  yields at all), and `scan` (long synchronous desktop-database work,
  which is what the Finder case is now suspected to be).
- **Announces before it blocks**, so the clock's start is a fact rather
  than an inference.

**It proves nothing about the Finder.** `tools/fakeguest.py` carries that
warning in its own header and this needs the same: the applet shows the
resident survives *that* starvation. The Finder's own modal stays the
acceptance test.

## What this plan does NOT close, and must say so

**Without the extension, a modal still ends the session.** Every
mechanism here lives in an optional resident component, and
`resident-components.md` requires the product to degrade honestly without
one. It will degrade — and honestly is the part that needs work: an
`open-issues.md` entry, a line in `README.md` (which carries what works
*and* what does not), and a sentence on the Mirror's own face when no
extension is present. Closing it for real is a later slice and probably
means the host tolerating silence differently when it knows there is no
resident.

## Verification

011's rules stand, plus the tier each claim belongs to:

- **Native** (`scripts/test-native`, and added to its manifest or it is
  not real): any new `peek_table.h` slot and the staleness predicate,
  with static asserts pinning layout across the two compilers.
- **Host** (`scripts/test-host`): § 1 and § 2 in full, by mutation.
- **Emulator**: the vehicle ticks under `guest-wedge spin`; then the
  channel survives it.
- **Metal**: the OT question, and only it. OT is not loaded at INIT time
  and OT 1.x on the PowerBook 1400c is not OT 2.x on an emulated G4, so
  the emulator may flatter this. **Attended, and Michelle's call** — do
  not schedule it as though it were a gate that can be run.

Three things measured on 2026-08-05 that this plan must not re-derive:
the deafness was **>90 s with recovery**, not indefinite; the mechanism
behind it is **not established** (the app-enumeration scan is a suspicion,
not a finding); and `ModalDialog` calls `GetNextEvent`, so a modal merely
*sitting* there may not starve anything at all. § 5's `modal` and `scan`
modes exist to settle exactly this, and the answer should be recorded
before § 3 chooses a tick rate.

## What would make this wrong

- **Sending the resident's ping on the application's endpoint.** § A.
- **Letting the resident become the normal path.** The application's own
  ping stays authoritative; the resident is a backstop that reports, and
  a machine whose application is healthy should be indistinguishable from
  today.
- **Choosing a tick rate or a staleness threshold independently of
  `idleTimeout`.** They are one interlocking set and the house rule is to
  state a limit once, where both sides read it. The control-frame cap was
  written in three places with three values and nothing was wrong until a
  message grew past the smallest.
- **Treating a green `guest-wedge` run as proof the Finder case is
  closed.**
