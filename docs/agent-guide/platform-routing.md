---
page_id: agent-platform-routing
title: Route classic Mac and host work
description: Select the correct implementation model and specialist guidance before changing host, Carbon, Toolbox, resident, or emulator code.
doc_type: reference
audience: agent
lifecycle: current
authority: [AGENTS.md]
source_dependencies: [AGENTS.md, docs/developer-guide/architecture/host.md, docs/developer-guide/architecture/ppc-guest.md, docs/developer-guide/architecture/68k-guest.md, docs/developer-guide/architecture/resident-components.md, docs/developer-guide/workflows/emulator-and-metal.md]
media_ids: []
last_verified: 2026-08-09
---

# Route classic Mac and host work

Choose by application model, not merely by CPU or folder name.

| Surface | Implementation model | Agent route |
|---|---|---|
| `now-host/` | Swift, SwiftUI, AppKit adapters | Read the [host architecture](../developer-guide/architecture/host.md); preserve native control ownership and host model boundaries |
| `now-guest-ppc/` | PowerPC CFM CarbonLib 1.6 application | Load Carbon platform guidance; load Carbon UI guidance for windows, controls, events, or redraw work |
| `now-guest-68k/` | Non-Carbon 68K Toolbox/MacTCP application | Load Toolbox platform guidance; load Toolbox UI guidance for interface work; do not route through Carbon skills |
| `ext/` | 68K INIT resident under emulation on PowerPC | Load INIT/resident platform guidance; preserve the versioned shared-table and bake gates |
| QEMU or physical-machine acceptance | Deterministic emulator or metal harness | Load emulator-harness guidance and follow the [emulator and metal workflow](../developer-guide/workflows/emulator-and-metal.md) |

Product agent integration under `now-host/Sources/NOWAgentIntegration/` is
ordinary host architecture, not coding-agent protocol. Read the human [product
agent boundary](../developer-guide/architecture/agent-boundary.md) for that
subsystem.

For every classic surface, determine the supported OS floor and application
model before proposing an API. A symbol present in a modern SDK or another
classic target is not evidence that it is callable in this one.
