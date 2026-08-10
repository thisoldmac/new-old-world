---
title: Development agent-loop hardening plan
type: plan
date: 2026-08-10
status: implemented
search:
  exclude: true
---

# Development agent-loop hardening plan

## Objective

Make a NOW-owned, guest-native development loop safe to run unattended: an
agent can discover a compatible host and guest, create or import a project,
edit fork-aware files in NOW's host scratch, build and test with a qualified
guest toolchain, launch the exact product, observe and act on its UI, and
recover or explain every incomplete operation without consulting hidden state.

The plan hardens the existing architecture. It does not add a shell, expose an
arbitrary host directory, make CodeKitten a dependency, or treat a build as a
test.

## Implementation result

Implemented on `codex/development-agent-loop-hardening` and verified on
2026-08-10. The NOW-owned parts of workstreams A-D and the manifest/input
portion of F are complete:

- compatibility preflight names the host build, local protocol, projection
  catalog and supported schema revisions;
- Projects and Development mutation attempts are caller-addressable and replay
  bounded terminal responses across host restart;
- Projects and Development publish operation-discriminated input schemas;
- snapshot, target resolution and act planning use one published Mirror state
  engine, every accepted direct act is journalled, and
  `wait_for_settlement` returns its actual terminal state;
- `Project.ckp` has a closed test vocabulary and the PPC guest returns
  `ckproject.test-receipt/1` after exact process-identity assertion;
- guest projects are discoverable through a bounded catalog, restart recovery
  inventories retained candidates, and guest-home publication remains guarded
  by the imported base digest;
- onboarding validates a relocatable Development starter-pack manifest with
  platform, version, component, license, provenance, size and qualification
  metadata rather than an HFS directory ID.

The isolated mac99/OS 9.1 acceptance used guest build `b1de53f2bfe9`, resident
manifest `28ef6c07ee6d`, resident fingerprint `085c4ebf8457`, qualified
`mpw-ffff-00000cf0@structural-1`, and base image SHA-256
`bf5a6cf67701e8628cca3ffe5311a0bd76d959a549b7cdb320287c2afd8ec22e`.
It completed simple, failure/repair/cancellation and guest-home promotion loops;
recovered one lost stage response without duplication; refused a divergent
promotion while preserving both sides; and cleaned up this run's candidates.
The exact receipts are summarized in [development.md](../development.md)
and the dated ledger entry in [open-issues.md](../open-issues.md).

Four acceptance statements were not silently redefined:

1. This repository has a stdio MCP companion and no HTTP MCP listener. The
   plan's HTTP-canonical/parity assumption was stale; implementing HTTP would
   add a new transport and security boundary.
2. CodeKitten is separately owned. NOW still lacks a returned `odoc` handler
   receipt, and cross-repository shared-fixture extraction must land with that
   sibling rather than making it a NOW dependency.
3. The portable starter-pack contract is present, but no redistributable MPW
   payload can be committed without settled license/provenance. The manually
   populated VM is test infrastructure, not the distributable pack.
4. The new receipts are emulator-verified. The earlier PowerBook proof covers
   the fork-aware host-home build/run/dialog loop, not this hardening delta.

These are residual product/integration gates, not missing local implementation
hidden behind the status word.

## Required invariants

1. **One identity chain.** Every request and receipt carries host build,
   companion protocol, machine, guest build, session epoch, project revision or
   candidate digest, qualified toolchain, operation ID, and product identity as
   applicable.
2. **One published semantic authority.** Snapshot, find, wait, act planning,
   act dispatch, and settlement read the same immutable scene generation. A
   reference from generation N cannot be resolved against an unrelated source
   or silently rebound after a session change.
3. **Every accepted operation settles.** Accepted work has a durable status and
   one terminal state: confirmed, refused, cancelled, timed out, confirmed
   after timeout/refusal, or abandoned after a named session/host change.
