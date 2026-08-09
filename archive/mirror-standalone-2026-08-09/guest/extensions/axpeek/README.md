# TBT AXPeek — cross-app UI observation INIT

The address oracle for the accessibility API classic Mac OS never had. A
resident **68K system extension (INIT)** observes each application's active A5
world through the system `GNEFilter` hook and publishes a fixed table of
`CurrentA5`, `CurStackBase`, `WindowList`, and `MenuList` samples via
`Gestalt('TBax')`.
The toolkit worker maps a sample to the live public Process
Manager partition, validates SysZone for system-allocated Finder records, then
`axtree` walks only those two explicit regions.

Full design, safety posture, and the empirical unknowns: [docs/41](../docs/41-accessibility-layer.md).

## Why an INIT (the A5-world barrier)

The Window/Control/Menu Managers keep **per-process** roots in low memory. From
its own process the worker sees only its own root, even though all application
memory is readable. AXPeek runs briefly when another application's low-memory
world is current and copies only those roots to shared system memory. It never
dereferences the foreign tree and never actuates UI.

## Status — q800, mac99, and Q950 producer proven (2026-07-10)

On a disposable q800/System 8.1 clone, the extension booted cleanly and the
shared table contained distinct Finder and worker samples. The initial
unthrottled hook proved coverage but committed roughly one million updates
during boot. The current assembly fast path records an A5 switch or changed
`WindowList` root immediately, and refreshes an otherwise stable process at
10 Hz (718 commits over roughly 4,000 ticks in the original throttled validation
run). The root comparison is O(1); the existing bounded table update only runs
when one of those conditions makes a sample due.

The root-change path was revalidated on a disposable q800/System 8.1 clone on
2026-07-10. After synchronizing on a fresh SimpleText sample, opening its
standard dialog published the changed root four ticks later, before the
six-tick fallback was due; `axtree` returned both windows with
`bytesScanned=0`.

The foreign Window/Control path passes on q800/System 8.1, mac99/System 9.1,
and the real 33 MHz 68040 Q950 with `bytesScanned=0`. Full-fleet state also
passes on q800 and Q950 through exact-PSN lifetime binding. Version 4 adds the
MenuList root; q800 returns Finder's live menus and a standard SimpleText
dialog's TextEdit contents without scanning. The Q950 and mac99 live v4 gates
remain.

**PB1400c: live as of 2026-07-10.** The earlier deferral was scheduling
(the human was working on the machine), not a blocker — lifted with human
authorization and the mandatory emu-gate-first (mac99 clone: `axpeek-context`,
`bytesScanned=0`, sample age &lt;120 ticks) before the metal install + reboot.
AXPeek now reads the live TBTChat Window/Control/Menu tree on the real
PowerBook 1400c via `axpeek-context`, `bytesScanned=0` — its first metal run
there (previously `ax_oracle_not_found`). Install = `AXPeek.bin` into
`System Folder:Extensions` via the worker `put` channel, then a clean Finder
restart (INITs load only at boot). See finding `axpeek-pb1400c-live`.

## Build

68K Retro68 toolchain (the INIT is 68K even for PPC machines):

```
cmake -B build -G Ninja -DCMAKE_TOOLCHAIN_FILE=\
  ~/Lab/Tools/Retro68-build-68k/toolchain/m68k-apple-macos/cmake/retro68.toolchain.cmake
cmake --build build
```

Products: `build/AXPeek.bin` (MacBinary, harness `put` channel) and
`build/AXPeek.dsk` (CD-insert deploy).

## Install & test (emu, session clone)

1. Boot a **session clone** of the base image (never the shared base).
2. Copy `AXPeek.bin` into the System Folder's **Extensions** folder and reboot.
3. Run a toolkit worker with `axtree` in scope. A foreign front application
   should report `locator.strategy="axpeek-context"`, `bytesScanned=0`, a
   sample age under 120 ticks, and its Window/Control tree.

## Layout

| Path | Role |
|---|---|
| `src/axpeek.c` | INIT install, Gestalt publisher, bounded sample commit |
| `src/axgne.S` | special-ABI `GNEFilter` hot path and safe tail-chain |
| `src/axoracle.c` | fixed-table upsert, range/freshness/name validation |
| `src/axshared.h` | versioned v4 `AXShared` pointer-table contract |
| `src/AXPeek.r` | `'INIT'` resource (sysHeap+locked so the relocated blob stays put) |
| `CMakeLists.txt` | 68K build → `AXPeek.bin` / `AXPeek.dsk` |
