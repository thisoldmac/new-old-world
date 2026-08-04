---
title: NOW Mirror State Engine - Plan
type: refactor
date: 2026-08-04
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: ce-plan-bootstrap
execution: code
---

# NOW Mirror State Engine - Plan

## Goal Capsule

Build one guest-authoritative state engine per connected guest session. It reduces repeated full guest observations into a coherent replica, retains incomplete inactive subtrees as visibly expected-stale, accepts deletion only from machine-readable complete coverage, serializes mutations from the native Mirror, and publishes the same immutable snapshots and operation records to the Mirror and later MCP adapters.

This is the architectural prerequisite for resuming the broader [NOW Mirror UX Completion plan](2026-08-03-001-now-mirror-ux-completion-plan.md). It expands and supersedes that plan's U3 and U4 and refines the sequencing of U5 through U8. It does not claim that the known C26 product reds are fixed merely because the state engine exists.

Success means the direct-input Mirror can complete the mandatory sweep without the host destructively losing previously authoritative state, falsely treating dispatch as success, mixing guest sessions, or issuing parallel observations through MCP. The acceptance gate remains a person or agent looking at the native Mirror, driving it with keyboard and mouse, comparing its whole frame with authoritative guest evidence, and inspecting the correlated state, operation, settlement, and logs before scoring anything green.

## Product Contract

### Actors

- A1. A person uses the native NOW Mirror as a classic Mac surface with ordinary mouse and keyboard input.
- A2. The classic Mac guest owns applications, menus, windows, controls, content, focus, visibility, and mutation effects.
- A3. An MCP client inspects and, only after the native path is proven, mutates an explicitly addressed guest through the same state engine and operation broker.
- A4. A test operator uses QEMU as a development oracle for framebuffer capture and diagnostics without making QEMU part of production behavior.

### Flows

- F1. Bootstrap. The host reduces successive bounded full scene observations until it has a complete base application/window structure for the guest session. Enrichment and structured content may converge independently.
- F2. Reconcile. A new observation updates the covered portions of the replica. Missing, failed, truncated, or stale partitions retain their prior state as expected-stale; only fresh complete coverage can prove deletion.
- F3. Render. The native Mirror renders one immutable projection of the current replica, including explicit freshness and non-actionable stale state, without optimistic mutation.
- F4. Mutate. A direct gesture resolves against the displayed snapshot, enters a per-guest FIFO, revalidates a current capability, dispatches a typed operation, and settles only from later guest evidence.
- F5. Observe through MCP. MCP status, scene, search, and wait read the same published snapshots as the Mirror without starting an independent poll. Mutation parity is added only after the direct path passes.
- F6. Prove. A direct mouse/keyboard sweep captures stable Mirror pixels, authoritative guest pixels or an approved authoritative transient reference, state, operation, settlement, and logs. The worst evidence determines the score.

### Requirements

#### Authority, observation, and reconciliation

- R1. Guest observations are the sole authority for canonical guest state. Host state is a replica, not a second authority.
- R2. The contract carries machine-readable scope, owner, completeness, and retraction for every collection whose absence could otherwise be mistaken for deletion. Host behavior must not parse `meta.errors` prose for semantics.
- R3. Process and window lifetime identities are session-scoped and durable across ordinary reordering and title changes. Observation refs remain short-lived action capabilities and are never durable entity keys.
- R4. Observations are ordered by guest session and monotonic scene sequence. Replayed or out-of-order observations are rejected; guest wall-clock timestamps do not determine order.
- R5. Initial acquisition reduces repeated bounded full one-shot scenes. It does not add a continuous scene stream or delta protocol before measurement justifies one.
- R6. A fresh complete Process Manager census that omits a process may tombstone that application. A fresh complete per-application window collection that omits a window may tombstone that window. An incomplete, stale, failed, absent, or truncated parent collection must retain prior descendants as expected-stale.
- R7. Expected-stale is presentation-only. Presence certainty, freshness, completeness, provenance, and actionability are separate dimensions, and retained stale objects never authorize mutations.
- R8. A guest-session change atomically invalidates capabilities, queued work, pending settlement, and active projections. No menu, window, content, enrichment, or operation state crosses guest sessions.
- R9. NOW self-description, foreign application walks, Finder enrichment, menus, and structured content are independent observations with independent coverage and freshness.
- R10. Cross-application z-order must have an authoritative source or remain explicitly approximate with provenance and a red fidelity gate. Retained background trees must not be presented as authoritatively stacked when the guest did not prove their global order.
- R11. Content is retained by exact guest, process incarnation, window incarnation, display epoch, and generation. Partial or overwritten transfers cannot replace the last settled display, and geometry, layout, scroll, or incarnation changes invalidate incompatible retained display data.
- R12. Retention is bounded by explicit count, byte, and age policies. Eviction changes presentation only; it must never synthesize deletion evidence or mutation authority.

#### State engine ownership and projections

- R13. One state engine per pinned guest-session incarnation owns scene polling and coalescing, normalization, replica reconciliation, enrichment, content lifecycle, mutation serialization, settlement, journal, snapshot publication, digest, and generation. A reconnect creates an explicit successor incarnation rather than silently resetting an engine in place.
- R14. The native Mirror and MCP clients consume the same immutable snapshot IDs, entity identities, freshness, completeness, and operation records.
- R15. `NOWMirrorSource` becomes a thin cadence and UI adapter. The Apple-only continuity reducer, `LiveMirrorController` stale-window cache, content retention, and settlement tracking migrate into general engine-owned components and are removed only after mutation-proven parity.
- R16. The active guest picker and an open Mirror binding remain distinct. A Mirror is pinned to one guest session; changing the picker does not silently retarget it.
- R17. Canonical state never changes optimistically. Local hover, pressed, drag, selection-preview, or open-menu state is explicitly provisional and cannot be reported as guest settlement.

#### Mutation and settlement

- R18. A gesture resolves against the displayed snapshot and stable entity identity. Dispatch revalidates the current guest session, current observation, advertised typed capability, and target identity; there is no coordinate, generic-click, QMP, or title-only fallback.
- R19. One FIFO per guest serializes human and later MCP mutations with operation ID, source, displayed snapshot, target, postcondition, timestamps, outcome, and bounded evidence.
- R20. Dispatch is not success. Only later authoritative evidence may confirm a mutation, and absence can settle deletion only when the relevant observation scope is complete.
- R21. Timeout remains non-green but can be augmented by a later confirmation. Refusal and session change are explicit terminal outcomes.
- R22. Direct keyboard and mouse mutation ships first. MCP mutation parity may follow when it is a thin adapter over the same broker and cannot be used to substitute for the native UX gate.

#### Fidelity and acceptance

