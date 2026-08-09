---
page_id: module-index-reference
title: Module reference
description: Map every macOS host module to its PowerPC Workshop page and explicit NOW-68K posture.
doc_type: reference
audience: user
lifecycle: current
authority: [docs/module-manifest.yaml, docs/contract-coverage.md]
source_dependencies: [docs/module-manifest.yaml, now-host/Sources/Host/ModuleRegistry.swift, now-guest-ppc/src/workshop/workshop_module.h, now-guest-68k/src/commands/commands68.c]
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
sources: docs/module-manifest.yaml now-host/Sources/Host/ModuleRegistry.swift now-guest-ppc/src/workshop/workshop_module.h now-guest-68k/src/commands/commands68.c
sources-sha1: pending
derive module-map sha256=pending lines=14
    tools/docs-gate module-inventory
rederived: pending
-->
