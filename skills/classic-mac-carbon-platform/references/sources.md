# Sources and Provenance

## Primary Apple Sources

- [Mac OS Runtime Architectures for System 7 Through Mac OS 9](https://developer.apple.com/legacy/library/documentation/mac/pdf/MacOS_RT_Architectures.pdf): PowerPC CFM ABI, stack, transition vectors, and PEF.
- [Inside Macintosh: PowerPC System Software — Exception Manager](https://developer.apple.com/library/archive/documentation/mac/pdf/PPC_System_Software/Exception_Mgr.pdf): machine state, handler ownership, and asynchronous restrictions.
- [Inside Macintosh: Memory](https://developer.apple.com/library/archive/documentation/mac/pdf/Memory/Memory_Preface.pdf): application heaps, pointers, handles, and compaction.
- [Inside Macintosh: Processes](https://developer.apple.com/library/archive/documentation/mac/pdf/Processes/Intro_to_Procs_Tasks.pdf): cooperative scheduling and application partitions.
- [Mac OS multitasking concepts](https://developer.apple.com/library/archive/documentation/Carbon/Conceptual/Multitasking_MultiproServ/02concepts/concepts.html): Thread Manager versus MP tasks.
- [Using Multiprocessing Services](https://developer.apple.com/library/archive/documentation/Carbon/Conceptual/Multitasking_MultiproServ/03tasks/tasks.html): runtime and hardware gates.
- [HFS Plus Volume Format, TN1150](https://developer.apple.com/library/archive/technotes/tn/tn1150.html): HFS+ structures and release boundary.
- [Files and the Finder](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPFileSystem/Articles/FilesAndFinder.html): forks, Finder attributes, and AppleDouble reconstruction.

## Installed Declarations

Use the selected Apple Universal Interfaces `CIncludes`/`RIncludes` tree for exact CarbonLib annotations, Carbon header mode, Gestalt selectors, packing, and UPP declarations. Extract annotations mechanically where possible, but treat them only as declaration evidence.

## Retro68 Implementation Evidence

Inspect the exact local revision, especially:

- `cmake/add_application.cmake` and Carbon toolchain files;
- `MakePEF`, `MakeImport`, `Rez`, `ResInfo`, and `LaunchAPPL` sources;
- PowerPC XCOFF linker script;
- Carbon startup/runtime and automated target tests;
- `libretro/syscalls.c`, `malloc.c`, and `consolehooks.c`.

Implementation evidence describes the selected toolchain revision, not all Retro68 releases.

## Evidence Discipline

Do not promote a claim because a symbol appears in a later header, a library filename exists, or a build creates output. Record declarations, link representation, weak/strong import, runtime gate, initialization result, complete artifact, and target observation separately.
