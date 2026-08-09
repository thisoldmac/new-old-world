# Mirror interaction latency, priority, and coherent state

**Status:** Proposed. This is the complete implementation roadmap; no behavior
change is implemented by this document.

**Planning baseline:** local `main` at `2598e40e` on 2026-08-09. This clone
has no configured remote, so the baseline is the verified local `main` head.
The plan branch is `codex/mirror-latency-state-plan` in the isolated worktree
`/Users/michelle/Lab/Code/timbottu/now-mirror-latency-state-plan`.

## Outcome

Make a Mirror gesture feel like the most important work in the system without
making the displayed Macintosh less truthful. At the end of this plan:

- one trace attributes a gesture's time from native input through admission,
  guest service, settlement, and visible publication;
- queued human gestures keep their order but run before Mirror-owned ambient
  observation and enrichment that has not started;
- direct and typed acts enter one guest dispatch lane rather than two lanes
  racing one resident request cell;
- dispatch and later state confirmation are distinct, so a 15-second
  postcondition wait does not automatically hold unrelated gestures behind it;
- every irreducible guest-side background operation has a measured, named
  monopolization budget and a conservative timeout result;
- the guest can announce typed invalidation generations so the host requests
  the state that changed instead of treating every poll as equally urgent;
- the existing session-pinned `MirrorStateEngine` remains the one host state
  owner and publishes immutable, generation-coherent projections; and
- a PowerBook campaign can say which latency class remains, rather than report
  one unexplained total.

The plan does **not** promise preemption inside arbitrary classic Toolbox
calls. It bounds work at safe normal-context boundaries and never pumps an act
while foreign addresses, movable-memory pointers, or a resident callback's
state are live.

## Target and scope

- **Guest:** PowerPC CFM Carbon application, CarbonLib 1.6, Mac OS 8.6–9.2.2.
- **Resident:** the optional 68K NOW Extension only where its existing
  transition evidence is consumed or a proved missing signal requires an
  accretive shared-contract change.
- **Host:** NOW's Swift host, including the NOW-owned `MirrorKit` package.
- **Primary metal row:** PowerBook 1400c / Mac OS 9.1.
- **Fallback:** a guest without the resident or the new invalidation event
  continues bounded polling and reports that source as unavailable.

### In scope

- Root-cause instrumentation and a reproducible latency campaign.
- One per-session scheduler for request-shaped guest work, with every caller
  explicitly classifying interactive, foreground, confirmation, ambient, and
  bulk-start work.
- Human-action priority, background coalescing, bounded starvation, and
  session cancellation.
- One action dispatch lane plus a separate correlated settlement ledger.
- Finder, visibility, scene, content, and semantic work sliced at existing safe
  boundaries.
- Guest-originated invalidation hints and domain generations.
- Generation-aware contribution and publication policy in
  `MirrorStateEngine`.
- Contract, host, guest, resident, emulator, and metal verification required by
  the code actually changed.

### Out of scope

- A second maintained Mirror state engine on the guest.
- Replacing `NowScene` with a new monolithic snapshot format.
- A second TCP connection or out-of-band urgent channel without measurements
  proving bounded single-stream scheduling cannot meet the acceptance budget.
- Reentrant scene traversal or act execution from an Open Transport notifier,
  Time Manager task, jGNE filter, OSA callback, or other restricted context.
- Turning the resident transition sampler into a claim that every Toolbox
  event is captured.
- Reprioritizing protocol-critical frames or bytes inside an already-started
  bulk frame. The scheduler owns request admission; `Session` retains frame
  integrity and transport control.
- NOW-68K feature parity. Its normal non-Carbon application model is outside
  this latency slice.
- Visual redesign of the Mirror.

## Current facts the implementation must preserve

1. The historical 9–12 second double-counted stall had a specific cause:
   `act_yield` did not pump the wire. It now calls `now_wire_pump()`. A new
   12-second report is not evidence that old defect returned.
2. `NOWMirrorSource.perform` currently holds a typed action outside the
   mutation broker while `pending` is true. The time spent "queued behind the
   current observation" begins before `MirrorActClocks.enqueuedAt` and is not
   attributed to the blocker.
