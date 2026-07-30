# NOW parity, part two — the twelve projections, then two new faces

**Date:** 2026-07-30 · **Status:** intent, nothing built · **Namespace:** `claude/`

A snapshot of intent, per [README](README.md). Where this and the code
disagree, the code is right; where this and
[open-issues.md](../open-issues.md) disagree, the ledger is right.

Successor to
[2026-07-29-004](2026-07-29-004-feat-now-tbt-classic-parity-slice-plan.md),
which ended at W0 + W1.5 + capture. **Read that plan's rule stack first — it
still governs, unchanged.** This file does not restate it.

## What is already true

Assume all of this; none of it is work here.

- A **projection registry** where a capability is one file plus one row, with
  duplicate registration fatal. Thirteen rows today.
- **Four mechanical gates**, each mutation-proven: one-file-one-row, a face
  left out of a row, a capability drivable without a log line, and the
  registry disagreeing with the contract.
- `requires` **and** `exposes` on every row, with `exposes ⊆ requires`
  enforced — so consumed-internally no longer reads as covered.
- The local codec admits the fields it writes; guest addressability works and
  is metal-verified for four of five cases.
- **Capture is metal-verified on the 1400c**: 800×600, 4–5 pages of 8 KiB
  under a 16 KiB cap, whole call 0.5–0.6 s.

## The cost model — the thing this plan is built on

Measured, not estimated, from the capture template (finding
`now-four-face-capability-cost`). **22 files**, of which the interesting part
is the split:

| Kind of item | Cost | Why |
|---|---|---|
| Rides an **existing** client verb | **~2 files** | one projection + one catalog row; the faces come free |
| Needs a **new** client verb | **~20 files** | 7 of them in `AgentIntegrationLocalProtocol.swift` alone |

The four faces really are near-free — app UI where an affordance already
exists, MCP from the registry loop, audit from the dispatch, AppIntents not
built. **Sort the twelve by that split before scheduling anything**; it
matters more than the item count and this plan's phases are shaped by it.

## P0 — the two cleanups, before the twelve

One-off costs that every subsequent item otherwise pays again. Doing these
late means paying them twelve times on shared files with one integration
lane.

- **P0.1 — collapse the four hand-maintained capability lists.**
  `HostProjectionRegistryTests`' known-names set, `NOWAgentCompanionTests`'
  approved-tool list, two exhaustive-switch fixtures, and an
  `MCPCoverageTests` assertion matching a doc heading that names the tool
  **count** literally — so today every new capability renames a heading and
  a test string. Derive them from the registry instead. Each is trivial
  alone; twelve times over on shared test files they are a serialized edit.
- **P0.2 — decide the shape of a new client verb.** Every capability needing
  one edits `AgentIntegrationLocalProtocol.swift` in five places, and its
  three list tails conflicted on **every** merge that touched them last
  slice. Either make the serialization derive from something (as the
  projections now do), or accept it and **batch every verb a phase needs
  into one deliberate edit by one agent**. Batching is the cheap answer and
  is acceptable; what is not acceptable is twelve agents discovering it
  independently.

Also cheap, and it cost a real misdiagnosis: **bump `PRODUCT_VERSION`.** It
is `"0.1.0"` in source and was `"0.1.0"` on the stale build deployed to the
1400c, so on 2026-07-30 a guest that answered nothing for eight exec tests
gave no version signal at all. A version that cannot tell two builds apart is
not a version.

## P1 — the twelve projections

From `docs/mcp-coverage.md`'s derived gap table. Numbering continues the
predecessor's W1.

