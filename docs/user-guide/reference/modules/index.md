---
page_id: module-index-reference
title: Module reference
description: Map every macOS host module to the alpha PowerPC Workshop and retained pre-Carbon source posture.
doc_type: reference
audience: user
lifecycle: current
authority: [docs/module-manifest.yaml, docs/contract-coverage.md]
source_dependencies: [docs/module-manifest.yaml, now-host/Sources/Host/ModuleRegistry.swift, now-guest-ppc/src/workshop/workshop_module.h, now-guest-68k/src/commands/commands68.c, scripts/docs-inventory, tools/docs-gate]
media_ids: []
last_verified: 2026-08-09
---

# Module reference

| Module | PowerPC Workshop | Pre-Carbon source (excluded from alpha) |
|---|---|---|
| [Screen](screen.md) | Screenshots | supported subset |
| [Files](files.md) | Files | supported subset |
| [iCloud](icloud.md) | iCloud | unavailable |
| [Processes](processes.md) | Processes | supported subset |
| [Mirror](mirror.md) | Mirror | unavailable |
| [Console](console.md) | Console | supported |
| [Chat](chat.md) | Chat | unavailable |
| [Web](web.md) | unavailable; use the host Direct listener | unavailable |
| [Hardware](hardware.md) | Hardware | supported subset |
| [Diagnostics](diagnostics.md) | Diagnostics | console-only diagnostics |
| [Networking](networking.md) | Networking | main-window summary |
| [Software](software.md) | Software | supported subset |
| [MCP](mcp.md) | MCP | unavailable |
| [Logs](logs.md) | Logs | console-only evidence |
| [Connections and preferences](connections-and-preferences.md) | Preferences + Connection | main window |

This table is a reader-facing projection of the machine-readable module
manifest. Capability coverage and proof remain separate questions; each page
states both. The third column records retained implementation shape for future
work; it does not mean NOW-68K ships in the alpha.

<!-- derived-doc v1
sources: docs/module-manifest.yaml now-host/Sources/Host/ModuleRegistry.swift now-guest-ppc/src/workshop/workshop_module.h now-guest-68k/src/commands/commands68.c scripts/docs-inventory tools/docs-gate
sources-sha1: 2b13100ccb1c3e10658bce7a5b8c9ece2429edd6
derive module-map sha256=e5edea5367719897f1b871c5c05fbe460aed80238440e32af30aca05ad5a9145 lines=16
    scripts/docs-inventory
rederived: pending
rederived: 2026-08-09T16:10:26-0400 e74b3ab1 sources, module-map 14->14
rederived: 2026-08-09T16:15:30-0400 e74b3ab1 sources
rederived: 2026-08-09T16:22:21-0400 9034e3eb sources
rederived: 2026-08-09T16:29:42-0400 9034e3eb sources
rederived: 2026-08-09T17:05:28-0400 446cf620 sources
rederived: 2026-08-09T17:08:04-0400 446cf620 sources
rederived: 2026-08-09T17:53:28-0400 ed9436c0 sources
rederived: 2026-08-09T18:53:52-0400 181db7a5 sources
rederived: 2026-08-09T18:56:23-0400 181db7a5 unchanged
rederived: 2026-08-09T19:21:55-0400 dc5bfcd2 sources
rederived: 2026-08-09T19:33:56-0400 c854246d sources
rederived: 2026-08-09T20:56:36-0400 9864da82 sources
rederived: 2026-08-09T21:05:28-0400 9864da82 sources
rederived: 2026-08-09T21:43:47-0400 2b3c2c0e sources
rederived: 2026-08-09T22:09:30-0400 d54812c2 sources
rederived: 2026-08-09T22:18:49-0400 e637efd3 sources
rederived: 2026-08-10T03:07:05-0400 9cbb4c28 unchanged
rederived: 2026-08-10T03:08:47-0400 9cbb4c28 unchanged
rederived: 2026-08-10T03:11:42-0400 9cbb4c28 unchanged
rederived: 2026-08-10T03:46:37-0400 68d74d72 unchanged
rederived: 2026-08-10T02:53:59-0400 62603174 sources, module-map 14->15
rederived: 2026-08-10T02:54:45-0400 62603174 unchanged
rederived: 2026-08-10T04:18:15-0400 423ef214 unchanged
rederived: 2026-08-10T04:49:22-0400 cd585106 unchanged
rederived: 2026-08-10T04:27:16-0400 886ee556 unchanged
rederived: 2026-08-10T04:38:54-0400 886ee556 unchanged
rederived: 2026-08-10T05:38:07-0400 a0ede9ec unchanged
rederived: 2026-08-10T13:37:38-0400 2f62ec11 unchanged
rederived: 2026-08-10T13:51:46-0400 f4a92045 unchanged
rederived: 2026-08-10T14:07:45-0400 b22898ee unchanged
rederived: 2026-08-10T13:10:56-0400 47bf54fb unchanged
rederived: 2026-08-10T13:36:45-0400 b15b4827 unchanged
rederived: 2026-08-10T14:32:11-0400 e75a07a0 sources, module-map 15->16
rederived: 2026-08-10T14:49:44-0400 4ea2d97d sources, module-map 16->16
rederived: 2026-08-10T14:20:14-0400 9e432b8b unchanged
rederived: 2026-08-10T15:11:52-0400 eb9d991c unchanged
rederived: 2026-08-10T15:34:28-0400 72868e9e unchanged
rederived: 2026-08-10T15:52:47-0400 77329146 unchanged
rederived: 2026-08-10T16:52:02-0400 d77cc444 unchanged
rederived: 2026-08-10T20:03:22-0400 d3e26c39 unchanged
rederived: 2026-08-10T20:22:53-0400 818c1577 unchanged
rederived: 2026-08-10T21:35:35-0400 a79833e9 unchanged
rederived: 2026-08-10T22:32:24-0400 e9bf9632 unchanged
rederived: 2026-08-10T22:33:05-0400 e9bf9632 sources
rederived: 2026-08-10T22:47:49-0400 431e7308 unchanged
rederived: 2026-08-11T00:25:05-0400 bbab04b9 unchanged
rederived: 2026-08-11T00:33:22-0400 4b24cc1f unchanged
rederived: 2026-08-11T03:40:39-0400 f568213 unchanged
rederived: 2026-08-11T03:52:03-0400 43d9691 unchanged
rederived: 2026-08-11T04:04:48-0400 edc4294 unchanged
rederived: 2026-08-11T04:18:29-0400 c830686 unchanged
rederived: 2026-08-11T13:21:47-0400 181ba5a sources
rederived: 2026-08-11T13:23:43-0400 181ba5a sources
rederived: 2026-08-11T18:32:08-0400 1e25306c sources
rederived: 2026-08-11T18:35:08-0400 66eedfc sources
rederived: 2026-08-12T12:38:33-0400 de3cc2f5 unchanged
-->
