---
page_id: dev-arch-system-context
title: System context
description: The applications, transports, and trust boundaries that make up New Old World.
doc_type: explanation
audience: developer
lifecycle: current
authority: [contract/asyncapi.yaml, docs/architecture.md]
source_dependencies: [contract/asyncapi.yaml, docs/architecture.md, now-host/Sources/Host/GuestListener.swift, now-guest-ppc/src/main.c, now-guest-68k/src/main.c]
media_ids: []
last_verified: 2026-08-09
---
# System context

The classic Mac initiates one TCP connection to the native macOS host. Control JSON and bulk bytes share that connection through a small binary frame header. The host can accept several guests, but drives one selected guest at a time.

```mermaid
flowchart LR
  U["Person on macOS"] --> H["NOW host\nSwift + AppKit/SwiftUI"]
  A["Approved local agent client"] --> H
  P["PowerPC guest\nCarbonLib 1.6"] -->|"TCP: control + bulk"| H
  K["68K guest\nMacTCP + Toolbox"] -->|"contract subset"| H
  E["Optional NOW Extension\nresident component"] <-->|"versioned memory table"| P
  H --> C["Optional cloud services"]
```

Text equivalent: a person and an approved local agent act through the host. Either guest dials the host over the same contract. Only the PowerPC application can consume the optional extension's in-memory table. Cloud services are host-owned and optional.

## Ownership rules

The host owns listening, guest selection, modern file and cloud integration, and agent policy. Each guest owns the facts and actions on its own classic Mac. The resident component owns only the foreign-context work that cannot safely occur in the application; it is always optional.

No component may infer consent from absence. The guest's hello describes its agent tier, and the host enforces it at the projection boundary.

