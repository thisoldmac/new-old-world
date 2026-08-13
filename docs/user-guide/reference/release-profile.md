---
page_id: release-profile-reference
title: Alpha features
description: The machine-readable release profile for what is included, optional, and excluded from the public alpha.
doc_type: reference
audience: user
lifecycle: current
authority: [docs/feature-catalog.yaml, docs/distribution-profile.yaml]
source_dependencies: [docs/feature-catalog.yaml, docs/distribution-profile.yaml, docs/developer-guide/reference/distribution-standard.md]
media_ids: []
last_verified: 2026-08-13
---

# Alpha features

This is the feature shape of the downloadable alpha. Availability in
the PowerPC application is the default. **Optional** means bundled but not
installed or required by default, and **excluded** means source may exist while
the alpha does not promise or package it.

<!-- release-feature-table -->

The table is rendered from `docs/feature-catalog.yaml`, which also drives the
availability notices on feature-specific pages. It is documentation authority
today, not a claim that runtime feature flags already exist. When runtime flags
land, their keys and release defaults must bind to this catalog or replace it
as the single source; a second hand-maintained availability list is not
acceptable.

The separate [distribution standard](../../developer-guide/reference/distribution-standard.md)
maps these feature decisions to the DMG, embedded host resources, generic
classic image, loose update pairs, manifest, and checksums. CodeKitten and the
retained NOW-68K source are not part of that bundle profile.
