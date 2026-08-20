---
title: Retire the stdio MCP transport after HTTP-only readiness is proved
type: refactor
date: 2026-08-20
artifact_readiness: due-diligence-gated
execution: code
---

<!-- now-doc-provenance: generated reviewed=false -->

# Retire the stdio MCP transport

## Goal capsule

New Old World should converge on one live MCP transport: authenticated
Streamable HTTP on loopback, owned in-process by the running host app. The
stdio transport should move through explicit **deprecation**, **sunset**, and
**removal** states rather than disappearing in one code deletion.

The reason is architectural rather than cosmetic. HTTP reaches the host
adapter directly. Stdio starts a second copy of the app executable, frames
JSON-RPC on its standard streams, and crosses a same-user Unix socket into the
running app. That extra process and bridge have produced stale-binary,
socket-ownership, launch-policy, and silent-liveness failure modes. The Chat
workspace lane already moved to HTTP and calls stdio its sunset path.

The migration is not ready to begin merely because HTTP exists. Stdio still
has two obligations that must be accounted for first:

1. external MCP clients may still be configured to launch `New Old World
   --mcp-stdio`; and
2. a spawned stdio process can receive a per-process `--workspace-root`, while
   the current HTTP lane pins a process-global root in the host.

Removal is therefore gated by evidence about actual consumers and by an HTTP
authorization model that preserves or improves the existing filesystem
boundary.

## Current evidence, not yet a removal verdict

This plan was grounded against `origin/main` at `1f5ce2f3` on 2026-08-20.

- The in-app Claude workspace lane uses HTTP with a bearer token and starts
  the listener on demand.
- The stdio configuration remains available for external clients that launch
  commands, starts automatically by default when no preference has been
  stored, and is still presented as a peer transport in the MCP module.
- HTTP and stdio share `NOWMCPServer`; exact transport-parity and full-client
  conformance tests currently protect that fact.
- The durable records schema stores `mcp-stdio` as a historical agent kind.
  Its decoder also incorrectly uses stdio as the fallback for an unknown kind,
  which must be corrected before the live transport is removed.
- The local records database contained four HTTP actions and no stdio actions
  when inspected on 2026-08-20. This is weak evidence only: the database is
  recent, is local to one installation, and creates agent history from audited
  actions rather than proving every successful initialization.

No removal decision may cite that last observation as proof of zero use.

## Decisions this plan makes

- **Destination:** HTTP is the only live MCP transport after removal.
- **Network boundary:** it remains loopback-only. This work does not make NOW
  a LAN or hosted MCP service.
- **Authentication:** bearer and OAuth remain supported. No-auth remains an
  explicit warned setting; migration never weakens authentication to make a
  client connect.
- **Startup:** HTTP does not silently become an always-on listener for an
  existing installation. The embedded lane may continue to start it as the
  consequence of the person's existing “attach NOW tools” grant. External
  clients receive an explicit migration action and connection recipe.
- **Filesystem authority:** an HTTP credential or session does not implicitly
  receive the Chat lane's workspace. Workspace access becomes session-scoped;
  an ordinary external HTTP session has no modern-host readable root unless a
  person explicitly grants one.
- **History:** `mcp-stdio` remains decodable and visible in durable records
  after the live transport is gone. Historical data is not rewritten or
  deleted.
- **Timing:** readiness and observed-use gates decide progression. The
  deprecation window lasts at least one complete release; elapsed time alone
  is never sufficient.
- **Contract:** the guest wire contract and projection catalog do not change.
  This is a host transport and authorization migration.

## Scope boundaries

In scope:

- live stdio entry point, bridge server, Unix-socket client, settings, UI,
  logging, records identity, tests, and current-state documentation;
- HTTP readiness needed to replace every supported stdio workflow;
- migration diagnostics and a bounded tombstone release; and
- emulator and metal evidence required by repository policy.

Out of scope:

- remote/LAN HTTP, TLS termination, or a hosted service;
- new MCP tools, guest commands, consent tiers, or catalog semantics;
- rewriting historical plans to remove accurate references to stdio; and
- deleting old audit history or user preferences merely for tidiness.

