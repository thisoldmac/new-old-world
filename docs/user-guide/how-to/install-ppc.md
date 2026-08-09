---
page_id: install-ppc-how-to
title: Install the PowerPC guest
description: Transfer the canonical MacBinary PowerPC guest to Mac OS 8.6–9.2.2 without losing its forks or identity.
doc_type: how-to
audience: user
lifecycle: current
feature_ids: [classic.powerpc]
authority: [docs/naming.md, AGENTS.md]
source_dependencies: [now-guest-ppc/CMakeLists.txt, now-guest-ppc/tools/name_macbinary.py, docs/naming.md]
media_ids: [setup-ppc-install]
last_verified: 2026-08-09
---

# Install the PowerPC guest

## Goal

Install the canonical **New Old World** guest with its Macintosh metadata and
product identity intact.

## Steps

1. Confirm the target is PowerPC Mac OS 8.6–9.2.2 with CarbonLib 1.6.
2. Transfer `New Old World.bin` with a tool that decodes MacBinary on the
   classic side.
3. Confirm the resulting application is named exactly **New Old World**.
4. Launch it and open the Workshop's **Connection** page.

![The decoded New Old World application on a PowerPC classic Mac](../../assets/screenshots/getting-started/ppc-install.svg){ .now-placeholder }

## Expected result

The Workshop opens with its navigation rail. The exact product name matters:
preferences and optional resident planes use it as part of their identity.

## Recovery

If the transferred file is a document, has no icon, or will not launch, the
MacBinary was probably not decoded. Re-transfer the `.bin`; do not rename a
data-fork-only file and assume its resource fork returned.
