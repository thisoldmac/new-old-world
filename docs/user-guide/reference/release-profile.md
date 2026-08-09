---
page_id: release-profile-reference
title: Initial alpha features
description: The machine-readable release profile for what is included, optional, and excluded from the first public alpha.
doc_type: reference
audience: user
lifecycle: current
authority: [docs/feature-catalog.yaml]
source_dependencies: [docs/feature-catalog.yaml]
media_ids: []
last_verified: 2026-08-09
---

# Initial alpha features

This is the planned public shape of the first downloadable alpha. **Included**
means part of the supported release path, **optional** means shipped but not
required, and **excluded** means source may exist while the release does not
promise or package it.

<!-- release-feature-table -->

The table is rendered from `docs/feature-catalog.yaml`, which also drives the
availability notices on feature-specific pages. It is documentation authority
today, not a claim that runtime feature flags already exist. When runtime flags
land, their keys and release defaults must bind to this catalog or replace it
as the single source; a second hand-maintained availability list is not
acceptable.
