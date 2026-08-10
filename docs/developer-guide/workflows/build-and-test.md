---
page_id: dev-workflow-build-test
title: Build and test
description: Run the repository gates in their intended order and report the result honestly.
doc_type: how-to
audience: developer
lifecycle: current
authority: [AGENTS.md, scripts/test-all]
source_dependencies: [scripts/test-all, scripts/test-native, scripts/test-mirrorkit, scripts/build-guests, scripts/test-host, scripts/test-docs]
media_ids: []
last_verified: 2026-08-09
---
# Build and test

## Run the full gate

```sh
scripts/test-all
```

The script runs cheap contract/native checks before package, documentation, cross-compile, and Xcode work. It stops on the first failing stage and names it. Do not replace it with `swift test`: the app target and the guest cross-compilers are separate failure surfaces.

## Run a focused stage

```sh
scripts/test-native frame
scripts/test-mirrorkit
scripts/test-docs
scripts/build-guests
scripts/test-host
```

Guest builds may skip when Retro68 is unavailable. State the skip. Metal suites are opt-in through their documented environment variables and fail, rather than skip, once opted in.

## Verify a new guard

Mutate the exact condition the guard claims to detect, prove the mutation built, and observe that test fail. Restore the source and observe it pass. A build failure is not a test failure, and a different mutation is not evidence for the named guard.

<!-- derived-doc v1
sources: scripts/test-all scripts/test-host scripts/test-native scripts/build-guests scripts/test-docs .github/workflows/ci.yml scripts/docs-source-group tools/docs-gate
sources-sha1: d5ef699abfbec77ac8434812e837f057cc354fb4
derive test-stages sha256=25c7e655f14b9b69236c5848029a7db69b97e5f152d74f23a9419531ce83ec91 lines=8
    scripts/docs-source-group build
rederived: pending
rederived: 2026-08-09T16:22:14-0400 9034e3eb sources, test-stages 7->7
rederived: 2026-08-09T16:24:13-0400 9034e3eb sources
rederived: 2026-08-09T16:29:42-0400 9034e3eb sources
rederived: 2026-08-09T17:05:28-0400 446cf620 sources
rederived: 2026-08-09T17:08:04-0400 446cf620 sources
rederived: 2026-08-09T17:53:28-0400 ed9436c0 sources
rederived: 2026-08-09T18:53:51-0400 181db7a5 sources
rederived: 2026-08-09T18:56:22-0400 181db7a5 unchanged
rederived: 2026-08-09T19:21:55-0400 dc5bfcd2 sources
rederived: 2026-08-09T19:33:55-0400 c854246d sources
rederived: 2026-08-09T20:56:35-0400 9864da82 sources
rederived: 2026-08-09T21:05:27-0400 9864da82 sources
rederived: 2026-08-09T21:43:47-0400 2b3c2c0e sources
rederived: 2026-08-09T22:09:30-0400 d54812c2 sources
rederived: 2026-08-09T22:18:48-0400 e637efd3 sources
rederived: 2026-08-10T02:53:59-0400 62603174 sources
rederived: 2026-08-10T04:27:16-0400 886ee556 unchanged
rederived: 2026-08-10T04:38:54-0400 886ee556 unchanged
rederived: 2026-08-10T05:38:07-0400 a0ede9ec unchanged
rederived: 2026-08-10T13:10:56-0400 47bf54fb sources
rederived: 2026-08-10T13:36:45-0400 b15b4827 unchanged
rederived: 2026-08-10T14:34:28-0400 e75a07a0 sources, test-stages 7->8
rederived: 2026-08-10T14:49:44-0400 4ea2d97d sources
-->
