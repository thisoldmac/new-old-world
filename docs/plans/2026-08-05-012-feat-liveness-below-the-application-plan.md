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

### 3 · The resident's interrupt-time context · **DONE, and PROVEN on the emulator**

**2026-08-05, later.** Armed, booting, ticking, and ticking through a
starvation that stops applications. The hang was the callback ABI: a Time
Manager task is a `CALLBACK_API_REGISTER68K` callback with its record in
**A1**, and the C tick was reading a stack argument. `now_liveness_tm.S`
is the shim; `open-issues.md` carries the full diagnosis, including that
the A5 explanation this section recorded was wrong for this component.

| claim | evidence |
|---|---|
| the vehicle installs, the guest boots | `capabilities: 63` on a fresh cold boot |
| it ticks at 5 s | +46 ticks over 232.5 s of the guest's own clock |
| it ticks while applications cannot | worker unreachable 25 s; +5 ticks over 26 s |

Instrument: `tools/liveness-experiment.py`, INCONCLUSIVE branch watched
to fire. Two of § 5's measurements did not reproduce on this clone and
are flagged in the ledger rather than quietly resolved.

### 3 (as it stood when disarmed) · **BUILT, DISARMED, UNPROVEN**

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

### 4 · The liveness channel · **DONE, and EMULATOR-VERIFIED end to end**

**2026-08-06.** A real Macintosh opens the second connection, says
`role: resident` on it, and keeps it alive while every application is
starved. Against the REAL host, an application starved for 110 s kept
its session — the same sockets, before and after.

| claim | evidence |
|---|---|
| the resident dials and is admitted | two connections, one hour apart in port, `role: resident`, `name`/`os` identical to the session's |
| the driver opened AND a stream exists | `capabilities: 127` — both P6 bits |
| it speaks while applications cannot | 108.8 s application starvation, three resident pings inside it, all answered |
| § 1's policy works with a real guest | 110 s starvation against `now-host`: session sockets unchanged |
| it is the RESIDENT doing it | mutation: an app that never publishes the endpoint, same wedge — see below |

Built on MacTCP's `.IPP` driver through the Device Manager, and with
**no completion routines** — the one decision here worth arguing with,
argued in `ext/src/now_liveness_net.c`'s header.

**It found a second defect that no host-side test could have.** The
guest's own `service_heartbeat` counted the starvation as silence and
tore the link down from its end, 65 s in. The host had done everything
right; the guest had the same wrong idea from the other side. Fixed by
forgiving a pass gap over ten seconds, and deliberately without needing
the extension at all.

**And the instrument was feeding the clock it measured.**
`tools/liveness-channel.py` polls `mirror` every five seconds, so the
queued requests refreshed `last_rx_tick` the moment the guest came back
and the defect above stayed invisible through two green runs. The real
host — which pings nothing, by contract — was the only observer quiet
enough to see it. `open-issues.md` carries this at length; it is the more
transferable half of the day.

### 4 (as it stood at the first gate) · **FIRST GATE CLEAR, transport not built**

**2026-08-05, later.** The MacTCP route named below was asked the same
cheap question that killed OT, and passed it: the resident opened `.IPP`
with `PBOpenSync` on a cold-booted OS 9 guest — `transportProbe: 1`,
`transportResult: 0` — with the machine booting normally around it. No
library, no CFM, nothing for a linker to refuse.

**The channel itself is NOT built and this must not be read as though it
were.** A driver opened; nothing was created, dialled or sent. What
remains is the whole of § 4: `TCPCreate` and `TCPActiveOpen` over
`PBControl`, a receive buffer in the system heap, register-based
completion routines each needing the shim discipline the vehicle just
charged for, the frame codec and a `hello` carrying
`role: resident` under the SAME machine name the application dials with.

The probe was watched to report a refusal: a build asking for `.NOP`,
cold-booted the same way, answered `transportProbe: 2` /
`transportResult: -43` (`fnfErr`).

### 4 (as it stood when blocked) · **BLOCKED — answered by the linker**

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