## Phase 0 — due diligence and exit criteria

This phase changes no product behavior. It produces a dated evidence packet
under `docs/local/` while active, then graduates only durable conclusions into
current documentation and the implementation PRs.

### 0.1 Consumer and configuration census

Build a matrix for every client NOW claims or is actually configured to serve.
At minimum inspect the embedded Claude lane, Agentis, Codex, Claude Desktop or
Claude Code configurations, and any locally configured Jan or other MCP
clients. Verify current transport support from the live configuration and
official client documentation; do not infer support from remembered product
behavior.

For each consumer record:

| Question | Required evidence |
| --- | --- |
| Does it currently use NOW? | exact local config or an explicit owner answer |
| Which transport? | command/arguments or URL/auth configuration |
| Can it use Streamable HTTP now? | current official docs plus a real initialize |
| How is authentication supplied? | bearer/OAuth path without recording secrets |
| Does it need host-file upload? | named workflow and required root semantics |
| Who owns migration? | repository or human owner, not an assumed audience |

Search public docs and support material for copied `--mcp-stdio` recipes, but
do not treat repository search as proof that no private configuration exists.

### 0.2 Local-use evidence

Add privacy-preserving local lifecycle evidence before beginning the
deprecation clock. An MCP initialize should update transport kind, bounded
client name/version, session identity, first seen, and last seen without
arguments, payloads, paths, tokens, or network reporting. Tool actions remain
recorded as they are today.

The MCP module must be able to answer separately:

- last stdio initialization;
- last stdio audited action;
- which bounded client identity supplied it; and
- whether the observation comes from this installation only.

Do not overload “no audited action” to mean “no client.” No new remote
telemetry is introduced.

### 0.3 Unique-capability inventory

Trace every value that enters through `--mcp-stdio`, every behavior implemented
only by `SocketAgentIntegrationClient`, and every lifecycle behavior derived
from child-process exit or EOF. The expected unique item is the optional
`--workspace-root`, but the trace—not this expectation—is authoritative.

For each unique item choose one disposition:

- reproduce it over HTTP with equal or narrower authority;
- migrate the owning workflow to another already-authoritative path; or
- deliberately remove it with a named user-visible consequence.

No item may remain in an “probably unused” state at the end of this phase.

### 0.4 HTTP replacement audit

Exercise HTTP independently of stdio across:

- initialize and `notifications/initialized` gating;
- tools, resources, prompts, ping, malformed requests, and unknown methods;
- every advertised tool through the real HTTP listener;
- bearer, OAuth, and explicit no-auth modes;
- Host and Origin validation;
- message/header bounds and unsupported transfer encoding;
- session creation, maximum-session refusal, expiry, and DELETE;
- listener start, stop, restart, cancellation during bind, fixed-port
  collision, app relaunch, and multiple app instances; and
- typed behavior when no guest, the wrong guest capability, or no machine
  consent is available.

The existing parity suite is useful during migration but cannot be the final
HTTP proof: once stdio is removed, HTTP needs a self-contained conformance
harness whose oracle is the shared registry and protocol contract rather than
the transport being retired.

### 0.5 Security and authority review

Threat-model the HTTP-only state explicitly:

- a shared bearer must not grant the current Chat workspace to every session;
- OAuth identity and transport identity must not be confused with a workspace
  grant;
- changing the Chat lane while another session exists must not retarget that
  session's readable root;
- concurrent sessions with different grants must not see one another's files;
- a session with no grant must receive the current typed refusal; and
- logs and records must never contain tokens, paths, request arguments, or
  file bytes.

### Phase 0 exit gate

Proceed only when:

- every known consumer has an owner and migration disposition;
- current client support has been verified rather than assumed;
- every stdio-only behavior has a chosen disposition;
- the HTTP-only conformance suite is specified and has a runnable baseline;
- the session-scoped workspace design has an accepted interface and tests;
- the records/history compatibility strategy is pinned; and
- open findings are classified as blocker, accepted limitation, or separately
  owned work.

## Phase 1 — make HTTP independently sufficient

