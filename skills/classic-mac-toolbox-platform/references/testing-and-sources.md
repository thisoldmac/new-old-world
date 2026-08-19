# Testing and Sources

## Verification progression

1. Test byte-order, parsers, state machines, and other pure logic on the host.
2. Compile and link each selected architecture with the exact toolchain.
3. Inspect `CODE`, PEF imports, `cfrg`, `SIZE`, resource inventory, forks, Finder metadata, and creator/type.
4. Reconstruct the transport representation on HFS and inspect again.
5. Launch on declared emulator OS/ROM rows.
6. Test representative physical hardware for timing, instructions, drivers, extension sets, memory pressure, display, networking, and real transfer paths.

Keep artifact hashes, Retro68 commit, compilers, flags, link maps/XCOFF, ROM/machine/system/component state, and exact results.

## Required target pressure

- minimum application partition and allocation failure;
- compact screen and claimed color depths;
- System 6 without MultiFinder when claimed;
- System 7 classic 68K;
- early native PPC when claimed;
- OS 8/9 Appearance absent/present/compatibility mode;
- optional Navigation/Standard File fallback;
- 68K-on-PPC and real 68K separately;
- both sides of a fat application;
- install, launch, quit, relaunch, file open/save, and error recovery.

## Primary sources

- [Macintosh Toolbox Essentials](https://developer.apple.com/legacy/library/documentation/mac/pdf/MacintoshToolboxEssentials.pdf)
- [Introduction to Processes and Tasks](https://developer.apple.com/library/archive/documentation/mac/pdf/Processes/Intro_to_Procs_Tasks.pdf)
- [Segment Manager](https://developer.apple.com/library/archive/documentation/mac/pdf/Processes/Segment_Manager.pdf)
- [Introduction to Memory Management](https://developer.apple.com/library/archive/documentation/mac/pdf/Memory/Intro_to_Mem_Mgmt.pdf)
- [Mac OS Runtime Architectures](https://developer.apple.com/legacy/library/documentation/mac/pdf/MacOS_RT_Architectures.pdf)
- [PowerPC System Software](https://vintageapple.org/inside_r/pdf/PPC_System_Software_1994.pdf)
- [Power Macintosh 7100/66AV specifications](https://support.apple.com/en-ca/112084)
- [Inside Macintosh: Files, 1992](https://vintageapple.org/inside_r/pdf/Files_1992.pdf)

Also inspect the exact selected Universal Interfaces availability blocks and exact installed Retro68 source. Mirrors above host Apple-authored books; they are preserved primary content rather than secondary interpretations.
