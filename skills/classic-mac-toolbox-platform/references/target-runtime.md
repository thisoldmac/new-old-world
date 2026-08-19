# Target and Runtime Profiles

## Contents

- Classic 68K
- Native PowerPC CFM
- Fat applications
- CFM-68K
- 68K under PPC emulation
- Minimum contract

## Classic 68K

Classic 68K applications use an A5 world, jump table, and executable `CODE` resources. Segment blocks can be relocatable and purgeable. Use a 68000-compatible build for broad reach. If selecting 68020+, FPU, or other later instructions, declare that hardware floor explicitly.

System 6 without MultiFinder is a single-application environment. System 6 with MultiFinder and System 7+ provide the cooperative Process Manager environment. Feature-test `WaitNextEvent`; otherwise use `GetNextEvent` and `SystemTask`.

## Native PowerPC CFM

Native PPC applications use CFM fragments, normally stored as PEF and located by `cfrg`. Function pointers identify transition vectors rather than raw instruction addresses. Import libraries, fragment preparation, global-data layout, Mixed Mode boundaries, and structure alignment differ from classic 68K.

System 7.1.2 is a practical first-Power-Mac validation floor because Apple's original Power Macintosh specifications list it. Still declare machine-specific System Enablers, ROM, CFM state, and optional library versions.

## Fat applications

The straightforward classic 68K/PPC application combines:

- 68K `CODE` resources in the resource fork;
- PPC PEF in the data fork;
- `cfrg` ID 0 describing the PPC fragment.

The 68K Process Manager executes `CODE`; the PPC Process Manager follows `cfrg`. Verify both launch paths. Keep shared resource IDs stable and define architecture-neutral serialized formats.

## CFM-68K

Apple requires:

- System 7.1 or later;
- 68020 or later;
- the CFM-68K runtime library or Runtime Enabler;
- enough RAM for required shared libraries, with 8 MB suggested where file mapping is unavailable.

Check `gestaltCFMAttr`/`gestaltCFMPresent`. The researched Retro68 installation exposes classic Retro68, RetroPPC, and RetroCarbon targets, not CFM-68K. Do not offer a CFM-68K build recipe without a different verified toolchain.

## 68K under PPC emulation

PowerPC system software includes a 68LC040 emulator for classic 68K code. Apple documents missing FPU, PMMU, and coprocessor-interface behavior. An emulator success does not prove a real 68K hardware row, timing, or instruction contract.

## Minimum contract

Record:

- CPU and executable format;
- system floor/ceiling and ROM/hardware families;
- 24-bit/32-bit compatibility and virtual-memory expectations;
- MultiFinder/Process Manager behavior;
- optional extensions/shared libraries and fallbacks;
- screen/depth and application partition;
- package transport and validation destination;
- emulator and hardware acceptance rows.