| # | Capability | Contract | ISAs | Verb exists? | User-facing home |
|---|---|---|:--:|:--:|---|
| 2 | Hardware census | `census.request`, 14 probes | both | new | machine pane |
| 3 | Software listing | `software.list` | both | new | pane |
| 4 | Transfer guest→host | `file.get` (PPC) / `put` (68K) | both | new | Files page |
| 5 | Bring to front | `process.front` | both | new | click a row |
| 6 | Frontmost app | `front` flag on `process.listing` | both | **existing** | machine pane |
| 7 | File mutation | `file.move`/`.trash`/`.restore`/`.mkdir` | PPC | new | Files page |
| 8 | Transfer cancel | `file.cancel` / `cancel` | both | new | transfer UI |
| 9 | Tail a file | `tail` verb | PPC | new | log viewer |
| 10 | Machine facts | `gestalt` verb | PPC | new | machine pane |
| 11 | Catalog search | `catsearch` verb | PPC | new | Files page |
| 12 | Reveal in Finder | `reveal` verb | PPC | new | Files page row action |
| 13 | Diagnostics module | `vprobe` / `shotdiag` / `putstat` | both | new | **its own module** |

**The column is verified against `AgentIntegrationLocalRequest.Operation`,
and it is worse than a first pass suggested.** Eleven of the twelve need a
new client verb. The existing operations are session health, session
capabilities, list processes, launch software, request quit, transfer
approved artifact, four guest-files operations, audit and capture — and
critically, `launchSoftware` returns a *launch result*, not a catalog, so
software listing does **not** ride it. There is no `front` operation at all.

Only **#6** genuinely rides an existing verb: `listProcesses` already returns
the listing with its `front` flag, so projecting frontmost-app is a rendering
change.

**That reshapes the estimate.** At ~20 files each, eleven new-verb items is
the bulk of the work and **P0.2 stops being housekeeping and becomes the
central structural decision of this plan.** It also means this plan may itself
be two: the eleven are not obviously one unit.

**#6 goes first** — it is the only item that can confirm the cost model's
cheap side, and it should land near two files. **#3 goes first among the
new-verb items**, because the gap it closes is the sharpest one in the
inventory: an agent can launch an application it can already name and cannot
ask what is installed.

**#13 is a decision already taken.** The diagnostics trio could have been
declared deliberate gaps on the grounds that agents do not need them; the
call (2026-07-29) is that they get a home, because a diagnostic an agent can
read and a person cannot is the asymmetry this work exists to close. Note
`shotdiag` is the verb that found the 180c addressing defect.

## P2 — W3, AppIntents / Siri

Unchanged from the predecessor's W3, which still holds: `GuestMachine` and
`GuestApplication` entities, session ids deliberately not entities, an intent
per rung. It comes after P1 because it consumes projections rather than
adding them, and the showcase must never drive scope.

**The gate is already armed.** `HostFaceParityTests` scans the app target for
`import AppIntents`; every row currently declares a shared not-yet constant.
The moment the first intent file lands, the gate **fails** and demands a
per-row justification. That is deliberate and was mutation-proven — expect it
and do not route around it.

Two hazards restated because they are easy to lose: a Shortcuts automation
can fire an intent **unattended**, so an intent is not proof a human is
present; and Siri will not wait the 32 seconds an unacknowledged launch takes
to settle, so the honest short answer is that the machine was *asked*.

## P3 — W4, granted control

Unchanged in substance from the predecessor's W4, with one thing now
**measured rather than assumed**: the `PostEvent` probe (finding
`postevent-modifiers-need-ppostevent`) established that `PostEvent` carries
no modifiers and `PPostEvent` does — and that `PPostEvent` is
`CALL_NOT_IN_CARBON` while the PPC guest **is** Carbon. So:

| | text injection | modifier/menu keys |
|---|---|---|
| 68K guest (non-Carbon) | app tier | **app tier** — `PPostEvent` |
| PPC guest (Carbon) | app tier | **extension plane** — no app-tier route |

The cheap path exists on the guest the work de-prioritised and is absent on
the one it focuses on. The plane's requirements are known: an arm cell naming
process and modifiers for one event with self-disarm, a bounded lifetime so a
wedged host cannot leave Command stuck down, and a capability bit keeping it
dark until metal. One extension by charter — a plane, developed as a
throwaway honest-named INIT first.

`MenuKey` is **not** the discriminator and will mislead anyone who uses it as
one: it resolves on the character and never inspects the event.

