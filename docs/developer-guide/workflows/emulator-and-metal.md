---
page_id: dev-workflow-emulator-metal
title: Emulator and metal verification
description: Use session-private emulators and real hardware without confusing a reachable machine for the build under test.
doc_type: how-to
audience: operator
lifecycle: current
authority: [AGENTS.md, docs/68k-metal-runbook.md, docs/staged-images.md]
source_dependencies: [scripts/spin-up-ppc, scripts/q800-68k, tools/lane-ports, tools/base-image, docs/68k-metal-runbook.md, docs/staged-images.md]
media_ids: []
last_verified: 2026-08-09
---

<!-- now-doc-provenance: generated reviewed=false -->

# Emulator and metal verification

## Reserve the lane

Use `tools/lane-ports`; ports derive from the worktree path. Never reuse a convenient fixed port or kill the process named by `lsof`. Reclaim only through the lane owner and QMP socket.

## Ask for the base image

```sh
tools/base-image which
```

The tool is the authority for which image a purpose clones and whether it is fit. `scripts/spin-up-ppc` stages this checkout's application and extension into a session-private clone; `scripts/q800-68k` provides the corresponding 68K harness.

## Identify the responder

Pass the lane's port into the test and assert a capability unique to the build under test. On hardware, set `NOW_METAL_MACHINE` so the machine guard can refuse concurrent ownership before binding.

## Preserve evidence

Record the build stamp, machine, port, base image, staged artifacts, and guest-reported identity. A metal measurement belongs in the structured output format, not only in prose. Stop the guest cleanly and retain the run provenance file with the result.

