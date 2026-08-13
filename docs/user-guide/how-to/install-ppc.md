---
page_id: install-ppc-how-to
title: Install the PowerPC guest
description: Transfer the canonical MacBinary PowerPC guest to Mac OS 8.6–9.2.2 without losing its forks or identity.
doc_type: how-to
audience: user
lifecycle: current
feature_ids: [classic.powerpc]
authority: [docs/naming.md, docs/developer-guide/reference/distribution-standard.md, AGENTS.md]
source_dependencies: [now-guest-ppc/CMakeLists.txt, now-guest-ppc/tools/name_macbinary.py, now-guest-ppc/src/core/carbon_warning.c, docs/naming.md, docs/developer-guide/reference/distribution-standard.md]
media_ids: [setup-ppc-install]
last_verified: 2026-08-13
---

<!-- now-doc-provenance: generated reviewed=false -->

# Install the PowerPC guest

## Goal

Install the canonical **New Old World** guest with its Macintosh metadata and
product identity intact.

## Steps

1. Confirm the target is PowerPC Mac OS 8.6–9.2.2. CarbonLib 1.6 is the
   supported runtime.
2. If CarbonLib 1.6 is absent, run the Apple installer included in the release
   setup image and accept its license. Source checkouts do not contain this
   licensed installer.
3. Transfer `New Old World.bin` with a tool that decodes MacBinary on the
   classic side.
4. Confirm the resulting application is named exactly **New Old World**.
5. Launch it and open the Workshop's **Connection** page. If NOW detects an
   older CarbonLib it warns without blocking launch; **Don't Warn Again**
   remembers only the warning choice.

![The decoded New Old World application on a PowerPC classic Mac](../../assets/screenshots/getting-started/ppc-install.svg){ .now-placeholder }

## Expected result

The Workshop opens with its navigation rail. The exact product name matters:
preferences and optional Extension-backed features use it as part of their
identity.

## Recovery

If the transferred file is a document, has no icon, or will not launch, the
MacBinary was probably not decoded. Re-transfer the `.bin`; do not rename a
data-fork-only file and assume its resource fork returned.
