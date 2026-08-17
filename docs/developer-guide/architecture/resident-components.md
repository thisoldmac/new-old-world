---
page_id: dev-arch-resident-components
title: Resident components
description: Optional extension ownership, versioned memory contracts, and bake requirements.
doc_type: explanation
audience: developer
lifecycle: current
authority: [docs/resident-components.md, contract/peek_table.h, contract/resident_version.h]
source_dependencies: [docs/resident-components.md, contract/peek_table.h, contract/resident_version.h, ext/src/now_ext.c, now-guest-ppc/src/peek/peek.c, tools/ext-bake-gate, product/features.yaml]
media_ids: []
last_verified: 2026-08-09
feature_ids: [resident.extension]
---

<!-- now-doc-provenance: generated reviewed=false -->

# Resident components

The NOW Extension performs only work that must run in a foreign application context. The PowerPC application is the sole reader of foreign memory and exposes the result to the rest of the product. The extension is optional: the application must report an unavailable plane honestly and keep non-resident features usable.

The public [feature coverage
matrix](../../user-guide/explanation/core-features.md#feature-coverage)
starts with user outcomes. This page owns the deeper P0–P8 execution, memory,
shared-header, bake, and recovery contracts.

```mermaid
flowchart LR
  F["Foreign application context"] -->|"bounded resident callbacks"| X["NOW Extension"]
  X -->|"versioned peek table"| P["NOW PowerPC application"]
  P -->|"validated facts and acts"| W["Wire contract"]
  P -.->|"extension absent: unavailable, not fabricated"| W
```

Text equivalent: resident callbacks observe or act in the foreign application, write a versioned shared table, and the NOW application validates and reads it before publishing results. Without the extension, the application reports unavailability rather than emulating resident state.

`contract/peek_table.h` is compiled by every reader and writer, with layout
assertions. `contract/resident_version.h` owns the one release identity shared
by the memory table and the resident liveness connection. The major version is
an exact compatibility boundary; the minor version is the monotonically
increasing release sequence within that boundary.

A change to `ext/`, either shared contract header, or resident behavior must
advance that tuple and have an exact-source bake receipt before landing on
`main`. The main-reference gate evaluates the proposed tree itself; a written
deferral may permit a branch checkpoint but never the landing.

<!-- derived-doc v1
sources: contract/peek_table.h ext/src/now_ext.c now-guest-ppc/src/peek/peek.c docs/resident-components.md scripts/docs-source-group tools/docs-gate
sources-sha1: 5aa16bd39dba40425c96341380f949cf053ded5f
derive resident-contract sha256=94aa1ceb2d2998a0973bc7f381405e008f6bcfcd416bac1a70e2b26d14ef97f8 lines=12
    scripts/docs-source-group resident
rederived: pending
rederived: 2026-08-09T16:22:14-0400 9034e3eb sources, resident-contract 11->11
rederived: 2026-08-09T16:29:42-0400 9034e3eb sources
rederived: 2026-08-09T17:05:28-0400 446cf620 sources
rederived: 2026-08-09T17:08:03-0400 446cf620 sources
rederived: 2026-08-09T17:53:28-0400 ed9436c0 sources
rederived: 2026-08-09T18:53:51-0400 181db7a5 sources
rederived: 2026-08-09T18:56:22-0400 181db7a5 unchanged
rederived: 2026-08-09T19:21:55-0400 dc5bfcd2 sources
rederived: 2026-08-09T19:33:55-0400 c854246d sources
rederived: 2026-08-09T20:56:35-0400 9864da82 sources, resident-contract 11->11
rederived: 2026-08-09T21:05:27-0400 9864da82 sources
rederived: 2026-08-09T21:43:46-0400 2b3c2c0e sources
rederived: 2026-08-09T22:09:30-0400 d54812c2 sources
rederived: 2026-08-09T22:18:48-0400 e637efd3 sources
rederived: 2026-08-10T03:07:04-0400 9cbb4c28 sources
rederived: 2026-08-10T03:08:46-0400 9cbb4c28 unchanged
rederived: 2026-08-10T03:11:42-0400 9cbb4c28 unchanged
rederived: 2026-08-10T03:46:36-0400 68d74d72 unchanged
rederived: 2026-08-10T02:53:59-0400 62603174 sources
rederived: 2026-08-10T04:18:14-0400 423ef214 sources
rederived: 2026-08-10T04:49:21-0400 cd585106 unchanged
rederived: 2026-08-10T04:27:16-0400 886ee556 unchanged
rederived: 2026-08-10T04:38:54-0400 886ee556 unchanged
rederived: 2026-08-10T05:38:07-0400 a0ede9ec unchanged
rederived: 2026-08-10T13:37:38-0400 2f62ec11 unchanged
rederived: 2026-08-10T13:51:46-0400 f4a92045 sources
rederived: 2026-08-10T14:07:44-0400 b22898ee unchanged
rederived: 2026-08-10T13:10:55-0400 47bf54fb unchanged
rederived: 2026-08-10T13:36:45-0400 b15b4827 unchanged
rederived: 2026-08-10T14:49:44-0400 4ea2d97d unchanged
rederived: 2026-08-10T14:20:13-0400 9e432b8b unchanged
rederived: 2026-08-10T15:11:51-0400 eb9d991c unchanged
rederived: 2026-08-10T15:34:28-0400 72868e9e unchanged
rederived: 2026-08-10T15:52:47-0400 77329146 unchanged
rederived: 2026-08-10T16:52:02-0400 d77cc444 unchanged
rederived: 2026-08-10T20:03:21-0400 d3e26c39 sources
rederived: 2026-08-10T20:22:52-0400 818c1577 unchanged
rederived: 2026-08-10T21:35:34-0400 a79833e9 sources
rederived: 2026-08-10T22:32:23-0400 e9bf9632 unchanged
rederived: 2026-08-10T22:33:05-0400 e9bf9632 sources
rederived: 2026-08-10T22:47:48-0400 431e7308 unchanged
rederived: 2026-08-11T00:25:04-0400 bbab04b9 unchanged
rederived: 2026-08-11T00:33:21-0400 4b24cc1f unchanged
rederived: 2026-08-11T19:45:15-0400 065da692 sources
rederived: 2026-08-11T20:08:52-0400 852b41ae sources
rederived: 2026-08-11T20:43:59-0400 5c07bcd6 sources
rederived: 2026-08-11T20:54:11-0400 f9ceab81 sources
rederived: 2026-08-11T21:13:09-0400 098805ff sources
rederived: 2026-08-11T21:20:50-0400 15514cc9 unchanged
rederived: 2026-08-11T21:26:22-0400 7bfb617b unchanged
rederived: 2026-08-11T21:32:38-0400 57a081ab unchanged
rederived: 2026-08-11T21:39:37-0400 5a82bf82 unchanged
rederived: 2026-08-11T21:49:34-0400 7dc5b09d unchanged
rederived: 2026-08-11T21:54:55-0400 8c482312 unchanged
rederived: 2026-08-11T21:59:53-0400 562b4b50 unchanged
rederived: 2026-08-11T22:06:34-0400 65f52bf3 unchanged
rederived: 2026-08-11T22:10:48-0400 3df65dde unchanged
rederived: 2026-08-11T22:15:20-0400 68853632 unchanged
rederived: 2026-08-11T22:31:03-0400 a16b6a61 unchanged
rederived: 2026-08-11T22:41:39-0400 e1fc84c4 unchanged
rederived: 2026-08-11T22:47:33-0400 9776cf7a unchanged
rederived: 2026-08-11T23:12:01-0400 ddf740ce sources
rederived: 2026-08-11T23:31:21-0400 ad4d680 sources
rederived: 2026-08-11T23:37:11-0400 ad4d680 unchanged
rederived: 2026-08-12T13:02:40-0400 7cea759e sources, resident-contract 11->12
rederived: 2026-08-12T13:11:34-0400 7cea759e unchanged
rederived: 2026-08-12T13:12:13-0400 7cea759e unchanged
rederived: 2026-08-12T15:54:08-0400 939e43b7 sources
rederived: 2026-08-12T17:19:19-0400 338eca21 sources
rederived: 2026-08-12T18:34:28-0400 3688b9f6 sources
rederived: 2026-08-12T18:58:27-0400 3771e144 sources
rederived: 2026-08-12T19:15:23-0400 3771e144 unchanged
rederived: 2026-08-12T19:31:57-0400 3771e144 unchanged
rederived: 2026-08-12T20:08:32-0400 5a601a18 unchanged
rederived: 2026-08-12T20:15:21-0400 9e828cdc sources
rederived: 2026-08-12T20:34:41-0400 4d9ba67d unchanged
rederived: 2026-08-12T20:37:07-0400 633da491 unchanged
rederived: 2026-08-12T20:45:45-0400 a0878023 unchanged
rederived: 2026-08-12T22:18:36-0400 18d0d3c4 unchanged
rederived: 2026-08-12T23:59:06-0400 e5b16a71 unchanged
rederived: 2026-08-13T00:21:45-0400 e5b16a71 unchanged
rederived: 2026-08-13T00:58:12-0400 9f5139cf sources
rederived: 2026-08-13T01:23:45-0400 9f5139cf unchanged
rederived: 2026-08-13T01:47:12-0400 59852197 unchanged
rederived: 2026-08-13T02:45:48-0400 e504061c unchanged
rederived: 2026-08-13T04:30:00-0400 47f632b3 unchanged
rederived: 2026-08-13T13:50:54-0400 a9e64fa4 sources
rederived: 2026-08-13T14:32:32-0400 4da9c4a3 unchanged
rederived: 2026-08-13T15:15:22-0400 2ccde05b sources
rederived: 2026-08-13T17:36:04-0400 043777df sources
rederived: 2026-08-13T17:37:42-0400 043777df unchanged
rederived: 2026-08-13T18:23:46-0400 e6d7996d sources
rederived: 2026-08-13T19:30:43-0400 1d154b67 sources
rederived: 2026-08-13T21:59:04-0400 8433efda sources
rederived: 2026-08-13T23:16:01-0400 fc235d4e sources
rederived: 2026-08-14T00:51:50-0400 94f1c614 sources
rederived: 2026-08-14T00:55:47-0400 3bd83df2 unchanged
rederived: 2026-08-14T02:20:50-0400 81247e50 sources
rederived: 2026-08-14T03:25:52-0400 ee8ef8a4 sources
rederived: 2026-08-14T03:54:48-0400 d016e771 sources
rederived: 2026-08-14T03:57:09-0400 e122c6c3 unchanged
rederived: 2026-08-14T04:03:19-0400 908215de unchanged
rederived: 2026-08-14T04:36:35-0400 e66db808 sources
rederived: 2026-08-14T12:32:38-0400 7742eab5 sources
rederived: 2026-08-14T12:35:44-0400 49e6dd98 unchanged
rederived: 2026-08-14T12:44:43-0400 4d52ba1a unchanged
rederived: 2026-08-14T12:47:23-0400 804be291 unchanged
rederived: 2026-08-14T12:49:05-0400 655b2bf1 unchanged
rederived: 2026-08-14T13:16:42-0400 90cfd8fa unchanged
rederived: 2026-08-14T14:27:57-0400 6d037a57 unchanged
rederived: 2026-08-14T15:56:43-0400 835e6acf unchanged
rederived: 2026-08-14T16:58:27-0400 cf962dbb unchanged
rederived: 2026-08-14T17:12:27-0400 32ac9165 unchanged
rederived: 2026-08-14T17:36:04-0400 02e9de5e unchanged
rederived: 2026-08-14T18:14:38-0400 db6a7c6a unchanged
rederived: 2026-08-14T18:17:41-0400 d9ed70d2 unchanged
rederived: 2026-08-14T18:19:50-0400 60bb3427 unchanged
rederived: 2026-08-14T18:20:41-0400 23dc0759 unchanged
rederived: 2026-08-14T18:22:06-0400 23dc0759 unchanged
rederived: 2026-08-14T18:23:11-0400 e2c66126 unchanged
rederived: 2026-08-14T18:30:52-0400 b248c9a1 unchanged
rederived: 2026-08-14T18:31:12-0400 b248c9a1 unchanged
rederived: 2026-08-14T18:31:25-0400 b248c9a1 unchanged
rederived: 2026-08-14T19:50:31-0400 d20eee81 unchanged
rederived: 2026-08-14T19:50:53-0400 d20eee81 unchanged
rederived: 2026-08-14T20:02:53-0400 068ca7fd sources
rederived: 2026-08-14T21:00:58-0400 ab304cb2 unchanged
rederived: 2026-08-14T21:15:08-0400 5316a23e unchanged
rederived: 2026-08-14T23:07:31-0400 9d85a31d unchanged
rederived: 2026-08-15T00:30:15-0400 f4dab407 unchanged
rederived: 2026-08-15T01:11:35-0400 c9a1a8a4 unchanged
rederived: 2026-08-15T03:16:30-0400 2c7ff2a1 unchanged
rederived: 2026-08-15T03:17:33-0400 2c7ff2a1 unchanged
rederived: 2026-08-15T03:18:49-0400 2c7ff2a1 unchanged
rederived: 2026-08-15T04:01:10-0400 b18a891c unchanged
rederived: 2026-08-15T12:33:03-0400 eadb1784 unchanged
rederived: 2026-08-15T13:22:24-0400 4e897bc6 unchanged
rederived: 2026-08-15T14:24:07-0400 599da71e unchanged
rederived: 2026-08-15T14:56:49-0400 4caf46ef unchanged
rederived: 2026-08-15T15:01:58-0400 a06d9396 unchanged
rederived: 2026-08-15T15:16:38-0400 cc0d429b unchanged
rederived: 2026-08-15T15:19:22-0400 658719b4 unchanged
rederived: 2026-08-15T15:25:07-0400 7949e13a unchanged
rederived: 2026-08-15T16:00:09-0400 69217d7a unchanged
rederived: 2026-08-15T16:06:08-0400 69217d7a unchanged
rederived: 2026-08-15T16:43:47-0400 919bcc60 unchanged
rederived: 2026-08-15T18:06:55-0400 feaa6945 unchanged
rederived: 2026-08-15T19:13:28-0400 ce43eb74 unchanged
rederived: 2026-08-15T22:25:51-0400 f627b5b4 unchanged
rederived: 2026-08-16T13:07:44-0400 3fff0d5e sources
rederived: 2026-08-16T13:48:35-0400 abfb91b7 sources
rederived: 2026-08-16T14:23:13-0400 8e68ec3a sources
rederived: 2026-08-16T14:56:45-0400 3eac8061 unchanged
rederived: 2026-08-16T15:14:02-0400 3eac8061 unchanged
rederived: 2026-08-16T15:40:23-0400 484f1ecd unchanged
rederived: 2026-08-16T15:51:38-0400 3c9b1213 sources
rederived: 2026-08-16T16:01:11-0400 5e83598e sources
rederived: 2026-08-16T16:12:59-0400 d9f3bb77 sources
rederived: 2026-08-16T16:57:25-0400 49fcbc64 sources
rederived: 2026-08-16T18:23:17-0400 1162e33a unchanged
rederived: 2026-08-16T18:52:31-0400 51558682 unchanged
rederived: 2026-08-16T19:17:52-0400 0c75216b unchanged
rederived: 2026-08-16T21:38:01-0400 9e1756d6 sources
rederived: 2026-08-16T22:00:21-0400 c578fc99 unchanged
rederived: 2026-08-16T23:39:04-0400 eecd0c30 unchanged
rederived: 2026-08-17T02:09:47-0400 f94e2762 unchanged
rederived: 2026-08-17T03:31:08-0400 8cf43bb9 unchanged
rederived: 2026-08-17T14:47:23-0400 1eb0e769 unchanged
-->