- R23. Every sweep begins with the documented preflight: visually validate Workshop; validate the menubar and Apple rows; resize and close Workshop; double-click Macintosh HD; validate Finder; hide Finder through the native Application menu; then test Date & Time. Workshop reopen and same-application window activation remain permanent regression rows.
- R24. Stable guest UI compares a native Mirror frame with a same-state authoritative guest framebuffer using a stability sandwich: stable snapshot A, both captures, stable snapshot B with the same digest and no intervening operation.
- R25. Mirror-owned transient overlays such as an open dropdown cannot be compared to a same-moment guest framebuffer in which the dropdown is closed. They require a genuine guest transient reference or guest-provided structured geometry/content, plus a direct Mirror selection that settles to an authoritative postcondition and a same-moment post-action capture. An unproven transient row stays unscored.
- R26. QMP is a read-only development-oracle adapter for explicit-socket `screendump` and identity checks. No production module imports it, no mutation uses it, and the architecture must run unchanged on metal.
- R27. Bitmap, PICT, manually drawn background, and raw pixel transport remain deferred. Declared placeholders are acceptable; missing structured text, controls, lists, and windows remain red.
- R28. No row is green from MCP/API capability, host pixels, guest pixels, state, logs, or settlement alone. The correlated bundle and direct interaction are all required.

### Key Technical Decisions

- KTD1. `session-settled: user-directed` — Use one guest-authoritative host replica with Mirror and MCP as clients. Rejected: treating each full scene as a destructive replacement or letting each client poll independently.
- KTD2. `session-settled: user-approved` — Add contract-level typed coverage and identity before generic reconciliation. Rejected: generalizing the Apple empty-shell exception or parsing English error strings.
- KTD3. `session-settled: user-directed` — Retain inactive application trees as expected-stale after initial acquisition. Rejected: erasing background state whenever an app is not freshly walkable.
- KTD4. `session-settled: user-directed` — Prioritize native keyboard and mouse input; add MCP parity later when cheap and shared. Rejected: using MCP-only success as the implementation or acceptance path.
- KTD5. `session-settled: user-directed` — Keep raw guest-pixel piping out of the core and defer it until structured behavior is proven. Rejected: making pixel transport load-bearing for normal applications.
- KTD6. `session-settled: user-directed` — QEMU remains an oracle, never an implementation dependency. Rejected: QMP input or QEMU-specific state mechanisms.
- KTD7. `session-settled: user-approved` — Preserve canonical guest state until evidence changes it; pending intent lives alongside it. Rejected: optimistic canonical mutation followed by rollback.
- KTD8. `session-settled: user-approved` — Implement the state engine in shadow mode before read or mutation cutover. Rejected: replacing the current high-water path in one step.

### Deletion-proof truth table

| parent scope | coverage | child missing | replica result | actionable |
|---|---|---:|---|---:|
| current guest/session and the authoritative parent collection that owns the child | fresh and complete for that collection | yes | tombstone child | no |
| current guest/session and the authoritative parent collection that owns the child | fresh and complete for that collection | no | replace authoritative fields | only with current capability |
| current guest/session | partial, truncated, stale, failed, or absent | yes | retain child as expected-stale | no |
| old or different guest/session | any | any | reject observation; clear on explicit session replacement | no |
| no prior child | partial, truncated, stale, failed, or absent | yes | keep unknown; invent nothing | no |

### Non-goals

- No scene streaming or delta wire protocol in this plan.
- No raw framebuffer, PICT, or bitmap transport into the Mirror.
- No coordinate/QMP mutation fallback.
- No reinstalling legacy resident components or reintroducing their runtime ports.
- No claim that the state engine by itself repairs guest-side menu tracking, application visibility, missing structured producers, cross-app ordering, or every C26 fidelity red.
- No release artifact while the mandatory core flow has a blocking red.

## Planning Contract

### Baseline and scope

The implementation begins at checkpoint commit `693324a` on `codex/recover-ptolemy-ux-loop`. The durable baseline is [Mirror high-water checkpoint — 2026-08-04](../mirror-high-water-checkpoint-2026-08-04.md), including exact host and guest identities, C26 paired captures, passing behaviors, known reds, and the Apple-menu mutation guard.

This plan owns the state-engine prerequisite. It supersedes U3 and U4 of [NOW Mirror UX Completion](2026-08-03-001-now-mirror-ux-completion-plan.md). On completion, the broader plan resumes at its interaction, renderer, structured-content, MCP work beyond the state-engine read parity and any enabled mutation parity delivered by U7, and final-campaign work, updated to consume the engine rather than create a second broker or scene store.

### Module map

```text
guest producers
  scene + typed coverage + lifetime identity
  NOW self | foreign tree | Finder enrichment | structured content | settlement
                    |
                    v
Host/MirrorStateEngine per GuestKey/session
  observation normalizer -> pure replica reducer -> immutable snapshot store
  enrichment/content reducers                 -> projection publisher
  typed mutation FIFO -> executor -> settlement reducer -> operation journal
                    |
          +---------+---------+
          |                   |
          v                   v
NOWMirrorSource facade   MCP local adapter, later
  MirrorKit.Scene            same snapshots
  native gestures            same queue
```

### Ownership boundaries

- `mirror/host/MirrorKit/Sources/MirrorKit` owns pure observation, identity, replica, reconciliation, projection, and operation state types with no host transport or QMP dependency.
- `now-host/Sources/Host` owns per-session polling, store registry, action execution, content/enrichment producers, journaling, pinning, and publication.
- `NOWMirrorSource` owns UI cadence and translation between immutable engine projections and the existing `LiveMirrorSource` protocol.
- `NOWAgentIntegration` owns transport-neutral snapshot and operation DTOs. The companion and MCP projection do not own polling or reconciliation.
- `now-guest-ppc` owns authoritative observation coverage, stable process/window incarnation facts, typed capabilities, and settlement evidence.
- `tools/mirror-gate`, `tools/shot`, and `tools/mirror-diff` own test evidence only. They are not linked into production targets.

### Native Mirror presentation contract

| engine state | retained frame | visible treatment | mutations | recovery action |
|---|---|---|---|---|
| acquiring base structure | last same-session frame if one exists; otherwise desktop loading shell | progress names the missing authoritative scope without drawing it empty | disabled | wait or close Mirror |
| fresh and complete | current immutable projection | normal native presentation | enabled only for current advertised capabilities | none |
| partial current observation | current covered fields plus compatible retained subtrees | affected retained regions carry an expected-stale treatment and status names the incomplete producer | disabled for affected entities; fresh unrelated entities remain eligible | automatic retry |
| complete-empty scoped collection | collection is visibly empty | normal empty state, never a stale placeholder | no child target exists | none |
| producer failed or retrying | last compatible same-session contribution | expected-stale treatment and bounded failure reason | disabled for affected entities | automatic retry plus inspectable status |
| disconnected | last same-session snapshot remains visible | persistent disconnected banner names the pinned guest and says the frame is retained | all disabled | reconnect that guest, open a different guest explicitly, or close |
| session replaced | no old actionable projection; the old retained frame may remain only as a clearly frozen transition surface until the new base barrier completes | persistent session-changed banner names old and new session identity | all disabled until new base structure is complete | wait for acquisition or close |

The pinned guest identity is always visible in Mirror status independent of the active picker. Changing the picker never changes that label or the open Mirror. Reconnect resumes only when the same logical binding establishes a new explicit session transition; opening another guest creates or focuses that guest's separate binding rather than silently retargeting the window.

### Native operation feedback contract