### Work unit 1: session-scoped workspace authority

Replace the process-global `HostProjectionLocalRead.workspaceRoot` decision at
tool invocation with an explicit session context owned beside the HTTP
`NOWMCPServer` and client identity.

- The embedded lane creates or selects one HTTP session carrying exactly its
  current granted root.
- Ordinary bearer and OAuth sessions begin with no readable host root.
- A workspace change cannot mutate an already-running unrelated session.
- `now_guest_files_upload_file` resolves and validates paths against the
  invoking session's grant.
- Two concurrent-session tests prove isolation in both directions.
- Mutation evidence replaces the session context with the old global root and
  watches the isolation test fail for the claimed reason.

If the selected MCP client cannot supply the session/grant handshake safely,
stop here and redesign the grant path. Do not preserve the feature by sharing
one ambient root.

### Work unit 2: durable lifecycle evidence and legacy decoding

- Record initialization/session lifecycle without capturing payloads.
- Preserve `mcp-stdio` as a historical record kind.
- Replace the current “unknown kind means stdio” fallback with an explicit
  unknown/legacy-safe presentation.
- Add a fixture database containing HTTP, stdio, and unknown historical rows;
  prove it opens and renders after live stdio code is absent.

### Work unit 3: HTTP-only conformance and operations

- Extract the full recipe now exercised through both transports into a
  transport-neutral conformance recipe.
- Run that recipe through the real HTTP listener without spawning stdio.
- Add focused lifecycle, auth, session-limit, expiry, and port-collision tests.
- Add a diagnostic that distinguishes configured, listener-bound,
  authenticated/initialized, and failed states.
- Provide copyable URL plus bearer/OAuth client recipes without rendering or
  logging secrets.

### Phase 1 exit gate

HTTP must serve the complete registry, preserve session-local authority,
produce useful failure evidence, and pass independently with stdio disabled in
the test fixture and app preferences.

## Phase 2 — deprecate stdio while it still works

This phase begins the compatibility window.

### Product behavior

- Change a missing stdio preference from auto-start to off.
- Preserve an existing explicit stdio-on preference for the deprecation
  release; do not silently rewrite it.
- Keep explicit Start/Stop and `--mcp-stdio` functional, but mark both
  **Deprecated** and show the exact HTTP migration path.
- Make HTTP the first and recommended transport in the MCP module and docs.
- On every stdio process start, write one bounded warning to **stderr only**.
  Stdout remains pure MCP framing.
- Show the last local stdio initialization/action evidence and explain its
  installation-local scope.
- Publish release notes naming the last release in which stdio is expected to
  execute, while reserving the right to extend the window if readiness or
  usage evidence is incomplete.

### Compatibility verification

- A real command-launch client can still initialize, list, and call during the
  deprecation release.
- The warning cannot corrupt stdout framing.
- Existing explicit preferences survive an upgrade.
- A clean install does not start the stdio bridge.
- HTTP migration recipes work for every supported client in the census.

### Phase 2 exit gate

Sunset requires all of the following:

- at least one complete released deprecation cycle;
- no unexplained stdio initialization or action on the installation-local
  evidence window selected during Phase 0;
- every known consumer migrated, retired, or explicitly accepted as broken;
- no open severity-1 or severity-2 HTTP replacement defect;
- emulator QA and applicable physical-machine QA on the current candidate;
  and
- an owner-approved rollback build and release note.

## Phase 3 — sunset with a diagnostic tombstone

Stdio stops being a transport in this phase, but the old entry point remains
recognizable for one bounded release so stale client configurations fail
quickly and explainably.

- Remove stdio startup, listener/socket ownership, settings, normal MCP card,
  and current-session controls.
- Keep a narrow `--mcp-stdio` tombstone that writes a migration message and
  HTTP endpoint instructions to stderr, then exits nonzero without launching
  the app or emitting protocol-looking stdout.
- Retain historical stdio agents, sessions, and actions in the records UI.
- Keep a current support page for the tombstone message to reference.
- Do not add a hidden environment override. Rollback is the previous signed
  release or a revert, not a secret second transport.

