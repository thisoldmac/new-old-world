---
page_id: dev-arch-resident-components
title: Resident components
description: Optional extension ownership, versioned memory contracts, and bake requirements.
doc_type: explanation
audience: developer
lifecycle: current
authority: [docs/resident-components.md, contract/peek_table.h, contract/resident_version.h]
source_dependencies: [docs/resident-components.md, contract/peek_table.h, contract/resident_version.h, ext/src/now_ext.c, now-guest-ppc/src/peek/peek.c, tools/ext-bake-gate, docs/feature-catalog.yaml]
media_ids: []
last_verified: 2026-08-09
feature_ids: [resident.extension]
---
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
sources-sha1: 41770a269d2c345e0d7e6e878600d02c3bedc347
derive resident-contract sha256=c9c8ffa94f6c2db0af0a8b407badbd9af9e80265cae227b57b68270df462ed0a lines=11
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
rederived: 2026-08-10T14:20:13-0400 9e432b8b unchanged
rederived: 2026-08-10T15:11:51-0400 eb9d991c unchanged
-->
