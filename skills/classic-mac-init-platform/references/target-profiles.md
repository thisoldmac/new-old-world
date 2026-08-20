# Target Profiles

## Scope

Use System 6.0.4 through Mac OS 9.2.2 as the knowledge and authoring range. Use System 6.0.8 as the default implementation floor. Earlier systems require ROM-specific techniques, older environment discovery, and recovery procedures outside the core skill.

Do not turn the skill's knowledge range into a product claim. A project supports only the rows it boots and exercises.

## Release matrix

| Profile | Loader and folders | Memory and services | Required posture |
|---|---|---|---|
| System 6.0.4-6.0.8 | INIT 31 scans visible `INIT`, `cdev`, and `RDEV` files in the System Folder | Static system heap; Gestalt from 6.0.4; no Process Manager API; Deferred Task Manager varies by hardware | Use `sysz` for retained installation memory; trap-probe optional managers; keep a rescue floppy |
| System 7.0-7.6.1 | Extensions and Control Panels folders are startup locations | Growable system heap; Process Manager and Folder Manager exist after startup; extended Time Manager; Deferred Task Manager broadly available | Do not assume Process Manager while the INIT runs; test Shift-to-disable recovery |
| Mac OS 8.0-8.1 | Same resource-based INIT model | 8.1 introduces HFS+ | Preserve resource forks and Finder metadata across HFS and HFS+ tooling |
| Mac OS 8.5-9.2.2 | Same INIT envelope on PowerPC-only hardware | 68K emulator, Mixed Mode and CFM present; Carbon facilities exist later in startup | Keep 68K INIT as the default common lane; separate native PPC and preemptive work |

## Architecture profiles

### Baseline 68K

- Emit 68000 instructions.
- Avoid FPU assumptions.
- Avoid direct high-pointer-bit manipulation.
- Trap-probe facilities not guaranteed by the minimum ROM and system.
- Test 24-bit mode when the chosen hardware supports it.

### 68K on PowerPC

Conforming 68K software can execute through the classic 68LC040 emulator. This does not validate undocumented register assumptions, stale pointers, self-modifying code, interrupt timing, or Mixed Mode crossings.

### Native PowerPC

Treat native PowerPC resident code as an explicit secondary design. Require:

- Code Fragment Manager and Mixed Mode design;
- routine descriptors or UPP ownership;
- separate ABI and global-data analysis;
- native callback verification;
- no assumption that Retro68's 68K code-resource workflow produces a native INIT.

### Mac OS X Classic

Treat the Classic Environment as advisory compatibility only. Do not fold it into a System 6 through Mac OS 9 native-boot claim.

## Out of core scope

- device drivers and driver replacement;
- Open Transport modules;
- slot declaration ROMs and secondary init code;
- ROM patches and boot blocks;
- nanokernel or Multiprocessing Services native tasks;
- Mac OS X kernel or System Extensions.
