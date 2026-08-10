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
sources-sha1: 1ee4ba7d040058619aa04db30408e30e80b86d86
derive mcp-catalog sha256=dadedb438a578e94422eb5eec7337288e94e19899e6592ebaaf6d86c080258dc lines=3
    scripts/docs-source-group mcp
rederived: pending
rederived: 2026-08-09T16:22:15-0400 9034e3eb sources, mcp-catalog 3->3
rederived: 2026-08-09T16:29:43-0400 9034e3eb sources
rederived: 2026-08-09T17:05:28-0400 446cf620 sources
rederived: 2026-08-09T17:08:04-0400 446cf620 sources
rederived: 2026-08-09T17:53:28-0400 ed9436c0 sources
rederived: 2026-08-09T18:53:52-0400 181db7a5 sources
rederived: 2026-08-09T18:56:23-0400 181db7a5 sources
rederived: 2026-08-09T19:21:56-0400 dc5bfcd2 sources
rederived: 2026-08-09T19:33:56-0400 c854246d sources
rederived: 2026-08-09T20:56:36-0400 9864da82 sources
rederived: 2026-08-09T21:05:28-0400 9864da82 sources
rederived: 2026-08-09T21:43:47-0400 2b3c2c0e sources
rederived: 2026-08-09T22:09:31-0400 d54812c2 sources
rederived: 2026-08-09T22:18:49-0400 e637efd3 sources
rederived: 2026-08-10T03:07:05-0400 9cbb4c28 sources
rederived: 2026-08-10T03:08:47-0400 9cbb4c28 sources
rederived: 2026-08-10T03:11:42-0400 9cbb4c28 sources
rederived: 2026-08-10T03:46:37-0400 68d74d72 sources
rederived: 2026-08-10T02:53:59-0400 62603174 sources, mcp-catalog 3->3
rederived: 2026-08-10T04:18:15-0400 423ef214 sources, mcp-catalog 3->3
rederived: 2026-08-10T04:49:22-0400 cd585106 sources
rederived: 2026-08-10T04:27:16-0400 886ee556 sources, mcp-catalog 3->3
rederived: 2026-08-10T04:38:55-0400 886ee556 sources
rederived: 2026-08-10T05:38:07-0400 a0ede9ec sources
rederived: 2026-08-10T13:37:38-0400 2f62ec11 sources, mcp-catalog 3->3
rederived: 2026-08-10T13:51:46-0400 f4a92045 sources
rederived: 2026-08-10T14:07:45-0400 b22898ee sources
-->
