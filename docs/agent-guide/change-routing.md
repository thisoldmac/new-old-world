---
page_id: agent-change-routing
title: Route a change through its owners
description: Map an authorized coding change to the developer guide, owning source, paired documentation, and required gate.
doc_type: how-to
audience: agent
lifecycle: current
authority: [AGENTS.md, contract/asyncapi.yaml]
source_dependencies: [AGENTS.md, contract/asyncapi.yaml, docs/developer-guide/index.md, docs/module-manifest.yaml, docs/feature-catalog.yaml, scripts/test-all]
media_ids: []
last_verified: 2026-08-09
---

<!-- now-doc-provenance: generated reviewed=false -->

# Route a change through its owners

## Identify the behavior and owner

Use the [codebase orientation](../developer-guide/orientation.md) to trace
the visible behavior. Do not begin at the first matching string if a contract,
registry, shared model, or resident table owns the meaning.

## Follow the matching route

| Requested change | Developer documentation | Agent-specific completion rule |
|---|---|---|
| Wire message, field, command, or limit | [Change the contract](../developer-guide/workflows/change-the-contract.md) | Update the contract first; name both receiving directions and deliberate asymmetry |
| Host or Workshop module | [Add a module](../developer-guide/workflows/add-a-module.md) | Update live registries, manifest, public module page, media slots, and inventory gate together |
| Host model or UI | [Host architecture](../developer-guide/architecture/host.md) | Keep business behavior in the owning model and native-control work in adapters |
| PowerPC guest behavior | [PowerPC architecture](../developer-guide/architecture/ppc-guest.md) | Preserve console/wire parity and pump the wire through nested Toolbox loops |
| Resident plane or shared layout | [Resident components](../developer-guide/architecture/resident-components.md) | Change the shared header once, run native guards, and satisfy or explicitly defer the exact-source bake before checkpointing |
| Public docs or availability | [Documentation and gates](../developer-guide/workflows/documentation-and-gates.md) | Keep user, developer, and coding-agent audiences distinct; rederive every moved source |

## Verify proportionally

Run the smallest owning test while iterating, then the documented subsystem
gate. Run `scripts/test-all` when the change crosses subsystems or is being
prepared to land. If a required toolchain or machine is unavailable, report
the skip as an unverified surface rather than converting it into success.
