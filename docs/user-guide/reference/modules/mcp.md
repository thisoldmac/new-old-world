---
page_id: mcp-module-reference
title: MCP module
description: Show the local companion, machine grant ceiling, exposed projections, and recent agent activity without treating connection as consent.
doc_type: reference
audience: operator
lifecycle: experimental
authority: [docs/agent-integration.md, docs/mcp-coverage.md]
module_ids: [mcp]
source_dependencies: [docs/agent-integration.md, docs/mcp-coverage.md, now-host/Sources/NOWAgentIntegration, now-guest-ppc/src/mcp]
media_ids: [mcp-host, mcp-ppc]
last_verified: 2026-08-09
---

# MCP module

## What it does

MCP presents the host's same-user companion readiness and the selected classic
Mac's explicit ceiling on what an agent may observe or change.

![The macOS MCP module showing companion and grant state](../../../assets/screenshots/modules/mcp/host.svg){ .now-placeholder }

## Availability

The host owns the companion and projections. PowerPC provides the machine
consent page. NOW-68K does not expose this MCP consent surface.

## On the modern Mac

The host shows companion transport, catalog, selected machine, available
capabilities, grant state, and auditable calls. A live socket is not a grant.

## On the classic Mac

The PowerPC MCP page sets the machine's ceiling. It cannot supply host-local
credentials or prove that a companion can reach the host.

![The PowerPC MCP consent page](../../../assets/screenshots/modules/mcp/ppc.svg){ .now-placeholder }

## Common tasks

- Confirm the selected machine and requested capability before granting.
- Read the recent call record after an agent action.

## Safety, consent, and privacy

Global companion connection, host authentication, and per-machine grants are
separate controls. Do not weaken same-user socket or local endpoint limits to
connect a client.

## Failure states

Companion unavailable, not addressed, not granted, capability unavailable,
stale reference, local authentication failure, and machine refusal are typed.

## Current limitations

The 68K guest has no matching consent UI. Experimental semantic tools inherit
Mirror's narrower observation and act evidence.

## For developers

See [agent boundary](../../../developer-guide/architecture/agent-boundary.md)
and [MCP coverage](../../../mcp-coverage.md).

<!-- derived-doc v1
sources: now-host/Sources/NOWAgentIntegration/Projection/HostProjectionCatalog.swift now-host/Sources/Host/AgentCompanionModel.swift docs/mcp-coverage.md scripts/docs-source-group tools/docs-gate
sources-sha1: b1a947be4db206e5ba2991427e7b8bf66d3c5ee8
derive mcp-catalog sha256=6a3d7581db637a48f6a3006dba3b874b60841badae4eee740304c7d2441ab711 lines=3
    scripts/docs-source-group mcp
rederived: pending
rederived: 2026-08-09T16:22:15-0400 9034e3eb sources, mcp-catalog 3->3
rederived: 2026-08-09T16:29:43-0400 9034e3eb sources
rederived: 2026-08-09T17:05:28-0400 446cf620 sources
rederived: 2026-08-09T17:08:04-0400 446cf620 sources
rederived: 2026-08-09T17:53:28-0400 ed9436c0 sources
-->
