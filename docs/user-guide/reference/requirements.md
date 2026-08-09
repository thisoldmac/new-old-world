---
page_id: requirements-reference
title: Requirements
description: Operating-system, architecture, network, and artifact requirements for the NOW pre-alpha.
doc_type: reference
audience: user
lifecycle: current
authority: [README.md, docs/naming.md, SECURITY.md]
source_dependencies: [now-host/Package.swift, now-host/NewOldWorld.xcodeproj/project.pbxproj, now-guest-ppc/CMakeLists.txt, now-guest-68k/CMakeLists.txt, SECURITY.md]
media_ids: []
last_verified: 2026-08-09
---

# Requirements

| Component | Requirement | Canonical artifact |
|---|---|---|
| macOS host | macOS 13 or later | `New Old World.app` |
| PowerPC guest | PowerPC, Mac OS 8.6–9.2.2, CarbonLib 1.6 | `New Old World.bin` |
| 68K guest | Current target: 68030, System 7.1, MacTCP | `now-guest-68k.bin` |
| Optional resident | PowerPC classic range only; restart and disable-Extensions recovery available | `NOW Extension` |

Both machines need IP connectivity on a trusted local network. The classic
wire is plaintext TCP and has no authentication. The host's listener must not
be exposed to the internet.

The release bundle is authoritative for what ships. Source-build directories,
emulator images, `.env.lab`, and private deployment credentials are contributor
or lab material, not user prerequisites.
