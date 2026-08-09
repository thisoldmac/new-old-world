# Mirror agent — the PPC guest app

A **faceless PowerPC/CFM application** for Mac OS 9.1. It maps an AXPeek
sample to the live Process Manager partition, walks only those validated
regions, and serves the scene and action planes as JSON over TCP.

Faceless on purpose: the agent must observe *other* applications' UI, so
it must not be the interesting one. It owns no window and no menu bar
(`onlyBackground`, `dontGetFrontClicks` in `src/mirror.r`), and it does
not touch the cursor — the click plane owns that, and the host is
watching it.

## Why this app exists

In the lab, these verbs live inside a 309 KB `verbs.c` behind
`#ifdef TBT_MORDOR` — a *toolkit* build the Runner refuses to lease,
which is why the AX plane always had to be hand-deployed there. Here the
AX plane is the product, so it is simply present, in an app that can be
deployed and supervised like any other. That is the structural fix.

## Why PPC only

Open Transport cannot link under Retro68 for 68K (ASLM), so a 68K port
would have to speak MacTCP — a different transport with its own wedge
history. One ISA and one transport until a second machine earns the
second one. The build fails loudly rather than silently degrading if
pointed at the 68K toolchain.

Note the asymmetry with `../extension`: an `INIT` is 68K code even on a
PowerPC machine, so the extension builds 68K and this app builds PPC.

## Verb surface

| Plane | Verbs |
|---|---|
| Perceive | `observe` (process list + front app), `axtree` (window/control/menu tree), `axsnap`, `mouseloc` |
| Act | `axdo` (act on a control by ref), `activate`, `click`, `key` |
| Identity | `hello`, `ping`, `quit` |

`hello` reports the build identity **and the oracle's status code** — not
a bare boolean. "No extension installed" and "installed but stale" are
different situations, and the host must be able to say which rather than
render an empty desktop that looks like a working one.

## Build

```bash
cmake -S . -B build -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE=$HOME/Lab/Tools/Retro68-build/toolchain/powerpc-apple-macos/cmake/retroppc.toolchain.cmake
ninja -C build
```

Products: `build/mirror-agent.bin` (MacBinary, for a `put`-channel
deploy) and `build/mirror-agent.dsk` (CD-insert deploy).

## Configuration

| File | Meaning |
|---|---|
| `mirror.port` | Guest listen port; default 1420. Out-of-range values fall back to the default rather than binding something surprising. |
| `mirror.log` | Appended, flushed per line — a wedge investigation needs the line already on disk. |

Both resolve **next to the app**: `LaunchApplication` does not set the
working directory to the app's folder, so the app sets it itself at
startup. Config files are role-named, not binary-named, so renaming the
app never breaks a deploy.

## Layout

| Path | Role |
|---|---|
| `src/main.c` | Toolbox init, cooperative loop, OT lifecycle, quit-AE handling |
| `src/mirrorverbs.c` | The verb surface and dispatch |
| `src/ax*.c`, `src/axoracle.c` | Bounded foreign-memory walk, refs, menus, dialog text, PSN binding, oracle mapping |
| `src/wire.c` | JSON envelope parse and escape |
| `src/ot.c`, `src/ot_sched.c` | Asynchronous Open Transport listener |
| `src/mirror.r` | `SIZE` resource: background-capable, faceless, high-level-event aware |

`src/ax*`, `src/wire.*`, and `src/ot*` are **clean copies** taken from
the lab at extraction and expected to diverge. The lab's copies are
frozen; do not sync them (AGENTS.md).

## Two things that bite

- **The quit Apple Event is not decoration.** An installer or supervisor
  that sends `kAEQuitApplication` and gets no answer hangs, and a guest
  app that cannot be reaped has to be killed by rebooting the machine.
  `WaitNextEvent` *delivers* the event but does not process it —
  `AEProcessAppleEvent` is what routes it.
- **Never exit mid-send.** The loop breaks only when `ot_is_sending()` is
  false, or a clean `quit` looks like a crash to the host.

## Status

Builds warning-free at `-O2` (PPC, Retro68). **Not yet run** — a clean
build proves nothing. The emulator gate is `tools/spin-up.sh` against a
session-private mac99 clone; see the repo README.
