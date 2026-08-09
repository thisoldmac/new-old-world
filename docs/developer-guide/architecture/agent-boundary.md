---
page_id: dev-arch-agent-boundary
title: Agent boundary
description: How local agent clients reach approved projections without gaining a parallel control surface.
doc_type: explanation
audience: developer
lifecycle: current
authority: [docs/agent-integration.md, now-host/Sources/NOWAgentIntegration/Projection/HostProjectionCatalog.swift]
source_dependencies: [docs/agent-integration.md, now-host/Sources/NOWAgentIntegration/Projection/HostProjectionCatalog.swift, now-host/Sources/Host/AgentCompanionModel.swift, now-host/Sources/Host/AgentActivityModel.swift, contract/asyncapi.yaml]
media_ids: []
last_verified: 2026-08-09
---
# Agent boundary

The agent companion is a client of the host, not an alternate face of the guest. `HostProjectionCatalog` declares capabilities once so the app UI and approved client share schemas, availability rules, bounds, and implementations.

```mermaid
flowchart TD
  C["Local agent client"] -->|"authenticated, bounded request"| P["Host projection"]
  UI["Host UI"] --> P
  P --> G["Guest-scoped model"]
  G --> W["Wire request"]
  W --> M["Selected classic Mac"]
  M -->|"hello agent tier"| P
  P -->|"audit activity"| L["Agent activity model"]
```

Text equivalent: the local client and host UI converge on the same projection, which uses guest-scoped state and the existing wire. The selected machine's hello tier constrains the request. Activity is recorded by the host; the client cannot bypass the projection to reach the socket.

Missing or unknown policy is never consent. A capability that cannot name its target, bounds, availability, and refusal behavior is not ready to enter the catalog.
