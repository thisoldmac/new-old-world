---
page_id: requirements-reference
title: Requirements
description: Operating-system, architecture, network, and artifact requirements for the NOW alpha.
doc_type: reference
audience: user
lifecycle: current
authority: [README.md, docs/naming.md, SECURITY.md, docs/onboarding.md, docs/developer-guide/reference/distribution-standard.md]
source_dependencies: [now-host/Package.swift, now-host/NewOldWorld.xcodeproj/project.pbxproj, now-guest-ppc/CMakeLists.txt, now-guest-68k/CMakeLists.txt, SECURITY.md, product/features.yaml, docs/distribution-profile.yaml, docs/onboarding.md, docs/developer-guide/reference/distribution-standard.md]
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
sources-sha1: 220a8c30796d5871ad4e64d2414d36cdfecc1af1
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
rederived: 2026-08-13T00:58:13-0400 9f5139cf sources
rederived: 2026-08-13T01:23:46-0400 9f5139cf unchanged
rederived: 2026-08-13T01:47:14-0400 59852197 unchanged
rederived: 2026-08-13T02:45:49-0400 e504061c unchanged
rederived: 2026-08-13T04:30:01-0400 47f632b3 unchanged
rederived: 2026-08-13T13:50:55-0400 a9e64fa4 unchanged
rederived: 2026-08-13T14:32:32-0400 4da9c4a3 unchanged
rederived: 2026-08-13T15:15:23-0400 2ccde05b unchanged
rederived: 2026-08-13T17:36:05-0400 043777df unchanged
rederived: 2026-08-13T17:37:43-0400 043777df unchanged
rederived: 2026-08-13T18:23:47-0400 e6d7996d unchanged
rederived: 2026-08-13T19:30:44-0400 1d154b67 unchanged
rederived: 2026-08-13T21:59:05-0400 8433efda unchanged
rederived: 2026-08-13T23:16:02-0400 fc235d4e unchanged
rederived: 2026-08-14T00:51:51-0400 94f1c614 unchanged
rederived: 2026-08-14T00:55:48-0400 3bd83df2 unchanged
rederived: 2026-08-14T02:20:51-0400 81247e50 unchanged
rederived: 2026-08-14T03:25:53-0400 ee8ef8a4 unchanged
rederived: 2026-08-14T03:54:49-0400 d016e771 unchanged
rederived: 2026-08-14T03:57:10-0400 e122c6c3 unchanged
rederived: 2026-08-14T04:03:19-0400 908215de unchanged
rederived: 2026-08-14T04:36:36-0400 e66db808 unchanged
rederived: 2026-08-14T12:32:39-0400 7742eab5 sources
rederived: 2026-08-14T12:35:45-0400 49e6dd98 unchanged
rederived: 2026-08-14T12:44:43-0400 4d52ba1a sources
rederived: 2026-08-14T12:47:23-0400 804be291 unchanged
rederived: 2026-08-14T12:49:06-0400 655b2bf1 unchanged
rederived: 2026-08-14T13:16:43-0400 90cfd8fa unchanged
rederived: 2026-08-14T14:27:58-0400 6d037a57 unchanged
rederived: 2026-08-14T15:56:44-0400 835e6acf unchanged
rederived: 2026-08-14T16:58:28-0400 cf962dbb sources
rederived: 2026-08-14T17:12:29-0400 32ac9165 unchanged
rederived: 2026-08-14T17:36:05-0400 02e9de5e unchanged
rederived: 2026-08-14T18:14:39-0400 db6a7c6a unchanged
rederived: 2026-08-14T18:17:42-0400 d9ed70d2 unchanged
rederived: 2026-08-14T18:19:51-0400 60bb3427 unchanged
rederived: 2026-08-14T18:20:42-0400 23dc0759 unchanged
rederived: 2026-08-14T18:22:08-0400 23dc0759 unchanged
rederived: 2026-08-14T18:23:12-0400 e2c66126 sources, sources
rederived: 2026-08-14T18:30:53-0400 b248c9a1 unchanged
rederived: 2026-08-14T18:31:13-0400 b248c9a1 unchanged
rederived: 2026-08-14T18:31:26-0400 b248c9a1 unchanged
rederived: 2026-08-14T19:50:32-0400 d20eee81 unchanged
rederived: 2026-08-14T19:50:54-0400 d20eee81 unchanged
rederived: 2026-08-14T20:02:54-0400 068ca7fd unchanged
rederived: 2026-08-14T21:00:58-0400 ab304cb2 unchanged
rederived: 2026-08-14T21:15:09-0400 5316a23e unchanged
rederived: 2026-08-14T23:07:32-0400 9d85a31d unchanged
rederived: 2026-08-15T00:30:16-0400 f4dab407 unchanged
rederived: 2026-08-15T01:11:36-0400 c9a1a8a4 unchanged
rederived: 2026-08-15T03:16:30-0400 2c7ff2a1 sources
rederived: 2026-08-15T03:17:34-0400 2c7ff2a1 unchanged
rederived: 2026-08-15T03:18:50-0400 2c7ff2a1 unchanged
rederived: 2026-08-15T04:01:11-0400 b18a891c sources
rederived: 2026-08-15T12:33:04-0400 eadb1784 unchanged
rederived: 2026-08-15T13:22:26-0400 4e897bc6 sources
rederived: 2026-08-15T14:24:10-0400 599da71e unchanged
rederived: 2026-08-15T14:56:50-0400 4caf46ef unchanged
rederived: 2026-08-15T15:02:00-0400 a06d9396 unchanged
rederived: 2026-08-15T15:16:39-0400 cc0d429b unchanged
rederived: 2026-08-15T15:19:24-0400 658719b4 unchanged
rederived: 2026-08-15T15:25:08-0400 7949e13a unchanged
rederived: 2026-08-15T16:00:11-0400 69217d7a sources
rederived: 2026-08-15T16:06:11-0400 69217d7a unchanged
rederived: 2026-08-15T16:43:48-0400 919bcc60 unchanged
rederived: 2026-08-15T18:06:56-0400 feaa6945 sources
rederived: 2026-08-15T19:13:29-0400 ce43eb74 unchanged
rederived: 2026-08-15T22:25:52-0400 f627b5b4 unchanged
rederived: 2026-08-16T13:07:45-0400 3fff0d5e unchanged
rederived: 2026-08-16T13:48:36-0400 abfb91b7 unchanged
rederived: 2026-08-16T14:23:14-0400 8e68ec3a unchanged
rederived: 2026-08-16T14:56:46-0400 3eac8061 unchanged
rederived: 2026-08-16T15:14:03-0400 3eac8061 unchanged
rederived: 2026-08-16T15:40:24-0400 484f1ecd unchanged
rederived: 2026-08-16T15:51:39-0400 3c9b1213 unchanged
rederived: 2026-08-16T16:01:12-0400 5e83598e unchanged
rederived: 2026-08-16T16:13:00-0400 d9f3bb77 unchanged
rederived: 2026-08-16T16:57:26-0400 49fcbc64 sources
rederived: 2026-08-16T18:23:18-0400 1162e33a unchanged
rederived: 2026-08-16T18:52:32-0400 51558682 unchanged
rederived: 2026-08-16T19:17:53-0400 0c75216b unchanged
rederived: 2026-08-16T21:38:02-0400 9e1756d6 unchanged
rederived: 2026-08-16T22:00:22-0400 c578fc99 unchanged
rederived: 2026-08-16T23:39:05-0400 eecd0c30 unchanged
rederived: 2026-08-17T02:09:48-0400 f94e2762 unchanged
rederived: 2026-08-17T03:31:09-0400 8cf43bb9 unchanged
rederived: 2026-08-17T14:41:19-0400 e7b68a20 sources
rederived: 2026-08-17T15:49:24-0400 6c899380 unchanged
rederived: 2026-08-17T15:52:53-0400 6c899380 unchanged
rederived: 2026-08-17T16:04:36-0400 ef984b29 unchanged
rederived: 2026-08-17T16:17:04-0400 f60e2999 unchanged
rederived: 2026-08-17T18:04:09-0400 30e23df6 unchanged
rederived: 2026-08-17T18:09:10-0400 4fb9b6b0 unchanged
rederived: 2026-08-17T18:50:31-0400 e18796a5 unchanged
-->
