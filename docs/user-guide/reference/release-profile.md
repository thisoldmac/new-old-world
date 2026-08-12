---
page_id: release-profile-reference
title: Alpha features
description: The machine-readable release profile for what is included, optional, and excluded from the public alpha.
doc_type: reference
audience: user
lifecycle: current
authority: [product/features.yaml]
source_dependencies: [product/features.yaml, tools/product-features, now-host/Sources/Host/ProductFeaturePolicy.swift, now-guest-ppc/src/core/product_feature_policy.c]
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

The table is rendered from `product/features.yaml`, which also drives the
availability notices and generated host and PowerPC runtime definitions.
Release inclusion and runtime flags are separate decisions: a runtime override
cannot add a profile-excluded feature, and guest capability negotiation still
decides whether a connected Macintosh can serve an admitted feature.