3. `MirrorMutationBroker` serializes dispatch through postcondition settlement,
   for up to 15 seconds. `MirrorDirectActLane` releases on the guest reply. They
   are separate lanes into the same one-cell guest act plane and can collide.
4. `GuestListener.runCommand` writes each request immediately and permits many
   pending callbacks. There is no session-wide admission order across scene,
   visibility, Finder, content, acts, or requests from another NOW module.
5. `Session` delays a control frame only behind a partially written bulk frame.
   That frame-boundary wait is normally tens of milliseconds and is not an
   explanation for a 12-second control delay.
6. The guest dispatches control frames serially. `serve_scene` runs
   `now_scene_collect` synchronously and deliberately does not yield while
   foreign addresses are live.
7. Finder complements call `OSADoScript`. The guest's default script deadline
   is 15 seconds, and its own help correctly says that one script's timeout is
   every other caller's wait.
8. Recent live evidence does not make the structural walk the leading suspect:
   the sampled PowerBook cycles were generally tens of milliseconds. Finder
   and visibility work still consume much larger cooperative intervals, and a
   prior Wallstreet first complement measured 12,983 ms.
9. The guest already aggregates a structural `NowScene`; the host already has
   one session-pinned `MirrorStateEngine` with retained semantic, content,
   Finder, and visibility contributions. The missing design is scheduling and
   coherent publication, not the absence of any snapshot or reducer.
10. The resident already provides the P5 transition tail: a preallocated,
    lossy sampler of front-process, window-list, menu-list, and heartbeat
    changes for one armed A5 world. Its cursor, dropped count, arm scope, and
    expiry make it useful invalidation evidence, not a complete machine model.

## Architecture decisions

### A. One admission point for session guest work

Add a session-pinned `GuestWorkScheduler`. Every request-shaped guest operation
enters it with:

- a trace ID and source (`human`, `agent`, `postcondition`, `ambient`);
- a work class;
- an optional coalescing key;
- a session and displayed-snapshot identity;
- a cancellation rule;
- a declared maximum guest monopolization budget; and
- a completion that says whether work was sent, answered, canceled before
  send, superseded, refused, or timed out.

The scheduler owns admission, not protocol encoding. `GuestListener` and
`Session` remain the transport and correlation owners.

Protocol-critical handshake, pong, bye, transfer-cancel, and frame-completion
traffic bypasses product priority. Request-shaped product work uses this
order:

1. Human-interactive operations, including Mirror gestures and explicit
   Stop/cancel actions, FIFO relative to one another.
2. A targeted postcondition refresh that is the dependency barrier for the
   oldest queued human operation.
3. Agent actions and foreground state explicitly requested by a person or
   active NOW module.
4. Other required postcondition and structural invalidation refreshes.
5. Content, Finder, visibility, semantic, inventory, and artwork enrichment.
6. New bulk work that is not itself an explicit foreground action.

Rules:

- A queued gesture prevents **new** ambient work from starting.
- Active non-reentrant guest work completes or reaches its next safe boundary;
  it is never interrupted inside foreign-memory traversal.
- Ambient work coalesces by session, domain, target, and base generation.
  Latest valid intent wins; superseded work is recorded, not silently lost.
- A starvation allowance may admit one required structural/postcondition read
  after a sustained gesture burst, but never a stale enrichment.
- Session stop, disconnect, or replacement cancels every unsent entry and
  prevents a late completion from publishing into the next session.
- Every request family has an explicit classification. Add a source census
  test that fails when a caller sends request-shaped work around the scheduler;
  defaults would turn a forgotten background caller into accidental priority.

### B. One action lane; settlement is not the lane

Replace the two host action lanes with one dispatch queue. Do this in two
reviewable steps:

1. Route direct and typed operations through one lane while preserving today's
   typed settlement barrier. This removes the one-cell collision without
   changing attribution semantics.
2. Move terminal state confirmation into a bounded correlated ledger. Release
   dispatch when the guest answers and provides a correlation or a definitive
   not-sent refusal. The guest's existing settlement ring and later scene
   evidence update the ledger independently.

