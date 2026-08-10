---
page_id: dev-workflow-add-module
title: Add a module
description: Add a host module, PowerPC Workshop page, or explicit 68K posture without documentation drift.
doc_type: how-to
audience: developer
lifecycle: current
authority: [docs/adding-a-workshop-module.md, docs/module-manifest.yaml]
source_dependencies: [docs/adding-a-workshop-module.md, docs/module-manifest.yaml, now-host/Sources/Host/ModuleRegistry.swift, now-guest-ppc/src/workshop/workshop_module.h, tools/docs-gate]
media_ids: []
last_verified: 2026-08-09
---
# Add a module

## Choose the product surfaces

Decide whether the capability needs a host module, a PowerPC Workshop page, a 68K wire implementation, or a deliberate unsupported posture. One product concept can map to differently named platform-native pages; record that mapping in `docs/module-manifest.yaml`.

## Implement in the owning registry

For the host, add the module descriptor to `ModuleRegistry.standard` and keep behavior in a feature model/view. For PowerPC, follow all six edits in `docs/adding-a-workshop-module.md`; the Workshop remains one window. For 68K, share the implementation between console and wire renderers.

## Add the public reference page

Create one page under `docs/user-guide/reference/modules/` with `module_ids`, capabilities, availability, safety, data movement, failure behavior, and at least host and guest media slots. Add its exact mappings to the manifest.

## Prove inventory parity

```sh
.docs-venv/bin/python tools/docs-gate module-inventory
scripts/test-docs
```

The gate derives the host IDs and PowerPC enum from source. A module cannot land with no page, no media slot, or an undocumented 68K posture.

