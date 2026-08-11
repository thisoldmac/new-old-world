---
page_id: release-profile-reference
title: Alpha features
description: The machine-readable release profile for what is included, optional, and excluded from the public alpha.
doc_type: reference
audience: user
lifecycle: current
authority: [docs/feature-catalog.yaml]
source_dependencies: [docs/feature-catalog.yaml]
media_ids: []
last_verified: 2026-08-09
---

<!-- now-doc-provenance: generated reviewed=false -->

# Alpha features

This is the planned public shape of the downloadable alpha. Availability in
the PowerPC application is the default. **Optional** means bundled but not
installed or required by default, and **excluded** means source may exist while
the alpha does not promise or package it.

This profile is the target contents of an alpha, not the maturity label of the
current build. The current product lifecycle is checked separately from
`contract/product_version.h` and remains pre-alpha until its qualification
criteria are deliberately advanced.

<!-- release-feature-table -->

The table is rendered from `docs/feature-catalog.yaml`, which also drives the
availability notices on feature-specific pages. It is documentation authority
today, not a claim that runtime feature flags already exist. When runtime flags
land, their keys and release defaults must bind to this catalog or replace it
as the single source; a second hand-maintained availability list is not
acceptable.