The second step must retain dependency barriers. An operation whose next
gesture would be interpreted against state it is changing may declare a
settlement barrier; independent operations need not inherit it. Repeated
direct gestures retain exact FIFO order. No operation is confirmed from
incomplete coverage, a reused identity, a different session, or an optimistic
host presentation.

A gesture received during a scene cycle is appended to the journal and
scheduler immediately. It is no longer parked in an unmeasured 25 ms polling
loop. Dispatch revalidates the newest authoritative target before sending.

### C. Bound background work; do not fake preemption

The first implementation uses boundaries that already exist:

- one scene request;
- one content drain chunk;
- one visibility census;
- one Finder container page;
- one semantic batch; and
- one artwork enrichment batch.

Finder front-container pages remain ahead of desktop and background
containers. Every page is a separate scheduler entry, and the host publishes
useful semantic facts without waiting for artwork.

U0 selects a single-slice budget from PB1400c distributions. The working
acceptance target is that Mirror-owned ambient work contributes no more than
2,000 ms to a queued gesture; changing that number requires recording the
measurement and updating this plan or the resulting architecture document.
No automatic Finder script may inherit the generic 15-second deadline merely
because it omitted `timeoutMs`. A timed-out or superseded complement retains
the last complete projection, marks coverage stale/partial, and retries only
after interactive pressure clears.

If a **single** scene walk exceeds the selected budget on metal, split it only
at a boundary where the collector owns no foreign pointer or dereferenced
Handle. The intermediate state must carry an exact base generation and may be
discarded as stale. Do not add `now_wire_pump()` inside an open foreign walk.

### D. Invalidation before a guest shadow model

The guest gains a normal-context observation coordinator, not a second state
authority.

It consumes what the current resident can already prove:

- P5 front-process, window-list, and menu-list transition records;
- P5 heartbeat, pass count, cursor gaps, and dropped count;
- act settlement correlations;
- state changes NOW itself already knows it performed; and
- scene digest/generation results.

It reduces those inputs into monotonic domain generations such as
`structure`, `front`, `menus`, `finder`, and `content`. Generations are
invalidation hints: they say a domain must be reread, not what the new state
is. A ring gap, dropped record, expired arm, missing resident, or uncovered
process forces conservative fallback polling/full observation.

Add a small, optional contract event through `contract/asyncapi.yaml` before
either peer emits or consumes it. Its symmetric meaning is: a peer that serves
scene state announces that one or more locally served domains advanced. It
carries session identity, overall generation, domain generations, and evidence
quality; it carries no window pointers, Finder item roster, or replacement
scene.

Do **not** change `contract/peek_table.h` merely to duplicate the P5 cursor.
Only a mutation-proven domain coverage gap may justify an accretive resident
field or tail record. Such a change triggers the shared-layout tests, guest
build, extension bake gate, session-private bake, and metal boot/recovery
requirements.

A resident shadow model remains a later decision. It is considered only after
the generation path has run long enough to show that its invalidations are
complete and that full walk cost, rather than scheduling or Finder work,
remains a material metal bottleneck.

### E. One reducer, generation-coherent publication

`MirrorStateEngine` continues to own the host replica. Introduce typed
contribution envelopes containing:

- guest session;
- structural sequence/digest;
- domain generation;
- exact process/window identity where applicable;
- coverage/completeness and provenance;
- received time; and
- the trace/work ID that acquired it.

The engine accepts contributions immediately but publishes only a coherent
cut:

- structure publishes promptly;
- retained last-complete enrichment may remain visible only when identity and
  coverage rules already permit it, and is explicitly stale;
- an enrichment from an older structural generation never republishes;
- front-surface semantic state may publish at a declared useful boundary, such
  as one complete Finder page, without waiting for artwork;
- related fields that would contradict one another publish together; and
- every immutable projection records its publication reason and base
  generations so a gesture can be joined to the frame a person saw.

This is not a debounce that hides progress for an arbitrary interval. The
publication policy is domain-specific and tested with state sequences that
previously flickered, disappeared, or showed empty interiors.

## Latency model and evidence grammar

Add a `MirrorWorkClocks` record beside `MirrorActClocks` and
`MirrorCycleClocks`. One trace should cover:

