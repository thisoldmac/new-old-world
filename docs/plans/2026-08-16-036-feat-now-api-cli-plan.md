<!-- now-doc-provenance: generated reviewed=false -->

# 036 — now-api and now-cli: plan

Status: **architecture review, not approved for implementation** (rewritten
2026-08-20 against `origin/main` `3922d2ab`). This plan supersedes the option
list in issue #33 and the earlier draft on `feat/now-cli-sketch`. That branch's
prototype remains evidence; it is not product code and is not carried into
this branch.

The product direction already established in discussion remains the center:

- Build the API with the CLI as its first client.
- Keep the CLI Python, standard-library-first, user-facing, and out of
  process on purpose. It must obtain product capabilities through the
  published surface rather than shared Swift compilation.
- Publish the host registry through the existing MCP server. Do not add a
  REST bridge, daemon, guest listener, second socket, or second dispatch
  implementation.
- Generate ordinary CLI commands from the published surface. Hand-written
  composition is permitted only where one user action genuinely spans
  several published calls, and every exception is inventoried and gated.

The current source observations and their dispositions live in the companion
[drift ledger](2026-08-20-036-now-api-cli-drift-ledger.md). The plan states
intent; the ledger says which live facts that intent was checked against.

## Naming and version correction

There is no shipped `now-api` v1 today. The first public contract created by
this work is therefore **now-api v1**.

`HostProjectionRegistry.catalogVersion` currently equals `1`, but that is an
existing internal compatibility identity for the compiled projection catalog.
It is not proof that a public product API already exists, and it must not be
renamed or presented as `now-api v1` by implication. The two versions answer
different questions:

| Identity | Owner | Meaning |
|---|---|---|
| `nowApiVersion` | published MCP extension | Shape and semantics a now-api client may depend on; first value is `1` |
| `projectionCatalogVersion` | host implementation | Compatibility shape of the compiled projection catalog and companion |
| `projectionCatalogDigest` | host implementation, exposed as identity | Exact published catalog descriptors compiled into this host |
| host build | host implementation | Exact executable implementation serving the descriptors |

The public compatibility statement for pre-1.0 clients is deliberately small:

- the same `nowApiVersion` means the same required public shape and
  semantics;
- the same catalog digest means the same catalog description, not necessarily
  identical runtime behavior;
- the host build identifies the implementation;
- a breaking change to the required public shape moves `nowApiVersion`;
- an additive row or descriptor-content change moves the digest, not the API
  version;
- no broader cross-version compatibility promise exists before 1.0.

## Live baseline

The implementation begins from current `origin/main`, not from the prototype
branch's August 16 snapshot.

| Surface | Current observation at `3922d2ab` | Consequence |
|---|---|---|
| Registry | 49 `HostProjection` rows | Never use the earlier 48-row table as an implementation manifest |
| Local adapter | `AgentIntegrationLocalProtocol.version == 14` | Internal transport only; not part of now-api |
| HTTP authentication | unauthenticated, bearer, or OAuth | CLI bootstrap must be mode-aware |
| HTTP sessions | eight by default, 30-minute expiry, explicit `DELETE` | A short-lived CLI owns and closes every session it creates |
| Audit | durable MCP agent/session/target/action records | CLI identity and every call are visible through the existing audit path |
| Result shapes | heterogeneous (`outcome`, `available`, `ok`, plus JSON-RPC errors) | Generic exit codes require a real common result disposition, not prose claiming one exists |

No count in this section is a standing product claim. The drift ledger records
the source and recheck command; implementation re-derives before every slice
that depends on it.

## Architecture

### One authority, one published rendering, one first client

```text
HostProjectionCatalog + HostProjection rows       registry authority
                 |
                 v
NOWMCPServer tools/list + tools/call               existing MCP face
                 |
                 +-- stdio companion              same-UID host adapter
                 +-- loopback Streamable HTTP     none / bearer / OAuth
                                  |
                                  v
                              now-cli              first now-api v1 client
```

`now-api` is not a new process. It is the explicitly named and versioned
client contract published by the existing MCP face. The internal local socket
operations, Swift model types, guest wire, and listener implementation remain
private.

If the CLI needs a product fact that the public rendering cannot express, the
default diagnosis is an API defect in that rendering. The repair belongs in
the registry or its MCP renderer, not in a CLI-only host-state side channel.
Local endpoint and credential discovery are the narrow bootstrap exception
described below; they locate and authenticate the API but do not answer a
product capability.

### now-api v1 published contract

A conforming v1 client may depend on exactly these parts:

1. MCP `initialize`, `tools/list`, `tools/call`, and the Streamable HTTP
   session lifecycle including `DELETE`.
2. Ordinary MCP tool fields: `name`, `title`, `description`, `inputSchema`,
   `outputSchema`, and annotations.