**REFUTED 2026-08-06, on a fresh clone with the same instrument plus two
better ones.** Two of those three rows are wrong. `NOW Wedge modal 45`
starved NOW for **43,974 ms** of its 45 seconds and `NOW Wedge scan 45`
for **43,975 ms**, against `spin`'s 44,061 ms — the three modes are
indistinguishable, and the guest's own `wirestat` histogram says its
event loop did not run once (`pass max` 44.9 / 45.0 / 45.0 s). The
reason is in the instrument: `ModalUntil` loops on `GetNextEvent` with
no sleep, which yields nothing, so **the `modal` mode is `spin` with a
dialog drawn over it** and has never measured what its name says. A
REAL application's `ModalDialog`, raised through `ctlact` so the
application runs its own handler, costs NOW a 20× slowdown (413 ms
median scene, 145 probes) and no starvation at all. `docs/open-issues.md`
carries the numbers and what they cost; the sentence below about the
hypothesis being dead is the one that has to go.

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

## Picking this up cold

**Rewritten 2026-08-06, at the end of the session that finished § 4.**
The section below it is the previous session's version, kept because
half of what it says is still how the rig works. If this and
[open-issues.md](../open-issues.md) disagree, the ledger is right; if
this and the code disagree, the code is right.

### The one-paragraph version

**This plan is done, at the emulator tier.** A Macintosh is
cooperatively scheduled, so one blocked application starves all of them,
and liveness was answered BY an application — so an ordinary dialog
killed the wire against a healthy machine. Now the machine answers for
itself: the optional resident component holds its OWN connection over
MacTCP's `.IPP` driver, says `role: resident` on it, and pings through
starvation. Watched end to end against the real host on 2026-08-06 — 110
seconds starved, session kept, and the mutation without the resident
watched to lose it.

### What is DONE and how it was proven

| § | what | evidence |
|---|---|---|
| 0 | `hello.role: [session, resident]` | contract, additive |
| 1 | host tells starved from gone | 7 tests, 4 mutations — and now a real guest |
| 2 | the Mirror shows the third state | 3 mutations |
| 3 | the interrupt-time vehicle | ticks through starvation; `now_liveness_tm.S` is the ABI fix |
| 4 | **the channel** | two connections, `capabilities: 127`, 110 s starved with the session kept, mutation watched to fail |
| 5 | `tools/guest-wedge` | built and run |
| — | the guest's own dead-link clock | `service_heartbeat` forgives a pass gap over 10 s |

`scripts/test-all` green with both cross-compilers.

### The three things most worth knowing before touching this

1. **There are no completion routines, and that was a decision.**
   `ext/src/now_liveness_net.c` issues every MacTCP call asynchronously
   with a nil completion and reaps `ioResult` on the next 5-second tick.
   Its header carries the argument; the short form is that `MacTCP.h`
   declares a STACK-based completion while the Device Manager documents
   A0/D0, and guessing wrong costs a five-second corruption of somebody
   else's memory. If you add one, `now_liveness_tm.S` is the pattern —
   but add it for a reason, not for symmetry.
2. **An instrument that talks to the guest cannot measure the guest's
   silence.** `tools/liveness-channel.py` polls `mirror` every five
   seconds, and those queued requests refreshed the very clock under
   test — hiding the guest-side defect through two green runs. The real
   host pings nothing by contract and is the quiet observer. If you are
   measuring silence, check what your instrument is sending.
3. **The endpoint is published by the APPLICATION and nothing else can
   publish it.** `now_peek_publish_endpoint` on `hello`,
   `now_peek_withdraw_endpoint` on every path out, epoch 0 meaning stay
   off the wire. A resident has no preferences and nobody to ask.

### What is NOT done

- **Metal.** Everything here is an emulated G4 under OS 9. MacTCP on a
  real PowerBook is not Open Transport's compatibility driver on an
  emulator. **Attended, and Michelle's call** — not a gate to schedule.
- **68K / System 7.1.** The extension is the same INIT and the route is
  the same Device Manager code, so § C's expected OT-versus-MacTCP
  asymmetry did not happen — but "the same code" is not "the same
  behaviour" and nothing has run it there.
- **Without the extension, a starvation past the host's window still
  ends the session.** Watched, by mutation. Closing that means the host
  tolerating silence differently when it knows there is no resident,
  and it is a later slice.
