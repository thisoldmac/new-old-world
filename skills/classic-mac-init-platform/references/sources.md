# Sources and Provenance

## Primary Apple documentation

- [Inside Macintosh: Start Manager](https://developer.apple.com/library/archive/documentation/mac/pdf/Operating_System_Utilities/Start_Mgr.pdf): startup sequence, INIT resource contract, temporary execution environment, system heap, `sysz`, installation locations, and extension human-interface guidance.
- [Inside Macintosh: Gestalt Manager](https://developer.apple.com/library/archive/documentation/mac/pdf/Operating_System_Utilities/Gestalt_Manager.pdf): System 6.0.4 availability, selector registration, system-heap ownership, and capability detection.
- [Inside Macintosh: Memory](https://developer.apple.com/library/archive/documentation/mac/pdf/Memory/Intro_to_Mem_Mgmt.pdf): system heap, zones, handles, 24-bit pointer flags, 32-bit cleanliness, and virtual-memory locking.
- [Inside Macintosh: Notification Manager](https://developer.apple.com/library/archive/documentation/mac/pdf/Processes/Notification_Manager.pdf): System 6 availability, INIT notifications, record lifetime, response procedures, and context rules.
- [Inside Macintosh: Time Manager](https://developer.apple.com/library/archive/documentation/mac/pdf/Processes/Time_Manager.pdf): original, revised, and extended managers plus interrupt-time restrictions.
- [Inside Macintosh: Process Manager](https://developer.apple.com/library/archive/documentation/mac/pdf/Processes/Process_Manager.pdf): System 7 API availability and process environment.
- [Inside Macintosh: Shutdown Manager](https://developer.apple.com/library/archive/documentation/mac/pdf/Processes/Shutdown.pdf): resident shutdown procedures, one-shot behavior, and System 6 versus System 7 flags.
- [Inside Macintosh: PowerPC System Software](https://developer.apple.com/library/archive/documentation/mac/pdf/PPC_System_Software/Preface.pdf): 68LC040 emulator, Mixed Mode, Code Fragment Manager, and PowerPC execution distinctions.
- [System Error Handler](https://developer.apple.com/library/archive/documentation/mac/pdf/Operating_System_Utilities/System_Error.pdf): System 7-and-later Shift extension-disable behavior.
- [Technical Note TN1150: HFS Plus Volume Format](https://developer.apple.com/library/archive/technotes/tn/tn1150.html): HFS+ introduction in Mac OS 8.1, forks, Finder information, and classic implementation details.
- [Inside Macintosh: Processes](https://vintageapple.org/inside_r/pdf/Processes_1994.pdf): Deferred Task Manager hardware and System 6 availability details where the chapter scan is easier to search than the split archive.

## Historical loader and recovery evidence

- [Apple Technical Information Library 03911 mirror](https://savagetaylor.com/TIL/TIL03911.pdf): System 6 INIT 31 file-type and visibility behavior.
- [Apple Technical Information Library 06815 mirror](https://savagetaylor.com/TIL/TIL06815.pdf): System 7 Extensions folder behavior.
- [MacTech: Writing INITs in C](https://preserve.mactech.com/articles/mactech/Vol.05/05.10/INITinC/index.html): contemporary `sysz` and system-heap practice. Treat contemporary third-party explanation as supporting evidence, not higher authority than Apple documentation.

## Retro68 implementation evidence

Audit the installed revision directly:

- `Samples/SystemExtension/SystemExtension.c`
- `Samples/SystemExtension/SystemExtension.r`
- `Samples/SystemExtension/ShowInitIcon.c`
- `libretro/Retro68Runtime.h`
- `libretro/relocate.c`
- the generated compiler flags, object headers, flat payload, and link map

The researched revision defaulted to 68000 code, implemented a 24-bit address-strip fallback, allocated code-resource BSS in the system heap when outside an application zone, and required callers to manage code-resource locking. These are implementation observations, not permanent Retro68 contracts; re-audit the active revision.

## Evidence cautions

- Universal Interfaces declarations are compile-time evidence only.
- A successful flat link does not prove an OS trap or manager exists.
- MacBinary and disk-image inspection does not prove the loader called the INIT.
- An icon at startup proves entry, not retained callback safety.
- Emulator success does not establish physical hardware timing or extension compatibility.
