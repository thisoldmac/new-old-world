---
page_id: dev-arch-resident-components
title: Resident components
description: Optional extension ownership, versioned memory contracts, and bake requirements.
doc_type: explanation
audience: developer
lifecycle: current
authority: [docs/resident-components.md, contract/peek_table.h]
source_dependencies: [docs/resident-components.md, contract/peek_table.h, ext/src/now_ext.c, now-guest-ppc/src/peek/peek.c, tools/ext-bake-gate]
media_ids: []
last_verified: 2026-08-09
---
# Resident components

The NOW Extension performs only work that must run in a foreign application context. The PowerPC application is the sole reader of foreign memory and exposes the result to the rest of the product. The extension is optional: the application must report an unavailable plane honestly and keep non-resident features usable.

```mermaid
flowchart LR
  F["Foreign application context"] -->|"bounded resident callbacks"| X["NOW Extension"]
  X -->|"versioned peek table"| P["NOW PowerPC application"]
  P -->|"validated facts and acts"| W["Wire contract"]
  P -.->|"extension absent: unavailable, not fabricated"| W
```

Text equivalent: resident callbacks observe or act in the foreign application, write a versioned shared table, and the NOW application validates and reads it before publishing results. Without the extension, the application reports unavailability rather than emulating resident state.

`contract/peek_table.h` is compiled by every reader and writer, with layout assertions. A change to `ext/` or that header requires an exact-source bake receipt before landing on `main`; a written deferral may permit a checkpoint but never the landing.

