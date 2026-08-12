<!-- now-doc-provenance: generated reviewed=false -->

# Architecture

> **A note on "TimBotTu" and "the corpus."** NOW grew out of a larger
> private project, TimBotTu, which maintains a corpus of validated
> findings about classic Mac hardware and platform behaviour — measured
> claims with their evidence, not lore. Documents here cite it where a
> number came from there. The corpus is not public and is not required to
> build, run or understand NOW; **no TimBotTu runtime code is imported on
> any side**, which is a boundary this project holds deliberately rather
> than an accident of packaging. Read a citation as provenance for a
> figure, and nothing more.

## Product boundary

Two applications and exactly one connection between them: a single
versioned contract over one multiplexed wire. No TimBotTu runtime
imports, no general remote-control surface. One app on each side,
polished and human-facing.

The **PowerPC guest** is the reference implementation (decided
2026-07-19): a Carbon app using the 8.6+ toolbox (CarbonLib 1.6+, Open
Transport via runtime CFM resolution, Appearance). The 68K sibling that
decision said "may exist someday" now does — NOW-68K, Retro68 68K,
non-Carbon Toolbox C, metal-proven on a PowerBook 180c — and the
constraint it was granted still holds: it serves a subset of the same
contract additively, and it does not shape the PowerPC codebase. Who
serves what is [contract-coverage.md](contract-coverage.md).

## Wire

[contract/asyncapi.yaml](../contract/asyncapi.yaml) is the contract:
an 8-byte binary frame header (channel / flags / transfer / length)
multiplexing a JSON control channel and a raw bulk channel over one TCP
connection, written as AsyncAPI 3.0 with normative prose for the frame
layout and connection rules. WS-shaped semantics without literal
WebSocket: hello gate with revision refusal, guest-driven ping/pong,
`bye` with close codes, one connection per guest.

Several guests share one port. Each connection is one guest, told apart
by the identity in its `hello`; the host serves all of them but DRIVES
one — the "active" guest that every request-shaped call goes to, chosen
in the sidebar's pop-up or under Guest ▸ Drive. Each module model keeps
what it holds per machine or throws it away on a switch, deliberately
and for stated reasons (`now-host/Sources/Host/GuestScopedState.swift`).

The **guest dials the host** — classic Mac OS listeners are the fragile
half of OS 9 networking, so every listener stays on the modern side.

### The machine's own answer, in `hello`

`hello` carries an optional `agent` field: `disabled` / `read-only` /
`full`, an **ordered** enum so a higher tier can be added without
re-shaping the wire. It is the Macintosh's own statement about what an
agent companion may do to it, and it is the only place that statement
appears — the host does not offer a switch, because the machine being
driven is the one entitled to answer.

Three rules the contract states and the host obeys:

- **Absence is a fact about the sender, not an answer.** A guest that
  predates the field has said nothing, and silence must never be read as
  consent. It currently fails **open**, which is a dated decision
  (2026-07-30) matching today's default-on behaviour rather than a
  property of the design; it is the line that flips when an installer
  ships.
- **An unrecognised token is not consent either.** A receiver that cannot
  name a tier cannot claim to be under it, so everything is refused.
- **Nothing else in `hello` changed.** The field is additive, and the 68K
  guest sends none — see [contract-coverage.md](contract-coverage.md).

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
There are **two guests** and they serve different verb sets, neither of
them closed ([contract-coverage.md](contract-coverage.md) has the roster,
derived). A command list on the host would be
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
  the verb — `now-guest-ppc/src/commands/cmd_line.c` for the Carbon guest.

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
answer it from their own table (`now-guest-ppc/src/commands/cmd_help.c`,
`now-guest-68k/src/commands/commands68.c`), which is also the table their own consoles
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

## Faces, and the one door they share

A **face** is something that can ask this host to act on the guest: the
app's own UI, and its MCP surface. A **projection** is one capability
rendered for every face at once — its schema, its bounds, its
availability rule and its answer, written once.
`HostProjectionCatalog` is the registry, in presentation order;
`HostProjectionRegistry` refuses a duplicate capability name.

What each row reaches, what it requires, and every guest capability no
row exposes yet — with a reason or an admission of not having noticed —
is [mcp-coverage.md](mcp-coverage.md), which is derived from the registry
in-process and gated by `MCPCoverageTests`. The boundary and trust model
are [agent-integration.md](agent-integration.md). Neither is restated
here, and neither is the row count: **the tables are derived and the
prose is not**, which is a lesson this repository has now learned twice.

Three rules hold the layer together.

1. **The companion is a client, not a face of its own.** It cannot ask
   for anything the app could not; adding a tool means adding a row, and
   a row arrives on every face together.
2. **Only `HostProjectionDispatch` invokes a projection**, so every
   invocation emits an audit event and nothing can act on the guest
   quietly. This is the rule most worth knowing about because it is the
   one a text-scanning gate cannot fully prove — the gate forgives any
   line containing `dispatch.invoke(`, and the real fix is narrowing
   `invoke`'s visibility ([source-text-gates.md](source-text-gates.md)).