4. **Classic identity survives all edits.** Data fork, resource fork, type,
   creator, and flags remain one logical file through reads, patches, commits,
   candidates, products, and recovery.
5. **Authority never expands implicitly.** Host writes remain below NOW's
   Projects root. Guest-home publication remains candidate-based and guarded by
   the imported base digest. Toolchains remain human-registered.
6. **Transport facts are not domain facts.** A broken or stale companion, a
   dropped response, an operation refusal, and a successful operation whose
   response was lost are distinct outcomes.

## Workstream A — compatibility and transport settlement

- Add a small compatibility preflight returning host build identity, companion
  protocol version, projection catalog version/digest, and supported schema
  revisions before a domain tool dispatches.
- Reject a stale host/companion pair with a typed incompatibility result that
  names both sides. Do not discover it through repeated
  `now-host-invalid-response` failures.
- Assign an attempt ID before transport. Retrying a query may mint a new
  attempt; retrying a mutation must query or resume the original attempt.
- Persist bounded request lifecycle events and expose status by attempt ID.
- Distinguish never-dispatched, dispatched/unknown, and terminal outcomes after
  a connection loss. Add late-success settlement rather than rounding a client
  timeout to product failure.

Acceptance: start an older host against a newer companion and receive one typed
compatibility refusal before any project mutation; interrupt a response after
dispatch and recover the original terminal receipt without duplicating work.

## Workstream B — one semantic scene and operation lifecycle

- Remove the independent scene authority between
  `MirrorStateEngineRegistry.snapshot` and `NOWMirrorSource.scene`, or make both
  projections views of one atomically published scene store.
- Bind element references to machine, session epoch, scene generation, and
  object identity. Make incomplete base state a typed readiness state.
- Admit an act only from a published actable generation. Journal queued,
  admitted, dispatched, awaiting-evidence, and terminal transitions before
  emitting externally visible state.
- Keep terminal correction states already modeled by MirrorKit, including
  confirmation after timeout or refusal. Do not collapse them for MCP.
- Add a `wait_for_settlement` operation that waits by operation ID and returns
  the final evidence or a still-pending receipt without requiring polling by
  prose convention.

Mutation proof: publish a scene only to the projection registry while leaving
the drive source empty. The focused test must fail by naming the authority
split; after the fix, the same published dialog item must plan, dispatch, and
settle or return a typed non-actable generation before dispatch.

## Workstream C — discriminated MCP contracts and observability

- Replace broad operation-plus-optional-field schemas with discriminated input
  unions for every Projects and Development operation.
- Make project revision and workspace commit guards structurally exclusive.
- Return typed field-level validation problems without leaking private paths.
- Correlate MCP call, local projection request, guest command, candidate, job,
  product, and semantic operation IDs in host logs and bounded agent activity.
- Expose a compact development-loop status view: current authority, active
  operation, last terminal receipt, retained candidate, and recovery action.
- Keep HTTP MCP canonical. Maintain stdio parity as a tested fallback, not an
  undocumented escape hatch.

Acceptance: generated client validation rejects impossible argument shapes
before dispatch; one correlation ID traces a full project-apply through dialog
settlement; HTTP and stdio conformance fixtures return equivalent structured
results.

## Workstream D — project, test, and recovery completeness

- Add a bounded guest-project catalog so a human does not have to type an opaque
  project ID into the import sheet.
- Add a closed `test` plan to `Project.ckp` and
  `ckproject.test-receipt/1`. Define expected product identity, actions,
  assertions, timeout, and artifact retention separately from build and run.
- Make candidate/job recovery explicit after host restart, guest reconnect, or
  cancellation. Retained artifacts must name why they were kept and how to
  inspect or discard them.
- Exercise successful and divergent guest-home promotion in the emulator before
  metal. Verify the old tree remains recoverable on every failure edge.
- Add CodeKitten acceptance without making it the executor. Prefer a returned
  AppleEvent result or a small shared receipt contract over timing/process-table
  inference.

