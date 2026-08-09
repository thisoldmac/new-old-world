---
page_id: dev-ref-repository-map
title: Repository map
description: Ownership map for the principal New Old World directories and entry points.
doc_type: reference
audience: developer
lifecycle: current
authority: [AGENTS.md]
source_dependencies: [AGENTS.md, contract/asyncapi.yaml, now-host, now-guest-ppc, now-guest-68k, ext, docs/agent-guide, scripts, tools]
media_ids: []
last_verified: 2026-08-09
---
# Repository map

| Path | Owns |
|---|---|
| `contract/` | AsyncAPI wire authority and shared resident-memory layouts |
| `now-host/` | Native macOS application, connection server, models, modules, agent projections |
| `now-host/Packages/MirrorKit/` | NOW-owned Mirror rendering package and tests |
| `now-guest-ppc/` | PowerPC CarbonLib reference guest and Workshop |
| `now-guest-68k/` | 68K non-Carbon Toolbox/MacTCP sibling guest |
| `ext/` | Optional resident extension and bake receipts |
| `docs/user-guide/` | Public task, concept, and module documentation |
| `docs/developer-guide/` | Architecture, code tracing, debugging, workflows, and reference for developers |
| `docs/agent-guide/` | Coding-agent authority, scope, platform routing, change routing, evidence, and handoff protocol |
| `scripts/` | Supported build, test, emulator, deploy, and docs entry points |
| `tools/` | Focused gates, derivations, diagnostics, and harness helpers |

The root `README.md` is the repository landing page; `docs/index.md` is the
website landing page. A technical explanation has one owner in the developer
guide; the coding-agent path links to it and adds only operational rules.
Session notes belong under ignored `docs/local/`, not in the published
hierarchy.
