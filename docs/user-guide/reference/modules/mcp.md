---
page_id: mcp-module-reference
title: MCP module
description: Control NOW's stdio and HTTP MCP transports, inspect the machine grant ceiling, and review recent agent activity without treating connection as consent.
doc_type: reference
audience: operator
lifecycle: experimental
authority: [docs/agent-integration.md, docs/mcp-coverage.md]
module_ids: [mcp]
source_dependencies: [docs/agent-integration.md, docs/mcp-coverage.md, now-host/Sources/Host/MCP, now-host/Sources/NOWAgentIntegration, now-guest-ppc/src/mcp]
media_ids: [mcp-host, mcp-ppc]
last_verified: 2026-08-14
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
- **HTTP**, a loopback listener running directly inside the normal NOW app.
  Its card exposes an editable loopback port and an **Access** mode while
  stopped, and shows and copies the derived URL. Access has three settings,
  applied the next time HTTP starts:
    - **Bearer token** (the default): requests must carry NOW's private
      token. The card copies it without rendering the secret in the module
      or logs.
    - **OAuth**: NOW acts as the authorization server for standard MCP
      clients — discovery metadata, dynamic client registration, and a
      PKCE authorization-code flow. A client's first sign-in parks on the
      card as an **Approve / Deny** consent row; nothing is issued until a
      person answers, and **Revoke OAuth Clients & Tokens** forgets every
      registration and cancels outstanding tokens.
    - **No authentication**: any process on this Mac can drive NOW over the
      port. The card says so in warning copy; the loopback Host and Origin
      checks still apply.

Each card has independent **Start** and **Stop** controls, which affect the
current app session. The persisted launch policy is not here: **Start
Standard Input automatically** and **Start HTTP automatically** live in the
Settings window's MCP tab, because they are read once at launch and never
mid-session. They apply the next time NOW opens.

The module also shows the shared catalog, selected machine, available
capabilities, grant state, and auditable calls. A running transport is not a
machine grant.

The page is two columns of cards — recent agent activity on the right by
default, everything else on the left. Every card collapses from its header
chevron, the handle at its top-left drags it anywhere in either column (a
context menu offers the same moves for the keyboard), and the arrangement
persists across launches. Each transport card also discloses a **Session
log**: the host log's lines for that transport from this run of the app.

The activity card reads a durable record, not a per-launch ring: every
audited call lands in a private database beside NOW's other application
data, kept 180 days. Rows filter by outcome, agent, and machine; the agent
and machine chips on a row — and the row itself — open a detail sheet for
that record, which pivots between an agent, its sessions, the machines it
drove, and individual actions. The record stores what the audit line
already said — capability, face, machine, outcome, bounded refusal reason,
plus the client name an MCP client stated about itself — and never
arguments or payloads.

## On the classic Mac

The PowerPC MCP page sets the machine's ceiling. It cannot supply host-local
credentials or prove that an MCP client can reach the host.

![The PowerPC MCP consent page](../../../assets/screenshots/modules/mcp/ppc.svg){ .now-placeholder }

## Common tasks