- **Nothing dismisses the dialog.** The machine is legible and
  survivable while wedged, not serviceable. That was always the
  non-goal.
- **The original 90 seconds is still unexplained.** No wedge mode
  reproduces what the Finder's alert did; see below, and do not quietly
  resolve it.

### Driving the rig, as it actually went

```bash
export NOW68K_TOOLCHAIN=~/Lab/Tools/Retro68-build-68k/toolchain/m68k-apple-macos/cmake/retro68.toolchain.cmake
export NOW_PPC_TOOLCHAIN=~/Lab/Tools/Retro68-build/toolchain/powerpc-apple-macos/cmake/retrocarbon.toolchain.cmake
scripts/build-guests
NOW_SPIN_RUN=/private/tmp/nowvm-$$ NOW_ANCHOR_PORT=1702 NOW_WIRE_PORT=5311 \
    scripts/spin-up-ppc                       # ~7 min, cold boots so the INIT loads
OUT="${TMPDIR:-/tmp}/now-guest-builds/$(printf '%s' "$PWD" | shasum | cut -c1-12)"
NOW_ANCHOR_PORT=1702 NOW_BUILD_OUT="$OUT" tools/stage-wedge.py spin 110
```

Then either observer:

```bash
# the guest's own words, both connections, timestamped
tools/liveness-channel.py --port 5311 --anchor 1702 \
    --lab ~/Lab/Code/timbottu --wedge 110 --run 60

# or the REAL host, which is the only end-to-end test
defaults write dev.newoldworld.now.settings.res1 listenPort -int 5311
(cd now-host && NOW_PREFS_SUFFIX=res1 swift run Host)
lsof -nP -iTCP:5311 -sTCP:ESTABLISHED   # same sockets before and after = survived
```

`NOW_PREFS_SUFFIX` is what makes a second host copy free — its own
settings and its own guest registry, so it cannot edit a working
instance's book.

Traps that cost time this session, all of them rig rather than product:

- **`scripts/test-all` SKIPS the cross-builds silently** without both
  toolchain variables exported in the same shell. It says so; it is easy
  to read past, and you then gate on yesterday's bytes.
- **The anchor's `quit` verb is out of scope**; Cmd-Q is
  `{"code": 12, "char": 113, "mods": 256}` through `key`, and NOW must be
  quit before its binary can be overwritten (`create err -48`).
- **The resident OUTLIVES the application**, by design. Restarting NOW
  does not clear the channel — a mutation that needs it gone needs a
  cold boot.
- **Stage applets to `Macintosh HD:TimBotTu:now-dev`**, never the
  Desktop Folder: launching from there resets the worker connection.
  `tools/stage-wedge.py` does it correctly; `tools/wedge-experiment.py`'s
  own path constant is the old, wrong one.

### The previous session's version of this section

Kept for the rig detail it carries and because two of its warnings are
still live. Where it says § 4 is not built, it is out of date.

### The one-paragraph version

A Macintosh is cooperatively scheduled, so one blocked application
starves all of them. Liveness was answered BY an application, and a modal
is exactly what takes the application away — so an ordinary dialog killed
the wire session against a perfectly healthy machine. The host half is
finished and gated: it can tell **starved** from **gone** and says which.
The guest half is not: the resident needs a way to answer for the machine
while every application is starved, and the two attempts at that are
respectively **blocked at the linker** and **disarmed after hanging a
boot**.

### What is DONE and gated

| § | what | evidence |
|---|---|---|
| 0 | `hello.role: [session, resident]` | contract, additive, no revision bump |
| 1 | host tells starved from gone | 7 tests, 4 mutations |
| 2 | Mirror shows the third state | 3 mutations |
| — | `NowPeekLivenessEndpoint` slot | 116 native tests; layout mutation fails 10 asserts |
| 5 | `tools/guest-wedge` | built AND run; results below |

`scripts/test-all` green, both cross-compilers, every guest and
instrument building. Ten commits on `claude/mirror-build-out-17bbed`.

**Nothing speaks `role: resident` yet**, so the host half has never been
exercised end to end by a real guest. That is § 4's job.

### What is NOT done, and exactly where it stopped

### § 4 — the transport. BLOCKED at the linker, not on a machine.