3. One namespaced now-api metadata object per tool containing:
   `nowApiVersion`, `domain`, canonical `verb`, short `summary`, and
   structured `examples` whose arguments are JSON values rather than shell
   strings.
4. One namespaced now-api result-disposition object on every successful
   `tools/call` result: `completed`, `refused`, or `unavailable`, with
   structured `code`, `message`, and `reach` where the state supplies them.
   Existing `structuredContent` remains the tool-specific value and is not
   wrapped or rewritten merely for the CLI.
5. JSON-RPC errors for malformed calls, unknown tools, invalid arguments, and
   consent denial. The v1 contract states how those map into a CLI refusal
   without pretending they are successful tool results.
6. `now_list_machines` for current host/guest identity and
   `now_session_capabilities` for the connected guest's per-tool
   `available` / `unavailable` / `unproven` state.
7. Host compatibility identity: catalog version, catalog digest, and host
   build, read from the current session-health response.

The exact extension namespace remains an owner decision before implementation;
the semantic members above do not. Tests consume the chosen namespace through
one constant so it cannot fork across renderer, fixtures, and clients.

### Result disposition is additive

The current result types are intentionally varied because they carry different
domain answers. now-api v1 does not flatten those answers into one lowest
common denominator.

Instead, `HostProjectionValue` gains a small typed disposition beside its
encoded value. `NOWMCPServer` renders that disposition as namespaced result
metadata while leaving `structuredContent`, image attachments, and existing
output schemas intact. A result type or adapter must state its disposition
through a typed seam; the renderer must not infer it by searching arbitrary
JSON for `available`, `ok`, or `outcome`.

This is the generic basis for CLI exit codes:

| CLI exit | Meaning |
|---|---|
| `0` | completed |
| `2` | refused, including invalid arguments or consent denial |
| `3` | capability or target unavailable |
| `4` | no usable transport or authentication could be established |
| `5` | client/API incompatibility or malformed server result |

`--json` prints the complete MCP tool result, including its now-api metadata;
it does not substitute the CLI's human rendering.

### Published presentation is client-neutral

The API publishes a semantic `domain` and canonical `verb`, not a
CLI-specific `cliName`. The first client renders those as
`now <domain> <verb>`, while another client may render the same identity
differently.

Examples are structured:

```json
{
  "title": "List the Lab folder",
  "arguments": { "path": "Lab" }
}
```

The CLI derives shell syntax from the schema and arguments. No client parses a
shell command string to recover API data.

Every row must declare a domain, verb, summary, and at least one structured
example when it has required arguments. There are no default implementations:
a new row that has not considered its human surface fails to compile.

### Authority and audit

The CLI has no privileged face. Guest consent, guest standing, path bounds,
receipts, and auditing remain host-side in `HostProjectionDispatch`. The
official CLI supplies bounded MCP `clientInfo` so the durable MCP record can
identify its stated name and version; that identity is visibility, not an
authorization boundary.

The three HTTP modes do not change product authority:

- unauthenticated accepts any process that can reach the loopback listener;
- bearer accepts the existing same-user token;
- OAuth uses the host's authorization-code + PKCE flow and human consent.

The stdio companion remains kernel/same-UID authenticated. Moving between
transports is always announced on stderr. A fallback that completes an MCP
handshake without a live host is not reported as a live host connection.

### Bootstrap and credential ownership

The official local CLI and a third-party client have different bootstrap
paths but reach the same API:

- The official CLI may discover the saved loopback port and selected HTTP
  authentication mode from NOW's local preferences, then authenticate by the
  corresponding mode. This is discovery only; no capability answer comes
  from preferences.
- A third-party client receives a URL and authentication material through the
  host's MCP page or follows the standard OAuth challenge and metadata.
- Bearer secrets are read from the existing mode-`0600` token file.
- OAuth client registration metadata may live in CLI state, but access and
  refresh tokens belong in macOS Keychain. They are not JSON cache entries.
- Unauthenticated mode sends no credential.
- `--url` overrides local discovery for an explicitly supplied endpoint.

Full OAuth support in the first CLI release remains an owner decision. If it
is deferred, the CLI must refuse OAuth mode explicitly and may offer stdio
only when the host actually exposes the same-UID socket. It may not silently
downgrade the selected HTTP authentication posture.

### State ownership and lifetimes

The host remains authoritative. CLI state is separated by meaning:

| State | Lifetime and key | Use |
|---|---|---|
| Registry cache | endpoint + now-api version + catalog digest | Offline surface/help only |
| Preferred machine | endpoint/profile + stable machine id | User preference; survives guest reconnect |
| Listing cache | exact guest connection session + listing kind | Index/name convenience; refused after reconnect |
| Filesystem completion hints | stable machine id + share label + path | 30-second fresh window, LRU-capped, stale hints permitted on deadline |
| OAuth public registration | endpoint | Reusable client registration metadata |
| OAuth tokens | Keychain | Credentials, never ordinary CLI JSON state |