```text
native input captured
  -> scheduler enqueued
  -> admitted to transport
  -> control frame written
  -> guest noticed readable data
  -> guest dispatched request family
  -> guest handler completed
  -> host received reply
  -> authoritative settlement observed
  -> coherent projection published
```

Host and guest clocks are not synchronized. Record local durations and shared
request/correlation IDs; never subtract a guest `TickCount` from a host date.

Every row names:

- session, guest build, resident fingerprint, trace, request ID/correlation;
- source, work class, command/scene kind, target/coalescing key;
- queue depth and the active blocker at enqueue;
- capture-to-enqueue, admission wait, transport/guest round-trip, guest
  handler duration when reported, settlement wait, publication wait, total;
- superseded/canceled/refused/timed-out outcome; and
- whether the content and transition planes were actually armed in the
  resulting artifact.

Extend the existing `NOWBASE` grammar rather than inventing an unrelated log.
Expose the same bounded rows through the native inspector and existing MCP
read projection. Metrics reads must never initiate another poll.

## Implementation units

### U0. Reproduce and attribute the current delay

**Goal:** Prove which latency classes create the reported ~12-second waits
before changing queue behavior.

**Actions**

- Add trace IDs at `NOWMirrorSource.perform`, poll/enrichment submission,
  `GuestListener`, guest command/scene dispatch, operation settlement, and
  `MirrorStateEngine` publication.
- Measure the current pre-broker `pending` hold explicitly.
- Record the active request family and work purpose whenever another request
  is admitted.
- Add a deterministic fake-guest fixture that can delay admission, scene,
  command, reply, settlement, and publication independently.
- Add a bounded log summarizer that groups by build/session and refuses rows
  that cannot be attributed to one guest.
- Reproduce close, front, double-click/open, selection, scroll, and menu acts
  under a matrix of:
  - polling on/off;
  - Finder complements on/off;
  - visibility on/off;
  - content on/off; and
  - idle versus deliberately slow guest handlers.

**Verification**

- Mutation-watch each timing bracket by delaying only the layer it names.
- Prove a pre-broker observation hold appears as admission wait.
- Prove a fast dispatch plus 15-second unconfirmed postcondition appears as
  settlement wait, not guest work.
- Prove a Finder page delay names that command as the active blocker.
- Run focused host tests and the existing native timing tests.
- Take a PB1400c baseline with exact build, machine, port, and plane evidence.

**Decision gate:** If the metal delay is not Mirror-owned, record the owning
subsystem and re-scope before U1. Do not build a scheduler to improve a number
it did not cause.

**Commit boundary:** instrumentation and baseline evidence only.

### U1. Add the per-session guest work scheduler

**Goal:** Stop building an invisible FIFO inside the guest.

**Actions**

- Add `GuestWorkScheduler.swift` and `MirrorWorkClocks.swift`.
- Put the scheduler at the `GuestListener` session boundary. Route every
  request-shaped family through it and require its caller to supply a work
  class; retain direct transport paths only for protocol-critical frames.
- Classify scene polls, content joins/drains, Finder complements, visibility,
  semantic batches, and both act paths explicitly.
- Classify Files, Processes, Software, Console/command, capture initiation, and
  other module work so none can become an invisible FIFO ahead of an act.
- Keep protocol-critical `Session` traffic outside product priority.
- Coalesce ambient entries and cancel them on session change.
- Display active work, queued human count, blocker, and age in the existing
  Mirror inspector; project the same facts through MCP.
- Remove the `mutationWaiting` polling loop. An act enters the scheduler and
  journal synchronously even while a scene is active.

**Test scenarios**

- Human A then human B remain A/B while queued ambient work moves behind both.
- An active background slice finishes; no second background slice starts
  before the waiting gesture.
- Two invalidations of the same domain coalesce to the newest generation.
- A required postcondition read runs before enrichment but cannot starve a
  sustained sequence of gestures indefinitely.
- Stop/reconnect cancels old entries and late callbacks cannot publish.
- Bulk frame boundaries remain valid and transfer cancel still bypasses
  product work.
- A source-census mutation that restores one direct request send fails the
  focused gate by naming the bypassing family.

