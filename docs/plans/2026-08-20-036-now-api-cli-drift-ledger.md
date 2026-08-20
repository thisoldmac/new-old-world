<!-- now-doc-provenance: generated reviewed=false -->

# 036 — NOW public API and power-user CLI drift ledger

Status: **active planning ledger**. Started 2026-08-20 while rewriting plan
036 from current `origin/main` `3922d2ab`.

This ledger tracks disagreement between the plan, its prototype evidence, and
the live repository. It is not a second architecture document. The companion
[plan](2026-08-16-036-feat-now-api-cli-plan.md) owns intended scope and
sequencing; current source and tests remain authoritative for what exists.

## How to maintain it

- Reconcile before each implementation slice and after rebasing or merging a
  slice onto a new base.
- Add a row when a source fact changes, a plan assumption is falsified, or an
  owner decision changes the intended contract.
- Keep the original observation. Update status and disposition with a dated
  note rather than rewriting history into a story where the drift never
  happened.
- Counts are evidence only when their derivation command and revision are
  present.
- `resolved-in-plan` means the plan now says the right thing. It does not mean
  product code exists.
- `implemented` requires a commit and verification status. `verified` names
  the exact build/host/guest or gate.

Statuses: `open`, `owner-decision`, `resolved-in-plan`, `implemented`,
`verified`, `superseded`.

## Baseline commands

Run from the repository root and record the revision beside the result:

```sh
git rev-parse HEAD
rg -c 'Projection\.self' \
  now-host/Sources/NOWAgentIntegration/Projection/HostProjectionCatalog.swift
rg -n 'public static let version' \
  now-host/Sources/NOWAgentIntegration/AgentIntegrationLocalProtocol.swift
rg -n 'case unauthenticated|case bearer|case oauth' \
  now-host/Sources/Host/MCP/HTTPMCPTransport.swift
rg -n 'catalogVersion|catalogDigest' \
  now-host/Sources/NOWAgentIntegration/Projection/HostProjectionRegistry.swift
```

The catalog count is not copied into the implementation as a constant. It is
the quickest alarm that the review surface has changed.

## Drift register

