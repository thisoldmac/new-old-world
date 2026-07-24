---
title: NOW MCP V0.5 Guest Files Command Roadmap
type: feat
date: 2026-07-24
---

# NOW MCP V0.5 Guest Files Command Roadmap

## Goal Capsule

- **Objective:** Add a typed NOW command layer for bounded guest filesystem
  observation and deployment, then project that same layer through the optional
  host-side MCP companion.
- **Product boundary:** NOW owns generic guest filesystem and transfer
  primitives. CodeKitten may later decide source manifests, ignore rules,
  builds, tests, and promotion, but it receives no special command and never
  bypasses NOW's host-owned session or transfer lane.
- **Authority:** [`contract/asyncapi.yaml`](../../contract/asyncapi.yaml) owns
  every guest-wire message. The command layer may compose existing messages;
  any new wire field or verb starts in that contract and is implemented on both
  sides before an MCP tool can depend on it.
- **Execution boundary:** V0.5 adds no visible UI, transport migration, guest
  listener, mobile client, daemon, launch agent, shared protocol service,
  shell, or CodeKitten project semantics.
- **Verification posture:** This plan is approved scope, not implementation
  evidence. Each slice moves through Builds, Tested, and attended
  Metal-verified independently.
- **Implementation status, 2026-07-24:** V05-U1 is tested and has bounded
  PowerBook acceptance. The create-only staged-upload half of V05-U3 is tested:
  private disk reservation, ordered bounded staging, file-backed host send,
  guest reservation/finalization evidence, cleanup/recovery, and three strict
  MCP projections. It is not metal-verified. Download, mkdir, update,
  move/delete, tree deployment, and prune remain unavailable.

## Grounded audit

The current Files family is a useful base, but it is not yet a safe generic
agent file service.

| Surface | Current evidence | V0.5 consequence |
| --- | --- | --- |
| Guest root | The guest persists a volume name plus directory ID; an explicit boot-volume toggle makes the boot volume root active. Every wire path is colon-separated and relative, and `""` means that active share root. | V0.5 stores an additional host-owned `guestRoot` policy as a canonical path relative to the active guest share. Its approved default is `""`. The host persists and logs that value; an MCP caller never supplies or changes it. |
| Listing | `file.list` / `file.listing` pages at most 16 entries inside the 4 KB control-frame cap and reports type, creator, both fork sizes, and modified time. | Capability, list, and initial stat commands can compose the existing read-only exchange without a new guest command. Results remain paged and byte/count bounded. |
| Guest-bound receive | `now_files_receive_*` writes to a temporary file in the destination directory with one 32 KB buffer, checks free space before starting, reserves with `SetEOF`, reports progress, maintains a running CRC, keeps only eligible data-fork partials, sweeps week-old orphan temps when the clock is trustworthy, and renames only after final validation and metadata stamping. | This is the proven starting sink for deployment. V0.5 must expose its progress, free-space, finalization, and cleanup evidence rather than replace it with an in-memory path. Reservation and cleanup outcomes need typed command receipts. |
| Guest send | The integrated reverse-streaming lane records file identity and fork lengths, then reads one protocol frame at a time from the File Manager. It emits a whole-wire CRC without retaining the artifact in a temporary-memory handle. | The memory-bound source gate is closed. Arbitrary download still needs its own NOW command, scope/size policy, receipts, audit, and MCP projection; reverse resume remains separately deferred. |
| Host receive | `GuestListener.Session` now writes pulled frames into a private disk sink, reports progress, validates length and optional sender CRC, cleans interrupted partials, and finalizes atomically. | The memory-bound sink gate is closed. Download, text read, and tail remain unexposed until their typed command and policy/receipt design is implemented and tested. |
| Host send | The host's ordinary Files and V0 artifact paths still use an in-memory `OutboundFile.Plan`; the V0 artifact lane remains capped at 4 MiB and stages a sealed approval copy. V0.5 staged upload now uses an immutable file-backed source read one existing bulk frame at a time. | The new path removes whole-file host memory retention for V0.5 upload without silently widening the existing V0 approval contract. Remaining deployment work must reuse this source rather than reintroduce `Data` buffering. |
| Mutations | Existing `file.move`, `file.trash`, `file.restore`, and `file.mkdir` are root-relative and logged, but act by path and do not accept a precondition identity. | V0.5 mutation tools remain unavailable until a contract-first, guest-revalidated opaque observation identity exists. Delete remains recoverable Trash-backed removal; permanent unlink is excluded. |
| Logging | Host and guest log Files operations under the `files` / `put` areas with wire IDs; no per-chunk logging is allowed. | Every NOW command adds one bounded start/outcome audit event and a receipt ID while retaining the ordinary wire logs and their correlation IDs. |