A cached listing or completion hint never decides an action. Name resolution,
file destinations, and any mutation refetch the relevant listing in the same
breath. A stale completion costs a wasted Tab press, never a wrong target.

### Generated and composed commands

The implementation derives the command inventory from current `tools/list`.
This plan deliberately does not freeze a 49-row copy that will look
authoritative after the 50th row lands.

Commands fall into three classes:

1. **Generated:** one domain/verb maps to one registry row; flags,
   requiredness, enums, examples, and help come from the API.
2. **Composed:** one user operation invokes several published rows or exposes
   an operation discriminator as subcommands. The CLI owns one typed table
   naming every component row. Tests fail if a component disappears or any
   current registry row becomes unreachable through the CLI.
3. **CLI-local:** help, API inspection, connection diagnostics, machine
   preference, completion generation, and `now dev tasks`. These are labelled
   local and never presented as host capabilities.

Likely composed families include status, staged file upload, and rows whose
own input schema declares an operation enum. The exact list is derived and
reviewed in the implementation slice; this sentence is not permission to
invent friendlier behavior that changes host semantics.

### References and paths

Reference-shaped arguments accept an opaque id, exact name, or an index from
the last listing of that kind:

- opaque ids pass through for host validation;
- names resolve exactly once against a fresh listing, with ambiguity refused;
- indices resolve only against a listing stamped with the current guest
  connection session;
- stale references render the host refusal rather than becoming a CLI guess.

The CLI renders guest file paths in Unix form and converts once at the invoke
boundary to the wire's share-relative HFS-colon form. The API description for
the file rows must state the wire grammar before the CLI depends on it. Tests
cover root, nesting, and the classic `/`-in-name to `:`-on-Unix swap in both
directions.

### Help and completion

`now help`, `now <domain> help`, and verb `--help` are generated from the
cached-or-live API description. When connected, domain help joins the
capability report without collapsing its three states. Offline help says
**surface, not this guest**.

`now completion bash|zsh` emits thin shell adapters around one hidden
completion entry point:

- static candidates come from the registry cache;
- live references use a roughly 300 ms deadline and fall back to cached hints
  or silence;
- filesystem candidates list the partial path's parent and use a 30-second
  freshness window with stale-while-deadline behavior;
- completion never performs a mutation or settles a costly capability probe.

### The local development-task exception

Michelle's 2026-08-16 naming decision remains: AppleScript owns the
`scripts` product domain, and the local repository runner is
`now dev tasks`.

`now dev tasks` is explicitly CLI-local. It derives executable tasks from a
registered `scripts/` directory, passes argv/stdin/stdout/exit status through,
and does not touch MCP, the guest, or now-api. Its inclusion in the executable
does not make workstation scripts part of the public host API.

## Scope of the first release

The first now-api/now-cli release covers the capabilities already published
by the current host registry plus the metadata/result contract needed to
consume them generically.

It does **not** add:

- host listener mutation, roster rename/forget, or driven-machine mutation;
- AppleScript projection, libraries, compile-checking, dictionaries, or a 68K
  OSA implementation;
- a guest wire or contract change;
- `now shell`;
- REST, a daemon, remote non-loopback serving, or app launching;
- a second host dispatch implementation.

Host administration and AppleScript are follow-on product arcs. They must not
be smuggled into the API foundation as metadata work.

## Implementation slices

Each slice begins by reconciling the drift ledger against its actual base
revision.

### S1 — publish now-api v1 atomically

One host/API PR:

- add the chosen public namespace and `nowApiVersion == 1`;
- add required domain, verb, summary, and structured-example declarations to
  every registry row;
- add the typed result disposition beside `HostProjectionValue`;
- render tool and result metadata through `NOWMCPServer`;
- retain existing structured results and conforming MCP behavior;
- extend registry, schema, descriptor, parity, and conformance tests;
- rederive MCP coverage and current documentation.

This is one PR rather than the earlier S1/S2 split because both halves modify
the same public contract and both trigger the repository's Emulator QA and
Metal QA policy. No intermediate state where fields exist but are unpublished
has product value.

Mutation evidence must prove: an omitted row field fails compilation; a stale
structured example fails schema validation; a renderer dropping one row's
metadata fails; and a tool value misclassified as completed/unavailable fails
the result-disposition test.

### S2 — CLI transport, authentication, and lifecycle core

Create `now-cli/` from behavior learned in the prototype, not by copying the
prototype forward unreviewed:

- stdlib-first Python package/executable layout with internal modules by real
  ownership rather than one catch-all file;
