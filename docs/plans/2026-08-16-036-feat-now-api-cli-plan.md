<!-- now-doc-provenance: generated reviewed=false -->

# 036 — NOW public API and power-user CLI: plan

Status: **architecture review, not approved for implementation** (rewritten
2026-08-20 against `origin/main` `3922d2ab`). This version supersedes both
the option list in issue #33 and the MCP-centered draft previously committed
on this branch. The prototype on `feat/now-cli-sketch` remains dated evidence;
it is not product code and is not carried forward.

This plan prepares the whole API/CLI body of work for execution. Its phases are
sequencing and verification boundaries, not default stopping points.

## Product decision

NOW is gaining one public developer API for applications and automation, with
an official CLI as its first demanding client. The API is not a developer
wrapper around an agent tool.

MCP has two precise relationships to that API:

- **Semantically, MCP is a child of the NOW API.** It may render and constrain
  public NOW operations for an agent, but it does not own a second set of
  product meanings.
- **Mechanically, MCP and HTTP are sibling protocol adapters.** Both call the
  same typed service in-process. Neither calls the other over localhost and
  neither reimplements guest behavior.

```text
contract/now-api.openapi.json                 public wire authority
              |
              v
NOWOperationCatalog + typed NOWService        product semantics and dispatch
              |
       +------+----------------+
       |                       |
       v                       v
HTTP /api/v1 adapter      MCP adapter (/mcp + stdio)
       |                       |
       v                       v
now CLI + developer apps      agents
```

The current projection catalog, dispatch, consent, audit, and host automation
are the implementation foundation. Their MCP-shaped presentation is not the
new API contract.

## Vocabulary

The normalized public noun is **guest**:

- routes use `/guests`;
- DTOs use `guestID` and `guestSessionID`;
- the CLI uses `now guests` and `--guest`;
- operation IDs use the `guests` domain.

Use **machine** only when the subject is physical hardware or a durable lab
machine profile. Existing internal names such as `MachineFactsProjection` do
not have to be mechanically renamed to establish the public vocabulary.

There is no shipped public NOW API today. This work creates **NOW API v1**.
`HostProjectionRegistry.catalogVersion`, the local adapter protocol version,
the host build, and the public API major are separate identities and must never
be presented as a single version.

## Users and required workflows

### Application developers

A developer can build a local macOS application or automation against a
published, versioned HTTP contract without implementing MCP. At minimum the
contract supports:

- discovering connected guests and their stable/session identities;
- reading listener, connection, capability, and guest status;
- starting or stopping NOW's inbound guest listener;
- disconnecting an exact live guest session;
- running a declared guest console command and receiving its bounded result;
- listing, inspecting, uploading, downloading, moving, trashing, restoring,
  and creating guest files within the product's existing bounds;
- observing connection, transfer, and relevant guest-state changes;
- invoking the other current host capabilities deliberately admitted to the
  public operation catalog after the MCP inventory is adjudicated;
- authenticating without reading private host implementation state.

### Power users

The official CLI makes the common operations short, inspectable, and
scriptable:

```text
now guests list
now guests status --guest pb1400c
now connections list
now connections start
now connections stop
now connections disconnect <guest-session-id>
now console --guest pb1400c gestalt
now console --guest pb1400c --line 'catalog applications'
now files list --guest pb1400c 'Macintosh HD:Lab:'
now files put --guest pb1400c ./DiskCopy.img 'Macintosh HD:Lab:DiskCopy.img'
now files get --guest pb1400c 'Macintosh HD:Lab:Report' ./Report.bin
now transfers list
now transfers watch <transfer-id>
now events watch --guest pb1400c
```

Human output is the default. `--json` emits the API response shape without a
second CLI-only interpretation. Mutations return stable exit codes and never
turn a refusal into success because prose happened to look friendly.

## Connection semantics

Classic guests dial the host. The host cannot initiate a new TCP connection
to a running guest, so the public API must not invent a `connect guest`
operation that the product cannot perform.

The lifecycle operations are instead explicit:

| Product operation | Meaning |
|---|---|
| `listener.get` | Read desired/bound/failed ports and idle/listening/connected/failed state |
| `listener.start` | Start accepting inbound guest connections on the configured profile ports |
| `listener.stop` | Stop accepting and gracefully close all current guest sessions |
| `connections.list` | List exact live sessions and the stable guests they belong to |
| `connections.disconnect` | Gracefully close one exact session; an auto-reconnecting guest may return |