**Verification:** focused scheduler/source/listener tests, watched-fail priority
and stale-session mutations, then `scripts/test-host`.

**Commit boundary:** scheduler and Mirror caller migration, with action lanes
still preserving their current settlement behavior.

### U2. Unify action dispatch and separate settlement

**Goal:** One cell, one dispatch lane, many honestly tracked outcomes.

**Actions**

- Replace `MirrorDirectActLane` plus the dispatch portion of
  `MirrorMutationBroker` with one action queue owned by the scheduler.
- Keep `MirrorOperationJournal` as the durable bounded operation record.
- Track every correlation in a settlement ledger independent of the dispatch
  head.
- Classify operations that require a dependency barrier; make the default
  release boundary the guest's correlated reply, not a later scene.
- Revalidate session, target incarnation, coverage, and capability at dispatch.
- Preserve late confirmation after timeout and ring-eviction honesty.
- Keep native and agent faces on the exact same executor and scheduler.

**Test scenarios**

- A brokered act and direct act cannot collide in the resident cell.
- Four rapid scroll clicks dispatch in order without `act-busy`.
- A fast close reply followed by slow scene confirmation does not block an
  independent gesture.
- A dependent gesture waits for its barrier and revalidates against the new
  projection.
- Two similar postconditions remain attributable by correlation.
- Incomplete coverage cannot confirm deletion; late complete evidence can.
- A target disappearing while queued refuses before send.

**Verification:** broker/lane/clock/settlement tests, mutation-watch
shared-correlation and false-confirmation defects, emulator native Mirror drive,
then `scripts/test-host` and `scripts/test-native`.

**Cleanup gate:** delete the old direct lane only after source tests prove no
interaction path bypasses the unified scheduler.

**Commit boundary:** action admission/dispatch/settlement only.

### U3. Bound every Mirror-owned background slice

**Goal:** A gesture waits behind at most one measured safe slice.

**Actions**

- Give each automatic Finder page an explicit purpose-specific deadline based
  on U0 metal distributions; never inherit the generic 15-second default.
- Schedule front Finder container, visible foreground semantics, and required
  confirmation before desktop, background containers, and artwork.
- Bound visibility, content, and semantic batches; checkpoint after each.
- Retain last complete state and mark coverage partial/stale on timeout,
  cancellation, or supersession.
- Add guest-side handler-duration fields contract-first where current replies
  cannot attribute the slice.
- Split `now_scene_collect` only if U0 metal evidence shows one walk exceeds
  the budget. Any split owns no foreign address across a pump/yield.

**Verification**

- Long Finder results cannot start another page ahead of a queued gesture.
- Timeout preserves the previous complete roster and does not publish empty.
- Disabled complements schedule no work.
- Scene/content/semantic continuation rejects a changed base generation.
- Mutation-watch the per-slice deadline and stale-completion guard.
- Run focused host/native tests, `scripts/build-guests`, and the relevant
  emulator campaign.

**Commit boundary:** one background domain at a time, beginning with Finder.

### U4. Add guest invalidation generations

**Goal:** Ask because something changed, not merely because a timer fired.

**Actions**

- Update `contract/asyncapi.yaml` first with the optional symmetric change
  event and any echoed generation fields.
- Add a small normal-context guest coordinator that drains the existing P5
  transition tail without claiming it is complete.
- Make that coordinator the one owner of the shared P5 `reader_cursor`. It
  copies bounded records into an application-owned ledger and fans them out to
  the console/command face and wire invalidation producer; two consumers may
  not race the resident ring or make each other observe false absence.
- Reduce transition, act, self-known, and scene evidence into typed monotonic
  domain generations.
- Emit coalesced invalidation events from the guest's ordinary wire service,
  never from resident/OT interrupt context.
- Have the host scheduler turn an invalidation into the smallest sufficient
  request; a gap/drop/unknown source requests a full repair.
- Preserve cadence polling as compatibility and liveness fallback, then reduce
  its frequency only after invalidations survive the verification campaign.
- Keep event arming leased and optional. Absence, expiry, no passes, and drops
  remain distinct states.

**Resident change gate**