| operation state | immediate feedback | persistent record | clearing rule |
|---|---|---|---|
| gesture preview | native highlight, press, drag, or menu tracking only | none | clear on release, cancel, disablement, or session change |
| queued | bounded status names action and target without sensitive payload | operation ID, source, snapshot, target, enqueue time | advance on dispatch or terminal pre-dispatch refusal |
| dispatched and awaiting evidence | preview clears; status says awaiting guest confirmation | dispatch receipt plus postcondition and deadline | advance only from authoritative settlement, timeout, refusal, or session change |
| refused | visible non-success reason; canonical pixels remain guest-derived | terminal refusal with evidence source | retain in journal; transient status clears on the next human action after remaining inspectable |
| timed out | visible unconfirmed outcome, never success | timed-out record remains eligible for late evidence | late confirmation augments the same record; a new action does not erase it |
| confirmed | no optimistic patch; the next authoritative projection shows the effect | confirmed record and settling snapshot | transient success may clear after the settled frame is presented; journal remains bounded |
| confirmed after timeout | visible late-confirmation update tied to the original action | original timed-out record is augmented, not replaced | clear like confirmed after the update has been presented |
| session changed or cancelled | visible terminal reason and frozen preview cleared | terminal record with old session identity | clear transient status only after the person acknowledges the new binding or begins a new action |

Human feedback and agent-attributed journal rows are distinct. An agent operation may update shared guest pixels but cannot overwrite the latest human-operation status. Typed text, file contents, raw payloads, and arbitrary paths are excluded from operation labels and the journal.

### Dependencies and ordering constraints

- The unified NOW Extension work and extension-only guest image remain prerequisites already completed by the preceding plan. New extension changes made here must be rebuilt and staged before final verification.
- U1 must land contract additions before U2 implements deletion behavior.
- U3 runs the engine in shadow mode while the checkpoint path remains the visible authority. Read cutover cannot occur until replay and live parity pass the complete preflight.
- U6 routes native input before U7 adds MCP mutation parity.
- The Apple continuity reducer and stale-window cache remain until watched mutations prove the general reducer catches their regressions.
- No unit may stop or replace the retained checkpoint VM merely for convenience. Final image promotion is a separate, explicit U8 action with a clean shutdown.

### Retention and digest defaults

- The semantic replica retains at most the contract's current-session bounds: 40 processes, 64 windows, 16 menus, 96 pooled menu rows, 96 controls, and 96 dialog items. It keeps one current record per lifetime identity plus a tombstone only until every pending operation older than that tombstone is terminal.
- Structured display retention keeps one last-settled display per window, at most 64 KiB per window and 4 MiB per guest-session incarnation. Least-recently-visible background content is evicted first; structural entities remain. Content unused for 24 hours or belonging to a session disconnected for 24 hours is evicted even if its frozen structure remains visible.
- Published snapshot history retains the current snapshot plus 31 predecessors, with a 15-minute maximum age. Waiters hold the exact snapshot they need independently until completion or session cancellation.
- The operation journal retains 128 records or 24 hours, whichever bound is reached first. Nonterminal and timed-out-but-late-settle-eligible records cannot be evicted; backpressure refuses a new mutation rather than discarding unresolved evidence.
- Exported evidence is not part of the live retention cache. It is an explicit test artifact governed by the checkpoint workflow.
- The semantic snapshot digest canonicalizes collection and entity ordering and includes authoritative replica fields, typed coverage, provenance, actionability, and content generations. It excludes snapshot ID, observation sequence, receive time, derived wall-clock age, operation metadata, and UI-only transient state. U2 implements this once and U3, U4, replay tests, and the stability sandwich call the same function.

### Acquisition and shadow-cutover gates

The mandatory base scopes are one complete Process Manager census plus a typed window-membership claim for every enumerated process. A base is complete only when the census and every membership claim are fresh and complete in one accepted observation sequence. Enrichment, menu semantics, controls, and content remain independently progressive after that structural barrier.

Acquisition retries at the normal scene cadence for five accepted observations and at least 15 seconds. If the base still cannot complete, the engine publishes a terminal degraded snapshot containing only proven current structure plus compatible retained state, names every blocking scope, disables unknown or retained targets, and continues background retry. A degraded snapshot is inspectable but cannot satisfy U3 shadow parity, U5 read cutover, or a direct campaign green row.

| shadow comparison | cutover rule |
|---|---|
| guest/session, front application, and front window | exact equality; any cross-session contribution blocks |
| fresh applications, windows, menus, controls, text, geometry, visibility, and structured content | exact authoritative equality; any loss or changed value blocks |
| expected-stale entities | engine may retain a legacy-dropped entity only when it is marked stale, non-frontmost, and non-actionable |
| deletion | engine-only deletion requires recorded complete parent coverage; unexplained deletion blocks |
| actionability | stale or incomplete targets must be disabled; any engine action enabled from weaker evidence blocks |
| provenance, coverage, and status labels | engine may add truthful metadata; it may not hide a legacy error or present partial as empty/current |
| snapshot IDs, receive times, sequence metadata, and bounded diagnostics | expected implementation differences; excluded from semantic parity |
| whole-frame output | menubar, Apple rows, Workshop, Finder, Date & Time, modal order, and retained structured content cannot regress from the checkpoint |

U3 records every mandatory preflight transition against this matrix. U5 cutover requires zero blocking differences across two consecutive complete sweeps, including watched stale, incomplete, reconnect, and session-change cases; a reviewer preference cannot waive a blocking row.

### Risks and controls

- Incorrect completeness could delete real UI state. Control: typed scopes, truth-table tests, shadow comparison, and conservative retain-on-unknown behavior.
- Process serial numbers, pointers, and window IDs can be reused. Control: session-scoped process/window incarnation identity plus capability leases bound to observation revision.
- Cross-application z-order may remain unobservable. Control: explicit provenance and red scoring until an authoritative portable source is proven.
- Cooperative guest work can be starved by duplicate polls or content drains. Control: one session-addressed poll owner, coalescing, action priority, and queue-wait metrics.
- Shadow and legacy caches can disagree. Control: emit bounded structured diffs, preserve the visible baseline, and remove old caches only after mutation-proven equivalence.
- Direct evidence can compare different states. Control: snapshot stability sandwich, explicit QMP socket and guest/build identity, and no green score while an operation is nonterminal.
- A host-local transient may have no same-moment framebuffer analogue. Control: genuine guest transient reference rule in R25; keep unproven rows unscored.

## Implementation Units

### U1. Add authoritative observation coverage and lifetime identity

**Goal:** Make the guest contract sufficient for deletion-safe, session-scoped reconciliation.

**Requirements:** R1-R6, R8-R10.

**Dependencies:** Checkpoint `693324a` and the unified NOW Extension prerequisite.

**Files:**