The CLI groups listener lifecycle under `now connections start|stop` because
that is the power-user intent, while help and JSON state name the actual
listener operation. `disconnect` is not `forget`, and `stop` is not a deny
list. Roster rename, durable forget, port reassignment, and changing the host
UI's driven guest remain separate administrative operations until their
authority and safety contracts are deliberately added.

## One canonical operation model

### Neutral descriptors

Every public operation has one `NOWOperationDescriptor` containing:

- stable `operationID` (`guests.list`, `listener.start`, `files.put`, etc.);
- API major and additive schema revision identity;
- semantic domain, verb, title, summary, and structured examples;
- typed request and response schema references;
- authority domain and required guest capabilities;
- effect class: read, bounded mutation, disruptive mutation, or bulk transfer;
- idempotency and cancellation behavior;
- addressability: host-wide, stable guest, or exact guest session;
- exposure declarations for HTTP, CLI, MCP, and app UI, each with evidence or
  an explicit reason it is not rendered.

The descriptor contains no MCP tool dictionary and no shell spelling. The MCP
adapter derives tool descriptors and annotations. The CLI derives ordinary
domain/verb grammar, then owns a small typed composition table only where one
human action spans several operations.

The existing 49-row MCP registry is evidence and implementation inventory, not
an automatic public API manifest. Each current row is adjudicated into exactly
one category:

1. a public NOW operation rendered by HTTP and, where suitable, MCP;
2. an MCP composition over one or more public NOW operations;
3. an agent-only convenience with a checked reason it is not a developer
   contract.

The workspace-file upload is the model for the distinction: the public
operation is `files.put`; reading a path inside a chat-granted workspace is
an MCP-specific way to supply that operation's source. Chat orchestration,
workspace grants, model-facing guidance, and similar agent mechanics do not
become public application concepts merely because a tool already exists.

### Typed service and dispatch

`NOWService` is the in-process application boundary used by every adapter. It
addresses a request, applies authentication/authorization and guest consent,
bounds it, invokes the existing host service, records the audit event, and
returns a typed result.

The existing `HostProjectionDispatch` behavior is preserved and generalized
rather than copied. Existing projection implementations continue to delegate
to `AgentIntegrationClient` and host automation. Listener and connection
administration join through typed service methods over `GuestListener`; they
do not masquerade as guest-owned facts.

The service result envelope is transport-neutral:

```json
{
  "requestId": "...",
  "operationId": "files.put",
  "guest": { "id": "pb1400c", "sessionId": "..." },
  "disposition": "completed",
  "value": {}
}
```

`disposition` is one of `completed`, `refused`, `unavailable`, `failed`,
or `cancelled`. A non-completed answer carries a stable code, safe message,
and reach. Domain values remain typed beneath `value`; adapters do not infer
success by searching arbitrary JSON for `ok`, `available`, or `outcome`.

### Public contract authority

`contract/now-api.openapi.json` is an OpenAPI 3.1 document and the public HTTP
wire authority. JSON is deliberate: repository scripts and the Python CLI can
parse and validate it with their standard libraries, without adding a YAML
runtime dependency.

A contract change starts there. A checked generator produces the Swift schema
identities/descriptors and CLI fixtures that would otherwise be duplicated.
The runtime operation catalog binds typed handlers to contract `operationId`s;
tests fail for an unbound contract operation, an uncontracted public handler,
or schema drift in either adapter.

The existing `contract/asyncapi.yaml` remains the authority for host/guest wire
messages. The public HTTP contract does not restate that wire.

## Public HTTP API v1

### Network shape

The current loopback HTTP service becomes one listener with two route families:

- `/api/v1/...` — ordinary NOW developer API;
- `/mcp` — MCP Streamable HTTP as today.

They share socket ownership, authentication policy, connection parsing,
request limits, and audit infrastructure. They do not share protocol sessions:
an API caller never performs MCP `initialize`, `tools/list`, or `tools/call`.
Stdio remains an MCP transport only.

V1 remains loopback-only. Remote/LAN serving, TLS termination, a background
daemon, and automatic app launching are later security/deployment decisions.
Third-party local applications receive a URL and standard auth bootstrap from
the NOW host UI rather than reading private preferences.

### Resource and action families

Exact paths are finalized in the OpenAPI contract, but v1 owns these
semantics:

```text
GET    /api/v1                         API identity and contract links
GET    /api/v1/operations              neutral operation catalog

GET    /api/v1/guests                  stable guests plus live session state
GET    /api/v1/guests/{guestID}        identity, status, and capabilities

GET    /api/v1/listener                configured/bound ports and state
PUT    /api/v1/listener                start on configured profile ports
DELETE /api/v1/listener                stop listener and close sessions

GET    /api/v1/connections             exact live guest sessions
DELETE /api/v1/connections/{sessionID} disconnect one exact session

POST   /api/v1/guests/{guestID}/commands

GET    /api/v1/guests/{guestID}/files
GET    /api/v1/guests/{guestID}/files/content
POST   /api/v1/guests/{guestID}/transfers
GET    /api/v1/transfers/{transferID}
DELETE /api/v1/transfers/{transferID}
GET    /api/v1/transfers/{transferID}/content

POST   /api/v1/operations/{operationID}
GET    /api/v1/events
```

The generic operation endpoint gives applications access to the remaining
typed catalog without proliferating bespoke routes. First-class resource
routes exist for the core workflows where HTTP semantics materially help:
identity, lifecycle, commands, files, transfers, and events.

### Authentication and authority

The API reuses the current host's unauthenticated, bearer, and OAuth modes and
their implementation, but defines API scopes separately from MCP tool
sessions. Recommended scopes are:

- `now.read` — guests, status, capabilities, listings, and events;
- `now.control` — bounded guest commands and mutations;
- `now.transfer` — file upload/download and transfer cancellation;
- `now.admin` — listener stop/start and exact-session disconnect.

Unauthenticated mode remains a deliberate host setting and conveys the same
local authority the mode currently conveys. Bearer uses the existing
same-user secret. OAuth uses authorization code + PKCE and human consent.
Credentials are never returned in discovery documents or written into normal
CLI JSON state.

Every mutation is audited through the shared service. The audit record names
the authenticated client, operation, addressed guest/session, disposition,
and bounded timing; it does not persist command arguments, file bytes, private
paths, or returned payloads.

### Console commands

`commands.execute` is an explicit v1 operation, not a CLI escape into a local
socket. It uses `GuestListener.runScheduledCommand`, which reaches the same
guest command dispatcher as typed features and the guest's own console.

The request accepts either:

- a declared command name with typed arguments; or
- a command name plus the raw argument line that the guest's console grammar
  parses.

The host validates that the connected guest advertised the command, applies
the guest's agent-access tier, limits names/arguments/output, uses the existing
watchdog, and audits the operation without storing arguments. Unknown,
unadvertised, timed-out, and disconnected are distinct typed dispositions.
There is no host shell, arbitrary process execution, or command batching.

### Files and transfers

The public API does not send bulk bytes as base64 MCP tool arguments.

Uploads stream an HTTP request body into bounded private host staging, compute
size and SHA-256 while receiving, then create a transfer resource that enters
the guest's existing single transfer lane. Downloads create or identify a
transfer and stream the completed host artifact as binary. Metadata states the
container (`data` or `macbinary`), classic type/creator when known, length,
digest, guest path, and disposition.

Transfer resources provide:

- opaque transfer ID;
- direction and exact guest session;
- queued/running/completed/refused/failed/cancelled state;
- byte progress where the underlying lane reports it;
- timestamps, digest, and safe refusal/failure code;
- cancellation through the existing bidirectional transfer cancel seam;
- bounded retention and private-stage cleanup.

The existing one-transfer-per-guest constraint remains true and visible.
HTTP backpressure, disconnect, retry, idempotency, and staging expiry are
specified before implementation. An interrupted HTTP upload never silently
becomes a guest transfer.

MCP exposes the same transfer semantics through safe references: a granted
workspace file, staged bytes, or an existing transfer ID. The current
workspace-upload projection remains an agent convenience, not the public
developer file protocol.

### Events

`GET /api/v1/events` is a server-sent event stream backed by `HostEventBus`.
V1 publishes a privacy-reviewed subset:

- listener state changed;
- guest connected/disconnected and roster changed;
- transfer progressed/ended;
- file tree changed;
- capability/status invalidation where a stable public schema exists.

Events carry event type, timestamp, applicable guest/session/transfer IDs, and
a bounded typed value. They never expose host file URLs, private paths, logs,
or internal Swift enum descriptions.

