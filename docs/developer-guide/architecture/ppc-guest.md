---
page_id: dev-arch-ppc-guest
title: PowerPC guest architecture
description: Event-loop, Workshop module, wire, and CarbonLib constraints in the reference guest.
doc_type: explanation
audience: developer
lifecycle: current
authority: [now-guest-ppc/src/workshop/workshop_module.h, docs/guest-ui-start-here.md]
source_dependencies: [now-guest-ppc/src/main.c, now-guest-ppc/src/workshop/workshop_module.h, now-guest-ppc/src/core/pump.h, docs/guest-ui-start-here.md, docs/command-parity.md]
media_ids: []
last_verified: 2026-08-09
---
# PowerPC guest architecture

The reference guest is C compiled with Retro68's retrocarbon environment for CarbonLib 1.6 on Mac OS 8.6–9.2.2. It uses a cooperative `WaitNextEvent` loop. Network progress therefore depends on returning to, or explicitly pumping, that loop.

The application has one window: the Workshop. Every feature page implements `WorkshopModuleOps`; modules create controls lazily, own their child identities, and do nearly free work in `idle`. Read `docs/guest-ui-start-here.md` before UI changes: UPP construction, nested Toolbox loops, and redraw ownership are runtime constraints, not style preferences.

The guest has two faces. Its Workshop/console and its wire dispatch must reach one implementation. `CommandParityTests` guards the inventory and records deliberate asymmetries.

## Cooperative scheduling

```mermaid
flowchart TD
  E["WaitNextEvent pass"] --> D["Dispatch Toolbox event"]
  D --> M["Selected Workshop module"]
  M --> I["Cheap module idle"]
  I --> W["Pump queued control and transfer work"]
  W --> E
  T["Nested tracking loop"] -->|"must call now_pump_action"| W
```

Text equivalent: each event-loop pass dispatches UI work, lets the active module perform bounded idle work, and advances the wire. Any nested control-tracking loop must also pump the wire or the classic Mac appears disconnected while the user is interacting.
