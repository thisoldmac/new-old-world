---
page_id: module-index-reference
title: Module reference
description: Map every macOS host module to its PowerPC Workshop page and explicit NOW-68K posture.
doc_type: reference
audience: user
lifecycle: current
authority: [docs/module-manifest.yaml, docs/contract-coverage.md]
source_dependencies: [docs/module-manifest.yaml, now-host/Sources/Host/ModuleRegistry.swift, now-guest-ppc/src/workshop/workshop_module.h, now-guest-68k/src/commands/commands68.c, scripts/docs-inventory, tools/docs-gate]
media_ids: []
last_verified: 2026-08-09
---

# Module reference

| Module | PowerPC Workshop | NOW-68K |
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
states both.

<!-- derived-doc v1
sources: docs/module-manifest.yaml now-host/Sources/Host/ModuleRegistry.swift now-guest-ppc/src/workshop/workshop_module.h now-guest-68k/src/commands/commands68.c scripts/docs-inventory tools/docs-gate
sources-sha1: e53767a359ebb3514eb9fa668ff3911c5fc6a425
derive module-map sha256=cc0ab1776e68f234416b59a648261f6dbfa2ba5e8c3aeb38ac8031ca5a55375e lines=14
    scripts/docs-inventory
rederived: pending
rederived: 2026-08-09T16:10:26-0400 e74b3ab1 sources, module-map 14->14
rederived: 2026-08-09T16:15:30-0400 e74b3ab1 sources
-->