If the existing P5 vocabulary cannot cover a required domain:

1. record the exact missed mutation and why polling cannot safely cover it;
2. extend the shared table/tail accretively with layout asserts;
3. watch the native test fail against the exact packing/invalidating mutation;
4. run `scripts/build-guests` and extension tests;
5. perform a session-private bake with a matching receipt; and
6. test boot, disable, restart, shutdown, and fallback without the resident.

No shared image bake happens as part of an ordinary plan branch.

**Verification:** contract conformance, guest native tests, transition
gap/drop/expiry fixtures, two-face drain/fan-out tests, command parity,
old-peer compatibility, emulator wake/invalidation campaign, and PB1400c cost
measurement of the armed sampler.

**Commit boundary:** contract; guest producer; host consumer; optional resident
extension are separate commits.

### U5. Make state publication generation-coherent

**Goal:** Preserve progressive usefulness without presenting contradictory
partial state as a finished frame.

**Actions**

- Add typed contribution envelopes to `MirrorStateEngine`.
- Join structure, semantics, Finder, visibility, and content by session,
  structural sequence/digest, domain generation, and exact identity.
- Add a bounded publication coordinator inside the engine rather than a second
  cache or poller.
- Publish structural changes promptly; retain last-complete compatible
  contributions as explicitly stale; reject old-generation enrichment.
- Define useful atomic boundaries for front Finder pages and application
  content. Artwork never blocks semantic usability.
- Record publication reason and generation set in `MirrorProjection` metadata
  and the event stream.
- Ensure settlement reads the authoritative contribution store, never a
  provisional animation or host-only Finder selection.

**Test scenarios**

- An old Finder page arriving after navigation cannot repopulate the new
  folder.
- Visibility from sequence N cannot settle an operation against N+1.
- A partial roster cannot erase a prior complete roster.
- Structural front-window change publishes without waiting for background
  artwork.
- Related menu/control fields appear in one coherent projection.
- Rapid base/invalidation/enrichment sequences produce a deterministic list of
  immutable projections with no cross-session contribution.

**Verification:** reducer/state-engine/store/projection/render tests,
watched-fail stale-generation and false-empty mutations, paired native Mirror
and guest captures, then `scripts/test-mirrorkit` and `scripts/test-host`.

**Commit boundary:** contribution model first; publication policy second;
presentation diagnostics last.

### U6. Run the acceptance campaign and close the arc

**Goal:** Demonstrate responsiveness and state honesty on the actual target.

**Campaign**

- Freeze exact host, guest, resident, asset pack, machine, port, and policy
  identities.
- Establish positive controls for structural, transition, content, and act
  planes before interpreting absence.
- Through the native Mirror, run repeated close, front, double-click/open,
  select, scroll, menu, and drag gestures:
  - idle;
  - during scene observation;
  - during Finder front/background/desktop pages;
  - during visibility census;
  - during content drains; and
  - during a deliberately timing-out background operation.
- Record distributions, not one success: capture-to-admit, scheduler wait,
  guest round-trip, guest handler, settle, publish, and total.
- Verify that the guest/build answering and the physical machine are the ones
  reserved for the campaign.

**Acceptance**

- Zero gestures wait behind ambient work that was queued but not started.
- Human gesture order is preserved exactly.
- A gesture delayed by active work names that work and waits no longer than one
  declared slice budget plus measured transport overhead.
- Mirror-owned ambient work contributes at most 2,000 ms to an interactive
  wait on the PB1400c, or the plan is not complete and the measured exception
  returns to U3.
- No act is confirmed from incomplete, stale, provisional, or wrong-session
  evidence.
- No stale enrichment republishes after its base generation changes.
- Transition drops, expiry, resident absence, and old peers all fall back to an
  honest full/cadence observation.
- Resident armed cost and Mac OS memory growth remain within the existing
  resident safety ledger's accepted bounds; otherwise the resident portion is
  disabled and the polling fallback remains the product path.

**Closeout**

- Update `docs/status.md`, `docs/open-issues.md`,
  `docs/mirror-measurement-method.md`, and architecture/contract coverage only
  from the recorded campaign.