- `contract/asyncapi.yaml`
- `mirror/docs/IR-V1.md`
- `mirror/docs/IR-V2.md`
- `mirror/host/MirrorKit/Sources/MirrorKit/IRSchema.swift`
- `mirror/host/MirrorKit/Sources/MirrorKit/Scene.swift`
- `now-guest-ppc/src/scene/scene.h`
- `now-guest-ppc/src/scene/scene_collect.c`
- `now-guest-ppc/src/scene/scene_json.c`
- `now-guest-ppc/src/observe/obsref.h`
- `now-guest-ppc/src/act/act_cmds.c`
- `now-guest-ppc/src/observe/observe.c`
- `now-guest-ppc/src/processes/proc_actions.c`
- `now-guest-ppc/tests/scene_walk_test.c`
- `now-guest-ppc/tests/scene_json_test.c`
- `now-guest-ppc/tests/act_args_test.c`
- `now-host/Tests/HostTests/SceneIRDecodeTests.swift`
- `now-host/Tests/HostTests/GuestWireConformanceTests.swift`

**Approach:**

- Treat the already-live IR v2 semantic-evidence contract as the baseline. Add collection coverage and identity as additive v2 fields, update the existing IR-v2 schema manifests and documentation, and preserve its current v1-read-only compatibility behavior.
- Carry a session-scoped process incarnation and window incarnation independent from display order, title, pointer, and act ref. If the guest cannot yet prove a lifetime boundary, encode uncertainty and refuse deletion or mutation rather than fabricate stability.
- Preserve opaque act refs as replaceable capability leases with the observation revision that minted them.
- Add exact guest-minted Finder-item and application-visibility capabilities bound to guest session, entity incarnation, and observation revision. These replace the current Finder item-name/window-title and application-name scripts for action-bearing paths while retaining human-readable names only for presentation and diagnostics.
- Encode process census, each app's window membership, menu rows, NOW self, foreign tree, Finder enrichment, structured content, and global layer order as distinct claims.
- Keep v1 decoding conservative and read-only where completeness or lifetime identity is unavailable.
- Define how each deletion-authorizing producer earns `complete`: Process Manager must reach the end without cap, loop, or API error; each app window walk must reach the end without cap, bad pointer, owner mismatch, stale anchor, reader fault, or unsupported path; Finder item membership must enumerate the exact container without AppleEvent error; menus must finish both the menu list and every owned row collection; structured content must finish the display epoch with no lost or overwritten interval; global layer order remains unavailable unless one portable source proves the whole stack. Every early exit, retry, truncation, allocation failure, and producer error must emit partial, retracted, failed, or unavailable before returning.
- Document the deletion truth table normatively. English diagnostic errors remain for people but cannot drive reducer semantics.

**Test scenarios:**

- Complete-empty, absent, retracted, failed, stale, and truncated collections decode to distinct typed states.
- A process omitted from a complete census is distinguishable from one missing after truncation.
- Duplicate titles, title changes, occurrence reordering, pointer reuse, and ref eviction do not collapse lifetime identities.
- Finder-item and application-visibility capabilities survive an ordinary refetch by reacquiring the same entity, refuse after eviction or session change, and cannot select a same-named item or app outside their exact owner.
- The same PSN and address on two guest sessions remain distinct.
- V1 cannot authorize deletion or mutation from an ambiguous omission.

**Verification:** Run `scripts/test-native`, `swift test --package-path now-host --filter SceneIRDecodeTests`, `swift test --package-path now-host --filter GuestWireConformanceTests`, and contract-derived tests. Watch mutations that flatten retracted into empty, mark each forced early-exit path complete, and use an act ref as entity identity fail before U1 is complete.

**Cleanup gate:** Do not remove v1 decode until all staged guests advertise v2 and the compatibility policy explicitly permits it.

### U2. Implement the pure replica and operation reducers

**Goal:** Make reconciliation and settlement deterministic, replayable, conservative, and independent of polling or UI.

**Requirements:** R1-R12, R17, R19-R21.

**Dependencies:** U1.

**Files:**

- `mirror/host/MirrorKit/Sources/MirrorKit/GuestSceneObservation.swift` (new)
- `mirror/host/MirrorKit/Sources/MirrorKit/MirrorEntityIdentity.swift` (new)
- `mirror/host/MirrorKit/Sources/MirrorKit/MirrorReplica.swift` (new)
- `mirror/host/MirrorKit/Sources/MirrorKit/MirrorReplicaReducer.swift` (new)
- `mirror/host/MirrorKit/Sources/MirrorKit/MirrorOperation.swift` (new)
- `mirror/host/MirrorKit/Sources/MirrorKit/MirrorOperationReducer.swift` (new)
- `mirror/host/MirrorKit/Sources/MirrorKit/MirrorProjection.swift` (new)
- `mirror/host/MirrorKit/Tests/MirrorKitTests/MirrorReplicaReducerTests.swift` (new)
- `mirror/host/MirrorKit/Tests/MirrorKitTests/MirrorOperationReducerTests.swift` (new)
- `now-host/Tests/HostTests/Fixtures/mirror-c26/` (new)

**Approach:**

- Implement pure reducers whose inputs include guest key, session, monotonic sequence, source, coverage claims, receive time, entities, enrichments, content epochs, and settlements.
- Track presence certainty, freshness, completeness, provenance, actionability, and last-authoritative revision independently.
- Reduce repeated full observations incrementally. Establish a base-structure completeness barrier before declaring initial load complete; allow independent producers to converge later.
- Tombstone only through the U1 truth table. Retain unresolved inactive subtrees expected-stale and force them non-frontmost and non-actionable.
- Reject out-of-order observations and isolate every record by guest session.
- Invalidate incompatible content when window lifetime, geometry, layout, scroll, owner epoch, or content generation changes.
- Model pending operations separately from canonical state. Settlement consumes later authoritative observations and their completeness claims.
- Record the C26 observation histories and paired metadata as deterministic fixtures without embedding private paths or raw user data.

**Test scenarios:**

- First load includes complete foreground and background application/window trees.
- Idempotent replay produces the same snapshot digest and no duplicate changes.
- Every render-, coverage-, provenance-, actionability-, and content-generation change changes the semantic digest; sequence, receive-time, snapshot-ID, wall-clock-age, operation, and UI-transient-only changes do not.
- Out-of-order scenes are rejected.
- Incomplete absence retains expected-stale; complete scoped absence tombstones.
- Fresh data atomically replaces retained stale data.
- Process/window reuse, ref eviction, duplicate titles, and two guests with overlapping identities remain isolated.
- Disconnect retains a displayable but inert snapshot; session replacement clears it atomically.
- A dispatched operation stays pending until a later complete matching observation; a partial scene cannot confirm close by omission.
- Timeout can later become confirmed-after-timeout, while refusal and session change stay terminal.
- Retention limits evict presentation data without manufacturing guest deletion.

**Verification:** Run focused MirrorKit reducer suites and replay the C26 fixture sequences. Mutation-watch deleting on any miss, leaving stale windows frontmost, accepting an old sequence, crossing guest keys, confirming on dispatch, and confirming close from partial absence.

**Cleanup gate:** None; U2 is additive and cannot change the visible Mirror yet.

### U3. Add session-addressed host plumbing and a shadow state engine

**Goal:** Feed one engine per pinned guest-session incarnation from live scenes without changing the visible checkpoint behavior.

**Requirements:** R4-R16.

**Dependencies:** U2.

**Files:**

