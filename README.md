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
  and the Connection dialog are gone. Metal-verified on the PB1400c:
  all four pages, including a live listing, a pull, a capture with its
  preview, streaming start/stop, and the in-canvas Console prompt.
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
- **Processes, from the host** — a Processes module here reads the
  connected Mac's running process table over the wire (`process.list` /
  `process.listing`, the first symmetric family to carry live state
  rather than files). It groups the table into Applications — the Finder
  among them — and Background, flags the front process, and captions each
  row with its kind, its two 4CCs and its partition size. It reads as the
  snapshot it is ("as of HH:MM:SS"); a process list is stale the instant
  it is taken. Metal-verified on the PB1400c — the machine's own process
  table, read and drawn on this Mac. And it drives: a selected process
  can be brought to the front, asked to quit (a request it may decline),
  or screenshotted — all from here. Screenshot App is a real window shot:
  the classic Mac fronts the process, lets it repaint, and captures just
  its front window, which lands in the Screenshots module. Each action
  names its target by the process serial number the listing carries, and
  the classic Mac re-checks that the process still exists before acting;
  it also refuses to quit NOW itself. Front and Quit are metal-verified;
  the window-cropped screenshot is tested and builds but not yet
  metal-verified. It runs one way by design: NOW is for driving old Macs
  from new ones, so the host sees and drives the guest, never the reverse.
- **A log on both machines** — one file per launch, in `now-logs` beside
  the classic app and in `~/Library/Logs` here, plus `tail` from either
  console. Built because three separate evenings were spent on
  information that existed and had nowhere to live. Both machines now have
  a **Logs page** — pinned in the sidebar footer, above Connection — that
  dumps the last ~2000 lines and follows them live, with switches to
  invert the canvas and to turn disk persistence on or off. The guest page
  is metal-verified; the host one is built and tested.
- **Menu-bar capture** — one command grabs the connected machine's
  screen straight to the clipboard, no window needed.
- **Optional agent integration** — a separate, client-launched stdio
  MCP companion can report the already-running host and guest session
  state and read a bounded point-in-time guest process snapshot through
  a private same-user socket. It can also launch one exact application
  selected from the current guest catalog; ambiguity launches nothing,
  opaque candidates are revalidated, and guest paths never cross the
  adapter. A recent opaque process reference can request cooperative
  quit only after a fresh full-identity re-list and the guest's existing
  live-PSN check. Acknowledgement does not claim the process exited. The
  fifth tool can redeem only a one-use receipt copied from NOW's native
  Files approval action: NOW privately stages one selected regular file,
  revalidates that copy, never overwrites a collision, and reports success
  only after the guest's existing `file.done` acknowledgement. The MCP
  never receives the source or guest path, and the receipt does not claim
  destination-byte verification. The companion exposes no lifecycle
  controls and changes neither app's module inventory. V0.5 adds three
  read-only projections over NOW's command layer: active guest-files
  capabilities, one bounded root-scoped listing page, and exact bounded
  stat. They accept only canonical paths relative to the host-owned
  `guestRoot`; download and mutations remain unavailable. All eight tools
  are tested here. All eight also have bounded connected acceptance receipts
  against the PowerBook 1400c: the original V0 receipt includes exact launch,
  separately observed exit after cooperative quit, and one native-approved
  69-byte artifact; the V0.5 receipt covers capability discovery, two bounded
  listing pages, and exact stat. This is not a broader transport, endurance,
  mutation, or destination-byte qualification; the exact evidence and limits
  are in
  [docs/agent-integration.md](docs/agent-integration.md).

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

Future host-product work is bounded by the
[NOW V1 host roadmap](docs/plans/2026-07-24-002-feat-now-v1-host-product-roadmap-plan.md).
It sequences a target catalog and host UI improvements after MCP V0 while
preserving the current guest-dials-host, one-port, single-session
transport. It is not a protocol migration or a multi-machine runtime.

The separately sequenced
[NOW MCP V0.5 guest-files roadmap](docs/plans/2026-07-24-003-feat-now-mcp-v0-5-files-command-roadmap-plan.md)
adds generic, root-scoped guest filesystem commands before projecting them
through MCP. It records the current streaming asymmetry as a gate: guest-bound
receives are disk-streamed, while guest sends and host receives still buffer
whole files. CodeKitten may later consume the generic commands but owns all
project meaning; V0.5 adds no project-specific or host-filesystem access.

## Layout

- `contract/asyncapi.yaml` — the wire contract (AsyncAPI 3.0 + normative
  prose): frame header, connection rules, messages, `x-commands`.
- `guest/` — Retro68 retrocarbon C. `src/wire.c` is the connection
  manager; `capture`/`pixels` the capture and wire-pixel engines; the
  human surface is the Workshop (`workshop_*`, one `*_module.c` per
  page) over `commands`/`console_model` and the file services.
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

The optional agent companion is a separate executable and has no
checked-in client configuration:

```sh
swift build --package-path host --product NOWAgentCompanion
```

The script's ad-hoc signature is fine for development, but system
notifications require a real one — `host/NewOldWorld.xcodeproj` builds the
same sources as an app target (synchronized folder group, so it never
needs file-list upkeep). Open it in Xcode, pick a signing team, and build.

Build products stay outside the repository; the bundling script enforces
it. See [docs/architecture.md](docs/architecture.md) for the design and
its rules.