The tombstone release proves that stale configuration fails visibly instead
of hanging or opening the normal app.

## Phase 4 — remove the implementation

After the tombstone window and the same usage/readiness audit:

- delete `MCPStdioTransport` and its line framer/output-only implementation;
- delete the stdio-only socket bridge, local client, audit sink, launch
  notification, activity state, transport card/layout identifier, settings,
  preference reads, and current-run log routing where no other owner remains;
- delete stdio liveness, subprocess, parity, preference, UI, and ownership
  tests, replacing—not merely removing—the behavioral coverage with HTTP-only
  conformance and historical-record fixtures;
- stop recognizing `--mcp-stdio` after the documented tombstone release;
- remove current-state stdio instructions from the user guide, agent boundary,
  status, MCP coverage, settings, source-text gates, and screenshots;
- leave historical plans and dated issue evidence intact; and
- retain the raw `mcp-stdio` historical identity and presentation for as long
  as the records database can retain such rows.

Add a source guard that permits `mcp-stdio` only in the historical records
compatibility seam and explicitly historical documents. Watch it fail once by
reintroducing a live entry point or current-state instruction.

## Verification matrix

| Area | Required proof |
| --- | --- |
| Build and suites | `scripts/test-all`, including both host configurations and docs gates |
| HTTP protocol | real listener conformance over the complete registry |
| Auth | bearer, OAuth, no-auth warning, Host/Origin rejection |
| Sessions | isolation, limit, expiry, DELETE, reconnect, app restart |
| Workspace | two concurrent roots plus an ungranted session; mutation-tested |
| Migration | supported-client HTTP recipes and clean stderr-only deprecation/tombstone output |
| Persistence | pre-removal database fixture still renders legacy stdio and unknown kinds |
| UI | MCP/settings screenshots and accessibility for migration/deprecation states |
| Emulator QA | current-head HTTP read and consented mutation against every affected guest surface |
| Metal QA | current-head HTTP read and consented mutation on the applicable physical Mac |
| Policy | record current-head Emulator QA and Metal QA with `tools/code-qa`; no agent metal override |

Every new guard is watched failing against the mutation it claims to detect,
with proof that the mutated build completed and the intended test ran.

## Delivery sequence

Use small PRs; do not mix the compatibility window with final deletion.

1. **Due-diligence receipt:** consumer matrix, support verification, unique
   capability trace, security decision, and baseline HTTP results.
2. **HTTP authority:** session-scoped workspace grants and concurrent isolation
   tests.
3. **HTTP proof and history:** independent conformance, lifecycle evidence,
   legacy/unknown database decoding, and migration recipes.
4. **Deprecation release:** stdio off by default, warning and migration UI,
   complete docs and release notes.
5. **Sunset release:** remove the live bridge and ship the diagnostic
   `--mcp-stdio` tombstone.
6. **Removal release:** delete the tombstone and implementation residue while
   retaining historical records compatibility.

Each PR re-derives current docs and tests at its merge revision. A green test
from an earlier phase is evidence for that revision only.

## Rollback and stop conditions

During deprecation, rollback means re-enabling the still-present explicit
stdio path while fixing HTTP. During and after sunset, rollback means shipping
the last signed stdio-capable release or reverting the sunset PR; the records
schema remains backward-compatible so no data restoration is required.

Stop progression when any of these occurs:

- a real supported client cannot use HTTP;
- HTTP would require broader network or filesystem authority than stdio;
- the session-scoped workspace boundary cannot be proved under concurrency;
- historical records cannot be opened without misclassification or loss;
- a listener/auth/session failure presents as healthy or silent;
- required current-head Emulator QA or Metal QA is absent; or
- the owner has not accepted a named consumer's breakage.

## Definition of done

New Old World owns one live MCP endpoint: authenticated loopback HTTP in the
running host. Every supported consumer uses it; every external session has
explicit, session-local authority; the full registry is independently
conformance-tested; stale stdio configurations received a bounded diagnostic
window; current docs advertise no stdio transport; and historical stdio audit
records remain accurate and readable.
