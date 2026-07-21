# New Old World ("NOW")

New Old World joins a classic Mac and a modern Mac around human-facing
tasks: one polished app on each side, one versioned contract over one
multiplexed wire between them. The guest is a PowerPC Carbon application
for Mac OS 9.1–9.2.2; the host is a native macOS menu-bar and window
application with a module registry. No TimBotTu runtime code is imported
on either side.

## What works today

- **The Workshop** — the guest is one window now: a sidebar rail
  (Screenshots, Files, Console, with Connection pinned at the bottom
  behind a divider and a status lamp), a header placard per page, a
  status placard below, Cmd-1..4 to switch. The five separate windows
  and the Connection dialog are gone. The shell is emulator-tested and
  deployed; the four pages inside it are **built and unit-tested but
  not yet watched on any display** — the ledger says so too.
- **Persistent connection** — the guest dials the host and holds one TCP
  connection with a guest-driven heartbeat, capped-backoff reconnect
  (adaptive or a fixed cadence from the Connection page), and orderly
  goodbyes. Control messages ride a retry queue so flow control on a
  saturated wire can never silently eat a protocol word. Connecting on
  launch is now a checkbox — off means the Connection page is the only
  dialer, and a Save never dials by surprise.
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
- **Files, both directions** — each machine shares a folder the other
  may browse, pull from and write into, and the same messages mean the
  same thing whichever side sends them. From this side: a browser with
  drag in and out, rename, move, delete-to-Trash with undo, and new
  folders. From the classic side: a native list of what this Mac shares,
  double-click to fetch into a chosen downloads folder, *Send to* for
  the other direction, and a replace prompt when a name is taken — the
  file it replaces goes to the Trash, because the person agreeing is at
  the other machine and cannot see what they are losing.

  The container rule does the right thing without being asked: plain
  files arrive plain, resource-only files arrive as MacBinary, and
  classic text arrives as UTF-8 with Unix line endings. Names cross the
  gap intact, including accents and the Apple logo. Metal-verified
  byte-for-byte in both directions, including cancel mid-flight; large
  transfers are clocked on the receiver's own count, which is what stops
  a long send collapsing (docs/large-transfers.md).
- **A log on both machines** — one file per launch, in `now-logs` beside
  the classic app and in `~/Library/Logs` here, plus `tail` from either
  console. Built because three separate evenings were spent on
  information that existed and had nowhere to live.
- **Menu-bar capture** — one command grabs the connected machine's
  screen straight to the clipboard, no window needed.

Measured on the real PB1400c: ~4.9 fps at 8-bit with predictive +
interlace over 802.11b, and file transfers byte-exact at ~227 KB/s.

Each side calls the other by the name it sent during the handshake:
"guest" and "host" are words for the protocol, not for the person using
it, and "the Mac" identifies nothing when both machines are Macs. The measurement story behind the design lives in
[docs/vram-readout.md](docs/vram-readout.md) and the TimBotTu corpus.

## What does not work

A "what works" list without its companion is a sales pitch.
[docs/open-issues.md](docs/open-issues.md) is the ledger, organised
around **broken** versus **unverified** — the second is not the lesser
category, since most of the surprises so far came from code that looked
obviously correct and had never run on the real machine. The headlines:
resume-by-offset hangs, one large transfer in about six degrades badly,
an unreachable host still presents as a hang rather than saying which
address it cannot reach, and the host's receiving half does not report
progress or verify checksums the way the classic side does.

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