- `now-host/Sources/Host/GuestListener.swift`
- `now-host/Sources/Host/HostAppState.swift`
- `now-host/Sources/Host/GuestScopedState.swift`
- `now-host/Sources/Host/MirrorStateEngine.swift` (new)
- `now-host/Sources/Host/MirrorStateEngineRegistry.swift` (new)
- `now-host/Sources/Host/MirrorSnapshotStore.swift` (new)
- `now-host/Sources/Host/MirrorEngineDiagnostics.swift` (new)
- `now-host/Sources/Host/NOWMirrorSource.swift`
- `now-host/Sources/Host/NOWMirrorWindow.swift`
- `now-host/Tests/HostTests/GuestListenerTests.swift`
- `now-host/Tests/HostTests/MirrorStateEngineTests.swift` (new)
- `now-host/Tests/HostTests/MultiGuestFocusTests.swift`
- `now-host/Tests/HostTests/NOWMirrorSourceTests.swift`

**Approach:**

- Make pending scene, command, and content-lane state addressable by `GuestKey` and session before creating per-session brokers.
- Instantiate one state engine per pinned guest session through `HostAppState`; coalesce simultaneous refresh requests and preserve action priority over new bulk work.
- Capture an explicit `GuestKey` when the Mirror opens, bind `NOWMirrorSource` and `NOWMirrorWindow` to that engine handle, and pass the key through every scene request rather than consulting the active picker.
- Normalize the existing scene envelope and U1 coverage into `GuestSceneObservation`, reduce it, and publish immutable snapshots with ID, guest/session, sequence, digest, completeness, freshness, content generations, and provenance.
- Run the engine in shadow mode while the current `NOWMirrorSource` remains visible. Emit structured bounded diffs between legacy projection and engine projection across the full preflight.
- Preserve the current Apple continuity and `LiveMirrorController` caches during shadowing. Do not let shadow state authorize actions.
- Pin each Mirror binding to one guest session; active picker changes do not retarget it.

**Test scenarios:**

- Concurrent Mirror, wait, and diagnostic refreshes create one guest scene request.
- Two guest sessions with overlapping PSNs, titles, and refs retain isolated replicas and journals.
- Active-picker changes leave an open Mirror pinned.
- Session replacement wakes waiters, cancels queued work, and cannot inherit state or capabilities.
- Shadow replay produces deterministic digests and bounded understandable diffs.
- Initial load does not publish complete until base application/window coverage is complete.

**Verification:** Run `swift test --package-path now-host --filter MirrorStateEngineTests`, `GuestListenerTests`, and `MultiGuestFocusTests`, then exercise the full direct preflight while shadow diagnostics record parity. Watch a duplicate-poller mutation and a global-pending-scene mutation fail.

**Cleanup gate:** Shadow mode remains until every preflight state transition has a reviewed parity record and no unexplained engine-only deletion.

### U4. Integrate enrichment, structured content, and snapshot evidence

**Checkpoint 2026-08-04:** Same-sequence render enrichment, app-owned frame
export, the separate `MirrorOracleKit` executable adapter, and platform-neutral
production target/action vocabulary are implemented and focused-tested.
Explicit-socket oracle capture and guest/session/build identity joins are also
implemented and mutation-watched. QuickDraw overwrite recovery now retains its
last settled contribution until a newer guest epoch/generation completes.
Inactive and frontless observations now retain each exact window's independently
published display as expected-stale instead of clearing it or exposing a partial
replacement. The first direct U4E sweep caught this distinct transition and U4F
is focused-tested and mutation-watched. The remaining U4 work is typed coverage
for the other enrichment producers, any missing operation/log export joins, the
exact latest resident/guest stage, and live stability-sandwich shadow-parity
evidence across the complete preflight.

**Goal:** Make all render-bearing producers converge through the same replica and emit the evidence required by the strict gate.

**Requirements:** R9-R14, R23-R28.

**Dependencies:** U3.

**Files:**

- `now-host/Sources/Host/NOWMirrorContentPlane.swift`
- `now-host/Sources/Host/NOWMirrorSource.swift`
- `now-host/Sources/Host/MirrorStateEngine.swift`
- `now-host/Sources/Host/MirrorEvidenceExporter.swift` (new)
- `now-host/Sources/Host/ActLog.swift`
- `now-host/Sources/Host/HostLog.swift`
- `now-host/Tests/HostTests/NOWMirrorContentPlaneTests.swift`
- `now-host/Tests/HostTests/MirrorStateEngineTests.swift`
- `tools/mirror-gate`
- `tools/shot`
- `tools/mirror-diff`
- `tools/mirror-gate-tests/test_mirror_gate_evidence.py`
- `docs/mirror-drive-loop.md`
- `mirror/host/MirrorKit/Package.swift`
- `mirror/host/MirrorKit/Sources/MirrorKit/ActionModel.swift`
- `mirror/host/MirrorKit/Sources/MirrorKit/ActionDispatcher.swift`
- `mirror/host/MirrorKit/Sources/MirrorKit/InteractionBridge.swift`
- `mirror/host/MirrorKit/Sources/MirrorKit/QmpClient.swift`
- `mirror/host/MirrorKit/Sources/MirrorOracleKit/` (new)

**Approach:**

- Convert NOW self, foreign walk, Finder positions/icons, menu rows, and structured content into independently fresh engine contributions keyed by exact identities.
- Generalize `NOWMirrorContentPlane` rules so partial pages, overwritten rings, stale generations, and retargeting cannot destroy last-settled compatible display data.
- Add an app-owned native Mirror frame export tied to an exact published snapshot. It observes host pixels only and never drives the guest.
- Emit snapshot ID, scene/content generations, owner epoch, operation ID, settlement, host log, guest act log, quiescence, and input provenance in the evidence manifest.
- Require `tools/shot` to receive an explicit QMP socket and assert guest/build identity; remove newest-socket guessing.
- Split QMP from the production `MirrorKit` product: move `QmpClient` and QMP-only action/dispatcher behavior into a `MirrorOracleKit` target consumed only by legacy `MirrorApp` and test tooling. Remove QMP cases and target fields from the core action model and verify the native NOW Host links only QMP-free `MirrorKit` and `MirrorKitUI` products.
- Add the stability sandwich and transient-oracle rule to `docs/mirror-drive-loop.md` and gate validation.
- Keep `tools/mirror-diff` a veto and diagnostic aid; human whole-frame judgment remains necessary for green.

**Test scenarios:**

- The Workshop overwritten-ring C26 history retains the last settled compatible display and reports lost new bytes without publishing a blank replacement.
- A window resize or content epoch change invalidates incompatible retained operations.
- The evidence exporter refuses a frame whose snapshot changed during capture.
- The gate refuses implicit QMP socket selection, wrong guest/build, missing operation join, nonterminal operation, MCP/API-only input, and mismatched stability digests.
- A transient dropdown without a genuine guest reference remains unscored even when its post-action settles.

**Verification:** Run `NOWMirrorContentPlaneTests`, `MirrorStateEngineTests`, and `python3 tools/mirror-gate-tests/test_mirror_gate_evidence.py`. Mutation-watch partial content replacement, implicit socket selection, missing direct-input provenance, and unequal stability digests.

**Cleanup gate:** Existing ad hoc evidence fields remain accepted only until one full direct sweep produces the new correlated manifest; then remove the compatibility path and update fixtures in the same commit.

