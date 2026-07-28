# Naming the guests

**Status: agreed in direction, not yet executed. One question open.**

Nothing in the tree has been renamed. This records the intended scheme so
that new work adopts it and a rename, when it happens, is mechanical
rather than a fresh argument.

## Where the names are today

| Thing | Called | Where |
|---|---|---|
| PowerPC Carbon guest | `guest/`, CMake target `now-guest` | `guest/CMakeLists.txt` |
| 68K guest | `guest68k/`, CMake target `now68k-guest`, product "NOW-68K" | `guest68k/CMakeLists.txt` |
| The shipped PowerPC binary | **`New Old World`** | `guest/src/product_identity.h` |
| Host application | `New Old World.app` | `host/` |

Two problems. `guest/` is unqualified — it was the only guest once, and
now reads as "the real one" beside `guest68k/`. And `now-guest` versus
`now68k-guest` puts the qualifier in a different place each time.

## The scheme

Name each guest for the machine it runs on, with the qualifier always in
the same position:

- `now-guest-68k`
- `now-guest-ppc`
- a third, for modern Macs — **name undecided, see below**

## The open question

The third name is not settled, because the axis stops being obvious
there.

`68k` and `ppc` are unambiguous: those machines had one architecture and
one operating-system era each. A modern Mac does not. Apple ships one
universal binary for two architectures, so:

- **`now-guest-arm64`** is literal and correct for Apple Silicon, but an
  Intel Mac would need `now-guest-x86_64` — two names for one product,
  or one name that quietly excludes half the machines it runs on.
- **`now-guest-macos`** treats the axis as *era of Mac* rather than CPU,
  which is arguably what actually distinguishes these three targets: a
  System 7 machine, a Mac OS 9 machine, and a modern one. One universal
  binary, one name.
- **`now-guest-modern`** is CPU-agnostic and survives Apple changing
  architecture again, but ages badly.

This wants deciding before anything is renamed, because the answer
determines whether the qualifier means "CPU" or "era" — and the first two
names are read differently depending on which.

## What a rename touches

Recorded now so the size of the job is known rather than discovered:

- Directory names `guest/` and `guest68k/`, and every path in
  `scripts/test-native`'s manifest, `scripts/build-guests`,
  `scripts/test-all`, `scripts/deploy-68k`, `scripts/q800-68k`.
- CMake target names in both `CMakeLists.txt`, plus the canonical
  MacBinary stamping rules that name `now-guest.bin`.
- `host/Tests/HostTests/GuestWireConformanceTests.swift`, which reads
  `guest/src/*.c` by path.
- CI paths in `.github/workflows/ci.yml`.
- Cross-references in `AGENTS.md`, `README.md`, `docs/*`, and the
  `#include "../../guest/tests/..."` in
  `guest68k/tests/proc_quit_parity_test.c`.

## What a rename must NOT touch

**The shipped product name stays `New Old World`.** It is the name a
person sees, it is what the host application is called, and — the part
that bites — *preferences key off the binary's name*. Any other name
starts with no preferences and dials the QEMU gateway, which never
answers on real hardware and looks exactly like a hang. The canonical
name lives once, in `prefs.c :: prefs_spec`. See AGENTS.md, "Deploying
to the PowerBook".

`now-guest-*` are **build and repository** names. They are not what the
product is called.
