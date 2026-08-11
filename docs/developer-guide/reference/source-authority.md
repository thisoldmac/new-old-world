---
page_id: dev-ref-source-authority
title: Source authority
description: Which file owns each class of durable claim and which documents are projections.
doc_type: reference
audience: developer
lifecycle: current
authority: [AGENTS.md]
source_dependencies: [AGENTS.md, contract/asyncapi.yaml, docs/module-manifest.yaml, docs/reference-index.yaml, tools/derived-doc-gate]
media_ids: []
last_verified: 2026-08-09
---
# Source authority

| Claim | Authority | Projection or ledger |
|---|---|---|
| Wire messages, fields, commands, limits | `contract/asyncapi.yaml` | `docs/generated/asyncapi.md`, contract coverage |
| Host module identity | `ModuleRegistry.standard` | `docs/module-manifest.yaml`, module pages |
| PowerPC Workshop pages | `WorkshopModuleID` | module manifest and pages |
| Resident memory layout | `contract/peek_table.h` | resident architecture pages |
| Current defects and unknowns | live code/tests plus evidence | `docs/open-issues.md`, `docs/known-wrong.md` |
| Documentation publication contract | `mkdocs.yml`, `tools/docs-gate` | rendered site |

Generated or derived documents must declare their source set and runnable derivation. Re-run the derivation after merges that touched any source, even when the textual merge was clean. Prose should link to an authoritative table rather than restating an enumeration.

