# Testing and Recovery

## Evidence rows

Record each result as one of:

- **artifact-verified**: CPU flags, resource map, Finder metadata, forks, and image insertion inspected;
- **loader-observed**: a visible marker or debugger proves INIT entry on the declared machine and OS;
- **callback-observed**: every retained entry point has executed in its real context;
- **stability-observed**: repeated boots, shutdowns, disable cycles, and removal complete cleanly;
- **hardware-verified**: representative physical hardware reproduces the required behavior.

Do not collapse these rows into “works.”

## Minimum test matrix

Select rows that match the product claim:

| Row | What it isolates |
|---|---|
| System 6.0.8, 68000/68030-class machine, 24-bit mode where supported | oldest default loader, static system heap, old manager set |
| System 7.1 or 7.5.5 on 68K | Extensions folder, growable heap, Process Manager-era system, Shift recovery |
| Mac OS 8.1 | HFS+ transfer and installation boundary |
| Mac OS 8.6 | mature pre-9 PowerPC environment |
| Mac OS 9.2.2 | final native classic release and late extension interactions |

Add minimum-RAM, virtual-memory, alternative extension-set, and physical-machine rows where relevant.

## Recovery

Before the first boot:

- preserve an untouched image and artifact hashes;
- make the test disk disposable or cloned;
- prepare a known-good boot floppy or alternate System Folder for System 6;
- document how to remove or disable the extension without loading it;
- verify Shift-to-disable only on System 7 and later;
- keep the extension's filename and exact destination recorded.

Stop after a boot hang, address error, damaged catalog, or callback crash. Recover offline, preserve the failed artifact and disk clone, then add instrumentation. Do not iterate by repeatedly rebooting the only writable system volume.

## Observability

Use the least invasive marker that proves the current layer:

- startup icon or sound for entry only;
- low-memory or fixed-buffer trace for bounded boot stages;
- a later Notification Manager record for post-startup status;
- a retained counter or signature for callback execution;
- debugger and exact link map for crashes.

Do not perform ordinary log-file writes from interrupt callbacks. If persistent diagnostics are needed, copy fixed data into a retained buffer and flush it later from safe cooperative context.

## Release gate

A release claim requires:

1. exact artifact hash and matching link map;
2. artifact inspection;
3. loader observation on the minimum OS row;
4. observation of every installed callback path;
5. recovery-path rehearsal;
6. repeated clean boots and shutdowns;
7. representative PowerPC verification when PPC compatibility is claimed.
