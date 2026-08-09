---
page_id: dev-arch-mirror
title: Mirror architecture
description: The observe, render, review, and native-input ownership model of Mirror.
doc_type: explanation
audience: developer
lifecycle: experimental
authority: [docs/mirror-drive-loop.md, docs/mirror-knowledge.md]
source_dependencies: [docs/mirror-drive-loop.md, docs/mirror-knowledge.md, now-host/Sources/Host/MirrorPlaneDomain.swift, now-guest-ppc/src/mirror, now-guest-ppc/src/peek]
media_ids: []
last_verified: 2026-08-09
---
# Mirror architecture

Mirror projects guest-provided scene state into a host rendering and review surface. Its control loop is asymmetric by design: native guest input drives; QMP and capture tools observe. Guest-provided state is the only input permitted to mutate the Mirror model.

```mermaid
flowchart LR
  U["Native input on guest"] --> APP["Target classic application"]
  APP --> EXT["Optional resident observation"]
  EXT --> G["NOW guest validates scene"]
  G --> H["Host Mirror model"]
  H --> R["Render and review"]
  Q["QMP / harness"] -.->|"observe only"| APP
  R -.->|"proposal, never synthetic truth"| U
```

Text equivalent: a person acts through native guest input. The resident component may observe the target; the NOW guest validates that state and sends it to the host; the host renders it for review. QMP observes the machine but does not become the product input path.

Any measurement must prove the content plane armed in the stored artifact. An invocation log or an empty capture is not evidence that observation occurred.

