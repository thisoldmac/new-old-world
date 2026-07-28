# Architecture

## Product boundary

Two applications and exactly one connection between them: a single
versioned contract over one multiplexed wire. No TimBotTu runtime
imports, no general remote-control surface. One app on each side,
polished and human-facing.

The envelope is **PowerPC only** (decided 2026-07-19): the guest is a
Carbon app using the 8.6+ toolbox (CarbonLib 1.6+, Open Transport via
runtime CFM resolution, Appearance). A 68K sibling may exist someday; it
must not constrain this codebase.

## Wire

[contract/asyncapi.yaml](../contract/asyncapi.yaml) is the contract:
an 8-byte binary frame header (channel / flags / transfer / length)
multiplexing a JSON control channel and a raw bulk channel over one TCP
connection, written as AsyncAPI 3.0 with normative prose for the frame
layout and connection rules. WS-shaped semantics without literal
WebSocket: hello gate with revision refusal, guest-driven ping/pong,
`bye` with close codes, one guest at a time.

The **guest dials the host** — classic Mac OS listeners are the fragile
half of OS 9 networking, so every listener stays on the modern side.

### Two planes on the control channel

`command.*` is the typed spine: a caller that knows the command, a declared
output schema per verb, a closed registry. `exec.*` is the console plane: one
opaque line in, the guest's own console text out, nothing declared about what
a line may say. Neither replaces the other and the split is the point — see
[remote-console.md](remote-console.md).

Exec rides the **control** channel and never the bulk lane. The lane is one
transfer wide across both directions, so a console session holding it would
block capture and file transfer for its lifetime; and control frames
queue-and-retry, which is what console text needs, because unlike pixels it
cannot be re-derived.

### Transfer rules (each learned the hard way)

- **One contiguous send per frame.** Real classic NICs drop the second
  of two back-to-back small writes (Farallon TX burst).
- **Meter bulk writes; the gap is the point.** The same card drops
  frames *inbound* too, including ones that land on the heels of its own
  ACK. Handing TCP a whole 32 KB frame keeps the socket buffer non-empty,
  so TCP fires the next segment 0.13 ms after every ACK and it dies: 48%
  of segments retransmitted, each costing a 311 ms RTO, pinning inbound
  at 4 KB/s while outbound ran at 227. The host now writes 1448 B every
  3 ms (`GuestListener.Pacing`) — 256 KB went 63.9 s → 0.8 s. Note it is
  the **quiet time**, not the write size: 1448 B with no gap still runs
  at 5 KB/s. Protocol framing is untouched at 32 KB, because the guest
  reassembles a byte stream and must never be able to tell.
- **Control messages queue and retry.** A streaming guest runs the send
  buffer at the brim; a single unretried `OTSnd` of `capture.end` or a
  heartbeat ping dies there of `kOTFlowErr` and wedges every layer at
  once. Control frames drain from the event loop, never interleaving
  into a partially-sent bulk frame; bulk stays best-effort — pixels are
  re-capturable, protocol words are not.
- **Abandon transfers, never frames.** An abort drains the in-flight
  bulk frame to its boundary before `capture.end ok:false`; cutting a
  frame mid-send desyncs the peer's decoder.
- **One transfer at a time.** Requests and offers are refused busy, not
  preempted. The stream bracket owns the lane while open.
- **Stops are always answered.** `stream.stop` gets `stream.stopped`
  even for a stream the guest no longer has; the host also self-heals
  (session close clears the bracket, stop times out after 5 s).
- **Tuning rides the messages.** `capture.request` and `stream.start`
  carry optional knobs (chunk, pacing, compress, predictive, interlace);
  absent fields fall back to the guest's panel. The initiator decides;
  there is no remote configuration to sync.
- **Only the receiver knows what arrived.** A sender's own completion
  says its socket accepted the bytes, which on this link runs minutes
  ahead of delivery: the put bar reached 100% with a third of a 2.7 MB
  file written, and the same false signal fed the inactivity watchdog,
  so a stalled guest read as healthy. Progress therefore travels back
  from the receiver (`file.progress`), and a watchdog is fed by nothing
  else. Advisory by design — dropped rather than queued when the control
  queue is busy, so its absence means an old peer, not a stalled one.

## The console is a dumb shell

The host console does not know what commands the guest has, and must not.
There are **two guests**: the PowerPC Carbon guest serves fifteen
commands, NOW-68K serves three. A command list on the host would be
wrong for one of them and wrong again the next time either grows a verb —
and wrong quietly, because a command the guest had and the console did
not was refused locally, without ever reaching the wire.

