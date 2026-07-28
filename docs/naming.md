# Naming the guests

**Status: decided and executed.** The rename landed with the `src/`
domain split, in one commit.

## The names

| Thing | Directory | CMake target | Product name |
|---|---|---|---|
| PowerPC Carbon guest | `now-guest-ppc/` | `now-guest-ppc` | **`New Old World`** |
| 68K guest | `now-guest-68k/` | `now-guest-68k` | `NOW-68K` |
| Host application | `now-host/` | — | `New Old World.app` |

The qualifier is always in the same position, and it always names the
machine the guest runs on. Before this, the directories were `guest/`,
`guest68k/` and `host/`, and the CMake targets were `now-guest` and
`now68k-guest` — the qualifier landed in a different place each time, and
`guest/` read as "the real one" beside `guest68k/` when it is simply the
older of two peers.

## Why the host has no suffix

This was the open question, and the answer is that it was the wrong
question. The scheme was originally drafted as three *guests*, with a
third name wanted "for modern Macs" — but the modern Mac does not run a
guest. It runs the host. There is exactly one of those, so nothing needs
disambiguating and no suffix is load-bearing.

The three candidates all failed for the same underlying reason: they
answered an axis question that only the guests actually have.

- **`now-host-arm64`** is literal for Apple Silicon, but `Package.swift`
  declares `.macOS(.v13)` and the Xcode project pins no `ARCHS`, so it
  inherits `ARCHS_STANDARD` and builds **arm64 + x86_64** today. The name
  would have excluded half the machines it runs on.
- **`now-host-macos`** distinguishes nothing: all three targets are a Mac
  OS of some era.
- **`now-host-modern`** ages badly, and dates the moment it is written.

`68k` and `ppc` work because those machines had one architecture and one
operating-system era each. A modern Mac has neither property, and `host`
already carries the whole meaning.

## What the rename did NOT touch

**The shipped product name stays `New Old World`.** It is the name a
person sees, it is what the host application is called, and — the part
that bites — *preferences key off the binary's name*. Any other name
starts with no preferences and dials the QEMU gateway, which never
answers on real hardware and looks exactly like a hang. The canonical
name lives once, in `prefs.c :: prefs_spec`. See AGENTS.md, "Deploying
to the PowerBook".

`now-guest-*` and `now-host` are **build and repository** names. They are
not what the product is called.

The dev / side-build MacBinaries followed their targets, though:
`now-guest.bin` is now `now-guest-ppc.bin`, and `now68k-guest.bin` is
`now-guest-68k.bin`. `New Old World.bin` is unchanged.

## The src/ domain split

The same commit stopped `src/` being one flat directory in each guest.
Sources are filed by domain — `core/` for what everything shares, then
one directory per feature, which for the PowerPC guest means one per
Workshop module:

```
now-guest-ppc/src/    main.c, core/, workshop/, commands/, console/,
                      connection/, files/, processes/, screenshots/,
                      software/, census/, logs/, peek/
now-guest-68k/src/    main.c, core/, ui/, commands/, console/,
                      connection/, files/, processes/, screenshots/,
                      census/
```

**Headers are still included by bare name** — `#include "json.h"`, not
`#include "core/json.h"`. Which domain a header is filed under is a
decision about where a human looks for it; making every consumer spell
out that decision would mean re-filing one header touches every file that
includes it. Both `CMakeLists.txt` and `scripts/test-native` therefore put
every domain directory on the include path, and both *discover* those
directories rather than listing them, so adding a domain needs no edit in
either place.

Two source-reading gates had to learn to recurse.
`GuestWireConformanceTests.guestSources()` enumerated `src/` shallowly,
which after the split finds only `main.c` — enough to satisfy its own
"not empty" assertion, so that assertion is not what protects it. Checked
by mutation: reverting the walk to `contentsOfDirectory` fails three
tests, because the message inventory and the cannot-check set both look
for frames that now live in `core/`. The protection is real but indirect,
and the code says so. `now-guest-ppc/tests/ot_connect_source_test.py` read
`src/wire.c` by literal path and failed outright.
