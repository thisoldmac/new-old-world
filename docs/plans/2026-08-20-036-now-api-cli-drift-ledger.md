<!-- now-doc-provenance: generated reviewed=false -->

# 036 — now-api and now-cli drift ledger

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
| D-001 | Earlier draft and spike described 48 registry rows | `HostProjectionCatalog.swift` contains 49 `Projection.self` entries; `ChatsProjection` and `GuestFilesUploadFileProjection` postdate the spike baseline | Remove the frozen command manifest as authority; derive the CLI inventory from current tools/list and recheck before every dependent slice | resolved-in-plan |
| D-002 | Earlier plan described HTTP as bearer-token-only | `MCPHTTPAuthMode` now has `none`, `bearer`, and `oauth`; user guide and tests describe all three | Make CLI bootstrap/authentication mode-aware; decide whether full OAuth ships in the first CLI | owner-decision |
| D-003 | Earlier CLI state model allowed only cache + preferred guest | OAuth introduces client registration plus access/refresh credentials | Keep public registration metadata in CLI state and credentials in Keychain; exact first-release OAuth scope remains A3 | owner-decision |
| D-004 | Earlier plan treated audit as a per-call log | `MCP Records/records.sqlite` now stores bounded agents, sessions, targets, and actions without arguments/payloads | Supply bounded CLI clientInfo and preserve existing audit dispatch; no CLI privilege | resolved-in-plan |
| D-005 | Earlier plan said every row already answered one completed/refused/unavailable envelope | Live results use several discriminators (`outcome`, `available`, `ok`) and consent/argument refusals may be JSON-RPC errors | Add typed, namespaced result disposition beside existing structured content; do not infer by JSON field search | resolved-in-plan |
| D-006 | Review language called the proposed public metadata “API v2” because `projectionCatalogVersion` is already 1 | No shipped surface is named/versioned `now-api`; catalog version is an internal compiled-surface identity | The first published product contract is now-api v1; keep public API version distinct from catalog version | resolved-in-plan |
| D-007 | Earlier compatibility text promised “same digest, same behavior” | `HostProjectionRegistry` defines the digest over sorted descriptors and calls it a callable-surface compatibility identity | Promise same catalog description only; use host build for implementation identity | resolved-in-plan |
| D-008 | Sticky machine preference and stale listing safety were both keyed to a “host session ID” | Session-health and roster identities describe the guest connection; stable machine id and exact session id are distinct | Persist stable machine preference; stamp ref/listing caches with exact guest connection session | resolved-in-plan |
| D-009 | Earlier S5 added listener control, roster mutation, and driven-machine selection to the foundation | Current health already reports listener state; listener stop/port mutation can disrupt the transport carrying the call | Defer host administration to its own authority/parity arc | resolved-in-plan |
| D-010 | Earlier S9 added PPC/68K AppleScript work while the same plan declared no guest changes | S9b–S9d require contract and guest work | Remove AppleScript from the first API/CLI release; retain `scripts` domain naming as the decided future boundary | resolved-in-plan |
| D-011 | Earlier plan had no complete distribution slice | A checkout-local Python file is not a user-facing installed command | Add an explicit distribution/install/docs slice and owner decision A4 | owner-decision |
| D-012 | Earlier plan split registry declarations and MCP publication into separate product PRs | Both modify `now-host/`, one public contract, and both trigger Emulator QA + Metal QA policy | Publish now-api v1 atomically in one host PR | resolved-in-plan |
| D-013 | Prototype found eight leaked CLI HTTP sessions could lock out later clients | `MCPHTTPService` caps initialized sessions at eight, expires after 30 minutes, returns 429, and supports DELETE | Require best-effort DELETE on every CLI exit path; defer any server reuse/eviction policy to separate transport hardening | resolved-in-plan |
| D-014 | Original issue described local protocol v12 and 47 tools; August 16 prototype observed 48 tools | Current local protocol is v14 and catalog is 49 rows | Treat issue and prototype counts as dated evidence; local protocol remains private to now-api | resolved-in-plan |
| D-015 | Prototype is committed on an old branch forked at `12d6dac8` | `feat/now-cli-sketch` unique diff is the plan, spike README, and 432-line spike; refreshed branch begins at `3922d2ab` | Preserve branch as evidence; do not merge/cherry-pick the prototype into the plan-refresh branch | resolved-in-plan |

## Owner decision register

| ID | Decision | Current options | Status | Resolution evidence |
|---|---|---|---|---|
| A1 | Exact now-api metadata namespace | reverse-domain NOW key; shorter `_meta.now` key | open | — |
| A2 | Canonical published verb | semantic short verb; mechanical row-derived verb | open | — |
| A3 | OAuth in first CLI release | full OAuth + Keychain; explicit OAuth refusal with stdio only when available | open | — |
| A4 | Distribution | bundled command; repository installer; both | open | — |
| A5 | Compatibility statement | narrow API-version/catalog-digest/host-build contract; alternative owner wording | open | — |
| D5 | Meaning of `scripts` | AppleScript owns product domain; local runner is `now dev tasks` | decided | Michelle, 2026-08-16 |

## Slice reconciliation log

| Date | Slice/base | Catalog | Auth modes | Local protocol | New drift | Result |
|---|---|---:|---|---:|---|---|
| 2026-08-20 | plan rewrite / `3922d2ab` | 49 | none, bearer, OAuth | 14 | D-001–D-015 | Plan corrected; no implementation started |

## Prototype evidence retained

The prototype on `feat/now-cli-sketch` demonstrated, against its dated host:

- registry-to-command generation was viable without a copied tool list;
- a per-invocation HTTP client must release its MCP session;
- stdio can complete MCP initialization without reaching a live host, so a
  transport fallback must be visible and host availability must be tested
  separately;
- generic scripting exit codes need a published cross-tool disposition.

It did not prove current 49-row parity, current auth-mode interoperability,
OAuth credential handling, packaging, or a production module structure. Those
remain work in the rewritten plan.