So the line a human types is relayed as typed. `command.request` carries
either shape:

- **`args`** — typed, for a caller that knows the command: a host module,
  an agent, a test.
- **`line`** — the raw text after the command name, for a console.
  Presence is the signal and `""` is present, so `gestalt` typed by a
  person (snapshot) is a different request from `gestalt` called by a
  module (every group). Each command's grammar is stated once in the
  contract as `x-line` and implemented once, by the machine that serves
  the verb — `guest/src/cmd_line.c` for the Carbon guest.

`command.request` has only ever run host to guest: the guest's console
runs its own commands in-process, and the host serves none. So `line`
adds no asymmetry — the other direction does not exist. If it ever does,
the field means the same thing there.

**Where the line runs.** Host-side there are four verbs, all behind a `/`
prefix so a bare word is always the far machine's and a command added to
either guest can never be shadowed. Three act on this console: `/clear`,
`/save` (write the scrollback to a file — the command-agnostic
replacement for `gestalt --save`, which only worked because the host knew
what gestalt returned) and `/help`. The fourth, `/swpage`, drives the
`software.list` family, which is a wire family the host implements rather
than a command any guest serves. That is the whole test for belonging
here: **no guest could answer it.** Everything else, including a typo,
crosses the wire and comes back answered — `unknown-command` is the
guest's word, not a local guess at it.

**Discovery is a request.** `help` is an x-command: a bare one lists what
that machine serves, a topic returns one command's usage. Both guests
answer it from their own table (`guest/src/cmd_help.c`,
`guest68k/src/commands68.c`), which is also the table their own consoles
read, so help cannot drift from the commands. The host console's Tab
completion is that answer, fetched on the first Tab and dropped when the
wire drops; a guest too old to serve `help` has no completion, which is
the honest outcome rather than a fallback list. History is host-local —
recalling a line needs no notion of what the line means.

## Menus on the host

Two surfaces, one rule for which is which.

The **status item** is what exists when there is no window: the
connection glyph and status line, Open, Screenshot Guest, Quit. The
**main menu** (`MainMenu.swift`) is everything, and duplicates exactly
those three verbs — a status item that mirrored the whole menu would be
two surfaces to keep honest. Its View menu is the module registry,
derived rather than retyped; the verbs that act on the other machine sit
in a Guest menu, because none of them touches anything on this side.

The app shipped without a main menu for a while, which is worth stating
plainly because the symptom was elsewhere: **`NSApp.mainMenu` dispatches
key equivalents**, so there was no ⌘Q, no ⌘W and no ⌘C/⌘V in the console,
while a Quit item plainly existed in the status item — where its ⌘Q only
fires with that menu open.

⌘Q tells the guest first. `bye` is a write and a write needs a turn of
the run loop, so `applicationShouldTerminate` returns `terminateLater`
and `GuestListener.shutDown` reports once the socket has taken the
farewell — bounded at half a second, because a guest wedged badly enough
to need telling is exactly the one that will not read.

## Logging

Each side keeps a log: one file per launch in a `now-logs` folder, plus
the last lines in memory. `tail` reads either machine's from either
console. What belongs in one, what must never be logged (anything in a
per-chunk path), and how to read the two together is
[docs/logging.md](logging.md).

## Capture and streaming

Full-screen capture cost is VRAM read bandwidth — transaction-bound at
~434 ns per bus beat on the PB1400c, floor ~90 ms, CopyBits within ~15%
of it (see [vram-readout.md](vram-readout.md) and the TimBotTu corpus).
Every streaming design decision follows from measurements:

- **Banded, pipelined capture** — banding is free (~0.2 ms per extra
  CopyBits), so frame N+1 is captured a band at a time from the event
  loop while frame N sends; capture is scheduled to complete as the send
  completes. Frame period approaches max(capture+encode, wire).
- **Delta frames** — after each capture the guest diffs against the
  previous frame (memory-bound, pixel-granular for free) and sends
  `key` / `delta` (≤16 dirty rects, byte-granular column spans) /
  `empty` (~150 bytes) frames. Deltas reference the previous frame
  implicitly; TCP ordering makes that safe. `stream.refresh` forces a
  keyframe.
- **Predictive capture** (toggle) — read only last frame's dirty rows
  plus a margin, plus a rotating sweep slice; partial VRAM reads are
  exactly linear, so capture cost scales with screen activity.
- **Interlacing** (toggle) — one decimated CopyBits into a half-height
  GWorld captures a field per frame (2:1 point sampling); each field
  diffs against its own parity, wire rects carry `rowStep`. Composes
  with predictive.