This audit originally proved that guest-bound receiving was disk-streamed while
the reverse direction retained whole artifacts. The independently accepted
reverse-streaming work is now integrated: guest sends and host receives are
bounded, disk-backed where appropriate, CRC-aware, and covered by compatibility
fixtures. That closes the transport-memory prerequisite only; it does not
authorize or expose an agent download command.
[`large-transfers.md`](../large-transfers.md) and
[`open-issues.md`](../open-issues.md) remain authoritative for the intermittent
low-rate/backoff problem. V0.5 detects and reports a stall; it does not claim
that network behavior fixed.

## Product contract

### Requirements

**Ownership and policy**

- V05-R1. Every exposed behavior is first a typed NOW host command with
  validation, audit events, typed outcomes, recovery semantics, and tests.
  Files UI, a future Integrations UI, and MCP are callers of that same layer.
- V05-R2. The running NOW host remains the sole owner of the paired guest
  session, guest transport, transfer serialization, and filesystem commands.
  The companion never talks to the guest or manages NOW lifecycle.
- V05-R3. `guestRoot` is a persisted host policy containing a canonical path
  relative to the guest's active share. The approved initial value is `""`,
  matching the current boot-volume-share setup. Initialization, changes, and
  the effective value are auditable. Only a future host-side Integrations
  surface may let a human change it.
- V05-R4. Agent paths are canonical, root-relative paths beneath
  `guestRoot`. Absolute paths, empty non-root segments, `.` / `..`, colon
  traversal, invalid MacRoman, and overlong HFS segments fail before a wire
  request. The agent can neither name nor change the root itself.
- V05-R5. This authority is only over the paired guest filesystem below
  `guestRoot`. It grants no read or write access to the modern host filesystem,
  including an open CodeKitten project tree. Host source paths, staging paths,
  and raw guest volume paths never appear in MCP input or output.

**Observation**

- V05-R6. Capability discovery reports the effective root-relative scope,
  active root label when observed from the guest, supported operations,
  pagination, text/download limits, transfer-lane state, freshness, and
  currently known fidelity/recovery limits.
- V05-R7. Directory listing is explicitly bounded by entry count, page count,
  encoded result bytes, and timeout. It reports truncation and continuation
  rather than silently dropping entries.
- V05-R8. Stat returns one exact item or typed `not-found`, `scan-limit`,
  `stale-session`, or `unavailable`. Its initial implementation may compose
  bounded parent listings; a dedicated wire verb is added only contract-first
  if that composition proves inadequate.
- V05-R9. Download is arbitrary only within `guestRoot`, with an explicit
  policy size limit and receipt. Text reads and tails are capped convenience
  views over that same download command, never shell commands or a second file
  path. They cannot ship until both sender and receiver are streaming.

**Mutation and deployment**

- V05-R10. Create/update, mkdir, recoverable delete, and rename/move use typed
  root-relative requests with explicit collision policy. Any operation against
  an existing item requires a fresh opaque observation reference that the
  guest revalidates immediately before mutation.
- V05-R11. Upload and tree deployment stage bytes to disk, reserve guest space,
  use bounded buffers, finalize atomically where the filesystem permits, and
  leave interrupted work visible through typed recovery state. No transfer
  success exists without the current completion evidence, including
  `file.done`.
- V05-R12. Tree deployment consumes a generic desired-state manifest of
  root-relative entries and fidelity metadata. It knows nothing about source
  control, ignore rules, projects, builds, tests, or releases.
