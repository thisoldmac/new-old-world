---
page_id: dev-orientation
title: Understand the codebase
description: A codebase tour from product behavior to the host, guest, resident, contract, and tests that own it.
doc_type: tutorial
audience: developer
lifecycle: current
authority: [README.md, contract/asyncapi.yaml, docs/architecture.md]
source_dependencies: [README.md, contract/asyncapi.yaml, docs/architecture.md, now-host/Sources/Host/ModuleRegistry.swift, now-guest-ppc/src/workshop/workshop_module.h, contract/peek_table.h, scripts/test-all]
media_ids: []
last_verified: 2026-08-09
---

<!-- now-doc-provenance: generated reviewed=false -->

# Understand the codebase

This tour builds a mental model before asking you to change anything. By the
end, you should be able to start with a visible behavior and identify the
module, process boundary, contract, implementation, and test that own it.

## Start with the running system

Read [system context](architecture/system-context.md) first. The shortest useful
model is:

- the macOS host listens, chooses the active classic Mac, and owns modern
  integrations;
- the PowerPC guest owns the Workshop and facts or actions on Mac OS 8.6–9.2.2;
- the bundled, optional NOW Extension owns only work that must execute inside another
  classic process;
- `contract/asyncapi.yaml` is the wire boundary between host and guests;
- `contract/peek_table.h` is the in-memory boundary between the PowerPC guest
  and resident extension.

The retained NOW-68K tree is a sibling implementation of a contract subset,
not a portability layer beneath the PowerPC guest. It is excluded from the
alpha but remains relevant when studying pre-Carbon constraints.

## Trace one behavior from the outside in

Choose a visible module from the [module reference](../user-guide/reference/modules/index.md),
then follow the row that matches what you are investigating:

| Behavior | First code to read | Then follow |
|---|---|---|
| Host module appears or disappears | `now-host/Sources/Host/ModuleRegistry.swift` | The module's model, view, and `GuestListener` request path |
| PowerPC Workshop page or control | `now-guest-ppc/src/workshop/workshop_module.h` | Its `WorkshopModuleOps`, command seam, and wire implementation |
| Connection or message decode | `contract/asyncapi.yaml` | Host contract model and the receiving guest wire implementation |
| Mirror scene or rendering | `now-host/Packages/MirrorKit/` | Guest scene/peek producer and recorded fixture tests |
| Resident-backed observation or action | `contract/peek_table.h` | PowerPC validation/reader, then the corresponding `ext/src/` plane |
| Product agent capability | `HostProjectionCatalog.swift` | Host model implementation, policy, and activity record |

Read tests alongside production code. Native C tests isolate framing, parsing,
policy, and resident decision logic; host package tests show model and
projection behavior; conformance fixtures show what actually crosses a seam.

## Understand the ownership rules

The architecture pages explain why code is divided the way it is:

- [Host](architecture/host.md): SwiftUI shell, AppKit adapters, session models,
  and listener ownership.
- [PowerPC guest](architecture/ppc-guest.md): cooperative event loop, Workshop
  modules, and console/wire parity.
- [Resident components](architecture/resident-components.md): foreign-context
  execution, shared memory, capability planes, and honest degradation.
- [Wire contract](architecture/wire-contract.md): handshake, symmetric message
  meaning, framing, and compatibility.
- [Mirror](architecture/mirror.md): observation, scene construction, rendering,
  and evidence boundaries.
- [Product agent integration](architecture/agent-boundary.md): how approved
  local clients reuse host models without bypassing policy.

## Establish a local baseline

For the complete repository:

```sh
scripts/test-all
```

For quicker subsystem work, use the commands in [Build and
test](workflows/build-and-test.md). Guest cross-builds may skip when Retro68 is
not installed; a skip tells you the surface was not checked.

Use the precise [verification vocabulary](reference/verification-levels.md)
when recording a result. Building, passing automated tests, observing behavior
in QEMU, and observing it on physical hardware answer different questions.

## Make a change

Once you can name the owner, choose the matching workflow:

- [Change the contract](workflows/change-the-contract.md)
- [Add a module](workflows/add-a-module.md)
- [Author documentation](workflows/documentation-and-gates.md)
- [Verify in an emulator or on hardware](workflows/emulator-and-metal.md)
- [Prepare a contribution](workflows/contributing.md)

If the behavior crosses multiple rows in the trace table, begin at the shared
contract or model instead of patching each visible symptom independently.
