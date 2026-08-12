---
page_id: mcp-module-reference
title: MCP module
description: Control NOW's stdio and HTTP MCP transports, inspect the machine grant ceiling, and review recent agent activity without treating connection as consent.
doc_type: reference
audience: operator
lifecycle: experimental
authority: [docs/agent-integration.md, docs/mcp-coverage.md]
module_ids: [mcp]
source_dependencies: [docs/agent-integration.md, docs/mcp-coverage.md, now-host/Sources/NOWAgentIntegration, now-guest-ppc/src/mcp]
media_ids: [mcp-host, mcp-ppc]
last_verified: 2026-08-10
---

<!-- now-doc-provenance: generated reviewed=false -->

# MCP module

## What it does

MCP presents NOW's two local client transports and the selected classic Mac's
explicit ceiling on what an agent may observe or change. Both transports use
one catalog and dispatcher inside NOW; there is no separately installed MCP
service.

![The macOS MCP module showing transport and grant state](../../../assets/screenshots/modules/mcp/host.svg){ .now-placeholder }

## Availability

The host app owns both transports and all projections. PowerPC provides the
machine consent page. NOW-68K does not expose this MCP consent surface.

## On the modern Mac

The host exposes independent controls for:

- **Standard Input**, a narrow `New Old World --mcp-stdio` process launched by
  an MCP client. Its card copies the executable command and shows the private
  same-user socket it uses to reach the already-running app.
- **HTTP**, an authenticated loopback listener running directly inside the
  normal NOW app. Its card shows the URL and copies the bearer token without
  rendering the secret in the module or logs.

The module also shows the shared catalog, selected machine, available
capabilities, grant state, and auditable calls. A running transport is not a
machine grant.

## On the classic Mac

The PowerPC MCP page sets the machine's ceiling. It cannot supply host-local
credentials or prove that an MCP client can reach the host.

![The PowerPC MCP consent page](../../../assets/screenshots/modules/mcp/ppc.svg){ .now-placeholder }

## Common tasks

- Confirm the selected machine and requested capability before granting.
- Start only the transport required by the client. HTTP is off by default;
  stdio remains available by default for client-launched sessions.
- Copy connection details from the relevant transport card rather than
  locating a helper executable.
- Read the recent call record after an agent action.

## Safety, consent, and privacy

Global transport availability, HTTP authentication, and per-machine grants
are separate controls. Do not weaken the same-user socket, loopback bind,
bearer, Host, Origin, session, or framing limits to connect a client.

## Failure states

Transport stopped, local socket unavailable, HTTP authentication failure, not
addressed, not granted, capability unavailable, stale reference, and machine
refusal are typed.

## Current limitations

The 68K guest has no matching consent UI. Experimental semantic tools inherit
Mirror's narrower observation and act evidence.

## For developers

See [agent boundary](../../../developer-guide/architecture/agent-boundary.md)
and [MCP coverage](../../../mcp-coverage.md).

<!-- derived-doc v1
sources: now-host/Sources/NOWAgentIntegration/Projection/HostProjectionCatalog.swift now-host/Sources/Host/AgentCompanionModel.swift docs/mcp-coverage.md scripts/docs-source-group tools/docs-gate
sources-sha1: bf1ed06906d2d3368a1df4a2e90c00c9d15bfbfa
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
rederived: 2026-08-10T02:53:59-0400 62603174 sources, mcp-catalog 3->3
rederived: 2026-08-10T04:27:16-0400 886ee556 sources, mcp-catalog 3->3
rederived: 2026-08-10T04:38:55-0400 886ee556 sources
rederived: 2026-08-10T05:38:07-0400 a0ede9ec sources
rederived: 2026-08-10T13:10:56-0400 47bf54fb sources
rederived: 2026-08-10T13:36:45-0400 b15b4827 sources
rederived: 2026-08-10T14:49:45-0400 4ea2d97d sources
rederived: 2026-08-10T14:45:43-0400 26b75393 sources
rederived: 2026-08-10T14:48:16-0400 26b75393 sources
rederived: 2026-08-10T15:30:54-0400 32bdd096 sources
rederived: 2026-08-10T15:34:29-0400 72868e9e sources
rederived: 2026-08-10T15:46:03-0400 72868e9e sources
rederived: 2026-08-10T15:52:48-0400 77329146 sources
rederived: 2026-08-10T16:52:02-0400 d77cc444 sources
rederived: 2026-08-10T20:03:22-0400 d3e26c39 sources
rederived: 2026-08-10T20:22:53-0400 818c1577 sources
rederived: 2026-08-10T21:35:35-0400 a79833e9 sources
rederived: 2026-08-10T22:33:06-0400 e9bf9632 sources
rederived: 2026-08-10T22:47:49-0400 431e7308 sources
rederived: 2026-08-11T00:25:05-0400 bbab04b9 sources
rederived: 2026-08-11T00:33:22-0400 4b24cc1f sources
rederived: 2026-08-11T19:45:16-0400 065da692 sources
rederived: 2026-08-11T20:08:53-0400 852b41ae sources
rederived: 2026-08-11T20:43:59-0400 5c07bcd6 sources
rederived: 2026-08-11T20:54:11-0400 f9ceab81 sources
rederived: 2026-08-11T21:13:10-0400 098805ff sources
rederived: 2026-08-11T21:20:51-0400 15514cc9 sources
rederived: 2026-08-11T21:26:23-0400 7bfb617b sources
rederived: 2026-08-11T21:32:39-0400 57a081ab sources
rederived: 2026-08-11T21:39:37-0400 5a82bf82 sources
rederived: 2026-08-11T21:49:35-0400 7dc5b09d sources
rederived: 2026-08-11T21:54:55-0400 8c482312 sources
rederived: 2026-08-11T21:59:54-0400 562b4b50 sources
rederived: 2026-08-11T22:06:35-0400 65f52bf3 sources
rederived: 2026-08-11T22:10:48-0400 3df65dde sources
rederived: 2026-08-11T22:15:21-0400 68853632 sources
rederived: 2026-08-11T22:31:04-0400 a16b6a61 sources
rederived: 2026-08-11T22:41:40-0400 e1fc84c4 sources
rederived: 2026-08-11T22:47:34-0400 9776cf7a sources
rederived: 2026-08-11T23:12:02-0400 ddf740ce sources
rederived: 2026-08-11T23:31:22-0400 ad4d680 sources
rederived: 2026-08-11T23:37:12-0400 ad4d680 sources
rederived: 2026-08-12T13:02:41-0400 7cea759e sources
rederived: 2026-08-12T13:11:34-0400 7cea759e sources
rederived: 2026-08-12T13:12:13-0400 7cea759e sources
rederived: 2026-08-12T15:54:08-0400 939e43b7 sources
rederived: 2026-08-12T17:19:20-0400 338eca21 sources
-->