- Confirm the selected machine and requested capability before granting.
- Start only the transport required by the client, or set its automatic-start
  switch in Settings for a transport that should be restored whenever NOW
  opens.
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
sources-sha1: dcd8f3d14156221b3831c73e38fd734879033f28
derive mcp-catalog sha256=0ba13827bca56a75d20d341f2455f7a8a90118af7b0e962864459ae1221bf6cb lines=3
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
rederived: 2026-08-12T18:34:29-0400 3688b9f6 sources
rederived: 2026-08-12T18:58:27-0400 3771e144 sources
rederived: 2026-08-12T19:15:24-0400 3771e144 sources
rederived: 2026-08-12T19:31:58-0400 3771e144 sources
rederived: 2026-08-12T20:08:33-0400 5a601a18 sources
rederived: 2026-08-12T20:15:22-0400 9e828cdc sources
rederived: 2026-08-12T20:34:42-0400 4d9ba67d sources
rederived: 2026-08-12T20:37:08-0400 633da491 sources
rederived: 2026-08-12T20:45:46-0400 a0878023 sources
rederived: 2026-08-12T22:18:37-0400 18d0d3c4 sources
rederived: 2026-08-12T23:59:07-0400 e5b16a71 sources
rederived: 2026-08-13T00:21:46-0400 e5b16a71 sources
rederived: 2026-08-13T00:58:13-0400 9f5139cf sources
rederived: 2026-08-13T01:23:46-0400 9f5139cf sources
rederived: 2026-08-13T01:47:14-0400 59852197 sources
rederived: 2026-08-13T02:45:49-0400 e504061c sources
rederived: 2026-08-13T04:30:01-0400 47f632b3 sources
rederived: 2026-08-13T13:50:55-0400 a9e64fa4 sources
rederived: 2026-08-13T14:32:32-0400 4da9c4a3 sources
rederived: 2026-08-13T15:15:23-0400 2ccde05b sources
rederived: 2026-08-13T17:36:05-0400 043777df sources
rederived: 2026-08-13T17:37:43-0400 043777df sources
rederived: 2026-08-13T18:23:47-0400 e6d7996d sources
rederived: 2026-08-13T19:30:44-0400 1d154b67 sources
rederived: 2026-08-13T21:59:04-0400 8433efda sources
rederived: 2026-08-13T23:16:02-0400 fc235d4e sources
rederived: 2026-08-14T00:51:51-0400 94f1c614 sources
rederived: 2026-08-14T00:55:48-0400 3bd83df2 sources
rederived: 2026-08-14T02:20:51-0400 81247e50 sources
rederived: 2026-08-14T03:25:53-0400 ee8ef8a4 sources
rederived: 2026-08-14T03:54:49-0400 d016e771 sources
rederived: 2026-08-14T03:57:10-0400 e122c6c3 sources
rederived: 2026-08-14T04:03:19-0400 908215de sources
rederived: 2026-08-14T04:36:35-0400 e66db808 sources
rederived: 2026-08-14T12:32:39-0400 7742eab5 sources
rederived: 2026-08-14T12:35:45-0400 49e6dd98 sources
rederived: 2026-08-14T12:44:43-0400 4d52ba1a sources
rederived: 2026-08-14T12:47:23-0400 804be291 sources
rederived: 2026-08-14T12:49:06-0400 655b2bf1 sources
rederived: 2026-08-14T13:16:43-0400 90cfd8fa sources
rederived: 2026-08-14T14:27:58-0400 6d037a57 sources
rederived: 2026-08-14T15:56:44-0400 835e6acf sources
rederived: 2026-08-14T16:58:28-0400 cf962dbb sources
rederived: 2026-08-14T17:12:28-0400 32ac9165 sources
rederived: 2026-08-14T17:36:05-0400 02e9de5e sources
rederived: 2026-08-14T18:14:39-0400 db6a7c6a sources
rederived: 2026-08-14T18:17:42-0400 d9ed70d2 sources
rederived: 2026-08-14T18:19:51-0400 60bb3427 sources, sources
rederived: 2026-08-14T18:20:42-0400 23dc0759 sources, sources, sources
rederived: 2026-08-14T18:22:07-0400 23dc0759 sources, sources, sources
rederived: 2026-08-14T18:23:12-0400 e2c66126 sources, sources, sources, sources
rederived: 2026-08-14T18:30:53-0400 b248c9a1 sources, sources, sources, sources
rederived: 2026-08-14T18:31:13-0400 b248c9a1 sources, sources, sources
rederived: 2026-08-14T18:31:26-0400 b248c9a1 sources
rederived: 2026-08-14T19:50:32-0400 d20eee81 sources
rederived: 2026-08-14T19:50:54-0400 d20eee81 sources
rederived: 2026-08-14T20:02:53-0400 068ca7fd sources
rederived: 2026-08-14T21:00:58-0400 ab304cb2 sources
rederived: 2026-08-14T21:15:09-0400 5316a23e sources
rederived: 2026-08-14T23:07:32-0400 9d85a31d sources
rederived: 2026-08-15T00:30:16-0400 f4dab407 sources, mcp-catalog 3->3
rederived: 2026-08-15T01:11:36-0400 c9a1a8a4 sources
rederived: 2026-08-15T03:16:30-0400 2c7ff2a1 sources
rederived: 2026-08-15T03:17:33-0400 2c7ff2a1 sources
rederived: 2026-08-15T03:18:50-0400 2c7ff2a1 sources
rederived: 2026-08-15T03:32:08-0400 083691c4 sources
rederived: 2026-08-15T04:01:11-0400 b18a891c sources
rederived: 2026-08-15T12:33:04-0400 eadb1784 sources
rederived: 2026-08-15T13:22:25-0400 4e897bc6 sources
rederived: 2026-08-15T14:24:09-0400 599da71e sources
rederived: 2026-08-15T14:56:50-0400 4caf46ef sources
rederived: 2026-08-15T15:02:00-0400 a06d9396 sources
rederived: 2026-08-15T15:16:39-0400 cc0d429b sources
rederived: 2026-08-15T15:19:24-0400 658719b4 sources
rederived: 2026-08-15T15:25:08-0400 7949e13a sources
rederived: 2026-08-15T16:00:10-0400 69217d7a sources
rederived: 2026-08-15T16:06:11-0400 69217d7a sources
rederived: 2026-08-15T16:43:48-0400 919bcc60 sources
rederived: 2026-08-15T18:06:56-0400 feaa6945 sources
rederived: 2026-08-15T19:13:29-0400 ce43eb74 sources
rederived: 2026-08-15T22:25:52-0400 f627b5b4 sources
rederived: 2026-08-16T13:07:44-0400 3fff0d5e sources
rederived: 2026-08-16T13:48:36-0400 abfb91b7 sources
rederived: 2026-08-16T14:23:14-0400 8e68ec3a sources
rederived: 2026-08-16T14:56:46-0400 3eac8061 sources
rederived: 2026-08-16T15:14:03-0400 3eac8061 sources
rederived: 2026-08-16T15:40:24-0400 484f1ecd sources
rederived: 2026-08-16T15:51:39-0400 3c9b1213 sources
rederived: 2026-08-16T16:01:12-0400 5e83598e sources
rederived: 2026-08-16T16:13:00-0400 d9f3bb77 sources
rederived: 2026-08-16T16:57:26-0400 49fcbc64 sources
rederived: 2026-08-16T18:23:18-0400 1162e33a sources
rederived: 2026-08-16T18:52:31-0400 51558682 sources
rederived: 2026-08-16T19:17:53-0400 0c75216b sources
rederived: 2026-08-16T21:38:02-0400 9e1756d6 sources
rederived: 2026-08-16T22:00:22-0400 c578fc99 sources
rederived: 2026-08-16T23:39:05-0400 eecd0c30 sources
rederived: 2026-08-17T02:09:48-0400 f94e2762 sources
rederived: 2026-08-17T03:31:09-0400 8cf43bb9 sources
rederived: 2026-08-17T14:41:19-0400 e7b68a20 sources
rederived: 2026-08-17T15:49:23-0400 6c899380 sources
rederived: 2026-08-17T15:52:53-0400 6c899380 sources
rederived: 2026-08-17T16:04:36-0400 ef984b29 sources
rederived: 2026-08-17T16:17:04-0400 f60e2999 sources
rederived: 2026-08-17T18:04:09-0400 30e23df6 sources
rederived: 2026-08-17T18:09:10-0400 4fb9b6b0 sources
rederived: 2026-08-17T18:50:31-0400 e18796a5 sources
rederived: 2026-08-17T23:36:26-0400 5aa1092c sources
rederived: 2026-08-17T23:52:46-0400 91fe237e sources
rederived: 2026-08-18T15:09:51-0400 c33eb6ee sources
rederived: 2026-08-18T17:19:00-0400 ffc561f4 sources
rederived: 2026-08-18T21:43:39-0400 eae627f6 sources
rederived: 2026-08-18T23:04:15-0400 fc295bcc sources
rederived: 2026-08-18T23:13:33-0400 ce4dc746 sources
rederived: 2026-08-18T23:19:31-0400 3341acb1 sources
rederived: 2026-08-18T23:25:22-0400 353a37be sources
rederived: 2026-08-18T23:33:03-0400 2c64a5c4 sources
rederived: 2026-08-18T23:44:45-0400 6692e45b sources
rederived: 2026-08-18T23:57:03-0400 d10402f4 sources
rederived: 2026-08-19T00:06:06-0400 b3b2ee57 sources, mcp-catalog 3->3
rederived: 2026-08-19T01:21:59-0400 0e46a4ac sources
rederived: 2026-08-19T01:34:47-0400 7ec2d6d1 sources
rederived: 2026-08-19T01:41:13-0400 399d4c78 sources
rederived: 2026-08-19T01:53:16-0400 db827bac sources
rederived: 2026-08-19T02:32:04-0400 a9efa24f sources
rederived: 2026-08-19T03:00:30-0400 26f5c9fc sources
rederived: 2026-08-19T03:14:02-0400 afcf45e6 sources
rederived: 2026-08-19T03:33:52-0400 648ab89c sources
rederived: 2026-08-19T03:53:11-0400 f9d1bd67 sources
rederived: 2026-08-19T03:59:56-0400 14486719 sources
rederived: 2026-08-19T04:47:57-0400 ba4e78ae sources
rederived: 2026-08-19T05:41:22-0400 a8ee7d50 sources
rederived: 2026-08-19T14:24:11-0400 d6583bbd sources
rederived: 2026-08-19T14:49:25-0400 75da2302 sources
rederived: 2026-08-19T15:06:39-0400 c9462eb5 sources, mcp-catalog 3->3
rederived: 2026-08-19T18:20:14-0400 4b072fe0 sources
rederived: 2026-08-19T18:25:39-0400 4b072fe0 sources
rederived: 2026-08-19T21:35:43-0400 485e4ee1 sources
rederived: 2026-08-19T21:40:50-0400 ae09a391 sources
rederived: 2026-08-19T22:18:12-0400 110215ff sources
-->
