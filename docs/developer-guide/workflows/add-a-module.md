---
page_id: dev-workflow-add-module
title: Add a module
description: Add a host module, PowerPC Workshop page, or explicit 68K posture without documentation drift.
doc_type: how-to
audience: developer
lifecycle: current
authority: [docs/adding-a-workshop-module.md, docs/module-manifest.yaml]
source_dependencies: [docs/adding-a-workshop-module.md, docs/module-manifest.yaml, now-host/Sources/Host/ModuleRegistry.swift, now-host/Sources/Host/HostModuleDefinition.swift, now-guest-ppc/src/workshop/workshop_module.h, now-guest-ppc/src/workshop/workshop_registry.c, tools/docs-gate]
media_ids: []
last_verified: 2026-08-11
---

<!-- now-doc-provenance: generated reviewed=false -->

# Add a module

## Choose the product surfaces

Decide whether the capability needs a host module, a PowerPC Workshop page, a 68K wire implementation, or a deliberate unsupported posture. One product concept can map to differently named platform-native pages; record that mapping in `docs/module-manifest.yaml`.

## Define it beside the implementation

For the host, put a `HostModuleDefinition` in the module's own `*HostModule.swift` file, then add that definition to `ModuleRegistry.standard`. The definition keeps the descriptor, optional feature binding, runtime factory, and view factory together. The runtime is constructed only when the module is first selected; a failed construction is not cached and can be retried.

For PowerPC, put a `WorkshopModuleDefinition` beside the module implementation and expose that definition to the one static Workshop registry. The definition owns the stable ID, copy, icon, tier, future domain grouping, optional feature binding, and ops factory. The Workshop resolves definitions into runtime instances before selection and commits `created` only after the module's control-construction transaction succeeds. Follow the detailed ownership and classic-Mac rules in `docs/adding-a-workshop-module.md`; the Workshop remains one window.

For 68K, share the implementation between console and wire renderers. Static module composition does not change the command-parity contract.

## Add the public reference page

Create one page under `docs/user-guide/reference/modules/` with `module_ids`, capabilities, availability, safety, data movement, failure behavior, and at least host and guest media slots. Add its exact mappings to the manifest.

## Prove inventory parity

```sh
.docs-venv/bin/python tools/docs-gate module-inventory
scripts/test-docs
```

The gate derives host definitions, PowerPC definitions, and the PowerPC enum from source. It compares each live surface's stable ID, tier, domains, and feature binding with the manifest. A module cannot land with split metadata, no page, no media slot, or an undocumented 68K posture.
