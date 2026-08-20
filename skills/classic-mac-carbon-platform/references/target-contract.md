# Target Contract and Capability Matrix

## Baseline

- PowerPC CFM application.
- Mac OS 8.6 through 9.2.2.
- CarbonLib 1.6 available as the project runtime contract.
- Retro68 `powerpc-apple-macos` Carbon toolchain, CMake, Rez, and Apple Universal Interfaces.

The OS version and CarbonLib version are independent. Do not imply that every OS release bundled the declared CarbonLib version.

## Out of Scope

- generic C/C++ instruction;
- visual UI design, owned by `classic-mac-carbon-ui`;
- 68K applications, classic drivers, INITs, extensions, or ROM patching;
- Mac OS X Carbon, Mach-O, Cocoa, or POSIX portability layers;
- emulator administration except as a test/deployment boundary.

## Evidence Labels

- **Verified:** primary source, exact installed header/source inspection, reproducible artifact evidence, or observed target result.
- **Probe-required:** declaration or plausible implementation exists, but the declared runtime combination has not exercised it.
- **Unsupported:** the selected configuration lacks the required substrate or Apple excludes it.
- **Unresolved:** evidence conflicts or the target observation is missing.

## Capability Matrix

| Capability | Declaration/link evidence | Runtime gate | Required observation |
|---|---|---|---|
| Carbon API | Carbon-mode headers and CarbonLib import | `gestaltCarbonVersion` when version matters | launch and operation on each OS family |
| Open Transport TCP | declarations and Networking import | OT Gestalt masks/version, optional symbol resolution, initialization result | connect, disconnect, timeout, error paths |
| FSRef/Unicode File Manager | core calls annotated CarbonLib 1.0+ | `gestaltFSAttr`, actual call result | explicit 8.6 probe; HFS/HFS+, Unicode, both forks |
| FSRef Resource Manager | core calls annotated CarbonLib 1.1+ | `gestaltResourceMgrAttr`, actual call result | create/open/update/close/reopen |
| named-fork Resource Manager | calls annotated CarbonLib 1.3+ | file-system and Resource Manager attributes | named-fork cases on HFS+ |
| Text Encoding Converter | TEC calls annotated CarbonLib 1.0+ | `TECGetInfo`, converter availability | representative conversions and failures |
| Thread Manager | calls annotated CarbonLib 1.0+ | Thread Manager Gestalt bits | cooperative yield and UI/event-loop responsiveness |
| MP Services | declarations/import | `MPLibraryIsLoaded`, version/hardware and callable-API attributes | only when product opts in |
| Exception Manager | `InstallExceptionHandler` annotated CarbonLib 1.1+ | installation result, previous-handler ownership | dedicated faulting test and chaining |
| optional weak import | import member/symbol | selector or `FindSymbol`, service initialization | feature-specific fallback test |

Apple's HFS Plus technical note says pre-9.0 systems expose no HFS Plus-specific programming interfaces, while installed CarbonLib annotations expose several FSRef/Unicode calls earlier. Treat Mac OS 8.6 plus CarbonLib 1.6 as probe-required rather than resolving this from one version claim.

## Required Rows

- Mac OS 8.6 plus CarbonLib 1.6;
- Mac OS 9.0.x plus CarbonLib 1.6;
- Mac OS 9.1 plus CarbonLib 1.6;
- Mac OS 9.2.2 plus CarbonLib 1.6;
- repeatable emulator configuration;
- representative physical PowerPC Mac selected by the project.
