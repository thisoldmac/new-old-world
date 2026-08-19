# Retro68, RetroPPC, and Packaging

## Toolchain discovery

Inspect the actual checkout and installed paths before writing commands:

- Retro68 git commit and dirty state;
- 68K and PPC compiler versions;
- CMake toolchain file;
- Universal Interfaces headers and target macros;
- import archives such as `InterfaceLib`, `AppearanceLib`, and `NavigationLib`;
- `Rez`, `MakePEF`, `ResInfo`, and application packaging templates.

Do not identify an SDK or runtime version from filenames alone.

## Installed build shapes observed in research

- `Retro68`: creates a classic code image and packages it with `Retro68APPL.r` into `CODE` resources and delivery containers.
- `RetroPPC`: links XCOFF, converts it to PEF, and packages the PEF as a data fork with `RetroPPCAPPL.r` and `cfrg`.
- `RetroCarbon`: is a separate PPC build mode that defines `TARGET_API_MAC_CARBON=1` and adds `carb`; do not select it for a non-Carbon Toolbox application.

The researched checkout was `335fa54f6d8ad1360840f08a067ffede7f554300` with GCC 16.1.0. Treat those as provenance, not permanent defaults.

## 68K segmentation

Prefer `--mac-single` initially. Multi-segment applications add Segment Manager loading/unloading, relocation, callback residency, jump-table, resource-file, and low-memory obligations. Never unload:

- the current call chain;
- code referenced by an active UPP/callback;
- interrupt, timer, VBL, completion, or deferred work;
- code whose residency cannot be proven.

Enable segmentation only after measured application size or heap pressure and inspect every `CODE` resource.

## Application resources

Supply deliberate project resources rather than shipping template defaults:

- `SIZE` with actual partition and process flags;
- menus, dialogs, controls, strings, icons, `vers`, `BNDL`, and `FREF` as required;
- `cfrg` for native PPC fragments;
- Finder type `APPL` and a real four-character creator signature.

Every System 7 or System 6+MultiFinder application needs an intentional `SIZE`. Template one-megabyte values and creator `????` are scaffolding.

## Artifact invariants

For classic 68K, verify `CODE` 0 and application code segments plus resources and `SIZE`.

For native PPC, verify a nonempty PEF data fork, `cfrg`, application resources, and `SIZE`. A `.pef` alone is incomplete.

For fat output, verify both 68K `CODE` and PPC PEF/`cfrg`, shared resources, Finder metadata, and launch on both architectures.

## Transport

Use MacBinary, AppleSingle/AppleDouble, a compatible HFS disk image, or a known fork-preserving filesystem path. After reconstruction, compare:

- Finder type and creator;
- data-fork size/hash;
- resource-fork size/hash and inventory;
- executable/import structure;
- launch result on the declared target.

Do not compare a MacBinary container directly to one AppleDouble sidecar and call a mismatch corruption; reconstruct the represented file first.