The resident must dial the host itself. Over Open Transport **it cannot,
from this component**: OT's 68K libraries are CFM/Shared Library Manager
fragments and `ext/` is a flat 68K code resource (`-Wl,--mac-flat`). They
do not link. Unresolved: `__SLM11FuncDispatch`, `__SLM11VTableDispatch`,
`__SLM11ConstructorDispatch`, `__SLM11ExtblDispatch`, `__gOTClientRecord`.
Four library combinations tried including the application flavour; best
case 15 unresolved symbols.

**This is plan 012 § C's metal question answered without a PowerBook.**

**The next attempt is MacTCP's `.ipp` driver through the Device
Manager.** It is the only route that keeps the resident an INIT: a flat
68K INIT can drive it with `PBControl` and completion routines, which is
how resident code did TCP before OT, and OS 9's OT still provides it for
exactly these callers. Fallbacks if that fails: ship the resident as a
CFM fragment, or as an OT module. Both change what the component IS and
have their own install stories.

**Do not start this until § 3 below is fixed** — a transport on a vehicle
that hangs the machine is untestable.

### § 3 — the vehicle. BUILT, DISARMED, and the cause is NOT known.

`ext/src/now_liveness.c` installs a Time Manager task, the extension's
first interrupt-time context. It currently returns before installing, and
the `return` is deliberate.

**Two defects, one behind the other. Only running it found either.**

1. **The tick fired once.** `livenessTicks` read `1` on a guest up for
   minutes. A Time Manager task enters with an ARBITRARY A5 and Retro68
   addresses globals through A5, so this component's statics are somebody
   else's memory at interrupt time. **Fixed** — everything the task needs
   now travels inside the task record, which the Time Manager hands back.
2. **With that fixed, a cold boot never completed.** Empty menu bar, no
   Finder, no anchor worker, unreachable five minutes later
   (screendumped). The first defect had MASKED the second: a task that
   fires once does not hang a machine; one that fires every 5 s does.

**Two candidates, both testable, neither tested:**

- **The globals-world shim.** The jGNE filter has one in assembly
  (`ext/src/now_ext_gne.S`) and this task has none. Even though the tick
  no longer reads statics, the compiler may still emit A5-relative
  access, and `NewTimerProc`'s UPP may need the same treatment. **Look at
  the shim first** — it is the existing, working answer to this exact
  problem in this exact component.
- **`PrimeTime` re-arming from inside a standard Time Manager
  completion.** Legal for the extended Time Manager (`InsXTime`); worth
  confirming for `InsTime`. Cheap alternative: `InsXTime` instead.

**How to test it:** delete the `return` in `now_liveness_install`,
rebuild, spin up (below), and read `livenessTicks` from the `mirror`
verb. It must climb by roughly one per 5 s. If the boot hangs again,
disarm and try the other candidate — **do not leave an armed
boot-hanging extension on any image anyone needs.**

### The rig, and how to drive it

```bash
export NOW68K_TOOLCHAIN=~/Lab/Tools/Retro68-build-68k/toolchain/m68k-apple-macos/cmake/retro68.toolchain.cmake
export NOW_PPC_TOOLCHAIN=~/Lab/Tools/Retro68-build/toolchain/powerpc-apple-macos/cmake/retrocarbon.toolchain.cmake
scripts/build-guests
NOW_SPIN_RUN=/private/tmp/nowvm-$$ NOW_WIRE_PORT=5277 scripts/spin-up-ppc
```

Both toolchain variables are needed or the cross-builds SKIP silently and
you test yesterday's bytes. `NOW_SPIN_RUN` must be short — a worktree
path exceeds the 104-byte UNIX socket cap and QEMU dies with nothing in
the script's output. Pick a `NOW_WIRE_PORT` nothing else is using.

A full spin-up is ~6 minutes and stages the current builds, cold-boots so
the INIT loads, and prints the resident's own report. Look for
`"capabilities": 63` — bit 5 (32) is the liveness capability, so 63 means
the vehicle installed; 31 means it did not.

Read the counter:

```bash
tools/askguest.py --port 5277 --wait 40 mirror
```

`livenessTicks` is in the extension block beside `heartbeat`.