- **Keyframes are the correctness anchor**: always whole, always full
  scale, outside both policies. A key replaces the host's canvas and
  carries no row mapping, so a decimated or partial capture can never be
  exported as one — and the need for a key can arise *after* a capture
  is in hand (palette change, failed diff), when what is in hand may be
  a field. That frame is dropped and the next capture reads everything.
  The guest enforces this before export; the host rejects a half-height
  key rather than resizing its canvas to match.
- **Frames are paced even when they are free.** An empty frame skips the
  bulk lane, so the wire does not pace it. The guest keeps a floor of
  its own (~15 fps, backing off to ~4 while nothing changes) that
  `minIntervalMs` raises; without it a static screen under predictive
  capture floods the control plane.
- **Recording is host-side**: every stream encodes live to a temp
  QuickTime movie with real VFR timestamps; stop offers the file.

## Nested loops and wire liveness

The connection is serviced from one place — `conn_service()`, called
each pass of `main.c`'s event loop. Every Toolbox call that runs its
**own** event loop suspends that one, and with it the entire wire: no
pings answered, no requests served, no transfers pumped. A modal dialog
froze the guest's wire exactly this way (see
[nested-loops.md](nested-loops.md)).

Two rules, both enforced by review:

1. **Any nested loop must pump.** `pump.h` provides the shared idle
   hooks — a modal filter, a Nav Services event proc, a `TrackControl`
   action proc — each calling `now_wire_pump()`. A bare
   `ModalDialog(NULL, …)` is a defect. `MenuSelect`, `DragWindow`,
   `GrowWindow`, `TrackGoAway` and `TrackBox` accept no callback and
   cannot be pumped; they stall the wire for the duration of a
   mouse-down, which is why a held-open menu visibly pauses a stream.
2. **Pumped code must never open a dialog.** A modal opened from a
   network callback nests inside the modal already running, and the
   guest becomes unrecoverable. Wire code sets status strings; keep it
   that way.

The guest can only promise liveness it controls. Classic Mac OS is
cooperatively multitasked, so a *foreground* application that busy-waits
instead of yielding starves every background process, this one included.
That is why the host carries its own deadline on every request rather
than trusting the guest to answer.

## Guest ownership

- `wire.c` — connection state machine, control TX queue, transfer
  (`g_xfer`), offer, stream bracket and frame pump. Serviced
  non-blocking from the event loop; nothing here ever waits.
- `capture.c` — span/decimation GWorld capture, pumped in bounded steps.
- `pixels.c` — wire pixel export (palette + per-row PackBits), diff.
- `json.c` — the one tolerant JSON scanner (natively unit-tested).
- `commands.c` — one command table serving both consoles, over
  `cmd_line.c` (the console-line grammar, natively tested) and
  `cmd_help.c` (the command doc table, which `help` answers from and the
  guest's own console renders); `console_model.c` the guest console's
  scrollback and history.
- `workshop_window.c` / `workshop_sidebar.c` / `workshop_layout.c` — the
  one window, its rail, and the pure geometry both read.
- `screenshots_module.c` / `files_module.c` (+ `files_browser_view.c`,
  `files_share_view.c`) / `console_module.c` / `connection_module.c` —
  the pages, one per sidebar row, behind `WorkshopModuleOps`. Adding one
  is [docs/adding-a-workshop-module.md](adding-a-workshop-module.md).
- `prefs.c` — versioned preferences (accretive record, v9).
- `main.c` — Toolbox event loop; drops its WaitNextEvent sleep to 0
  while any pump is live.

## Host ownership

- `GuestListener` + `Session` — listener lifecycle, hello gate, capture
  routing (solicited / pushed / stream by id), stream canvas
  compositing, idle timeout.
- `CaptureDecoder` — wire pixels to CGImage; delta rect patching.
- `StreamRecorder` — live VFR H.264 encoding.
- `ScreenshotModuleModel` / `ConsoleModel` / `SettingsModel` — module
  state; `ModuleRegistry` the composition root; `HostAppState` wiring.
- `MainMenu` — the menu bar, as a pure function over the registry;
  `App.swift` installs it, owns the status item, and holds the quit
  sequence. `ConsoleInputField` is AppKit because ↑/↓ and Tab are out of
  SwiftUI's reach on macOS 13.

## Naming seam

Display names, creator codes, bundle identifiers, and preference keys
stay confined to `guest/src/product_identity.h` and
`host/Sources/Host/ProductIdentity.swift`.