| ID | Observed drift | Evidence at `3922d2ab` | Disposition | Status |
|---|---|---|---|---|
| D-001 | Earlier draft and spike described 48 registry rows | `HostProjectionCatalog.swift` contains 49 `Projection.self` entries; `ChatsProjection` and `GuestFilesUploadFileProjection` postdate the spike baseline | Remove the frozen command manifest as authority; bind current rows to the neutral operation catalog and recheck before every dependent slice | resolved-in-plan |
| D-002 | Earlier plan described HTTP as bearer-token-only | `MCPHTTPAuthMode` now has `none`, `bearer`, and `oauth`; user guide and tests describe all three | API v1 uses a host-issued `X-API-Key`; MCP authentication remains unchanged; OAuth and scopes are deferred rather than inherited from MCP | resolved-in-plan |
| D-003 | Earlier CLI state model allowed only cache + preferred guest | OAuth would introduce client registration plus access/refresh credentials | Superseded for v1 by `X-API-Key`; the CLI stores one API key using the credential-storage decision in its slice | superseded |
| D-004 | Earlier plan treated audit as a per-call log | `MCP Records/records.sqlite` now stores bounded agents, sessions, targets, and actions without arguments/payloads | Generalize the bounded record around the shared service; API and MCP adapters do not log arguments or payloads | resolved-in-plan |
| D-005 | Earlier plan said every row already answered one completed/refused/unavailable envelope | Live results use several discriminators (`outcome`, `available`, `ok`) and consent/argument refusals may be JSON-RPC errors | Add one transport-neutral service disposition beside the typed domain value; MCP and HTTP render it without JSON field inference | resolved-in-plan |
| D-006 | Review language called the proposed public metadata “API v2” because `projectionCatalogVersion` is already 1 | No shipped surface is named/versioned `now-api`; catalog version is an internal compiled-surface identity | The first published product contract is now-api v1; keep public API version distinct from catalog version | resolved-in-plan |
| D-007 | Earlier compatibility text promised “same digest, same behavior” | `HostProjectionRegistry` defines the digest over sorted descriptors and calls it a callable-surface compatibility identity | Promise same catalog description only; use host build for implementation identity | resolved-in-plan |
| D-008 | Sticky machine preference and stale listing safety were both keyed to a “host session ID” | Session-health and roster identities describe the guest connection; stable guest id and exact guest session id are distinct | Persist stable guest preference; stamp ref/listing caches with exact guest connection session | resolved-in-plan |
| D-009 | Earlier S5 combined listener control, roster mutation, and driven-guest selection, so the MCP-centered rewrite deferred all three | `GuestListener.start(ports:)`, `stop()`, and exact-session closure are distinct from durable roster and UI-focus mutation | Restore listener start/stop and exact-session disconnect to v1; continue deferring rename/forget/port reassignment/driven-guest mutation | superseded |
| D-010 | Earlier S9 added PPC/68K AppleScript work while the same plan declared no guest changes | S9b–S9d require contract and guest work | Remove AppleScript from the first API/CLI release; retain `scripts` domain naming as the decided future boundary | resolved-in-plan |
| D-011 | Earlier plan had no complete distribution slice | A checkout-local Python file is not a user-facing installed command | Add an explicit distribution/install/docs slice and owner decision A3 | owner-decision |
| D-012 | Earlier plan split registry declarations and MCP publication into separate product PRs | Both modify `now-host/`, one public contract, and both trigger Emulator QA + Metal QA policy | Superseded by contract-first neutral catalog migration followed by adapter slices; MCP publication is no longer the public API boundary | superseded |
| D-013 | Prototype found eight leaked CLI MCP-over-HTTP sessions could lock out later clients | `MCPHTTPService` caps initialized sessions at eight, expires after 30 minutes, returns 429, and supports DELETE | Preserve as MCP transport evidence; the rewritten CLI uses ordinary `/api/v1` requests and owns no MCP session | superseded |
| D-014 | Original issue described local protocol v12 and 47 tools; August 16 prototype observed 48 tools | Current local protocol is v14 and catalog is 49 rows | Treat issue and prototype counts as dated evidence; local protocol remains private to now-api | resolved-in-plan |
| D-015 | Prototype is committed on an old branch forked at `12d6dac8` | `feat/now-cli-sketch` unique diff is the plan, spike README, and 432-line spike; refreshed branch begins at `3922d2ab` | Preserve branch as evidence; do not merge/cherry-pick the prototype into the plan-refresh branch | resolved-in-plan |
| D-016 | The first refreshed plan defined now-api as metadata published through MCP | Its architecture named `NOWMCPServer tools/list + tools/call` as the only public rendering and made the CLI an MCP client | Make the public OpenAPI contract and typed service authoritative; HTTP and MCP are adapters, and the CLI proves HTTP | resolved-in-plan |
| D-017 | The runtime registry authority is not client-neutral today | `HostProjection` requires `mcpDescriptor: [String: Any]`; accepted argument keys are explicitly derived from that MCP dictionary | Replace MCP dictionaries in operation rows with neutral typed/schema descriptors; derive MCP rendering and retain golden parity | resolved-in-plan |
| D-018 | The MCP-centered plan excluded connection lifecycle even though it is a primary API/CLI workflow | `GuestListener` already owns start, stop, live session identity, and graceful close behavior | Add listener state/start/stop, connection list, and exact-session disconnect to v1 with admin authority | resolved-in-plan |
| D-019 | Earlier API examples and internal source often used “machine” as the public resource noun | Current product discussion selects “guest” as the normalized term; “machine” remains meaningful for physical hardware/profiles | Use `guests`, `guestID`, and `guestSessionID` in the public contract and CLI | resolved-in-plan |
| D-020 | Current agent upload is not a general developer file protocol | MCP message bodies are bounded; staged bytes use begin/append/commit; `GuestFilesUploadFileProjection` is intentionally restricted to a granted workspace and reads one file whole | Add HTTP binary streaming plus transfer resources, progress, cancellation, digest, staging expiry, and cleanup; keep workspace upload as an MCP convenience | resolved-in-plan |
| D-021 | The current HTTP MCP service cannot provide the required event surface | `HTTPMCPTransport` closes each connection after one response and rejects GET; `HostEventBus` already publishes typed connection/transfer/file changes in-process | Add bounded SSE as an API route backed by a privacy-reviewed event translation; make v1 live-only and require refetch after reconnect | resolved-in-plan |
| D-022 | The typed MCP catalog does not expose a general console-command operation | `GuestListener.runCommand` and `runScheduledCommand` already reach the shared guest command dispatcher with watchdog behavior | Add a bounded, advertised-command-only, audited `commands.execute` API operation; no host shell or second command implementation | resolved-in-plan |
| D-023 | The MCP-centered plan made tools/list the CLI grammar and schema authority | Third-party applications need a stable published contract and should not initialize MCP to discover ordinary operations | Make OpenAPI plus neutral operation IDs authoritative; generate/check CLI grammar from that surface | resolved-in-plan |
| D-024 | “Start a connection” is ambiguous and could promise an impossible outbound dial | Guests initiate their TCP connection; the host can start accepting, stop accepting/close all, or disconnect one session | Define start/stop as listener lifecycle and disconnect as exact-session lifecycle; explicitly state the host cannot dial a guest | resolved-in-plan |
| D-025 | Sharing a service could still accidentally produce two sockets and two auth implementations | The existing host already owns a loopback HTTP listener and all three auth modes | Route `/api/v1` and `/mcp` on one listener with shared parsing/auth, separate protocol sessions, and one in-process service | resolved-in-plan |
| D-026 | Treating the current MCP registry as the new API manifest would still make the API an agent-tool wrapper | Some rows encode MCP-only workspace grants, chat orchestration, or model-facing presentation rather than application-domain concepts | Adjudicate every row as public operation, MCP composition, or agent-only convenience; publish only deliberate product operations in OpenAPI | resolved-in-plan |
| D-027 | The rewritten plan still said `/api/v1` would inherit MCP's none/bearer/OAuth modes and scope model | The owner selected one host-issued `X-API-Key` for API v1; `/mcp` must retain its independent none/bearer/OAuth behavior | Route both families through one bounded listener/parser, but authorize `/api/v1` only with `X-API-Key` and do not let either route's credential authorize the other | implemented in S2 (`65006191`); focused-tested |
| D-028 | The command URL addresses a stable guest, but the existing request-shaped guest API drives only the active session | `GuestListener.runScheduledCommand` deliberately targets `activeKey`; `selectGuest` warns that switching leaves module caches owned by the previous connection | S3 refuses a connected but inactive guest as `guest_not_addressed`, captures the active session before loading its advertised table, and refuses if that session changes; it does not silently switch or retarget | implemented in S3; focused-tested |
| D-029 | S3 planned `now console`, but no production CLI module or transport foundation exists after S2 | No CLI source/package/command tree exists in the S2 base; S6 owns the complete API-only CLI reach and distribution pass | Keep S3's HTTP console operation complete and add `now console` with the real CLI client in S6 rather than creating a throwaway command scaffold | resolved-in-plan |