### U5. Cut native Mirror reads over to the engine

**Goal:** Make the visible native Mirror a thin projection client without losing the checkpoint's high-water behavior.

**Requirements:** R13-R17, R23-R28.

**Dependencies:** U4 and reviewed shadow parity across the full preflight.

**Files:**

- `now-host/Sources/Host/NOWMirrorSource.swift`
- `now-host/Sources/Host/NOWMirrorWindow.swift`
- `mirror/host/MirrorKit/Sources/MirrorKitUI/LiveMirror.swift`
- `mirror/host/MirrorKit/Sources/MirrorKit/Scene.swift`
- `now-host/Tests/HostTests/NOWMirrorSourceTests.swift`
- `now-host/Tests/HostTests/SceneRenderTests.swift`
- `now-host/Tests/HostTests/SceneHitTestTests.swift`

**Approach:**

- Publish the engine's immutable `MirrorProjection` through `NOWMirrorSource`; keep UI-owned transient gesture state separate from canonical state.
- Expose freshness and actionability to rendering and hit testing. Expected-stale entities remain visible and visibly stale where appropriate but have no mutation target.
- Preserve current menubar geometry, Apple rows, Workshop, Finder, modal ordering, and window chrome as regression floors.
- Remove the Apple-only reducer and `LiveMirrorController` stale-window cache only after watched mutations show the engine's generic tests fail when either behavior regresses.
- Keep a runtime rollback switch for one development checkpoint; remove it after the direct read-only sweep is fully correlated and reviewed.

**Test scenarios:**

- Empty Apple shell retains same-session rows expected-stale; complete fresh rows replace them; initial empty invents nothing; guest switch never reuses them.
- Background application and same-app window trees persist expected-stale without remaining frontmost or actionable.
- Menubar and native Application menu do not collide or duplicate.
- Workshop close, Macintosh HD open, Finder rendering, Date & Time, modal stacking, and same-app selection preserve snapshot identity through the projection.

**Verification:** Run focused source/render/hit tests and the entire direct-input preflight without routing mutations through the new queue yet. Compare stable whole frames against the C26 baseline and fresh guest captures. Watch the existing Apple mutation guard and a migrated stale-window mutation fail.

**Cleanup gate:** Remove the legacy read projection, rollback switch, Apple-only continuity, and controller cache in one reviewable commit only after the new path passes the preflight. Never leave two visible replica owners.

**2026-08-04 U5 read-cutover checkpoint.** Production `HostAppState` now
installs one session engine and `NOWMirrorSource` publishes that engine's
immutable scene. The pre-reduction candidate remains diagnostic comparison
input only; registry-free source fixtures retain an explicit fallback. A
watched mutation that returned the fallback after a snapshot existed made
`testVisibleSceneComesFromTheSessionEngineAfterCutover` fail, then the engine
selection was restored. All 21 source tests and all 10 engine tests pass, and
the Xcode Debug app target builds.

The rebuilt app replaced exactly one host while retaining the same VM. Direct
mouse input verified the complete Apple menu, application activation, exact
window fronting as far as the stale guest permits it, and Date & Time content
acquisition. The engine retained Date & Time's 162 structured operations after
Finder became front. The cold-host run also made an existing coverage hole
plain: already-open Finder windows initially have their structure but no item
content, and the stale guest still refuses `winact select`; those rows remain
red. Workshop was already closed, so application selection correctly did not
recreate it; only `Windows > Workshop` is the reopen failure. U6 owns truthful
operation classification; U8 owns staging the current guest that serves
`select`. This checkpoint is directly exercised and tested, not a green full
preflight and not metal-verified.

### U6. Route direct human mutations through the serialized broker

**Goal:** Make native mouse and keyboard actions settle truthfully against the same engine that rendered their targets.

**Requirements:** R17-R28.

**Dependencies:** U5.

**Files:**

- `now-host/Sources/Host/MirrorMutationBroker.swift` (new)
- `now-host/Sources/Host/MirrorActionExecutor.swift` (new)
- `now-host/Sources/Host/MirrorOperationJournal.swift` (new)
- `now-host/Sources/Host/NOWMirrorSource.swift`
- `now-host/Sources/Host/Automation/AgentIntegrationActControl.swift`
- `now-host/Sources/Host/MirrorSettlementTracker.swift`
- `mirror/host/MirrorKit/Sources/MirrorKit/InteractionPolicy.swift`
- `mirror/host/MirrorKit/Sources/MirrorKitUI/LiveMirror.swift`
- `now-host/Tests/HostTests/MirrorStateEngineTests.swift`
- `now-host/Tests/HostTests/AgentIntegrationActLaneTests.swift`
- `now-host/Tests/HostTests/AgentActivityModelTests.swift`

**Approach:**

- Add one FIFO per guest with human source attribution, displayed snapshot ID, stable target identity, current capability lease, typed action, postcondition, and operation record.
- Revalidate guest/session, entity incarnation, observation revision, freshness, completeness, and advertised capability at dispatch.
- Dispatch Finder open/select and application Hide/Show/Hide Others through the exact U1 guest-minted capabilities; remove the action-bearing item-name/window-title and application-name scripts after watched no-hijack tests pass.
- Extract action execution from `NOWMirrorSource`; preserve `AgentIntegrationActControl` as the resident-action adapter rather than a parallel broker.
- Join dispatch, guest settlement, later scene postcondition, logs, and UI status by operation ID and guest session.
- Keep menu/open/pressed/drag previews provisional. Dismissing a local dropdown is never evidence that the guest selected its row.
- Give queued human acts priority over new polling/content chunks without starving required postcondition refreshes.
- Retire `MirrorSettlementTracker` only after its late-success and bounded-record behavior is represented by the operation reducer and watched-fail tests.

**Test scenarios:**

- Two rapid native clicks serialize and keep independent targets, correlation, settlement, and visible feedback.
- A stale capability, expected-stale target, wrong session, or changed incarnation refuses before dispatch.
- Dispatch without guest change stays non-green.
- Workshop reopen cannot report success when the application never calls `MenuSelect`.
- Hide Finder settles only after authoritative visibility changes.
- Same-app window selection settles against the exact target window.
- Close from a partial scene remains pending; complete scoped absence can confirm.
- Timeout retains a later-confirmed path and cannot be overwritten by another operation.

**Verification:** Run focused operation, act-lane, activity, policy, and source tests. Then drive every preflight action through the native Mirror and require correlated evidence. Mutation-watch false success, shared-correlation overwrite, acting on stale state, and deletion settlement from incomplete observations.

**Cleanup gate:** Direct interactions may not bypass the broker after cutover. Remove old dispatch branches only after the full preflight has exercised each typed action class.

**2026-08-04 U6 vertical checkpoint.** The host now owns one bounded
operation journal and one settlement-serial FIFO per pinned guest session.
Application activation, exact-window activation, close, Finder open, and
`Windows > Workshop` mint typed postconditions from the immutable engine
snapshot that was displayed. Attempt replies are recorded separately: a
post-dispatch refusal remains pending, a later complete same-session scene can
confirm it without erasing the contradiction, and a timeout can still become
late-confirmed unless an active retry makes attribution ambiguous. A second
gesture cannot dispatch until the active operation confirms or times out.

