---
page_id: dev-workflow-build-test
title: Build and test
description: Run the repository gates in their intended order and report the result honestly.
doc_type: how-to
audience: developer
lifecycle: current
authority: [AGENTS.md, scripts/test-all]
source_dependencies: [scripts/test-all, scripts/test-native, scripts/test-mirrorkit, scripts/build-guests, scripts/test-host, scripts/test-docs, docs/onboarding.md]
media_ids: []
last_verified: 2026-08-10
---

<!-- now-doc-provenance: generated reviewed=false -->

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

The guest cross-build uses Retro68's import libraries; it does not require a
CarbonLib binary in this checkout. Runtime installation does: the public
instructions link to
[CarbonLib 1.6.1 on Macintosh Repository](https://www.macintoshrepository.org/17069-carbonlib).
GitHub source and binary releases must not silently acquire or redistribute
that third-party component. The owner may publish a separately hosted
binaries-plus-CarbonLib convenience package after its URL, contents, and
checksum are recorded.

Both host packages and the Xcode application compile in Swift 6 language mode.
`scripts/test-mirrorkit` and `scripts/test-host` reject compiler warnings that
originate in their project source trees; a warning is a failing gate, not an
informational budget to carry forward.

The ordinary host gate compiles unsigned Debug and Release applications so a
clean contributor checkout and GitHub-hosted runner need no Apple credential.
That is build evidence, not distribution-signature evidence. Owner release
qualification is a separate explicit mode:

```sh
NOW_HOST_SIGNING=release scripts/test-host
```

Release mode supplies the selected public Team ID at build time and refuses an
artifact whose signature, application identifier, or Keychain access group
does not match. The Team ID is public release identity; its certificate and
private key are not stored in Git.

`tools/product-version-gate check` verifies the release identity copies in a
candidate index. `tools/product-version-gate main-ref-check OLD NEW` is the
immutable-tree check the `reference-transaction` hook runs before any product
change reaches main. `scripts/test-all` mutation-tests both that refusal and the
Extension's independent main/bake gate.

## Verify a new guard

Mutate the exact condition the guard claims to detect, prove the mutation built, and observe that test fail. Restore the source and observe it pass. A build failure is not a test failure, and a different mutation is not evidence for the named guard.

<!-- derived-doc v1
sources: scripts/test-all scripts/test-host scripts/test-native scripts/build-guests scripts/test-docs .github/workflows/ci.yml scripts/docs-source-group tools/docs-gate
sources-sha1: c43e6a4b4aa013c818ef374f4e5705c5e4f97730
derive test-stages sha256=f78dc22859b46a2e58f5cfceec0ceaf149bf5b1e89be24a1705af22181842aa5 lines=8
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
rederived: 2026-08-10T03:07:05-0400 9cbb4c28 sources
rederived: 2026-08-10T03:08:46-0400 9cbb4c28 unchanged
rederived: 2026-08-10T03:11:42-0400 9cbb4c28 unchanged
rederived: 2026-08-10T03:46:11-0400 68d74d72 sources, test-stages 7->7
rederived: 2026-08-10T03:46:36-0400 68d74d72 unchanged
rederived: 2026-08-10T02:53:59-0400 62603174 sources
rederived: 2026-08-10T04:18:14-0400 423ef214 sources
rederived: 2026-08-10T04:49:22-0400 cd585106 unchanged
rederived: 2026-08-10T04:27:16-0400 886ee556 unchanged
rederived: 2026-08-10T04:38:54-0400 886ee556 unchanged
rederived: 2026-08-10T05:38:07-0400 a0ede9ec unchanged
rederived: 2026-08-10T13:37:38-0400 2f62ec11 unchanged
rederived: 2026-08-10T13:51:46-0400 f4a92045 sources
rederived: 2026-08-10T14:07:44-0400 b22898ee unchanged
rederived: 2026-08-10T13:10:56-0400 47bf54fb sources
rederived: 2026-08-10T13:36:45-0400 b15b4827 unchanged
rederived: 2026-08-10T14:34:28-0400 e75a07a0 sources, test-stages 7->8
rederived: 2026-08-10T14:49:44-0400 4ea2d97d sources
rederived: 2026-08-10T14:20:13-0400 9e432b8b sources
rederived: 2026-08-10T15:11:51-0400 eb9d991c sources
rederived: 2026-08-10T15:34:28-0400 72868e9e unchanged
rederived: 2026-08-10T15:52:47-0400 77329146 unchanged
rederived: 2026-08-10T16:52:02-0400 d77cc444 sources, test-stages 8->8
rederived: 2026-08-10T20:03:22-0400 d3e26c39 sources
rederived: 2026-08-10T20:22:52-0400 818c1577 sources
rederived: 2026-08-10T21:35:35-0400 a79833e9 sources
rederived: 2026-08-10T22:32:24-0400 e9bf9632 sources
rederived: 2026-08-10T22:33:05-0400 e9bf9632 sources
rederived: 2026-08-10T22:47:48-0400 431e7308 sources
rederived: 2026-08-11T00:25:05-0400 bbab04b9 sources
rederived: 2026-08-11T00:33:21-0400 4b24cc1f unchanged
rederived: 2026-08-11T19:26:24-0400 955069d1 sources
rederived: 2026-08-11T19:45:15-0400 065da692 sources
rederived: 2026-08-11T20:08:53-0400 852b41ae sources
rederived: 2026-08-11T20:43:59-0400 5c07bcd6 sources
rederived: 2026-08-11T20:54:11-0400 f9ceab81 sources
rederived: 2026-08-11T21:13:10-0400 098805ff sources
rederived: 2026-08-11T21:20:51-0400 15514cc9 unchanged
rederived: 2026-08-11T21:26:22-0400 7bfb617b unchanged
rederived: 2026-08-11T21:32:38-0400 57a081ab unchanged
rederived: 2026-08-11T21:39:37-0400 5a82bf82 unchanged
rederived: 2026-08-11T21:49:35-0400 7dc5b09d unchanged
rederived: 2026-08-11T21:54:55-0400 8c482312 unchanged
rederived: 2026-08-11T21:59:53-0400 562b4b50 unchanged
rederived: 2026-08-11T22:06:34-0400 65f52bf3 unchanged
rederived: 2026-08-11T22:10:48-0400 3df65dde unchanged
rederived: 2026-08-11T22:15:20-0400 68853632 unchanged
rederived: 2026-08-11T22:31:03-0400 a16b6a61 unchanged
rederived: 2026-08-11T22:41:39-0400 e1fc84c4 unchanged
rederived: 2026-08-11T22:47:33-0400 9776cf7a unchanged
rederived: 2026-08-11T23:12:01-0400 ddf740ce sources
rederived: 2026-08-11T23:31:22-0400 ad4d680 sources
rederived: 2026-08-11T23:37:11-0400 ad4d680 unchanged
rederived: 2026-08-12T12:53:57-0400 5feb2eb sources
rederived: 2026-08-12T13:02:41-0400 7cea759e sources
rederived: 2026-08-12T13:11:34-0400 7cea759e unchanged
rederived: 2026-08-12T13:12:13-0400 7cea759e unchanged
rederived: 2026-08-12T14:17:18-0400 5feb2eb sources
rederived: 2026-08-12T14:19:58-0400 5feb2eb unchanged
rederived: 2026-08-12T14:31:49-0400 429dc08 sources
rederived: 2026-08-12T15:54:08-0400 939e43b7 unchanged
rederived: 2026-08-12T17:19:19-0400 338eca21 unchanged
rederived: 2026-08-12T18:34:28-0400 3688b9f6 sources
rederived: 2026-08-12T18:58:27-0400 3771e144 sources
rederived: 2026-08-12T19:15:24-0400 3771e144 unchanged
rederived: 2026-08-12T19:31:58-0400 3771e144 unchanged
rederived: 2026-08-12T20:08:32-0400 5a601a18 unchanged
rederived: 2026-08-12T20:15:22-0400 9e828cdc sources
rederived: 2026-08-12T20:34:42-0400 4d9ba67d unchanged
rederived: 2026-08-12T20:37:07-0400 633da491 sources
rederived: 2026-08-12T20:45:45-0400 a0878023 unchanged
rederived: 2026-08-12T22:18:37-0400 18d0d3c4 unchanged
rederived: 2026-08-12T23:59:07-0400 e5b16a71 unchanged
rederived: 2026-08-13T00:21:45-0400 e5b16a71 unchanged
rederived: 2026-08-13T00:58:12-0400 9f5139cf sources
rederived: 2026-08-13T01:23:45-0400 9f5139cf unchanged
rederived: 2026-08-13T01:47:13-0400 59852197 unchanged
rederived: 2026-08-13T02:45:49-0400 e504061c sources
rederived: 2026-08-13T04:30:00-0400 47f632b3 unchanged
rederived: 2026-08-13T13:50:55-0400 a9e64fa4 unchanged
rederived: 2026-08-13T14:32:32-0400 4da9c4a3 sources
rederived: 2026-08-13T15:15:23-0400 2ccde05b unchanged
rederived: 2026-08-13T17:36:05-0400 043777df unchanged
rederived: 2026-08-13T17:37:43-0400 043777df unchanged
rederived: 2026-08-13T18:23:46-0400 e6d7996d unchanged
rederived: 2026-08-13T19:30:44-0400 1d154b67 unchanged
rederived: 2026-08-13T21:59:04-0400 8433efda unchanged
rederived: 2026-08-13T23:16:01-0400 fc235d4e sources
rederived: 2026-08-14T00:51:51-0400 94f1c614 unchanged
rederived: 2026-08-14T00:55:48-0400 3bd83df2 unchanged
rederived: 2026-08-14T02:20:51-0400 81247e50 unchanged
rederived: 2026-08-14T03:25:52-0400 ee8ef8a4 unchanged
rederived: 2026-08-14T03:54:48-0400 d016e771 sources
rederived: 2026-08-14T03:57:09-0400 e122c6c3 unchanged
rederived: 2026-08-14T04:03:19-0400 908215de unchanged
rederived: 2026-08-14T04:36:35-0400 e66db808 unchanged
rederived: 2026-08-14T12:32:38-0400 7742eab5 sources
rederived: 2026-08-14T12:35:44-0400 49e6dd98 sources
rederived: 2026-08-14T12:44:43-0400 4d52ba1a sources
rederived: 2026-08-14T12:47:23-0400 804be291 sources
rederived: 2026-08-14T12:49:05-0400 655b2bf1 unchanged
rederived: 2026-08-14T13:16:43-0400 90cfd8fa sources
rederived: 2026-08-14T14:27:57-0400 6d037a57 unchanged
rederived: 2026-08-14T16:58:27-0400 cf962dbb sources
rederived: 2026-08-14T17:12:28-0400 32ac9165 unchanged
rederived: 2026-08-14T17:36:04-0400 02e9de5e unchanged
rederived: 2026-08-14T18:14:39-0400 db6a7c6a unchanged
rederived: 2026-08-14T18:17:42-0400 d9ed70d2 unchanged
rederived: 2026-08-14T18:19:50-0400 60bb3427 unchanged
rederived: 2026-08-14T15:56:43-0400 835e6acf sources
rederived: 2026-08-14T18:20:41-0400 23dc0759 sources, sources
rederived: 2026-08-14T18:22:07-0400 23dc0759 sources, sources
rederived: 2026-08-14T18:23:12-0400 e2c66126 sources, sources, sources
rederived: 2026-08-14T18:30:52-0400 b248c9a1 unchanged
rederived: 2026-08-14T18:31:12-0400 b248c9a1 unchanged
rederived: 2026-08-14T18:31:25-0400 b248c9a1 unchanged
rederived: 2026-08-14T20:24:56-0400 6d3d74d7 sources
rederived: 2026-08-14T20:18:49-0400 cccec57a unchanged
rederived: 2026-08-14T21:50:42-0400 edcc526f unchanged
rederived: 2026-08-14T22:27:41-0400 5a6c46dc unchanged
rederived: 2026-08-14T22:10:44-0400 568967b9 unchanged
rederived: 2026-08-14T23:30:11-0400 0017d984 unchanged
rederived: 2026-08-14T22:14:12-0400 0e743bc5 sources
rederived: 2026-08-14T23:32:09-0400 a9afc153 unchanged
-->