- V05-R13. Prune is limited to one named deployment subtree and one explicit
  desired-state manifest. Apply requires an unexpired dry-run receipt bound to
  the current session, root policy version, subtree, manifest digest, and
  observed entry identities. Every removed entry has its own recoverable
  outcome; unknown or changed entries stop or refuse according to the preview.
- V05-R14. Classic fidelity remains explicit: data and resource forks,
  Finder type/creator, MacBinary where required, and the signed-32-bit guest
  date rule in [`files.md`](../files.md). Missing or unrepresentable metadata
  is reported or omitted, never fabricated.

**Receipts, observability, and safety**

- V05-R15. Every command returns a bounded receipt containing an opaque command
  ID, session identity, policy version, operation, start/end time, outcome
  code, affected relative paths or counts, and only the evidence that was
  observed.
- V05-R16. Transfer receipts additionally report total and transferred bytes,
  elapsed time, sampled rate, stalled state, finalization evidence,
  destination acknowledgement, integrity evidence, and cleanup/recovery
  disposition. Sending all local bytes is not delivery.
- V05-R17. Commands are idempotent only when their contract says so. Duplicate
  or replayed mutation/deployment requests return the prior receipt or a typed
  conflict; they do not apply twice.
- V05-R18. No operation exposes shell execution, arbitrary host filesystem
  access, permanent recursive deletion, streaming output through MCP, raw
  guest paths, transfer-lane preemption, or hidden automatic retry.

### Command map

| NOW command | Existing wire basis | First availability | Receipt / recovery boundary |
| --- | --- | --- | --- |
| `guestFiles.capabilities` | host policy + bounded root `file.list` | Slice 1 | Read-only observation with session, policy version, root label, limits, and supported-command flags. |
| `guestFiles.list` | `file.list` / `file.listing` | Slice 1 | Bounded page(s), freshness, continuation, and no stale fallback. |
| `guestFiles.stat` | bounded exact match through parent `file.listing` pages | Slice 1 | Exact metadata observation or explicit scan-limit/not-found. |
| `guestFiles.download` | `file.get` / begin / bulk / end | Slice 2, after streaming gates | File-backed host staging, integrity and cleanup receipt. |
| `guestFiles.readText` / `tailText` | bounded view over `download` | Slice 2 | UTF-8/MacRoman conversion evidence, byte/line truncation, never follow mode. |
| `guestFiles.put` | `file.offer` / accept / begin / bulk / end / done | Slice 3a, tested; metal pending | Create-only private stage, file-backed source, disk reservation, delivery and cleanup receipt. The parent must already exist; success requires matching guest length, CRC, finalization, and temp cleanup. Update/overwrite remains gated on mutation preconditions. |
| `guestFiles.mkdir` | `file.mkdir` / `file.result` | Slice 3b, deferred | Idempotent existing-folder result; collision remains typed. |
| `guestFiles.move` | extended `file.move` / `file.result` | Slice 4 | Fresh observation precondition; recoverable overwrite policy. |
| `guestFiles.delete` | extended `file.trash` / `file.result` | Slice 4 | Trash-backed recovery receipt; no permanent unlink. |
| `guestFiles.deployTree` | staged `put` + `mkdir` + finalize command additions as required | Slice 5 | Per-entry and aggregate receipts; interrupted staging is inspectable and cleanable. |
| `guestFiles.previewPrune` / `applyPrune` | contract-first identity and recovery additions | Slice 6 | Mandatory preview receipt; apply refuses drift and reports every entry. |

The MCP projection follows the same names with the `now_` tool prefix only
after each NOW command is complete. MCP schemas narrow command inputs; they do
not add authority or alternate behavior.

## Data model

### Canonical scoped path

`AgentGuestPath` is an array of validated HFS leaf components, encoded on the
wire with `:`. The empty array means `guestRoot`, not the guest share root
unless policy currently sets `guestRoot` to `""`. Joining policy and caller
paths happens once in the command layer. Display labels from the guest are
untrusted text and never become authority.

### Observation and mutation identity

A listing/stat receipt may mint an opaque observation reference bound to:

- current host session UUID;
- `guestRoot` policy version;
- canonical scoped path;
- guest-side catalog identity and a bounded metadata tuple;
- observation time and expiry.