The cleanup rule is now enforced for those modeled plans: failure to resolve a
stable process/window identity is an explicit non-dispatch, not a silent fall
through to the old `serve(plan)` label path. The current development VM made
that guard necessary: its visible scene can render compatibility windows while
the engine has no stable identity for them, so the pre-checkpoint host emitted
only `act-refused` even for state changes observed later.

The corrected direct drive established two separate facts. With Finder first
selected, clicking the exposed `System Folder` title bar targeted that exact
Finder window and the stale guest refused `winact select`; it did not come
front. Selecting `New Old World` in the Application menu activated NOW and did
not recreate the already-closed Workshop, which is correct. The distinct
`Windows > Workshop` operation remains red: it is named-window creation and
times out when the guest never calls `MenuSelect`. These observations are not a
green U6 sweep; the latest identity-producing guest and extension still have to
be staged before the broker's positive live path can be proven.

Focused source, engine, executor, and broker tests pass. Removing the FIFO's
`active == nil` guard made the rapid-two-click test dispatch both operations
and fail; restoring it returned the gate to green.

### U7. Add MCP reads and conditional mutation as a thin state-engine client

**Goal:** Bring mandatory MCP reads into parity without creating another observer or state cache, then add mutation parity only for native equivalents that are already proven.

**Requirements:** R13-R16, R19, R22, R28.

**Dependencies:** U5 for mandatory read parity. U6 direct-input proof for each optional mutation projection.

**Files:**

- `now-host/Sources/NOWAgentIntegration/Projection/MirrorObserveModels.swift`
- `now-host/Sources/NOWAgentIntegration/Projection/ObserveElementsProjection.swift`
- `now-host/Sources/NOWAgentIntegration/Projection/MirrorActProjections.swift`
- `now-host/Sources/NOWAgentIntegration/Projection/AgentIntegrationClient.swift`
- `now-host/Sources/NOWAgentCompanion/SocketAgentIntegrationClient.swift`
- `now-host/Sources/Host/Automation/AgentIntegrationSessionHealth.swift`
- `now-host/Tests/HostTests/MirrorActProjectionTests.swift`
- `now-host/Tests/HostTests/AgentIntegrationActLaneTests.swift`
- `now-host/Tests/HostTests/MCPCoverageTests.swift`

**Approach:**

- Add status, snapshot, find, and wait projections over immutable engine DTOs. Remove `ObserveElementsProjection`'s independent guest call.
- Preserve grants, machine/session addressing, and source attribution above the engine.
- Add a mutation projection only after its native equivalent is green enough to serve as the semantic reference; submit the same typed action to the same FIFO. Record every deferred mutation row explicitly for the broader completion plan rather than blocking MCP read parity.
- Return the same snapshot and operation IDs exposed by the Mirror evidence exporter.
- Keep MCP-only success insufficient for UX scoring and keep API input ineligible for direct-input provenance.

**Test scenarios:**

- Mirror and MCP reads expose the same snapshot ID, digest, entity IDs, freshness, and completeness.
- Concurrent Mirror and MCP waits do not duplicate guest polls.
- MCP mutation enters the same queue behind an earlier human mutation and retains agent attribution.
- MCP cannot act on expected-stale state or a snapshot from another guest session.
- Removing a Mirror or MCP catalog disposition fails the derived parity test.

**Verification:** Run projection, companion, and coverage tests plus a live read-parity check. Run act-lane tests for the optional mutation rows that are enabled. Do not use MCP to satisfy any direct-input row.

**Cleanup gate:** Remove the old direct guest observe/act projection only after derived coverage proves every retained method has an engine disposition.

### U8. Run the full direct campaign and promote the development image

**Goal:** Prove the state-engine cutover, preserve findings, and hand control back to the broader completion plan on a clean exact guest image.

**Requirements:** R23-R28 and all preceding requirements as exercised by their flows.

**Dependencies:** U7 mandatory read parity and all cleanup gates satisfied. Optional U7 mutation rows are not an U8 prerequisite.

**Files:**

- `docs/mirror-drive-loop.md`
- `docs/mirror-high-water-checkpoint-2026-08-04.md`
- `docs/open-issues.md`
- `docs/plans/2026-08-03-001-now-mirror-ux-completion-plan.md`
- `docs/images/mirror-checkpoint-*/`
- `tools/mirror-gate`
- `tools/mirror-diff`
- canonical staged development image outside Git

**Approach:**

- Run as much of the mandatory sweep as possible before patching. Patch only state-engine-owned regressions or blockers to truthful engine validation, batching them by producer, reducer, projection, mutation, or evidence ownership. Record renderer, structured-producer, or guest-action reds owned by the broader UX plan instead of absorbing them into this prerequisite.
- At every batch start, run the full preflight and tail host plus guest act logs while driving the native Mirror.
- Capture the stability sandwich, whole Mirror frame, authoritative guest evidence, state snapshot, operation, settlement, and logs for every scored row.
- Record remaining product reds honestly. State-engine completion requires no state-engine regressions and truthful evidence; it does not convert unresolved renderer or guest action defects to green.
- Build the exact current guest application and NOW Extension, install them in the canonical Mirror development VM image, verify fingerprints from the running guest, then perform and record a clean classic Mac shutdown before saving the image. If automation cannot safely complete the shutdown, stop and ask the user to perform it; do not call the image complete while dirty.
- Update the broader completion plan to consume the landed engine and resume at the remaining interaction, fidelity, structured-content, MCP, and final release work without recreating U3/U4.
- Leave one uniquely identified host and one VM alive for user inspection after the final verification run, unless the clean-image shutdown is the last authorized action; in that case relaunch only the saved clean image once and record that it is the exact promoted artifact.

**Test scenarios:**

- Workshop visual baseline, resize, close, and reopen.
- Menubar geometry, Apple rows, and native Application menu Hide/Hide Others/Show All behavior.
- Macintosh HD double-click, Finder render, desktop activation, exact same-app window activation, and close.
- Date & Time panel, Set Time Zone modal, structured city/country list, and Cancel.
- Disconnect, reconnect, guest switch, inactive-app retention, and session replacement.
- When at least one optional MCP mutation row is enabled, rapid mixed human/MCP operations prove serialization, but only native input contributes to UX green. Otherwise the row is explicitly deferred without blocking U8.

**Verification:** Run `scripts/test-native`, `scripts/test-host /private/tmp/now-state-engine-test`, `scripts/test-all`, the mirror-gate mutation suite, the complete direct Computer Use sweep, explicit-socket QMP capture, `tools/mirror-diff`, and human whole-frame review. Classify the result as builds, tested, emulator-verified, or metal-verified without collapsing levels.

**Cleanup gate:** Update `docs/open-issues.md`, preserve a new exact checkpoint and evidence set, confirm the staged image's clean shutdown and fingerprints, and ensure no legacy state cache, independent MCP poller, QMP production import, or duplicate host/VM instance remains.

## Verification Contract

### Automated gates

