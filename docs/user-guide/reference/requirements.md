---
page_id: requirements-reference
title: Requirements
description: Operating-system, architecture, network, and artifact requirements for the NOW alpha.
doc_type: reference
audience: user
lifecycle: current
authority: [README.md, docs/naming.md, SECURITY.md, docs/onboarding.md]
source_dependencies: [now-host/Package.swift, now-host/NewOldWorld.xcodeproj/project.pbxproj, now-guest-ppc/CMakeLists.txt, now-guest-68k/CMakeLists.txt, SECURITY.md, docs/feature-catalog.yaml, docs/onboarding.md]
media_ids: []
last_verified: 2026-08-09
---

# Requirements

| Component | Requirement | Canonical artifact |
|---|---|---|
| macOS host | macOS 13 or later | `New Old World.app` |
| PowerPC guest | PowerPC, Mac OS 8.6–9.2.2, CarbonLib 1.6 | `New Old World.bin` |
| Bundled, optional NOW Extension | PowerPC classic range only; restart and disable-Extensions recovery available | `NOW Extension` in the alpha bundle |
| Pre-Carbon/NOW-68K | Excluded from alpha; retained target was 68030, System 7.1, MacTCP | No alpha artifact |

Both machines need IP connectivity on a trusted local network. The classic
wire is plaintext TCP and has no authentication. The host's listener must not
be exposed to the internet.

The guided [Set Up a New Mac](../how-to/set-up-new-mac.md) path additionally
needs a classic web browser and Disk Copy 6.3.3. Those are requirements of the
guided disk-image path, not of a manual fork-preserving installation.

The [alpha feature profile](release-profile.md) is the release-facing
authority until a concrete bundle is cut. The release bundle then becomes
authoritative for what ships. Source-build directories,
emulator images, `.env.lab`, and private deployment credentials are contributor
or lab material, not user prerequisites.

<!-- derived-doc v1
sources: docs/naming.md now-guest-ppc/CMakeLists.txt now-guest-68k/CMakeLists.txt scripts/docs-source-group tools/docs-gate
sources-sha1: 8443bffca2859f4fb1ca5b2f402ab3be9d4dc194
derive setup-targets sha256=7abfcb8135501ce74d37a77c83677d830f97650a2919791c6fa7c71706c54c99 lines=5
    scripts/docs-source-group setup
rederived: pending
rederived: 2026-08-09T16:22:15-0400 9034e3eb sources, setup-targets 5->5
rederived: 2026-08-09T16:29:43-0400 9034e3eb sources
rederived: 2026-08-09T17:05:28-0400 446cf620 sources
rederived: 2026-08-09T17:08:04-0400 446cf620 sources
rederived: 2026-08-09T17:53:28-0400 ed9436c0 sources
rederived: 2026-08-09T18:53:52-0400 181db7a5 sources
rederived: 2026-08-09T18:56:23-0400 181db7a5 unchanged
rederived: 2026-08-09T19:21:56-0400 dc5bfcd2 sources
rederived: 2026-08-09T19:33:56-0400 c854246d sources
rederived: 2026-08-09T20:56:36-0400 9864da82 sources
rederived: 2026-08-09T21:05:28-0400 9864da82 sources
rederived: 2026-08-09T21:43:47-0400 2b3c2c0e sources
rederived: 2026-08-09T22:09:31-0400 d54812c2 sources
rederived: 2026-08-09T22:18:49-0400 e637efd3 sources
rederived: 2026-08-10T03:07:05-0400 9cbb4c28 sources
rederived: 2026-08-10T03:08:47-0400 9cbb4c28 unchanged
rederived: 2026-08-10T03:11:43-0400 9cbb4c28 unchanged
rederived: 2026-08-10T03:46:37-0400 68d74d72 unchanged
rederived: 2026-08-10T02:53:59-0400 62603174 sources
rederived: 2026-08-10T04:18:15-0400 423ef214 sources
rederived: 2026-08-10T04:49:22-0400 cd585106 unchanged
rederived: 2026-08-10T04:27:17-0400 886ee556 unchanged
rederived: 2026-08-10T04:38:55-0400 886ee556 unchanged
rederived: 2026-08-10T05:38:07-0400 a0ede9ec unchanged
rederived: 2026-08-10T13:37:39-0400 2f62ec11 unchanged
rederived: 2026-08-10T13:51:46-0400 f4a92045 sources
rederived: 2026-08-10T14:07:45-0400 b22898ee unchanged
rederived: 2026-08-10T13:10:56-0400 47bf54fb sources
rederived: 2026-08-10T13:36:45-0400 b15b4827 unchanged
rederived: 2026-08-10T14:49:45-0400 4ea2d97d sources
rederived: 2026-08-10T14:20:14-0400 9e432b8b sources
rederived: 2026-08-10T15:11:52-0400 eb9d991c unchanged
rederived: 2026-08-10T15:34:29-0400 72868e9e unchanged
rederived: 2026-08-10T15:52:48-0400 77329146 unchanged
rederived: 2026-08-10T16:52:03-0400 d77cc444 sources
rederived: 2026-08-10T20:03:22-0400 d3e26c39 sources
rederived: 2026-08-10T20:22:53-0400 818c1577 unchanged
rederived: 2026-08-10T21:35:35-0400 a79833e9 sources
rederived: 2026-08-10T22:33:06-0400 e9bf9632 sources
rederived: 2026-08-10T22:47:49-0400 431e7308 sources
rederived: 2026-08-11T00:25:05-0400 bbab04b9 unchanged
rederived: 2026-08-11T00:33:22-0400 4b24cc1f sources
rederived: 2026-08-11T03:40:39-0400 f568213 unchanged
rederived: 2026-08-11T03:52:03-0400 43d9691 unchanged
rederived: 2026-08-11T04:04:48-0400 edc4294 unchanged
rederived: 2026-08-11T04:18:29-0400 c830686 unchanged
-->
