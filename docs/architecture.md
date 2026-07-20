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

### Transfer rules (each learned the hard way)

- **One contiguous send per frame.** Real classic NICs drop the second
  of two back-to-back small writes (Farallon TX burst).
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
- `commands.c` — one command table serving both consoles.
- `console_win.c` / `shots_panel.c` / `settings_dialog.c` — the human
  surfaces; `prefs.c` versioned preferences.
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

## Naming seam

Display names, creator codes, bundle identifiers, and preference keys
stay confined to `guest/src/product_identity.h` and
`host/Sources/Host/ProductIdentity.swift`.
