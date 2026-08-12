<!-- now-doc-provenance: generated reviewed=false -->

# Census trap-dispatch spike

**One question:** can NOW's Carbon guest reach the two 68K-trap-only
managers the `ata` and `pccard` probes need — the ATA Manager at `$AAF1`
and the PC Card Manager at `$AAF0` — from PowerPC, **without wedging the
machine**?

It matters because the internal boot disk is IDE (the SCSI scan cannot
see it) and the PowerBook's PC Card cage is real hardware to census —
and because reaching these traps the wrong way is exactly what froze the
1400c four times in the parent project.

## Why this is dangerous, and the fix

The corpus finding `cis-metal-safe-mixed-mode-fix` is the whole story:
the `cis` recon verb's machine-freezes were **never** a Card Services
fault. `CallUniversalProc` handed a raw code pointer runs the 68K bytes
as **native PPC** — the CPU executes trap-thunk bytes as instructions and
wedges the whole machine (physical reboot, the wire dies first). The two
fixes that brought it live:

1. a real **M68K RoutineDescriptor** (`kM68kISA`), so `CallUniversalProc`
   performs the PPC→68K switch and the thunk runs **under emulation**
   instead of as PPC;
2. an **RTS thunk** that keeps its return address on the stack, because
   the trap handler preserves no scratch register (an earlier thunk held
   the return address in A1 across `$AAF0` and the handler trashed it).

This spike reimplements that recipe in NOW's own code — the thunk bytes
are the recovered hardware trap ABI, not borrowed logic — and, crucially,
**follows the corpus's own method**: a trap-free `selftest` thunk that
just returns `0x4242` is dispatched through the identical M68K descriptor
path *before any trap is touched*. If the descriptor is wrong the selftest
fails as a survivable **app death** (the bytes run under emulation, never
as PPC), and no trap is ever reached. Only if `0x4242` comes back does it
try the two read-only trap calls.

## Carbon vs the Mixed Mode API

Carbon hides `CallUniversalProc` (`CALL_NOT_IN_CARBON` — there is no 68K
on Mac OS X), but on OS 9 the symbol is in InterfaceLib and the Mixed
Mode Manager is running. So it is resolved by name with
`GetSharedLibrary`/`FindSymbol`, exactly as the ADB and SCSI probes
resolve their managers. The `RoutineDescriptor` struct, `_MixedModeMagic`,
`kM68kISA` and `MakeDataExecutable` all compile and link under Carbon
directly.

## What it does, and does not, do

- `selftest` — dispatch a trap-free thunk (returns `0x4242`). Proves the
  descriptor and PPC→68K switch.
- `ata` — `$AAF1` IDENTIFY DEVICE on bus 0 / device 0. Non-destructive
  read; reports the model string if a drive answers.
- `pccard` — `$AAF0` `CSGetCardServicesInfo` (selector 7): Card Services
  signature, socket count, version, vendor. **Read-only** — it configures
  no card and powers no socket. (`RequestConfiguration` and anything that
  touches socket power is a known Farallon/wire hazard and is NOT here.)

Every risky step is written to **`Census Trap Steps`** on the desktop
*before* it runs, so a whole-machine wedge names the last thing attempted.
The full report lands in **`Census Trap Spike`**.

## Deploy

Attended, on the PB1400c, under its own name (`now-trap-spike`). Read the
step crumbs and the report. The expected shape:

- selftest `0x4242` → the mechanism is sound; proceed to read the two
  trap results.
- selftest garbage/app-death → the descriptor is wrong, and **no trap was
  touched** — safe to iterate.

## The verdict

_(pending first run on the PB1400c)_