The raw volume reference, directory ID, catalog node ID, or full HFS path never
crosses MCP. `file.listing` now carries an opaque responder-generated catalog
identity, and the host binds it into a short-lived opaque observation
reference. Before V0.5 mutation work begins, each mutation request must carry
the precondition back to the guest and the guest must recompute it immediately
before acting. Host-only comparison remains insufficient because the final
lookup and mutation occur on the guest.

### Transfer and deployment receipt

A transfer entry records requested bytes, accepted offset, receiver-confirmed
bytes, integrity algorithm/value when present, final `file.done` result,
staging cleanup disposition, and any retained resumable partial. A deployment
receipt contains a deterministic manifest digest, ordered entry receipts,
aggregate counts/bytes, and final state: `complete`, `partial`, `refused`,
`interrupted`, or `cleanup-needed`.

## Recovery model

- Read-only commands hold no durable state and never return cached rows after a
  disconnect or session change.
- A guest-bound transfer writes only a recognized temporary artifact until
  finalization. An interrupted eligible data-fork transfer may remain
  resumable; MacBinary and integrity-failed transfers restart or are discarded.
- Guest-bound upload input uses a private per-process host directory and
  bounded file handles. Normal completion, expiry, integrity failure, and
  process teardown remove recognized stages. Startup reconciliation removes
  only well-formed private stage directories owned by a demonstrably dead PID,
  logs the count, and retains live-process or unfamiliar state.
- Tree deployment stages under one deployment ID. Final paths change only
  after every staged entry required for that phase is validated. If classic
  HFS cannot provide one atomic tree swap, the receipt names the exact
  commit order and any partial state; it must not claim transactionality the
  filesystem did not provide.
- Delete and overwrite are recoverable in V0.5. Existing content moves to the
  volume Trash or a named deployment recovery location before replacement.
- Recovery cleanup is an explicit typed command or startup reconciliation
  event with receipts. Silent unknown-file cleanup is prohibited.

## Approval and lifecycle ownership

Read-only commands and configured mutations are authorized by the persisted
NOW `guestRoot` policy plus the existing private same-user local adapter. That
boundary protects against other local users and accidental clients, not
malicious code running as the same macOS user. V0.5 logs the effective policy
when the adapter starts and every command names its policy version.

The existing V0 one-time artifact approval remains the only transfer available
until V0.5 upload policy and staging are complete. A future Agent Integration
UI may enable, narrow, inspect, or revoke V0.5 access and show logs/recovery,
but it is not part of this roadmap. The companion remains client-launched and
adds no daemon or second app.

## Implementation units

### V05-U1 — Command seam, policy, capabilities, list, and stat

- Add small host-owned command, path, policy, receipt, and audit types.
- Persist the approved `guestRoot = ""` default explicitly and version it.
- Compose the existing list exchange; expose no download or mutation.
- Add the MCP projection only after direct command tests pass.
- Prove root escape rejection, path normalization, bounds, disconnected and
  reconnect behavior, pagination, empty/populated listings, exact stat,
  scan-limit, concurrency, audit events, and companion noninterference.

### V05-U2 — Streaming download and bounded text views

- **Integrated prerequisite:** guest whole-file send staging is replaced by a
  bounded fork reader with incremental MacBinary encoding and running CRC.
- **Integrated prerequisite:** host `fileBuffer` is replaced by a private
  streaming sink with running CRC, receiver progress, interruption cleanup,
  and file-backed delivery.
- **Integrated prerequisite:** symmetric `file.progress` contract prose and
  receiver behavior are implemented on both sides.
- Design the typed NOW download/read/tail commands, root/size policy, receipts,
  and audit before adding any MCP projection.
- Prove increasing disposable sizes, cancellation, interruption, insufficient
  space, CRC mismatch, cleanup, text truncation, and classic fork fidelity.

### V05-U3 — Disk-backed put, then mkdir

- **Implemented and tested:** create-only staged put with a file-backed source,
  host/guest disk reservation evidence, progress/rate/stall evidence, strict
  finalization/cleanup evidence, late-collision preservation, bounded
  off-UI-actor disk I/O, replay conflict, and no host-path input or implicit
  parent creation. The
  V0 approved-artifact lane remains behaviorally unchanged.
