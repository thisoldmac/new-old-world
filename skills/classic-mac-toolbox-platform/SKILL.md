---
name: classic-mac-toolbox-platform
description: Build, diagnose, review, package, and verify normal non-Carbon classic Mac applications from System 6 through Mac OS 9, including classic 68K CODE-resource applications, native PowerPC CFM/PEF applications, and fat 68K/PPC applications. Use for Retro68 or RetroPPC, CMake, Rez, Universal Interfaces, manager initialization, event loops, A5 worlds, segmentation, CFM and import libraries, Mixed Mode callbacks, Handles and heaps, resources and files, Standard File or Navigation Services, Finder metadata, MacBinary or AppleDouble transport, crash investigation, deployment, emulators, or hardware validation. Use classic-mac-toolbox-ui for interface design, classic-mac-carbon-platform for CarbonLib applications, and classic-mac-init-platform for INITs.
---

# Classic Mac Toolbox Platform

Develop normal non-Carbon applications without importing Unix, macOS, Carbon, or modern-runtime assumptions. Route first by executable model, then prove declarations, builds, packaging, and target behavior separately.

## Establish the Target Contract

1. Record classic 68000-compatible 68K, later-CPU 68K, native PPC CFM, fat 68K/PPC, or advanced CFM-68K.
2. Record minimum/maximum system, hardware/ROM families, addressing mode, MultiFinder/Process Manager state, virtual memory, RAM, and application partition.
3. Record compiler, Retro68 revision, CMake toolchain, Universal Interfaces, import libraries, flags, and artifact/deployment path.
4. Record every optional extension/shared library and its fallback.
5. State the emulator and physical-machine rows required for the support claim.

Read [target-runtime.md](references/target-runtime.md) before selecting APIs or binary structure.

## Apply the Evidence Ladder

Distinguish:

1. declaration in selected headers;
2. successful compile;
3. successful classic-trap glue or CFM link/import;
4. successful code image or fragment creation;
5. correct `CODE`, PEF, `cfrg`, `SIZE`, resources, forks, and Finder metadata;
6. runtime capability/version check;
7. successful manager initialization and operation;
8. observed behavior on the exact target row.

Label conclusions **verified-document**, **verified-implementation**, **verified-target**, **probe-required**, **unsupported**, or **unresolved**. Never promote an earlier layer into a later one.

## Follow the Executable Model

- **Classic 68K:** use `CODE` resources, A5-world globals, and the classic Segment Manager model. Default modern Retro68 work to 68000-compatible single-segment output until measured size or heap pressure justifies segmentation.
- **Native PPC CFM:** package a PEF fragment described by `cfrg`; link the exact import libraries; respect transition vectors, Mixed Mode, alignment, and fragment preparation.
- **Fat classic application:** combine classic 68K `CODE` resources with a PPC data-fork PEF and `cfrg`; keep shared resources and serialized formats architecture-neutral.
- **CFM-68K:** treat as advanced and component-gated. It requires System 7.1+, 68020+, and the CFM-68K runtime; the currently researched Retro68 installation has no CFM-68K target.

Read [build-and-packaging.md](references/build-and-packaging.md) for Retro68/RetroPPC and artifact invariants.

## Own Manager, Memory, and Callback Lifetimes

- Initialize the non-Carbon managers actually used in a stable early sequence.
- Feature-test `WaitNextEvent`. Without it, use `GetNextEvent` plus `SystemTask`; do not call `SystemTask` in addition to `WaitNextEvent`.
- Dispatch every `updateEvt`, including those for inactive or background windows, through one balanced `BeginUpdate`/`EndUpdate` cycle owned by the UI layer.
- Keep event-loop, modal/filter, control-action, file-panel, completion, and interrupt callbacks within their documented context.
- Timer, service, I/O, and null-event work mutates model state and invalidates through the UI layer; it does not perform ordinary drawing. A bounded control-action or tracking callback may provide immediate feedback under the UI skill's redraw contract.
- Prefer Handles for movable long-lived data. Never retain a dereferenced Handle pointer across a call that can move or purge memory.
- Lock only for the interval requiring pointer stability; save and restore original Handle state.
- Call `MoreMasters` early from the main or never-unloaded segment and size `SIZE` deliberately.
- Never serialize native 68K/PPC structs without explicit byte order, widths, packing, and versioning.

Read [managers-memory-callbacks.md](references/managers-memory-callbacks.md) before implementing lifecycle or ownership code.

## Gate Optional Services by Executable Model

An API in Universal Interfaces may compile differently for classic 68K and native PPC. Establish trap availability or import-library requirements separately, then perform the runtime selector/version test.

- Appearance: 68K selector glue versus PPC `AppearanceLib`, followed by Appearance Gestalt and client registration.
- Navigation: 68K `Navigation` support versus PPC `NavigationLib`, followed by `NavServicesAvailable()` and Standard File fallback.
- Process Manager, Apple events, Drag Manager, Balloon Help, Open Transport, Thread Manager, and MP Services: each requires its own target and context contract.

Read [optional-services.md](references/optional-services.md). Invoke `classic-mac-toolbox-ui` for interaction design, visual behavior, redraw ownership, and damage handling, including its `references/redraw-and-damage.md`.

## Preserve the Complete Application

- Treat the resource fork as application structure, not optional metadata.
- Treat a `.pef` as an intermediate, not a Finder application.
- Set deliberate `APPL` type and four-character creator signature.
- Preserve both forks and Finder metadata using a verified MacBinary, AppleSingle/AppleDouble, compatible disk image, or HFS-aware path.
- Inspect after reconstruction on the destination representation; do not compare unlike container bytes as a preservation test.
- Preserve matching XCOFF/link maps and toolchain fingerprints for crash work.

## Verify in Proportion to the Claim

Use the smallest applicable progression:

1. host-only pure logic tests;
2. compile/link probes for each executable model;
3. package/resource/fork inspection;
4. emulator launch on a declared OS/ROM row;
5. representative hardware for instruction, timing, extensions, files, networking, low-memory, and transfer reality.

Read [testing-and-sources.md](references/testing-and-sources.md). Use the reusable sources under `assets/probes/` for Appearance and Navigation build-gate experiments, copying them into a temporary or project-owned directory first. They prove only the layer actually exercised. For the emulator control plane itself — headless launch, request-level readiness, driving by OS-API verbs rather than synthetic clicks, liveness diagnosis, and clean teardown — invoke the `classic-mac-emulator-harness` skill; `q800` is the 68K profile, `mac99` the PowerPC one.

For substantial work, report the target contract, executable model, manager/ABI ownership, build and package structure, optional-service gates, verification performed, fallback behavior, and residual uncertainty.