V1 is a live stream with heartbeat and explicit reconnect semantics. It does
not claim durable replay until an event store exists. A reconnecting client
refetches current resource state; `Last-Event-ID` is not accepted as proof of
replay the server cannot provide.

## MCP adapter

MCP continues to be a first-class agent surface, but its descriptor becomes a
rendering of `NOWOperationDescriptor` plus MCP-only annotations:

- tool name and agent-facing description;
- read-only/destructive/idempotent hints;
- guest-addressing argument injection;
- consent explanations;
- workspace grants and artifact attachment rendering;
- MCP session and JSON-RPC error mechanics.

Every MCP tool binds a canonical `operationID`. Every public operation declares
one of:

- rendered in MCP;
- represented by a named MCP composition over the same service;
- not representable in MCP, with a checked reason such as binary request body
  or continuous event stream.

Absence from MCP does not create a second meaning. For example, an HTTP file
body is transport-only; the underlying `files.put` operation and transfer
resource remain the same operation MCP initiates by workspace reference.

Existing MCP clients must continue to work through additive migration. Golden
tests capture current `tools/list`, tool-call results, consent behavior, and
audit records before descriptor extraction; the refactor must preserve them
except for explicitly reviewed additions.

## CLI architecture and behavior

The CLI is Python, standard-library-first, out of process, and a real public
API client. It never imports Swift code, reads the host's local socket
protocol, or falls back to MCP. If the public API is unavailable, it fails with
an actionable transport/authentication error instead of proving a different
surface works.

Modules follow real ownership:

```text
now-cli/
  now_cli/
    api/             HTTP, auth, contract identity, SSE
    model/           generated/public DTO bindings
    commands/        guests, connections, console, files, transfers, events
    render/          human tables/progress and JSON passthrough
    state/           endpoint preference and non-secret caches
    completion/      bounded schema/resource completion
  tests/
```

### Discovery and state

The official CLI may discover the saved loopback URL and selected auth mode
through one documented host bootstrap seam. That seam locates the API only; it
does not answer guest status or capabilities. Third-party clients use the host
UI's connection material or OAuth metadata.

CLI state is separated by meaning:

| State | Key/lifetime | Rule |
|---|---|---|
| Endpoint preference | named host profile | URL and non-secret display name only |
| Contract cache | endpoint + API major + contract digest | Offline help; never capability truth |
| Preferred guest | endpoint + stable guest ID | Convenience; every response echoes resolved session |
| Listing/completion hints | exact session + kind, short TTL | Hints only; mutations refetch |
| OAuth public registration | endpoint | Reusable public metadata |
| OAuth tokens | Keychain | Never ordinary CLI JSON |

### Grammar, help, and completion

One-to-one domain/verb commands derive from the neutral operation catalog and
OpenAPI schemas. A small checked composition table owns friendlier workflows
such as `now connections start` mapping to `listener.start`. It is not a
copied capability catalog.

Every public operation is either reachable from a CLI command or explicitly
marked library-only with a reason. `now api operations` exposes the canonical
inventory and `now api call <operation-id> --json-arguments ...` provides a
developer/power-user escape hatch without bypassing validation.

Help distinguishes the stable API surface from what the currently addressed
guest actually supports. Completion uses contract enums and bounded live
lookups with a short deadline; it never performs a mutation and never turns a
stale hint into a target decision.

### Exit status

| Exit | Meaning |
|---:|---|
| `0` | completed |
| `2` | refused or invalid invocation |
| `3` | guest/capability/resource unavailable |
| `4` | transport or authentication failure |
| `5` | API incompatibility or malformed server response |
| `6` | operation failed after admission |
| `130` | locally interrupted; cancellation attempted when applicable |

`--json` still uses these exits. Connection stop and other disruptive actions
require an interactive confirmation unless `--yes` is supplied; the HTTP API
itself remains non-interactive and relies on `now.admin` authorization.

## First-release scope

V1 includes:

- neutral operation descriptors and one shared dispatch/service boundary;
- generated OpenAPI contract and compatibility identity;
- loopback HTTP API beside `/mcp` on the existing service;
- guest roster, status, capabilities, listener lifecycle, connection listing,
  and exact-session disconnect;
- declared guest console command execution;
- core guest file operations, binary transfer resources, progress, and cancel;
- a live SSE event subset;
- an adjudicated disposition for every current MCP projection, with HTTP
  renderings for operations admitted to the public API and checked
  mappings/reasons for the rest;