## Owner decision register

| ID | Decision | Current options | Status | Resolution evidence |
|---|---|---|---|---|
| A1 | First-release network reach | loopback only; LAN/remote with a new security/deployment design | open | Recommended: loopback only |
| A2 | API v1 authentication | `X-API-Key`; OAuth; bearer token | decided | Michelle selected `X-API-Key`; MCP authentication remains unchanged; OAuth is deferred, 2026-08-20 |
| A3 | Distribution | bundled command; repository installer; both | open | Recommended: both |
| A4 | Transfer staging ceiling and retention | derive from current 32 MiB single-file bound; approve another measured ceiling/expiry | open | Requires S4 measurement |
| A5 | API scopes | read/control/transfer/admin split; another reviewed split | superseded | V1 API-key authorization has no scope model; revisit with OAuth or another multi-principal design |
| D5 | Meaning of `scripts` | AppleScript owns product domain; local runner is `now dev tasks` | decided | Michelle, 2026-08-16 |
| D6 | API product boundary | third-party developer API with CLI as first client; not an MCP wrapper | decided | Michelle, 2026-08-20 |
| D7 | MCP relationship | semantic child of the NOW API; transport sibling to HTTP | decided | Michelle, 2026-08-20 |
| D8 | Public resource noun | guest; machine reserved for physical hardware/profile contexts | decided | Michelle, 2026-08-20 |

