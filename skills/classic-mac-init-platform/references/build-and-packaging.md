# Build and Packaging

## Retro68 compile and link profile

Use explicit flags instead of relying on toolchain defaults:

```cmake
target_compile_options(MyExtension PRIVATE
    -mcpu=68000
    -ffunction-sections
    -fdata-sections)

target_link_options(MyExtension PRIVATE
    -Wl,--mac-flat
    -Wl,-gc-sections
    -Wl,-Map,MyExtension.map)
```

Set the actual code-resource entry point when it is not the linker's default. Inspect the generated object flags and link map. A successful flat link does not prove that all invoked traps exist on the minimum system.

Section garbage collection is mandatory for the default profile. Retro68 runtime and library archives can otherwise pull a small INIT above the historical 32 KB guidance.

## Rez envelope

A conventional envelope is:

```rez
#include "Retro68.r"

type 'INIT' {
    RETRO68_CODE_TYPE
};

resource 'INIT' (128, locked) {
    dontBreakAtEntry, $$read("MyExtension.flt");
};
```

For pre-System-7 retained memory:

```rez
type 'sysz' {
    longint;
};

resource 'sysz' (0) {
    8192
};
```

`sysz` contains one big-endian long word. It asks the loader to make installation headroom available; it does not allocate or own memory. Base its value on retained executable resources, retained state, records, and bounded installation slack. A transient INIT with no retained state normally does not need it.

## Artifact contract

Verify:

- Finder type is `INIT`;
- `INIT` resource 128 exists and has the locked attribute;
- the INIT payload meets the declared size budget;
- `sysz` is absent by design or is resource 0 with exactly four bytes;
- icons, strings, version resources, and retained code resources have stable IDs;
- resource and data forks survive every transfer step;
- the installed filename is visible on System 6;
- the destination is System Folder for System 6 and Extensions for the normal System 7-and-later case.

Run:

```bash
python3 scripts/inspect_init.py MyExtension.bin
```

The inspector accepts MacBinary and raw resource-fork files. It does not prove boot loading or callback safety.

## Transport

Prefer a MacBinary, AppleSingle, AppleDouble, StuffIt archive, or HFS/HFS+ disk image whose preservation path has been tested. Do not use a plain host copy that discards Finder metadata or the resource fork.

When injecting into a disk image, work on a clone and verify the resulting catalog entry, Finder type, visibility, and both fork lengths before booting.
