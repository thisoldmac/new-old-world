---
page_id: dev-home
title: Developer guide
description: Entry point for reading, debugging, changing, and verifying the New Old World codebase.
doc_type: explanation
audience: developer
lifecycle: current
authority: [README.md, contract/asyncapi.yaml]
source_dependencies: [README.md, contract/asyncapi.yaml, scripts/test-all, docs/developer-guide/orientation.md]
media_ids: []
last_verified: 2026-08-09
---
# Developer guide

This guide is for developers digging into the code: understanding why a
boundary exists, tracing a behavior across processes, finding the
implementation that owns it, running the right test, and preparing a
reviewable change.

New Old World is a native macOS host, a PowerPC Carbon guest, an optional
resident extension, and a retained 68K Toolbox sibling. The initial alpha
includes the first pair, offers the extension as an optional component, and
excludes the currently stale pre-Carbon build. They share a versioned wire
contract, but not a UI architecture or implementation language.

Start with [orientation](orientation.md), then use the architecture pages to
find the owning boundary and the workflow pages to make a specific kind of
change. The generated [AsyncAPI reference](../generated/asyncapi.md) is useful
for lookup; `contract/asyncapi.yaml` remains authoritative.

If you are a coding agent, begin with the separate [coding agent
guide](../agent-guide/index.md). It overlays operating protocol on this guide;
it does not duplicate the architecture.

The [documentation standard](reference/documentation-standard.md) records the web-facing choices: Diátaxis, AsyncAPI 3.0, Mermaid with text equivalents, a WCAG 2.2 AA target, Schema.org metadata, and RFC 9116 release assets.
The [initial-alpha feature profile](../user-guide/reference/release-profile.md)
is machine-readable and drives feature-page availability notices.

## Change map

| Change | Start here | Required gate |
|---|---|---|
| Wire behavior | [Change the contract](workflows/change-the-contract.md) | `scripts/test-all` |
| Host or guest module | [Add a module](workflows/add-a-module.md) | module inventory plus platform tests |
| Resident component | [Resident components](architecture/resident-components.md) | bake gate plus full suite |
| Public documentation | [Documentation and gates](workflows/documentation-and-gates.md) | `scripts/test-docs` |
| Emulator or hardware evidence | [Emulator and metal](workflows/emulator-and-metal.md) | identity and machine guards |
