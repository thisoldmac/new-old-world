---
page_id: guest-compatibility-explanation
title: Guests and compatibility
description: How the PowerPC Carbon Workshop and NOW-68K divide the classic Macintosh compatibility range.
doc_type: explanation
audience: user
lifecycle: current
authority: [README.md, docs/naming.md]
source_dependencies: [now-guest-ppc/CMakeLists.txt, now-guest-68k/CMakeLists.txt, docs/module-manifest.yaml, docs/feature-catalog.yaml]
feature_ids: [classic.powerpc, classic.pre-carbon]
media_ids: []
last_verified: 2026-08-09
---

<!-- now-doc-provenance: generated reviewed=false -->

# Guests and compatibility

The two guests are siblings, not ports.

The alpha includes the PowerPC guest. NOW-68K is retained as a pre-Carbon
architecture and future release feature; its current build is stale and its
source-level capabilities are not an alpha promise.

The PowerPC guest uses CarbonLib and provides the one-window Workshop across
Mac OS 8.6–9.2.2. It carries the broadest UI surface and is the only guest that
can use the bundled, optional NOW Extension and its deeper Mirror features.

NOW-68K is a non-Carbon Toolbox application for the historically targeted System
7.1/MacTCP environment. Its compact main window and console preserve the
connection, screen, file, process, software, and hardware subset that fits the
machine. It intentionally omits iCloud, Chat, Mirror, and the resident.

The contract remains symmetric even when capability coverage is not. An older
or smaller guest refuses or omits what it cannot serve; the host must not infer
support from product identity alone.

Use [Choose the right guest](../how-to/choose-a-guest.md) for the release
boundary and the [module index](../reference/modules/index.md) for the retained
source-level map.