- MCP migration onto the neutral catalog without client regression;
- the Python CLI, auth modes claimed by the release, completion,
  distribution, and user/developer documentation.

V1 does not include:

- initiating an outbound connection to a classic guest;
- remote/LAN exposure, TLS termination, or a background daemon;
- arbitrary host shell/process execution;
- roster forget/rename, profile port reassignment, or driven-guest mutation;
- a new guest message or command solely for API convenience;
- AppleScript/App Intents, official language SDK packages, or `now dev tasks`;
- durable event replay or concurrent guest transfer lanes.

Generated clients from OpenAPI are supported as a developer workflow, but
shipping and maintaining official Swift/TypeScript/Python SDK packages is a
later product commitment.

## Implementation slices

Each slice begins by reconciling the drift ledger against its actual base.
Contract, source, tests, and docs move together; implementation continues
through the whole approved plan rather than stopping after the foundation.

### S1 — contract and neutral operation seam

- add `contract/now-api.openapi.json`, compatibility rules, standard errors,
  operation/result envelopes, and the initial core schemas;
- introduce `NOWOperationDescriptor`, typed exposure declarations, and the
  checked contract binding/generator;
- inventory every current MCP projection as public operation, composition, or
  agent-only convenience before adding it to OpenAPI;
- migrate `HostProjection` rows away from `mcpDescriptor` to neutral request,
  response, effect, and presentation data;
- generalize `HostProjectionDispatch` into the shared service boundary while
  preserving addressing, consent, bounds, audit, and existing handlers;
- render current MCP descriptors from the neutral catalog;
- capture then enforce golden MCP parity.

Mutation evidence: an unbound OpenAPI operation, an uncontracted public
handler, a missing exposure declaration, schema drift, and one altered MCP
descriptor each fail the intended gate.

### S2 — HTTP foundation, identity, guests, and connections

- refactor the current HTTP listener into shared parsing/auth plus route
  adapters for `/mcp` and `/api/v1`;
- add API identity, contract digest, operation catalog, standard errors,
  request IDs, limits, and auth scopes;
- expose guests, status/capabilities, listener state/start/stop, live
  connections, and exact-session disconnect;
- prove stopping the guest listener does not stop the developer API listener;
- add API audit records without arguments or payloads;
- build a minimal fixture client that knows no Swift or MCP.

Mutation evidence: cross-route auth bypass, a stop that leaves a bound guest
port, a disconnect aimed by stable ID instead of exact session, and a private
host field leaked into JSON each fail.

### S3 — console operation

- add the OpenAPI command request/result schemas and limits;
- validate the command against the addressed guest's advertised command
  table;
- route typed arguments or raw argument line through
  `runScheduledCommand` with the existing watchdog;
- enforce control scope, consent tier, output bounds, and argument-free audit;
- add CLI `now console` behavior and completion from the guest command table.

Mutation evidence: an unadvertised command, wrong guest, omitted watchdog,
oversized result, and audit payload capture each fail.

### S4 — binary files and transfer resources

- add streaming upload staging, digest/length verification, expiry, and
  cleanup;
- bind admitted uploads and downloads to the existing guest transfer lane;
- add transfer list/get/cancel/content resources and state transitions;
- adapt current file list/stat/mutation operations to first-class routes;
- expose transfer progress through the neutral service;
- implement CLI file and transfer commands with progress and interruption.

Mutation evidence: partial upload admission, traversal/symlink escape, digest
mismatch, stale-session delivery, abandoned stage leakage, concurrent-lane
violation, and cancel-settles-success each fail.

### S5 — events

- define the privacy-reviewed public event schemas in OpenAPI;
- add a route mode that keeps an SSE response alive with heartbeat and
  bounded buffering;
- translate the allowed `HostEventBus` subset without internal enum strings or
  host paths;
- specify reconnect/refetch behavior without claiming replay;
- add `now events watch` and transfer watch behavior.

Mutation evidence: slow-consumer unbounded growth, leaked host URL/path,
wrong-guest event identity, and false replay acceptance each fail.

### S6 — complete API/MCP/CLI reach and UX

- render every remaining public neutral operation through generic HTTP
  invocation;
- finish the MCP exposure/reason matrix and agent-specific compositions;
- finish generated CLI grammar, human rendering, JSON passthrough, help,
  preferred guest, safe references, and Bash/Zsh completion;