## Fanout

Cost-split-led. The barriers are real dependencies.

```
P0   cleanups + version .............  2 agents  BARRIER
P1a  #6 frontmost app ...............  1 agent   BARRIER (confirms the cheap side)
P1b  the batched verb edit ..........  1 agent   BARRIER (all eleven verbs, one commit)
P1c  the eleven rows ................  up to 11 agents, integration lane queued
P2   AppIntents .....................  2 agents
P3   grant, then injection ..........  2-3 agents
```

**P0 is a barrier** because P1b's shape depends on it and the four lists are
edited by everything.

**P1a is a barrier** for the same reason capture was: it confirms the cost
model before anything fans out against it. It is a small item, and that is
the point — if the only existing-verb projection in the inventory does not
land near two files, the model is wrong and this plan needs rewriting rather
than staffing.

**P1b is the structural heart of this plan**, not a chore. One agent adds all
eleven client verbs to `AgentIntegrationLocalProtocol.swift` in a single
deliberate commit — operation cases, result cases, response fields and inits,
decode branches — and only then do per-capability agents fan out against a
file nobody else needs to touch. Eleven agents each adding their own verb to
the same three list tails is eleven conflicts on a file where every conflict
needs a human decision, and last slice proved those tails conflict on *every*
merge that touches them.

The trade is real and worth stating: batching means one large reviewable
commit that no single capability's tests cover in isolation. Accept it, and
have P1b's agent write the round-trip tests for all eleven verbs in the same
commit so the batch is not landing untested.

Every phase ends with an adversarial verification agent, and the standing
rule holds: a test you have not watched fail proves nothing.

### Collision hazards

The predecessor's list stands in full. Two are load-bearing here:

- **The agent socket is per-uid**, so exactly one agent at a time holds the
  host-app + companion + paired-guest lane. Build and unit work fans out
  freely; integration verification **queues**. With twelve items this is the
  throughput ceiling, not agent count.
- **`AgentIntegrationLocalProtocol.swift`** — see P0.2. One owning agent per
  phase, no exceptions.

## Metal

The 1400c is reachable and the procedure is proven: port 5251, 30-second
guest poll, `NOW_METAL=1 NOW_METAL_PORT=5251 NOW_METAL_MACHINE=<addr>`.
`MetalCaptureProjectionTests` and `MetalAddressingTests` are the pattern for
a new gate.

Rules paid for the hard way:

- **Ask before every metal pass.** Per-action; permission for one is not
  permission for the next. Never reboot or power-cycle, never quit the
  person's applications.
- **Do not trust the version string** to tell you which build answered.
  Assert a capability only the build under test has.
- **One `swift test` at a time on this Mac** — the suites share
  `~/Library/Logs/now-logs` and a fixed port 52981.
- `now-guest-not-addressed` needs a **second live session**; a second real
  machine or a QEMU guest on the same port is what closes it.
- The `CopyBits failed` that `vprobe` reports on the 1400c does **not**
  reproduce through `capture.request`. Different paths; do not conflate them.

## Stop conditions

The predecessor's all carry over. Three specific to this plan:

- **P1a does not land near 2 files.** The cost model is wrong; stop and
  re-derive before fanning out.
- **A projection needs a guest change.** Then it was never a projection —
  reclassify and re-cost rather than growing the phase.
- **An agent adds a client verb outside the batched edit.** Stop it. That is
  the conflict P0.2 exists to prevent, and it compounds.

## Still undecided

**Streaming** (`stream.start`/`.stop`/`.refresh`, PPC only). Deliberately not
in P1: it is a real feature, much larger than a projection, and it is either
its own workstream or an explicit deferral with a reason. An undecided row is
worse than an absent one.

## Corpus impact

`corpus_impact: none` — intent only, and the two measurements it rests on are
already recorded (`now-four-face-capability-cost`,
`postevent-modifiers-need-ppostevent`). The next finding is P1a's cost on the
cheap side of the split.
