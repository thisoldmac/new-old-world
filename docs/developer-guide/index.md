---
page_id: dev-home
title: Developer guide
description: Entry point for understanding, changing, and verifying New Old World.
doc_type: explanation
audience: developer
lifecycle: current
authority: [AGENTS.md, contract/asyncapi.yaml]
source_dependencies: [AGENTS.md, contract/asyncapi.yaml, scripts/test-all]
media_ids: []
last_verified: 2026-08-09
---
# Developer guide

New Old World is a native macOS host, a PowerPC Carbon guest, a 68K Toolbox guest, and an optional resident extension. They share a versioned wire contract, but not a UI architecture or an implementation language.

Start with [orientation](orientation.md), then use the architecture pages to find the owning boundary. The workflow pages turn the repository's working rules into executable paths. The generated [AsyncAPI reference](../generated/asyncapi.md) is useful for lookup; `contract/asyncapi.yaml` remains authoritative.

The [documentation standard](reference/documentation-standard.md) records the web-facing choices: Diátaxis, AsyncAPI 3.0, Mermaid with text equivalents, a WCAG 2.2 AA target, Schema.org metadata, and RFC 9116 release assets.

## Change map

| Change | Start here | Required gate |
|---|---|---|
| Wire behavior | [Change the contract](workflows/change-the-contract.md) | `scripts/test-all` |
| Host or guest module | [Add a module](workflows/add-a-module.md) | module inventory plus platform tests |
| Resident component | [Resident components](architecture/resident-components.md) | bake gate plus full suite |
| Public documentation | [Documentation and gates](workflows/documentation-and-gates.md) | `scripts/test-docs` |
| Emulator or hardware evidence | [Emulator and metal](workflows/emulator-and-metal.md) | identity and machine guards |
