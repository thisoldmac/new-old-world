---
name: classic-mac-carbon-platform
description: Build, diagnose, review, and verify the platform layer of PowerPC CFM applications for classic Mac OS 8.6 through 9.2.2 using CarbonLib, Retro68, CMake, Rez, Universal Interfaces, Toolbox managers, and classic application packaging. Use for compiler or header selection, ABI and CFM linkage, Carbon Events and event loops, pointers and handles, C++ runtime limits, files and resource forks, text encodings, Open Transport, cooperative concurrency, redraw delivery across timers or services, artifact preservation, crash symbolication, deployment, or emulator and hardware test gates. Use classic-mac-carbon-ui instead for visual layout, redraw ownership, damage, and control design.
---

# Classic Mac Carbon Platform

Develop the layer below the UI without importing Unix, macOS, or modern C++ runtime assumptions into classic Mac OS. Treat the declared target, installed toolchain, runtime services, complete application artifact, and observed target result as separate evidence.

## Establish the Target and Toolchain

1. Read the repository instructions and record the OS floor/ceiling, CarbonLib floor, CPU, toolchain, artifact path, deployment path, and test machines.
2. Inspect the actual Retro68 source revision, compiler, CMake toolchain, Universal Interfaces version, import libraries, flags, and generated artifacts. Run `scripts/fingerprint_toolchain.py` when the layout is available.
3. Do not label manually supplied Apple libraries as a particular SDK merely from filenames. Hash the relevant interface/import inputs.
4. Preserve the exact XCOFF/DWARF, link map, fingerprint, and packaged artifact for each diagnosable build.

Read [target-contract.md](references/target-contract.md) for the support boundary and capability matrix. Read [toolchain-build.md](references/toolchain-build.md) for the Retro68 pipeline and build diagnostics.

## Apply the Evidence Ladder

For every disputed API or behavior, distinguish:

1. declaration in the selected headers;
2. successful compilation;
3. successful link/import description;
4. successful CFM fragment preparation;
5. runtime capability selector or symbol gate;
6. successful service initialization and operation;
7. correct packaged metadata and forks;
8. observed behavior on the declared OS/hardware row.

Never promote an earlier layer into proof of a later one. Label conclusions **verified**, **probe-required**, **unsupported**, or **unresolved**.

## Route by Platform Boundary

- **ABI, callbacks, assembly, binary formats:** read [powerpc-cfm-abi.md](references/powerpc-cfm-abi.md).
- **C/C++ library or startup behavior:** read [runtime-cpp.md](references/runtime-cpp.md).
- **pointers, handles, resources, low-memory or interrupt safety:** read [memory-ownership.md](references/memory-ownership.md).
- **files, forks, Finder metadata, resource files, paths, or encodings:** read [files-resources-text.md](references/files-resources-text.md).
- **Gestalt, weak imports, Open Transport, Thread Manager, or MP Services:** read [services-concurrency.md](references/services-concurrency.md).
- **APPL, MacBinary, AppleDouble, disk images, copying, or LaunchAPPL:** read [artifacts-deployment.md](references/artifacts-deployment.md).
- **exceptions, crash records, maps, addresses, or stack recovery:** read [crash-symbolication.md](references/crash-symbolication.md).
- **release, emulator, hardware, or compatibility verification:** read [testing.md](references/testing.md).
- **launching, driving, observing, or tearing down an emulator (headless QEMU `mac99` for PowerPC/CarbonLib) to verify:** invoke the `classic-mac-emulator-harness` skill and drive by OS-API verbs, never synthetic cursor clicks.
- **windows, controls, layout, redraw ownership, damage, Appearance Manager, or Platinum-era UX:** invoke the peer `classic-mac-carbon-ui` skill and follow its `references/redraw-and-damage.md`.

## Enforce the Baseline Invariants

- PowerPC CFM is 32-bit big-endian. Do not serialize native structs or host representations.
- A PowerPC function pointer addresses a transition vector, not an instruction.
- Carbon source uses opaque Toolbox structures, opaque UPP types, and accessor calls.
- A relocatable handle's dereferenced pointer cannot survive a call that may compact memory unless the handle is locked.
- The application and Thread Manager are cooperative. Bound work and yield explicitly. Treat MP Services as an optional restricted environment.
- Retro68's newlib/libstdc++ presence does not imply POSIX paths, process APIs, entropy, clocks, stdio, threads, locale, or `std::filesystem` semantics.
- A PEF data fork is not a complete application. Preserve `cfrg`, `carb`, `SIZE`, Finder type/creator, resource fork, and project resources.
- UTF-8 protocol text, HFS+ Unicode names, classic script/Pascal strings, and `OSType` values are distinct byte domains.
- Exception handlers must be bounded, allocation-free, and reentrancy-safe. Treat exception-time file writing as target-probe-required.
- Event loops must deliver draw, update, activation, and idle work while foreground or background as the selected managers require. Timer, service, and I/O callbacks mutate state and request redraw through the UI layer; they do not perform ordinary drawing.

## Use Deterministic Inspection

- Run `scripts/fingerprint_toolchain.py --help` to capture the build environment.
- Run `scripts/inspect_artifact.py --help` to classify XCOFF, native APPL, MacBinary, AppleDouble, PEF, or disk-image outputs. For MacBinary, require an explicit parse status, Finder type/creator, fork sizes and hashes, and resource inventory before treating the report as package evidence.
- Run `scripts/verify_preservation.py SOURCE DEST` after a copy/archive reconstruction path.
- Run `scripts/symbolicate_crash.py --help` only with the exact matching XCOFF and the documented crash-record format.
- Copy `assets/target-probe/` to a temporary or project-owned location when a runtime capability report is needed; build it with the same RetroCarbon toolchain as the application.

Treat helper output as inspection evidence, not target behavior. Read [sources.md](references/sources.md) for the primary-document and implementation provenance.

## Verify in Proportion to the Claim

Use the smallest applicable progression:

1. host-only pure logic test;
2. compile/link probe;
3. package-structure inspection;
4. emulator launch on a declared OS row;
5. representative physical PowerPC hardware for timing, drivers, networking, memory pressure, extensions, and transfer reality.

Report the target contract, evidence gathered at each layer, fallback behavior, verification performed, and residual uncertainty. Do not claim launch or compatibility from artifact creation alone.