- prove every operation's declared faces are real or carry a checked reason;
- run live interop against every auth mode claimed by the release.

### S7 — distribution and documentation

- settle bundle/repository installation and a stable `now` executable path;
- document OpenAPI discovery, authentication, scopes, compatibility, errors,
  events, transfer lifecycle, and local-only network posture;
- publish CLI task-oriented guides for guests, connections, console, files,
  transfers, and scripting;
- update README works/does-not-work, contract coverage, and open issues;
- verify a clean-clone installation and an independent fixture application
  generated or written solely from the public contract.

## Compatibility policy

- `/api/v1` and OpenAPI `info.version` identify the first public major.
- Additive optional fields, operations, and event types may ship within v1.
- Existing required fields do not change meaning within v1.
- Removing an operation, narrowing accepted input, changing a required field,
  or changing disposition semantics requires a new major or an explicitly
  documented compatibility bridge.
- The contract digest identifies the exact published OpenAPI document.
- The host build identifies the implementation serving it.
- MCP catalog version/digest and the internal local protocol remain separate
  implementation identities.

Clients must ignore unknown optional fields and event types, but never unknown
dispositions or API majors. The official CLI refuses a newer unsupported major
before attempting a mutation.

## Owner decisions before implementation

| ID | Decision | Recommended default | Blocks |
|---|---|---|---|
| A1 | First-release network reach | Loopback only | S2 |
| A2 | Full OAuth in the first CLI release | Yes; it proves third-party auth rather than same-user shortcuts | S2/S6 |
| A3 | Distribution | Bundle plus repository development entry point | S7 |
| A4 | Transfer staging ceiling and retention | Derive from existing 32 MiB single-file bound; short private retention with explicit cleanup | S4 |
| A5 | Exact OAuth scopes and disruptive-operation split | Four scopes in this plan; `now.admin` for listener/disconnect | S2 |

Already decided by Michelle on 2026-08-20:

- the API is for third-party developers, not an MCP wrapper;
- the CLI is for power-user guest operations;
- MCP is a semantic child of the API and a transport sibling to HTTP;
- `guest` is the normalized public noun;
- this is the first public API, therefore v1.

## Verification contract

| Claim | Required evidence |
|---|---|
| One semantic API exists | Contract-to-catalog binding and face parity matrix; no adapter-owned product handler and no automatic MCP-to-API promotion |
| MCP remains compatible | Golden descriptor/call fixtures and current MCP conformance suites |
| Developer API is independent of MCP | Fixture client performs core workflows without MCP initialization or tool names |
| CLI proves the public API | Network trace/fixture shows only `/api/v1`; no local protocol or MCP fallback |
| Guest addressing is safe | Stable-ID versus exact-session mutation tests and response identity echo |
| Listener lifecycle is honest | Start/stop/bind failure tests and explicit proof that host cannot dial a guest |
| Console reaches the shared guest face | Wire fixture plus `CommandParityTests`; no second command implementation |
| Binary transfer is bounded | Streaming/backpressure, staging cleanup, digest, session, lane, and cancel tests |
| Events are honest | Live-only reconnect test, bounded slow consumer, identity and privacy fixtures |
| Auth claims are real | Live independent-client interop against every claimed mode and scope |
| Public compatibility is enforceable | Old-v1 fixture suite runs against the new host revision |
| Product change is landable | `scripts/test-all`, applicable docs gates, current-head Emulator QA and Metal QA for product slices |

Builds, Tested, and Metal-verified remain distinct. An HTTP fixture proves the
host/API path it exercised; it does not prove guest behavior on a PowerBook.

## Stop conditions

Stop and return to architecture review if:

- an adapter needs private host state or a bespoke product handler to satisfy
  a public operation;
- HTTP and MCP need different meanings for the same operation rather than
  transport-specific representations;
- a requested `connect` behavior would require pretending the host can dial a
  guest;
- console execution cannot be bounded or authorized without silently
  narrowing the guest's declared command semantics;
- transfer streaming would bypass the existing guest lane, path policy,
  consent, or receipt authority;
- OAuth credentials would be stored in ordinary JSON;
- remote exposure, a daemon, a new dependency, or a guest contract change is
  required without owner approval;
- the implementation produces a second operation catalog that can drift from
  OpenAPI or the runtime binding.