- **Still gated:** attended PowerBook acceptance for the new path.
- **Deferred within U3:** update/overwrite and mkdir. Update waits for the
  mutation precondition boundary; mkdir remains its own typed command rather
  than being smuggled into upload.

### V05-U4 — Revalidated move and recoverable delete

- Add the guest-verifiable precondition contract first.
- Implement opaque observation storage, expiry, session/root invalidation, and
  guest-side identity comparison immediately before the operation.
- Preserve recovery receipts for Trash or displaced content.

### V05-U5 — Tree deployment

- Define a generic manifest with canonical paths, kinds, sizes, digests, and
  optional classic metadata.
- Stage, validate, and finalize deterministically with per-entry and aggregate
  receipts. Report partial commit boundaries honestly.

### V05-U6 — Manifest prune

- Preview only within one named deployment subtree.
- Bind the preview receipt to the desired manifest and every observed extra.
- Apply only that receipt, revalidate every entry, and stop/report drift.

## Test and verification matrix

| Area | Deterministic checks | Safe metal checks after green |
| --- | --- | --- |
| Scope | absolute/traversal/empty/overlong/non-MacRoman paths; root policy cannot be supplied over MCP; host paths never appear | List the approved root and reject one escape without touching disk. |
| Browse | empty/populated/paged/oversized directory, stat exact/not-found/scan-limit, reconnect invalidation, concurrent reads | Browse and stat disposable entries; compare type/creator/fork sizes in Finder/Get Info. |
| Download | increasing sizes, bounded resident memory, CRC, cancel, disconnect, insufficient host space, cleanup, stall report | Pull increasing disposable files and one forked/MacBinary file; verify receipts and integrity. |
| Put | free-space refusal, reservation, progress/rate/elapsed/stall, collision, `file.done`, interruption/resume/discard, date bounds | Send increasing disposable files to a safe location; inspect final names, forks, metadata, and cleanup. |
| Mutation | stale/reused identity, collision policies, reconnect, replay, Trash recovery | Rename/delete/restore only disposable entries and confirm the expected Finder-visible result. |
| Tree/prune | deterministic manifest digest/order, partial finalize, dry-run required, preview expiry, drift, unknown extras, per-entry receipts | Deploy and prune a disposable subtree only; never a working project. |
| Noninterference | companion absent/present, no module inventory change, one transfer lane, host unavailable | Leave normal paired NOW usable and the host running where practical. |

Tests must watch new guards fail before implementation. Metal claims require an
attended PowerBook observation and record exact files, sizes, receipts, elapsed
time, and cleanup limits. The known intermittent low-rate transfer remains an
observability target, not a claimed fix.

## Explicit deferrals

- NOW V1 host UI, target catalog, and Integrations UI;
- guest listener, mobile transport, multi-session runtime, or shared protocol
  extraction;
- CodeKitten project discovery, manifests, ignores, builds, tests, or release
  promotion;
- permanent deletion, generic recursive delete, shell/console execution, raw
  wire access, host filesystem browsing, and MCP streaming;
- hidden retry, transfer-lane preemption, or a claim that the intermittent
  throughput collapse is fixed;
- broad mutation exposure before guest-side identity revalidation exists.

## Definition of Done

- Every V0.5 MCP tool is a strict projection of a tested typed NOW command.
- `guestRoot` is explicit, persisted, versioned, logged, and never
  caller-supplied.
- Browse, transfer, mutation, deployment, and prune receipts state only
  observed evidence and recovery state.
- Both transfer directions use bounded memory before arbitrary download or
  deployment ships.
- Classic files retain the supported forks and metadata, including the
  canonical modern-date omission rule.
- Root escape, stale identity, collision, replay, interruption, insufficient
  space, and cleanup behavior are deterministic tests.
- Existing V0 tools and artifact approval remain compatible, and normal paired
  NOW use is unchanged with the companion absent or present.
- Remaining gaps and verification rungs are updated in
  [`open-issues.md`](../open-issues.md); no unobserved behavior is called
  Metal-verified.
