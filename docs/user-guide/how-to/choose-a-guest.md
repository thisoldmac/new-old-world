---
page_id: choose-guest-how-to
title: Choose the right guest
description: Use the PowerPC Carbon guest for the initial alpha and understand the future pre-Carbon boundary.
doc_type: how-to
audience: user
lifecycle: current
authority: [README.md, docs/naming.md]
source_dependencies: [now-guest-ppc/CMakeLists.txt, now-guest-68k/CMakeLists.txt, now-host/Package.swift, docs/feature-catalog.yaml]
feature_ids: [classic.powerpc, classic.pre-carbon]
media_ids: []
last_verified: 2026-08-09
---

# Choose the right guest

## Goal

Choose an initial-alpha artifact without mistaking source presence for release
support.

## Steps

1. If the classic Mac runs Mac OS 8.6–9.2.2, is PowerPC, and has CarbonLib
   1.6, choose **New Old World.bin**, the initial-alpha guest.
2. If the machine requires a non-Carbon application, stop at the release
   boundary. NOW-68K exists in source, but its current build is stale and is
   excluded from the initial alpha.
3. Use the retained [NOW-68K installation page](install-68k.md) only for
   contributor work, not as a public-release promise.

## Expected result

The supported artifact launches the one-window PowerPC Workshop.

## Recovery

If the PowerPC build refuses to launch, check the CarbonLib version before
changing network settings. Do not substitute the stale 68K artifact as a
recovery path.
