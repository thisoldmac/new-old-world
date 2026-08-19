---
name: classic-mac-init-platform
description: Design, build, diagnose, package, and verify 68K INIT resources and resident system extensions for classic Mac System 6.0.4 through Mac OS 9.2.2 using Retro68, C or C++, Rez, Toolbox managers, system-heap memory, callbacks, resource forks, and HFS disk images. Use for startup-time execution, INIT 31 loading, sysz sizing, trap patches, Notification Manager, Time Manager, Deferred Task Manager, VBL or shutdown procedures, 24-bit cleanliness, extension recovery, or 68K-on-PowerPC compatibility. Use classic-mac-carbon-platform for normal application platform code and classic-mac-carbon-ui for application UI.
---

# Classic Mac INIT Platform

Develop boot-time code as system software, not as an application. Treat source compatibility, artifact correctness, successful loading, retained-code lifetime, callback execution, and stable boot behavior as separate claims.

## Establish the Target Contract

1. Record the minimum and maximum system versions, hardware families, CPU baseline, 24-bit or 32-bit addressing modes, virtual-memory expectation, toolchain revision, and recovery medium.
2. Use System 6.0.8 as the default System 6 release floor. Accept 6.0.4 through 6.0.7 only when their exact hardware and manager set will be tested.
3. Default to 68000-compatible 68K code. Treat native PowerPC, CFM, Mixed Mode, drivers, slot resources, and ROM patches as separate advanced projects.
4. Record whether the INIT is transient, installs resident code, patches a trap, registers a callback, or merely launches later work.
5. Decide whether an INIT is necessary. Prefer a normal application, control panel, or later-starting helper when boot-time privilege is not required.

Read [target-profiles.md](references/target-profiles.md) before selecting APIs or claiming a release range.

## Apply the Evidence Ladder

Distinguish:

1. declaration in selected headers;
2. successful 68000 compilation;
3. successful flat-resource link;
4. correct `INIT` resource and Finder metadata;
5. correct MacBinary, AppleDouble, HFS, or HFS+ preservation;
6. successful loader invocation on a declared system and ROM;
7. successful retained callback execution;
8. repeated clean boot, shutdown, disable, and recovery behavior.

Label conclusions **verified**, **probe-required**, **unsupported**, or **unresolved**. Never infer runtime compatibility from a header, link, resource listing, or disk-image insertion.

## Respect the INIT Lifecycle

- Assume no application heap, event loop, menu bar, Process Manager context, or valid application A5 world.
- Keep installation fast, deterministic, and nonmodal. Use the Notification Manager for deferred user notification.
- Assume the extension resource file closes after the INIT returns.
- For a transient INIT, release temporary globals and return.
- For resident behavior, detach and lock executable resources, retain system-heap state, and ensure every registered callback points only to retained code and data.
- Never let a callback reference stack storage, purgeable resources, an application's globals, or Retro68 BSS after `Retro68FreeGlobals()`.
- Do not mutate the folder being enumerated for extensions during startup.
- Do not depend on catalog order, filename prefixes, or another third-party INIT having run first.

Read [init-lifecycle.md](references/init-lifecycle.md) and [memory-and-callbacks.md](references/memory-and-callbacks.md) before implementing resident code.

## Gate Every Manager and Context

- Use Gestalt selectors for capabilities; trap-probe managers and traps that predate or vary within System 6.
- Do not infer manager presence from a system-version number when hardware or ROM controls availability.
- Treat Deferred Task, Time Manager, VBL, notification, shutdown, completion, and interrupt routines as distinct execution contexts.
- Do not allocate, compact memory, load resources, perform synchronous file I/O, or call UI managers from interrupt context unless Apple explicitly documents the call as safe there.
- Do not use Process Manager APIs during INIT execution, including on System 7 or later.
- Do not treat CarbonLib as a boot-time dependency. Default INIT code uses documented Toolbox traps and feature gates.

Read [manager-availability.md](references/manager-availability.md) before selecting a callback mechanism.

## Build a Compact Resource

- Compile explicitly for `-mcpu=68000` unless the target contract requires a later CPU.
- Use function and data sections and link flat resources with garbage collection.
- Generate a link map and preserve it with the packaged artifact.
- Treat 32 KB as a conservative advisory budget, not a generic packaging-validity limit. Supply and enforce a project limit only when the selected loader, repository authority, and test matrix establish it; larger resources remain a risk signal requiring cold-boot evidence.
- Package a locked `INIT` resource, conventionally ID 128, in a file with Finder type `INIT`.
- Add a four-byte big-endian `sysz` resource ID 0 only when pre-System-7 retained code or data requires system-heap headroom. Size the retained installation, not merely the transient installer.
- Preserve both forks and Finder metadata. A bare flat payload or resource fork is not an installable extension.

Read [build-and-packaging.md](references/build-and-packaging.md). Run `scripts/inspect_init.py` on MacBinary or raw resource-fork output before deployment.

## Verify With Recovery in Place

1. Build and inspect without modifying the only boot volume.
2. Install into a cloned image or disposable volume.
3. Keep a known-good boot floppy or alternate System Folder for System 6. Shift-to-disable is a System 7-and-later recovery path.
4. Test the minimum OS on representative minimum hardware, both addressing modes where applicable, a representative 68K Mac, and a PowerPC Mac when that claim is made.
5. Observe installation, retained callbacks, shutdown, restart, disable, and removal separately.
6. Record ROM, machine, RAM, addressing mode, VM state, system version, extension set, artifact hash, and exact result.

Read [testing-and-recovery.md](references/testing-and-recovery.md) for the test matrix and stop conditions. Read [sources.md](references/sources.md) for primary-source and implementation provenance. To drive an emulator for repeated boot, disable, and recovery observation, invoke the `classic-mac-emulator-harness` skill — use the `q800` 68K profile, tell hung from slow by frame-differencing and program-counter sampling rather than one screenshot, and never route boot testing to `pb1400` (its emulator cannot boot an OS).

## Produce a Gated Handoff

For substantial work, report:

1. target contract and excluded systems;
2. INIT mechanism and why boot-time code is necessary;
3. resident-code and global-state ownership;
4. manager, trap, and callback gates;
5. resource, `sysz`, and packaging plan;
6. recovery procedure;
7. evidence obtained at each ladder step;
8. remaining target probes and unsupported claims.
