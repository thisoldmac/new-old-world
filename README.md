# New Old World ("NOW")

New Old World joins a classic Mac and a modern Mac around human-facing
tasks: one polished app on each side, one versioned contract over one
multiplexed wire between them. The guest is a PowerPC Carbon application
for Mac OS 9.1–9.2.2; the host is a native macOS menu-bar and window
application with a module registry. No TimBotTu runtime code is imported
on either side.

## What works today

- **Persistent connection** — the guest dials the host and holds one TCP
  connection with a guest-driven heartbeat, capped-backoff reconnect
  (adaptive or a fixed cadence from the Connection dialog), and orderly
  goodbyes. Control messages ride a retry queue so flow control on a
  saturated wire can never silently eat a protocol word.
- **Console** — the same command table runs locally on the guest and as a
  remote shell from the host (`gestalt`, `screenshot`, `vprobe`, unix-style
  flags, history).
- **Screenshots** — one-shot captures in either direction: host-requested
  (progress, cancel), or guest-pushed via offer/accept with a system
  notification on arrival. Contemporary file naming both sides.
- **Live streaming** — watching-first screen streaming with banded,
  pipelined capture (frame N+1 is captured while N sends), delta frames
  (dirty rects; empty frames cost ~150 bytes), and two optional capture
  policies: predictive reads (dirty rows + rotating sweep) and interlaced
  fields (2:1 decimated CopyBits). Tuning knobs ride the messages, so the
  initiating side decides.
- **Recording** — every stream is encoded live to a temp QuickTime movie
  (hardware H.264, real variable-frame-rate timestamps); stopping offers
  Save As / Discard instantly.

Measured on the real PB1400c: ~4.9 fps at 8-bit with predictive +
interlace over 802.11b. The measurement story behind the design lives in
[docs/vram-readout.md](docs/vram-readout.md) and the TimBotTu corpus.

## Layout

- `contract/asyncapi.yaml` — the wire contract (AsyncAPI 3.0 + normative
  prose): frame header, connection rules, messages, `x-commands`.
- `guest/` — Retro68 retrocarbon C. `src/wire.c` is the connection
  manager; `capture`/`pixels` the capture and wire-pixel engines;
  `commands`/`console_win`/`shots_panel` the human surfaces.
- `host/` — Swift package (`GuestListener` + modules) plus
  `NewOldWorld.xcodeproj` for signed builds.
- `docs/` — architecture and measurement notes.

## Build

Guest, with Retro68:

```sh
cmake -S guest -B /private/tmp/now-guest-ppc -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE=/path/to/Retro68/toolchain/powerpc-apple-macos/cmake/retrocarbon.toolchain.cmake
cmake --build /private/tmp/now-guest-ppc
```

The guest requires CarbonLib 1.6 on OS 9.1 (stock 1.2 exports no Open
Transport); it resolves OT at runtime and says so kindly when missing.

Host tests and app bundle:

```sh
swift test --package-path host --scratch-path /private/tmp/now-host-tests
./scripts/build-host-app /private/tmp/now-host-product
open /private/tmp/now-host-product/New\ Old\ World.app
```

The script's ad-hoc signature is fine for development, but system
notifications require a real one — `host/NewOldWorld.xcodeproj` builds the
same sources as an app target (synchronized folder group, so it never
needs file-list upkeep). Open it in Xcode, pick a signing team, and build.

Build products stay outside the repository; the bundling script enforces
it. See [docs/architecture.md](docs/architecture.md) for the design and
its rules.
