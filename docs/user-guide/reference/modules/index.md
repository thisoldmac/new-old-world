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
sources-sha1: 5932f6c1726853093aad46c8a67b0e73518a95f7
derive module-map sha256=0896e6bbb20891a434ea64242d5f00f529b621b5595b55af77f326a308c502ae lines=15
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
rederived: 2026-08-10T02:53:59-0400 62603174 sources, module-map 14->15
rederived: 2026-08-10T02:54:45-0400 62603174 unchanged
rederived: 2026-08-10T04:27:16-0400 886ee556 unchanged
rederived: 2026-08-10T04:38:54-0400 886ee556 unchanged
-->