3. **Consent is checked before the row runs, not inside it.** One check
   covers every registered row without per-row opt-in.

### The consent ceiling

`HostCapabilityTier` is `read-only < full`, ordered rather than boolean.
`disabled` is deliberately not a tier — it is the absence of one. The
guest's `hello` answer becomes a **ceiling**, and a row is permitted when
its required tier is at or below it.

A row's required tier is **derived from what it already publishes**:
`readOnlyHint` in its own rendered MCP descriptor. There is no separate
tier field to keep in step, because a second declaration of the same fact
is the thing that goes stale. `destructiveHint` is not a second boundary;
it is only a coherence check — a row claiming both read-only and
destructive fails the suite. A row declaring neither falls to `full`,
which is fail-restrictive.

**A denial is not an unavailability, and a caller must be able to tell.**
Consent refusal is a JSON-RPC **error**, code `-32010` — in the
implementation-defined range, deliberately not `-32602`, because the
caller asked correctly. Its data names the ground (`machine-declines`,
`above-granted-tier`, `unrecognized-tier`), the capability, the tier it
needed and the machine's verbatim answer. A capability the guest simply
does not serve comes back the other way: a **successful** result carrying
the row's own `unavailable` arm. So a caller branches on transport shape,
not on prose.

### Companions, not sockets

The local surface is one request per connection and the companion is
short-lived and client-launched, so an `isConnected` boolean would be
true for milliseconds and false whenever anyone looked. The host models
**companions** instead (`AgentCompanionActivity`), identified by the pid
the kernel attests on the accepted socket rather than by anything the
peer claims. Four states, derived from the clock at read time rather than
stored: **never-attached**, **working** (a call is in flight — it
outranks recency), **active** (seen inside a two-minute window) and
**idle**. The ledger keeps counts and clock times and deliberately no
operation names, arguments or payloads, so it cannot become the back door
that reintroduces what an audit event leaves out.

## Logging

Each side keeps a log: one file per launch in a `now-logs` folder, plus
the last lines in memory. Classic guests keep 10 recognized launch logs by
default under one configurable 1–100 policy. `tail` reads either machine's from either
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
- `agent_access.c` — the one seam that answers `hello`'s `agent` field.
  A function rather than a constant so a future switch or installer has a
  single landing place; today it returns `full` unconditionally.
- `main.c` — Toolbox event loop; drops its WaitNextEvent sleep to 0
  while any pump is live.

## Host ownership

- `GuestListener` + `Session` — listener lifecycle, hello gate, capture
  routing (solicited / pushed / stream by id), stream canvas
  compositing, idle timeout.
- `CaptureDecoder` — wire pixels to CGImage; delta rect patching.
- `StreamRecorder` — live VFR H.264 encoding.
- `ScreenshotModuleModel` / `ConsoleModel` / `SettingsModel` /
  `DiagnosticsModel` / `AgentActivityModel` and the rest — module state;
  `ModuleRegistry` the composition root; `HostAppState` wiring. A module
  declares a `ModulePlacement`, so the sidebar's pinned footer is derived
  from the one ordered array rather than stored twice, and the View menu
  numbers that array rather than being retyped.
  - `DiagnosticsModel` runs the three guest probes that measure the
    machine itself (`vprobe`, `shotdiag`, `putstat`) and decides which
    cards can run **from that machine's own `help` table**, never from
    which Mac it is. A refusal is shown in the guest's words; an
    unknown-command refusal reads as absence rather than as an error.
  - `AgentActivityModel` + `AgentCompanionModel` are the Agent page:
    companion presence, the machine's consent answer, and a bounded
    in-memory audit stream. It is a glance, not the record — the log is
    the record — and it holds no arguments, paths or payloads.
- `HostProjectionCatalog` / `HostProjectionRegistry` /
  `HostProjectionDispatch` — the projection layer above; `NOWMCPServer`
  renders the registry for the companion face.
- `MainMenu` — the menu bar, as a pure function over the registry;
  `App.swift` installs it, owns the status item, and holds the quit
  sequence. `ConsoleInputField` is AppKit because ↑/↓ and Tab are out of
  SwiftUI's reach on macOS 13.

### Projects are a second authority domain

The host owns one bounded Projects root in Application Support, including its
Git object store, persistent workspaces and candidate receipts. A guest-home
project does not move into that domain when imported: the host copy is a
history mirror and scratch workspace until a digest-guarded promotion settles
on the classic Mac. Toolchains and active guest projects remain guest-owned;
their private import and candidate transfer scopes never join generic Files.

The Development service is headless and page-neutral. The host module, Chat
and MCP use one typed adapter; the PPC Workshop page and wire commands use one
guest runtime. CodeKitten consumes the shared project format and is only an
optional human handoff. The complete ownership and lifecycle description is
[development.md](development.md).

## Naming seam

Display names, creator codes, bundle identifiers, and preference keys
stay confined to `now-guest-ppc/src/core/product_identity.h` and
`now-host/Sources/Host/ProductIdentity.swift`.