| layer | required proof | watched-fail mutation |
|---|---|---|
| Contract and guest encoding | coverage, lifetime identity, v1 conservatism, conformance | flatten retracted into empty |
| Pure replica | replay, idempotence, ordering, deletion truth table, isolation, retention bounds | delete on partial absence |
| Pure operations | dispatch non-success, later postcondition, timeout augmentation, session terminality | confirm on dispatch |
| Host engine | one poller, per-session registry, pinning, shadow parity, immutable snapshots | global pending scene |
| Content and enrichment | exact identity, partial retention, invalidation, overwritten-ring behavior | publish partial page |
| Native projection | Apple/background continuity, stale non-actionability, frame parity | remove retained rows or leave stale frontmost |
| Mutation broker | FIFO, independent correlation, capability revalidation, complete-absence settlement | share one correlation between rapid clicks |
| MCP adapter | same snapshot and queue, no independent poll, grant/session preservation | call guest observe directly |
| Evidence tooling | explicit QMP socket, build identity, direct input, stable digest, complete joins | accept MCP-only input or mismatched digests |

### Required commands

```sh
swift test --package-path mirror/host/MirrorKit --filter MirrorReplicaReducerTests
swift test --package-path mirror/host/MirrorKit --filter MirrorOperationReducerTests
swift test --package-path now-host --filter MirrorStateEngineTests
swift test --package-path now-host --filter NOWMirrorSourceTests
swift test --package-path now-host --filter NOWMirrorContentPlaneTests
swift test --package-path now-host --filter AgentIntegrationActLaneTests
swift test --package-path now-host --filter MirrorActProjectionTests
scripts/test-native
python3 tools/mirror-gate-tests/test_mirror_gate_evidence.py
scripts/test-host /private/tmp/now-state-engine-test
scripts/test-all
```

If the MirrorKit package path or suite invocation differs when U2 lands, U2 must update this command block and the repository gate rather than leave a fictional command in the plan.

### Direct UX gate

1. Assert exactly one uniquely identified host owns the configured listener and exactly one expected guest answers. Record host, guest application, extension, port, and build fingerprints.
2. Start host and guest log tails before interaction.
3. Visually validate Workshop and menubar, then open the Apple menu and validate exact guest-provided rows.
4. Resize Workshop, close it, double-click Macintosh HD, validate Finder, and Hide Finder through the native Application menu.
5. Reactivate Finder through the native Application menu, then navigate through Finder to Date & Time; validate panel structure/content, Set Time Zone, its city/country rows, and Cancel.
6. Validate Workshop reopen, desktop-to-Finder activation, exact same-app window activation, close, Hide Others, Show All, and other C26 regression rows.
7. For each settled stable state, require snapshot A, native Mirror frame, explicit-socket guest capture, snapshot B with equal digest/no intervening operation, operation and settlement records, both logs, and human pixel judgment.
8. For transient host overlays, apply R25. Keep the row unscored until its genuine guest reference and authoritative post-action settlement are both present.
9. Patch related failures in batches, rerun the full preflight at the start of every sweep, and never preserve a new checkpoint over a regressed baseline.

### Release-status vocabulary

- Builds: the relevant targets compile.
- Tested: automated suites pass here.
- Emulator-verified: the direct native Mirror sweep passed against the exact QEMU oracle build with correlated evidence.
- Metal-verified: the same portable behavior was watched on the target classic Mac.

No lower level implies a higher one. The state-engine plan can be implementation-complete while known product reds remain in `docs/open-issues.md`; no release may be called complete while a core direct flow remains blocked.

## Definition of Done

- D1. The contract provides typed coverage and lifetime identity sufficient to implement the deletion truth table without parsing error prose.
- D2. Pure deterministic reducers pass replay, ordering, deletion, stale retention, identity reuse, content invalidation, operation settlement, bounded retention, and per-guest isolation tests, including watched-fail mutations.
- D3. One engine per pinned guest-session incarnation owns observation, reconciliation, enrichment, content, mutation, settlement, journal, and immutable snapshot publication; reconnect creates an explicit successor and cancels the old incarnation's work.
- D4. `NOWMirrorSource` is a thin client, and the Apple-only reducer, controller stale cache, old settlement tracker, and any independent visible replica owner are removed after proven parity.
- D5. Native Mirror mouse and keyboard input resolves against displayed snapshot identity, enters the serialized broker, and is scored only from later authoritative evidence.
- D6. MCP reads the same snapshots without another poller; any MCP mutation uses the same queue and remains ineligible to satisfy direct UX provenance.
- D7. Evidence tooling emits the strict manifest fields, exports the exact native frame, uses an explicit QMP socket and asserted guest/build identity, enforces the stability sandwich, and refuses incomplete joins.
- D8. The complete preflight and C26 regression corpus are rerun with direct native input, paired authoritative visual evidence, state, settlement, and logs. Known remaining reds are documented rather than relabeled.
- D9. `scripts/test-all` passes at the Tested level, skipped cross-build or metal gates are named honestly, and relevant mutations have been watched fail.
- D10. The canonical Mirror development VM contains the exact latest guest application and NOW Extension, reports their fingerprints, and is saved only after a documented clean shutdown.
- D11. A new durable checkpoint records source commit, exact builds, runtime identities, evidence, passes, reds, and resume instructions. The broader UX completion plan is updated to consume this engine and remains the owner of remaining product completion.
- D12. No production code depends on QEMU/QMP, no raw pixel transport has become load-bearing, and one host plus one VM are left available for inspection as specified by U8.

## Appendix

### C26 characterization cases carried forward

- Apple rows survive a later same-session empty shell but stay explicitly expected-stale until a fresh complete menu replaces them.
- Workshop structure can remain while its detail content is lost after ring overwrite; the last compatible settled display must survive.
- Finder can open and render while Hide fails to settle and while another same-app window click fails to raise the exact target.
- Date & Time can launch while values, control kinds, and city/country list content remain missing.
- Set Time Zone can appear late and Cancel can work; its current red is partial fidelity, not absence or a broken Cancel button.
- Workshop reopen can dismiss the Mirror-local Windows menu while the guest never calls `MenuSelect`; local dismissal is not mutation success.

### Primary implementation seams

- Guest full walk and transfer: `now-guest-ppc/src/core/wire.c`, `now-guest-ppc/src/scene/`.
- Host session envelope and requests: `now-host/Sources/Host/Session.swift`, `now-host/Sources/Host/GuestListener.swift`.
- Current overburdened source: `now-host/Sources/Host/NOWMirrorSource.swift`.
- Existing content lifecycle: `now-host/Sources/Host/NOWMirrorContentPlane.swift`.
- Current settlement join: `now-host/Sources/Host/MirrorSettlementTracker.swift`, `now-guest-ppc/src/act/act_settlement.c`.
- Pure interaction meaning and direct input: `mirror/host/MirrorKit/Sources/MirrorKit/InteractionPolicy.swift`, `mirror/host/MirrorKit/Sources/MirrorKitUI/LiveMirror.swift`.
- Existing per-guest cache pattern: `now-host/Sources/Host/GuestScopedState.swift`.
- Strict UX gate: `docs/mirror-drive-loop.md`, `tools/mirror-gate`, `tools/mirror-diff`.