- Re-derive any declared derived document after the final merge.
- Run `scripts/test-all`; state explicit SKIPs.
- If `ext/` or `contract/peek_table.h` changed, satisfy the extension bake gate
  at the exact final source revision before landing.
- Record what is Built, Tested, emulator-verified, and Metal-verified
  separately.

**Commit boundary:** campaign evidence and durable closeout documents.

## Proposed module map

| Owner | Files |
|---|---|
| Host admission | `now-host/Sources/Host/GuestWorkScheduler.swift`, `MirrorWorkClocks.swift` |
| Host actions | `MirrorMutationBroker.swift`, `MirrorDirectActLane.swift` (retired after cutover), `MirrorOperationJournal.swift`, `NOWMirrorSource.swift` |
| Host state | `MirrorStateEngine.swift`, `MirrorSnapshotStore.swift`, `MirrorEventStream.swift`, projection/inspector models |
| Host transport | `GuestListener.swift`, `Session.swift` only at the typed scheduling/trace seam; frame safety remains owned there |
| Guest coordinator | new bounded module under `now-guest-ppc/src/mirror/`, plus `wire.c` integration |
| Guest bounded work | `scene/`, `input/input_cmds.c`, transition readers, content/semantic callers only where U0 proves a need |
| Shared contracts | `contract/asyncapi.yaml`; `contract/peek_table.h` and `event_tail.h` only through U4's resident gate |
| Tests | focused host scheduler/action/state tests, guest native fixtures added to `scripts/test-native`, contract/conformance tests, emulator and metal campaign harness |

Avoid growing `NOWMirrorSource.swift` into the scheduler, reducer, and metrics
owner. It remains the adapter between MirrorKit interaction/state and the
session-owned services above.

## Alternatives considered

### Guest-side urgent flag

Insufficient by itself. A flag travelling in the same TCP stream cannot be
read while the parser is blocked in the work it is meant to preempt. An OT
notifier may set a bounded wake/bytes-pending signal, but it cannot parse JSON,
run an act, allocate, or call ordinary Toolbox managers. Keep the signal as
diagnostic input unless a safe normal-context cancellation boundary consumes
it.

### Second urgent connection

Deferred. It complicates authentication, session identity, ordering, frame
ownership, and metal failure diagnosis. It is warranted only if U0/U3 prove an
irreducible single operation routinely exceeds the interaction budget and
cannot be split or canceled safely.

### One monolithic guest snapshot

Rejected for this arc. `NowScene` already aggregates the structural guest
view. Finder, visibility, resident transitions, and content are observed at
different instants and with different completeness. Serializing them into one
larger document creates false atomicity, more classic-Mac memory pressure, and
a longer uninterruptible operation. Generation-stamped contributions plus one
host reducer preserve both responsiveness and provenance.

### Publish every contribution immediately

This is close to the current behavior and is part of the reported jank. It
makes the internal state current at the cost of showing incompatible
intermediate cuts. U5 keeps progressive publication but gives each domain an
explicit useful boundary and generation join.

## Stop conditions

- The delay cannot be attributed to the Mirror session/build under test.
- A proposed priority change would reorder protocol-critical or bulk-frame
  safety traffic.
- Meeting the budget requires reentrant Toolbox work or retaining a foreign
  address across a yield.
- Dispatch/settlement separation loses exact correlation or permits an act
  against weaker state than today.
- An invalidation source can miss a mutation without reporting a gap,
  incomplete scope, expiry, or fallback.
- A resident change lacks exact shared-layout mutation evidence, a recovery
  path, or the required bake receipt.
- Emulator improvement does not reproduce on the PB1400c, or resident armed
  cost materially degrades the machine.
- The implementation introduces another poll owner, cache, or state authority
  beside `MirrorStateEngine`.

## Natural execution order

`U0 instrumentation and metal baseline -> U1 scheduler -> U2 unified action
lane -> U3 bounded background slices -> U4 invalidation generations -> U5
coherent publication -> U6 exact-revision campaign and closeout`

Each unit is independently reviewable and recoverable. The whole sequence is
the approved body of work if this plan is later handed off for implementation;
the unit boundaries are commit and verification gates, not default stopping
points.
