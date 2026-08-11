---
page_id: dev-workflow-emulator-metal
title: Emulator and metal verification
description: Use session-private emulators and real hardware without confusing a reachable machine for the build under test.
doc_type: how-to
audience: operator
lifecycle: current
authority: [AGENTS.md, docs/68k-metal-runbook.md, docs/staged-images.md, docs/developer-guide/workflows/sheepshaver-86.md]
source_dependencies: [scripts/emulator, scripts/spin-up-ppc, scripts/q800-68k, scripts/sheepshaver-86, tools/lane-ports, tools/base-image, docs/68k-metal-runbook.md, docs/staged-images.md]
media_ids: []
last_verified: 2026-08-09
---
# Emulator and metal verification

## Choose the domain before the tool

```sh
scripts/emulator matrix
```

| Domain | Use it for | Do not infer |
|---|---|---|
| `qemu-ppc` | Full-stack PowerPC behavior on `mac99`: Mac OS 9.1+, resident components, networking, hardware interactions, wire and QMP-driven acceptance. | That the UI is the quickest or minimum-floor Carbon reference; that hardware timing matches a PowerBook. |
| `sheepshaver-86` | Fast PowerPC Carbon UI iteration on Mac OS 8.6 plus CarbonLib 1.6: native Toolbox controls, menus, windows, application launch, and minimum-floor compatibility for NOW and CodeKitten. | Resident, hardware, or 9.1+ behavior; QMP semantics; compatibility of a toolchain or package whose own manifest requires a newer system. |
| `qemu-68k` | 68K correctness on the current q800 profile: application logic, MacTCP, File Manager, and frame integrity before metal. | Exact System 7 or target-machine UI, memory pressure, timing, or hardware fidelity. |
| Metal | Final behavior on the actual machine with its real OS, peripherals, storage, network, and timing. | Nothing broader than the named machine, build, and observation. |

`scripts/emulator` is only a domain router. Each existing harness retains its
own lifecycle, safety guards, and evidence vocabulary. Basilisk II is reserved
for future profile-driven 68K UI oracles and is intentionally not exposed as a
working domain yet.

## Reserve the lane

Use `tools/lane-ports`; ports derive from the worktree path. Never reuse a convenient fixed port or kill the process named by `lsof`. Reclaim only through the lane owner and QMP socket.

## Ask for the base image

```sh
tools/base-image which
```

The tool is the authority for which image a purpose clones and whether it is fit. `scripts/spin-up-ppc` stages this checkout's application and extension into a session-private clone; `scripts/q800-68k` provides the corresponding 68K harness.

SheepShaver uses a different ownership model: its 8.6 oracle is a persistent
`.sheepvm` profile with explicit clean and versioned snapshots. Operate it with
`scripts/sheepshaver-86`; its HFS images do not enter QEMU's base-image or
resident-bake machinery.

## Identify the responder

Pass the lane's port into the test and assert a capability unique to the build under test. On hardware, set `NOW_METAL_MACHINE` so the machine guard can refuse concurrent ownership before binding.

## Preserve evidence

Record the build stamp, machine, port, base image, staged artifacts, and guest-reported identity. A metal measurement belongs in the structured output format, not only in prose. Stop the guest cleanly and retain the run provenance file with the result.