**Recovering a wedged guest:** `python3 tools/shutdown-guest.py <qmp.sock>
--port 1700 --timeout 90`, then delete the run directory. QMP `quit` is a
power cut — it dirties the volume and the next boot spends minutes in
Disk First Aid. Never kill by port: `lsof -ti tcp:<wire>` matches QEMU
itself under user-mode networking.

### The wedge instrument, and what it measured

`tools/guest-wedge` is a staged applet, a sibling of `tools/guest-shutdown`.
It is launched BY NAME through the anchor and the name is the argument:
`NOW Wedge spin 25`. Bounded and self-releasing — every mode stops at its
deadline and quits, so the rig survives the experiment.

Stage it by pushing the same binary under three names (the path name
wins, so one binary serves every mode), then `launch` it through the
anchor on port 1700. The push reports a "catalog dates" error after
committing; the file lands, so `stat` and carry on.

**Results, 2026-08-05, with the modal screendumped mid-run — TWO OF
THESE THREE ROWS WERE REFUTED 2026-08-06. Read the correction under § 5
above before quoting anything here.**

| mode | application-level work | reading | 2026-08-06 |
|---|---|---|---|
| `spin` | **starved the full 20 s** | a non-pumping loop denies every other application time | **stands** — 44,061 ms of 45 s |
| `modal` | ~~never starved, 71 s watched~~ | ~~a modal SITTING there starves nothing; `ModalDialog` pumps~~ | **REFUTED** — starved 43,974 ms of 45 s. `ModalUntil` loops `GetNextEvent` with no sleep, so this mode is `spin` with a dialog drawn over it and has never measured a modal |
| `scan` | ~~never starved, 71 s watched~~ | ~~sync File Manager work yields~~ | **REFUTED** — starved 43,975 ms of 45 s |

The three modes are indistinguishable, and the guest's own `wirestat`
histogram says its event loop did not run once (`pass max` 44.9 / 45.0 /
45.0 s). What a REAL modal costs was measured separately, by raising one
through `ctlact` so the application runs its own handler: a **20×
slowdown** (scene median 21 ms idle → 413 ms, n=145) and **no starvation
at all** — acts work through it.

**Two traps this instrument taught, both drive-loop rule 2e:**

1. The first script **swallowed a failed launch**, so "nothing happened"
   was reported as "this block does not starve other applications". The
   launch is now a positive control that raises.
2. The probe asked the worker `hello`, **which kept answering right
   through a spin wedge**. A question answered below the application
   cannot see application starvation. Use `stat` — it needs the worker's
   own main loop. Same class as `probe-oracles-were-blind`.

The experiment script is ``tools/wedge-experiment.py`, committed so it does not have to be
rewritten.

### What is still unexplained, and must not be quietly resolved

**The original 90 seconds.** The real Finder alert silenced even `hello`;
a spin wedge does not. So the Finder's alert starves something DEEPER
than a busy application loop, and none of the three wedge modes reaches
it. The mechanism is a suspicion, not a finding, and the `scan` mode as
written is not it. If you need the answer, the next mode to try is one
that reproduces the alert's own work — enumerating the volume's
applications the way the "select an alternate program" list does.

**Do not** write this up as "the modal starves the machine". That
specific claim is dead: measured, 71 s, nothing starved.

### The one measured thing the whole plane rests on

Under `guest-wedge spin`, the anchor worker could not serve a `stat` and
went on answering `hello`. **Something answering below the application
keeps answering while applications are starved** — on this guest, by
measurement, not by argument from the scheduling model.

That is why § 3 and § 4 are worth finishing. It is also the thing to
re-check first if the design ever stops making sense.

### Advice on scope

The host half is done and the product is better than it was: the lane
survives being driven, and a starved Mac is told apart from a gone one.
**Without the extension a modal still ends the session** — that is in
README's headline gaps and on the ledger.

If § 3's boot hang does not yield in two or three diagnostic boots,
**leave it disarmed and go back to the core Mirror work** (plan 001,
Cycle 18, 10/40 rows). This slice is a detour that has already returned
most of its value; the remaining piece is the part that needs a
Macintosh to behave, and it will still be here.


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