- HTTP request/session lifecycle and unconditional best-effort `DELETE` on
  normal exit, error, and signals;
- unauthenticated and bearer paths;
- OAuth DCR, PKCE, loopback callback, browser consent, refresh, revocation
  response handling, and Keychain storage if full OAuth is approved;
- stdio companion fallback with explicit diagnostics;
- fake HTTP and stdio servers covering framing, session pressure, auth modes,
  fallback, and host-unavailable behavior;
- `scripts/test-cli`, added to `scripts/test-all` before the host gate.

The current host's three auth modes become the interop matrix. A self-test is
not real-client interop; the CLI must connect to a current host in each mode
the release claims.

### S3 — generated grammar, outcome handling, and help

- typed model for tools/list plus now-api metadata;
- generated domain/verb grammar and schema-derived flags;
- JSON-first coercion with explicit handling for arrays/objects;
- generic result-disposition to exit-code mapping;
- human rendering and verbatim `--json`;
- connection-aware and offline-honest help;
- parity test: every published row is reachable through a generated or
  declared composed command.

### S4 — machine, reference, path, and completion UX

- `now guests`, `now use`, and per-call `--guest`;
- stable machine preference separated from exact-session listing caches;
- opaque-id / exact-name / session-stamped-index resolution;
- Unix/HFS path normalization at one invoke boundary;
- Bash and Zsh completion with bounded live deadlines and hint-only caches.

### S5 — local development tasks

- `now dev tasks list|run|register`;
- derived executable inventory and descriptions;
- passthrough argv, stdio, and exit status;
- completion from the same derived inventory;
- tests that refuse non-executable, missing, ambiguous, or unregistered tasks.

### S6 — distribution and user documentation

The release is not complete when a script exists only in a checkout.

- settle bundle/repository installation and the stable `now` executable path;
- document Python and macOS prerequisites;
- document URL/auth bootstrap for the official CLI and third-party clients;
- add the user-guide page, README works/does-not-work pair, and open-issues
  closeout;
- verify a clean-machine/clean-clone installation path appropriate to the
  chosen distribution decision.

## Owner decisions before implementation

| ID | Decision | Recommended default | Blocks |
|---|---|---|---|
| A1 | Exact namespaced MCP metadata key | Reverse-domain NOW-owned key, one constant | S1 |
| A2 | Publish canonical short verbs or mechanical row-derived verbs | Canonical semantic short `verb` | S1 |
| A3 | Full OAuth in the first official CLI release | Yes; it is the first real-client interop proof | S2 |
| A4 | Distribution: bundled tool, repository installer, or both | Bundle plus repository development entry point | S6 |
| A5 | Public pre-1.0 compatibility wording | The narrow version/digest/build statement in this plan | S1 docs |

Already decided:

- D5: AppleScript owns `scripts`; the local runner is `now dev tasks`.

Deferred from this plan rather than silently decided:

- publishing a host-administration mutation domain;
- server-side session eviction/reuse beyond the existing expiry and client
  `DELETE` contract;
- AppleScript capability scope across PPC and 68K guests.

## Verification contract

| Claim | Required evidence |
|---|---|
| Public surface is registry-derived | Current catalog parity test and CLI reachability test |
| now-api v1 is generic | Fixture client uses only published metadata, schemas, result disposition, and identity oracles |
| Existing MCP clients remain conforming | MCP conformance suites ignore the additive namespaced metadata and still pass |
| Results are generically classifiable | One test per disposition plus invalid-argument and consent JSON-RPC errors |
| HTTP lifecycle is bounded | DELETE leak mutation fails; 429 is actionable; signal/error cleanup covered |
| Auth claims are real | Live CLI interop against every claimed current host auth mode |
| Offline help is honest | Cache fixture labels surface-only and never asserts guest availability |
| Target selection is safe | Exact-session stale index, ambiguous name, stable machine preference, and host refusal tests |
| Path conversion is lossless | Root/nesting and slash-colon round-trip fixtures |
| Completion cannot decide | Deadline/cache tests plus fresh refetch at every actual resolution/mutation |
| Product change is landable | `scripts/test-all`, current-head Emulator QA and Metal QA for S1, plus applicable docs gates |

Builds, Tested, and Metal-verified remain distinct statuses. A live host
interop result proves only the host and authentication mode named in its
receipt.

## Stop conditions

Stop and return to architecture review if:

- a required CLI behavior can only be implemented by reading private host
  capability state outside bootstrap;
- a generic result disposition cannot be stated without erasing a domain
  fact existing clients need;
- OAuth credential storage would put refresh/access tokens in ordinary JSON;
- a new command requires guest or contract behavior not already published;
- the generated grammar needs per-row client code outside the declared
  composition table;
- distribution requires a new dependency or deployment target not approved by
  Michelle.
