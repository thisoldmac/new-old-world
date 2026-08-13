---
page_id: web-module-reference
title: Web Proxy module
description: Run the host-side compatibility gateway used by Classilla, MacWeb, and conservative 68K browser profiles.
doc_type: reference
audience: user
lifecycle: experimental
authority: [web-bridge/README.md, docs/status.md, SECURITY.md]
module_ids: [web]
source_dependencies: [web-bridge/nowweb/server.py, web-bridge/nowweb/document.py, now-host/Sources/Host/Web/WebBridgeModels.swift, now-host/Sources/Host/Web/WebModuleView.swift, now-host/Sources/Host/ModuleRegistry.swift, now-guest-ppc/src/web/web_model.c, now-guest-ppc/src/web/web_module.c, SECURITY.md]
media_ids: [web-host, web-ppc]
last_verified: 2026-08-13
---

<!-- now-doc-provenance: generated reviewed=false -->

# Web Proxy module

## What it does

Web Proxy runs a host-side compatibility gateway for a browser already installed on
a classic Macintosh. The host fetches HTTP and HTTPS pages, optionally runs
their contemporary JavaScript through Playwright, and returns bounded ASCII
HTML selected for Classilla, MacWeb, or a conservative 68K profile.

![The macOS Web Proxy module](../../../assets/screenshots/modules/web/host.svg){ .now-placeholder }

## Availability

The implemented baseline is the macOS **Direct** listener. The classic browser
connects to the modern Mac's selected LAN address and port.
The listener defaults to host loopback for safety, but host loopback is not
reachable from the classic Mac.

The PowerPC Workshop ships a Web page that saves the proxy port, browser
profile, and default lens. It deliberately reuses the host address from the
Connection page: under this repository's QEMU user network that address is
`10.0.2.2`; on real hardware it must be the modern Mac's LAN address. The page
shows a start URL whose query carries the selected profile and lens.

NOW-68K does not yet ship a Web page. Direct browsing does not require one: set
MacWeb's HTTP proxy to the same host listener. A guest-local relay remains
probe-required; Open Transport and MacTCP support for connections to the
guest's own address, including `127.0.0.1`, must be established separately on
the exact browser and system row.

## On the modern Mac

1. Choose the folder containing `nowweb/__main__.py`.
2. Choose **Use This Mac's LAN Address**, or enter one explicit bind address.
3. Enter the classic Mac's address under **Allowed classic Mac address**.
4. Choose a browser profile, rendering lens, and fetch engine.
5. Start the service and use the displayed address and port in the browser's
   HTTP proxy settings.

Compatible Page is the deterministic default. Reader is a reduced view of the
same semantic block tree. AI Layout is optional and falls back to Compatible
Page when its planner is unavailable, invalid, slow, or over budget.

## On the classic Mac

Use the displayed host address, not `127.0.0.1`, as the HTTP proxy. HTTPS
destinations are fetched by the host and rewritten through plain HTTP gateway
links; NOW Web does not expose a general CONNECT tunnel.

![The PowerPC Web page](../../../assets/screenshots/modules/web/ppc.svg){ .now-placeholder }

## Common tasks

- Start the Direct listener and copy its displayed address into the browser's
  HTTP proxy settings.
- On the PowerPC guest, make the Web page's port match the host module and use
  its displayed start URL when you want the selected profile and lens.
- Choose MacWeb when the browser needs conservative HTML 2, flattened tables,
  ASCII entities, smaller pages, and 4 KB delivery chunks.
- Choose Reader for an article-oriented page without changing the browser
  profile.
- Return to Compatible Page whenever a handler, Reader, or AI Layout removes
  context needed to navigate the site.
- Stop the listener when the classic Mac is no longer browsing through it.

## Safety, consent, and privacy

The classic-browser listener cannot rely on modern bearer authentication.
Restrict it to the classic Mac's address and a trusted network. An empty peer
restriction accepts every peer that can reach the selected interface.

Private, link-local, loopback, and special-use destinations are blocked by
default. The unsafe development switch broadens the host's outbound reach and
must not be enabled casually.

Ordinary helper logs omit request paths, URL queries, cookies, authorization,
and page bodies. The bridge does not import browser cookies or credentials.

## Failure states

Missing helper, stopped, starting, ready, incompatible helper protocol,
renderer failure, blocked destination, refused peer, unsupported browser
profile, expired page token, and unavailable AI planner remain distinct.

## Current limitations

- The static engine does not execute JavaScript. Playwright and Chromium are
  explicit optional dependencies and are never downloaded on a page request.
- Forms, logins, uploads, session replay, synthetic JavaScript event links,
  video, and a complete image-transcoding pipeline are not yet served.
- Direct browsing and the PowerPC page have built, but have not yet been
  metal-verified from Classilla or MacWeb in this branch.
- The optional local layout model is not distributed until its model card,
  base-model and training-data provenance, license, version, and checksum are
  settled. An already-installed local model folder can be selected in the host
  module; the first adapter cold-loads it per AI request.

## For developers

The source-tree implementation plan, operator note, and provenance inventory
are `docs/plans/2026-08-10-032-feat-web-bridge-plan.md`,
`web-bridge/README.md`, and `web-bridge/PROVENANCE.md`.
