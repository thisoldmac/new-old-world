---
page_id: requirements-reference
title: Requirements
description: Operating-system, architecture, network, and artifact requirements for the NOW alpha.
doc_type: reference
audience: user
lifecycle: current
authority: [README.md, docs/naming.md, SECURITY.md, docs/onboarding.md]
source_dependencies: [now-host/Package.swift, now-host/NewOldWorld.xcodeproj/project.pbxproj, now-guest-ppc/CMakeLists.txt, now-guest-68k/CMakeLists.txt, SECURITY.md, product/features.yaml, docs/onboarding.md]
media_ids: []
last_verified: 2026-08-09
---

<!-- now-doc-provenance: generated reviewed=false -->

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
sources-sha1: e7eb3d4a5663893567755cce2e76c588ae6ebd98
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
rederived: 2026-08-11T19:45:16-0400 065da692 sources
rederived: 2026-08-11T20:08:54-0400 852b41ae sources
rederived: 2026-08-11T20:44:00-0400 5c07bcd6 sources
rederived: 2026-08-11T20:54:12-0400 f9ceab81 sources
rederived: 2026-08-11T21:13:11-0400 098805ff sources
rederived: 2026-08-11T21:20:51-0400 15514cc9 sources
rederived: 2026-08-11T21:26:23-0400 7bfb617b sources
rederived: 2026-08-11T21:32:39-0400 57a081ab sources
rederived: 2026-08-11T21:39:38-0400 5a82bf82 sources
rederived: 2026-08-11T21:49:35-0400 7dc5b09d sources
rederived: 2026-08-11T21:54:56-0400 8c482312 sources
rederived: 2026-08-11T21:59:54-0400 562b4b50 sources
rederived: 2026-08-11T22:06:35-0400 65f52bf3 sources
rederived: 2026-08-11T22:10:48-0400 3df65dde sources
rederived: 2026-08-11T22:15:21-0400 68853632 sources
rederived: 2026-08-11T22:31:04-0400 a16b6a61 sources
rederived: 2026-08-11T22:41:40-0400 e1fc84c4 sources
rederived: 2026-08-11T22:47:34-0400 9776cf7a sources
rederived: 2026-08-11T22:56:41-0400 2401cdb7 sources
rederived: 2026-08-11T23:03:13-0400 496fd2cd sources
rederived: 2026-08-11T23:12:02-0400 ddf740ce sources
rederived: 2026-08-11T23:31:22-0400 ad4d680 sources
rederived: 2026-08-11T23:37:12-0400 ad4d680 unchanged
rederived: 2026-08-12T13:02:41-0400 7cea759e sources
rederived: 2026-08-12T13:11:35-0400 7cea759e unchanged
rederived: 2026-08-12T13:12:13-0400 7cea759e unchanged
rederived: 2026-08-12T15:54:09-0400 939e43b7 unchanged
rederived: 2026-08-12T17:19:20-0400 338eca21 unchanged
rederived: 2026-08-12T18:34:29-0400 3688b9f6 unchanged
rederived: 2026-08-12T18:58:28-0400 3771e144 unchanged
rederived: 2026-08-12T19:15:24-0400 3771e144 unchanged
rederived: 2026-08-12T19:31:58-0400 3771e144 unchanged
rederived: 2026-08-12T20:08:33-0400 5a601a18 unchanged
rederived: 2026-08-12T20:15:22-0400 9e828cdc sources
rederived: 2026-08-12T20:34:42-0400 4d9ba67d unchanged
rederived: 2026-08-12T20:37:08-0400 633da491 unchanged
rederived: 2026-08-12T20:45:46-0400 a0878023 unchanged
rederived: 2026-08-12T22:18:37-0400 18d0d3c4 sources
rederived: 2026-08-12T23:59:07-0400 e5b16a71 unchanged
rederived: 2026-08-13T00:21:46-0400 e5b16a71 unchanged
-->