## Slice reconciliation log

| Date | Slice/base | Catalog | Auth modes | Local protocol | New drift | Result |
|---|---|---:|---|---:|---|---|
| 2026-08-20 | plan rewrite / `3922d2ab` | 49 | none, bearer, OAuth | 14 | D-001–D-015 | Plan corrected; no implementation started |
| 2026-08-20 | architecture rewrite / `3922d2ab` | 49 | none, bearer, OAuth | 14 | D-016–D-026 | MCP-centered plan superseded by one public API with HTTP/MCP adapters; no implementation started |
| 2026-08-20 | S1 / `3b50e8b7` | 49 | API: `X-API-Key`; MCP: none, bearer, OAuth | 14 | API auth decision resolves D-002/D-003/A2/A5 | Neutral descriptor migration, 49-row adjudication, OpenAPI identity, checked generation, shared service seam, and MCP golden parity implemented and focused-tested in the same change |
| 2026-08-20 | S2 / base `4d7dde7e` | 49 | API: `X-API-Key`; MCP: none, bearer, OAuth | 14 | D-027 records the final separate-auth boundary | One listener now routes ordinary `/api/v1` identity, operation, guest, listener, and exact-session connection resources independently of MCP sessions. Seven API tests, one host-adapter test, four record-seam tests, the independent Python fixture client, eight existing MCP HTTP tests, eleven OAuth tests, and HTTP listener liveness pass. Auth bypass, omitted guest-listener stop, stable-ID disconnect, and private-field leakage mutations each failed the intended test. |
| 2026-08-20 | S3 / base `65006191` | 49 | API: `X-API-Key`; MCP: none, bearer, OAuth | 14 | D-028 records active-session command addressing; D-029 records the CLI dependency | `commands.execute` is bound in OpenAPI and HTTP to the existing scheduled guest command lane with per-session advertised-table validation, consent, input/output bounds, typed dispositions, and argument-free audit. Focused API, service, adapter, and catalog tests pass; unadvertised-command, wrong-guest, output-bound, and audit-payload mutations fail the intended tests. No guest command semantics changed, so CommandParityTests were not required. |

## Prototype evidence retained

The prototype on `feat/now-cli-sketch` demonstrated, against its dated host:

- registry-to-command generation was viable without a copied tool list, which
  now informs neutral operation-to-CLI generation rather than tools/list;
- a per-invocation MCP-over-HTTP client must release its MCP session, which
  remains MCP evidence rather than a requirement for the new HTTP API client;
- stdio can complete MCP initialization without reaching a live host, so a
  transport fallback must be visible and host availability must be tested
  separately;
- generic scripting exit codes need a published cross-operation disposition.

It did not prove current 49-row parity, current auth-mode interoperability,
OAuth credential handling, packaging, or a production module structure. Those
remain work in the rewritten plan.