Acceptance: a guest-only project can be imported, changed and committed in the
host scratch, tested on an inactive candidate, promoted only at the original
base digest, opened in CodeKitten for a human, and recovered after interruption.

## Workstream E — shared CodeKitten boundary

- First bring CodeKitten and NOW's `CKPROJECT 1` fixtures back into conformance,
  including fork and Finder identity records and receipt fixtures.
- Extract only pure project/build vocabulary, operation-state vocabulary,
  receipt parsing, and conformance fixtures into a neutral owner when both
  consumers pass the same fixtures.
- Keep UI, host storage, Toolbox execution, MCP transport, and desktop scene
  observation in their owning applications.
- Use CodeKitten's archive/journal recovery as prior art, not as proof that
  NOW's Mirror scene and act authorities are coherent.

Acceptance: both repositories consume the same versioned fixtures and reject
the same malformed records; neither imports the other's application core.

## Workstream F — portable starter pack and qualified VM fixture

- Define a versioned, redistributable Development starter pack rather than a
  desk-specific `Lab` layout. Its manifest names supported guest platforms,
  toolchain versions, required components, licenses/provenance, install size,
  and qualification probes without embedding HFS directory IDs.
- Keep toolchain registration human-owned after installation. Resolve the
  selected directory into a fresh opaque identity on that guest; never copy a
  directory ID from another image or machine and call it portable.
- Extend onboarding's portable image input so one build can carry NOW,
  CodeKitten and the selected starter toolchains. Until an installer owns the
  layout, the image input directory and manifest are relocatable and contain
  no machine-local absolute path.
- Maintain a versioned mac99 acceptance fixture with both the canonical anchor
  worker and MPW. Qualify the worker and toolchain independently before a
  Development loop begins, and fail with the missing component rather than a
  generic boot or build timeout.
- Publish a platform matrix after research: which MPW/compiler/SDK combination
  is useful and legally redistributable for each supported System 7, Mac OS 8
  and Mac OS 9 target. Do not imply that one PPC MPW pack serves NOW-68K or
  every classic target.
- Add fixture provenance beside each VM receipt: base image digest, pack
  manifest digest, anchor policy digest, guest build, resident fingerprint and
  qualified toolchain identity.

Acceptance: from a relocatable input directory, onboarding produces one image
that installs NOW, CodeKitten and the starter pack; a fresh session-private VM
boots without manual repair, reports the expected anchor policy, qualifies the
installed MPW from a human-owned registration, and completes the canonical MCP
create/build/run/observe/act/discard loop.

## Verification ladder

1. Native unit and mutation tests for compatibility, schema discrimination,
   operation journals, classic identity, and the exact scene-authority split.
2. `scripts/test-all`, including docs, both guest builds, native suites,
   MirrorKit, host tests, and the app target.
3. A portable-fixture preflight proving the anchor policy and registered
   toolchain pack independently.
4. An isolated mac99/OS 9.1 loop through the canonical HTTP MCP: create/revise,
   stage, build, typed test, exact run, observe, semantic act, terminal wait,
   process exit, discard, and restart recovery.
5. Negative VM rungs for stale host, response loss after dispatch, session
   replacement, stale scene reference, divergent promotion, and cancelled job.
6. PowerBook 1400c acceptance using the same recipe and exact identity receipt.

No rung may use host Retro68 builds or host-side classic execution as evidence
for the guest-native workflow. Host use is limited to NOW-owned project scratch,
the NOW host/companion, orchestration, and evidence collection.

## Landing gates

- Every new guard is mutation-tested against the exact defect it names.
- Derived documents and generated contract reference are rederived after the
  integrated merge.
- `docs/status.md`, the Development module page, and `docs/open-issues.md` state
  the final evidence level and residual risk.
- If resident source or `contract/peek_table.h` changes, the integrated source
  is baked, guest-reported, cleanly shut down, volume-clean, and promoted under
  the staged-image rules before `main` advances.
