# New Old World ("NOW")

New Old World joins a classic Mac and a modern Mac around human-facing
tasks: one polished app on each side, one versioned contract over one
multiplexed wire between them. The guest is a PowerPC Carbon application
for Mac OS 9.1–9.2.2; the host is a native macOS menu-bar and window
application with a module registry. A second, much smaller guest —
**NOW-68K** — speaks the same contract from a 68K Macintosh under System
7.1 over MacTCP, for machines the Carbon guest cannot reach. No TimBotTu
runtime code is imported on any side.

## What works today

- **The Workshop** — the guest is one window now: a sidebar rail
  (Screenshots, Files, Console, with Connection pinned at the bottom
  behind a divider and a status lamp), a header placard per page, a
  status placard below, Cmd-1..4 to switch. The five separate windows
  and the Connection dialog are gone. Metal-verified on the PB1400c:
  all four pages, including a live listing, a pull, a capture with its
  preview, streaming start/stop, and the in-canvas Console prompt.
- **Persistent connection** — the guest dials the host and holds one TCP
  connection with a guest-driven heartbeat, reconnect on a cadence the
  guest picks (capped backoff, or a fixed interval from the Connection
  page — the contract asks only for a 1s floor), and orderly
  goodbyes. Control messages ride a retry queue so flow control on a
  saturated wire can never silently eat a protocol word. Connecting on
  launch is now a checkbox — off means the Connection page is the only
  dialer, and a Save never dials by surprise.
- **Console** — one command table on the guest, reachable from its own
  window and as a shell from this side. The host console is a **dumb
  shell**: it relays the line as typed and knows no command's grammar,
  because the two guests do not serve the same commands — so `help` is a
  wire request (a machine that serves four commands says four), Tab
  completes from that answer, and an unknown command comes back refused
  by the machine that would have run it. Host-side there are four verbs,
  all behind a `/`: `/clear`, `/save`, `/help`, and `/swpage` (which
  drives a wire family, not a command). The cost of that shell being
  dumb is that a guest verb which never reached the wire is unreachable
  from here: `ps` on NOW-68K was exactly that — served at the guest's own
  keyboard, `unknown-command` from this side — and is now a wire command
  like the rest, with a parity test that fails on the next one. Tested
  here, and the PowerPC and 68K guests both build; **the PowerBook run is
  pending**.
- **`launch` and `quit`, by name** — open an application on the classic Mac,
  and ask a running one to quit, naming it the way `ps` names it. `quit`
  composes list → match → quit → **re-list**, and reports `gone` apart from
  `still-running`: a 'quit' Apple Event is a request, and an application
  with an unsaved document stops to ask and stays running, which comes back
  as a failure rather than a success. Emulator-verified end to end
  (console and wire); **the PowerBook run is pending** — see
  [docs/open-issues.md](docs/open-issues.md).

  A name is a *person's* identifier, and a machine should not use one: it
  is capped at 31 characters, need not be unique, and — the way this bit —
  is not derivable from anything a guest reports on the wire. So a caller
  that already holds a process listing sends `process.quit` with that
  row's PSN instead, and every listing marks the responder's own row
  (`isSelf`) so "which process is on the other end of this connection" has
  an answer that is read rather than guessed. Both guests answer both
  routes, over one implementation. **Built and tested here; the PowerBook
  run of the PSN route is pending.**
- **`front`, both faces, both guests** — bring an application on the
  classic Mac forward, named the way `ps` names it, from either guest's
  own console or from the host's. It existed as a button in the
  Processes module and as nothing a person could type, on either
  machine; a capability reachable only by clicking is the same gap `ps`
  had. NOW-68K also answers the `process.front` drive verb now, which it
  did not. The switch is cooperative, so both guests yield briefly and
  then re-read which process is frontmost — `front` says "is frontmost"
  or "is NOT frontmost", never the first when it means the second.
  Unlike `quit`, nothing by that name is a **failure**: you cannot front
  what is not running. **Built and tested; the PowerBook run is
  pending**, and the confirm branch in particular has never executed —
  see [docs/open-issues.md](docs/open-issues.md).
- **A real menu bar on the host** — App / File / Edit / View / Guest /
  Window / Help, populated with what NOW does: the View menu is the module
  registry (⌘1…), the Guest menu carries the verbs that act on the other
  machine, and Edit carries the editing commands the console's field needs
  to have ⌘C at all. The status item stays the small surface for when no
  window is open. ⌘Q quits and tells the guest first — `bye shutting-down`
  goes out and is waited for (bounded) before the process ends, instead of
  the wire being dropped abortively. Verified live via accessibility: the
  menu bar is there and Quit ends the app; the ⌘Q **keystroke** itself is
  not keypress-verified here.
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
  it also refuses to quit NOW itself — and now says which row that is
  (`isSelf`), so the row wears a **NOW** badge and Ask to Quit is not
  offered for it rather than refused after the fact. Front and Quit are
  metal-verified;
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
  stat. It also adds a create-only staged upload lifecycle: reserve private
  disk staging, append ordered 8 KiB-or-smaller chunks, then verify and
  commit through NOW's existing guest transfer lane. These tools accept only
  canonical paths relative to the host-owned `guestRoot`; the destination's
  parent must already exist, no host path is an input, and download, mkdir,
  overwrite, move, delete, tree deployment, and prune remain unavailable.
  A twelfth tool reports what the **currently connected** guest can do, and
  therefore which of the other eleven are available against it. NOW now has
  two guests of very different completeness, and that answer is derived from
  the guest's own `help` table plus observed and bounded-probed message
  families — **never from which guest it is**. A tool whose safety model
  cannot stand up against a guest is unavailable there in typed form, which
  is a complete answer; `unproven` is a third state meaning nobody has asked
  yet, and does not mean "no". All twelve tools are tested here. The original
  five V0 tools and the three read-only V0.5 tools have bounded connected
  acceptance receipts against the PowerBook 1400c; staged upload and the
  whole capability projection are **not** metal-verified — nothing in this
  paragraph about a partial guest has been watched against the PowerBook
  180c. This is not a broader transport, endurance, mutation, or
  destination-byte qualification; the exact evidence and limits are in
  [docs/agent-integration.md](docs/agent-integration.md).

Measured on the real PB1400c: ~4.9 fps at 8-bit with predictive +
interlace over 802.11b, and file transfers byte-exact at ~227 KB/s.

Each side calls the other by the name it sent during the handshake:
"guest" and "host" are words for the protocol, not for the person using
it, and "the Mac" identifies nothing when both machines are Macs. The measurement story behind the design lives in
[docs/vram-readout.md](docs/vram-readout.md) and the TimBotTu corpus.

- **NOW-68K** — a second guest for pre-PowerPC machines, built and
  metal-proven on a PowerBook 180c (33 MHz 68030, 4 MB RAM, System 7.1,
  MacTCP over a BlueSCSI-emulated DaynaPORT). Retro68 68K, non-Carbon
  Toolbox C, a 384 KB partition with ~231 KB of free application heap.
  Metal-verified: it dials out, completes the hello handshake, holds a
  keepalive at a **33 ms** round trip, reports the machine honestly
  (`mach=71 68030 sys=7.1.0 VM=off 640x480x8 row=640 RAM=4MB`), writes
  one timestamped log per launch into `logs:`, quits cleanly, and serves
  two commands — `launch` and `quit`, the latter answering `gone` after
  confirming by re-listing rather than trusting the Apple Event's return.
  Since 2026-07-25 the rest of `quit`'s outcome table is metal-proven too,
  including the one it was written for: a TeachText holding unsaved text
  answers **`quit-declined`**, not success. So are the orderly `bye`, the
  redial after the host goes away, and — with no independent
  `process.list` on this guest — the fact that its confirmation of `gone`
  was weaker than the PowerPC guest's until this guest gained
  `process.list`; the metal gate now PROBES that capability rather than
  assuming it from the hello name, and reports STRONG on the 180c.
  It also answers the contract's `process.quit` drive verb, so a host
  holding a listing can name a target by PSN instead of by name — the
  same three steps (`re-validate → refuse self → ask`) with the name
  matching gone, since a PSN has already done that job. Built and tested;
  **not yet metal-verified**, and the first handoff onto a build that has
  it has to be launched by hand, because the outgoing 0.19 answers
  neither `isSelf` nor `process.quit`.
  It is deliberately smaller than the Carbon guest: one page, no tabs, no
  preferences at all (the human types host and port each launch), dial-out
  only with a human-controlled fixed-interval redial, and no bulk features
  — bulk frames are consumed and discarded to stay in frame sync. The one
  exception to "one page" is the interactive console below, which is a
  second window by decision and is not yet metal-verified.

- **One command table, two readers.** `launch` and `quit` are implemented
  once. A command fills an `N68CmdResult` — what happened, no formatting
  — and `guest68k/src/n68_cmdresult.c` renders that either as the
  contract's `command.result` JSON for the host or as text for a human
  typing at the machine. Adding a command means one case in
  `now68k_commands_run()` and nothing else; it reaches the wire and the
  console in the same commit. Tested off-metal both ways, including six
  outcomes walked through both renderers asserting they never disagree
  about success or the error code — the failure mode the corpus finding
  `two-halves-never-met-in-a-test` names. The move itself was checked
  differentially against the pre-refactor builders over 1,092 shape ×
  message × code × capacity combinations: the host sees the same bytes.

- **An interactive console on NOW-68K** — its own window (⌘K, and it
  toggles), with an edit field, up/down history and a scrollback pane.
  The main window's console pane stays what it always was: a log viewer.
  It runs the same command table the wire does rather than a copy —
  `launch`, `quit`, `ps` — because the two faces failing at different
  times is the normal case here, and the day the 180c's display died the
  wire was all that still worked. `ps` reached that table late: it began
  as a console-only reader of the `process.list` family, which made it
  look present on both faces while the host console — a dumb shell that
  can only send commands — got `unknown-command` for it. Emulator-verified
  on a Quadra 800 under OS 8.1 for the console; the wire `ps` is
  **untested on any Macintosh**. The second window is a deliberate
  exception to this guest's one-page shape, recorded in the ledger.

- **`vprobe` on both guests** — measures a machine's VRAM read cost by
  access method, so a capture stage is designed against numbers rather
  than hope. Metal-verified on the PB1400c and now the PB180c, and the
  two disagree in ways worth knowing: the 68030's framebuffer path tops
  out around 16 bits wide, `MOVEM.L` does not burst because the VRAM is
  uncached, the FPU is slower than plain 32-bit reads, and raw reads beat
  CopyBits 1.5× where on the PowerPC they barely beat it at all. Best
  case there is 1.8 MB/s — a 300 KB frame costs 159 ms — so full-frame
  streaming on that machine is arithmetic, not tuning.
  [docs/vram-readout-68k.md](docs/vram-readout-68k.md).

- **`screenshot` on NOW-68K, to the guest's own disk.** The 68K guest
  captures its screen, encodes a packed 8-bit PICT and writes it to its
  own desktop as `Screenshot 2026-07-26 02.51.06` — type `PICT`, creator
  `ttxt`, so it opens with a double-click — and reports what it cost. No
  pixels cross the wire yet; the contract already said this slice was the
  measurement, and the measurement is the point. It never holds a frame
  or a picture: a picture being *recorded* is never drawn into, so the
  destination is the Window Manager's own port and the opcodes stream
  through a replaced `putPicProc` into a 1 KB buffer. The whole capture's
  ceiling is ~21 KB against a 384 KB partition, whatever the screen size.
  **Metal-verified on the PowerBook 180c** (System 7.1, 4 MB): three
  captures, two files on its desktop with distinct names, one pulled back
  over FTP and decoded here — pixel-for-pixel the 180c's screen, 8-bit,
  cursor shielded out. It reads in ~200 ms, **packs in ~480 ms** — the one
  cost nobody had measured, and 2.4x the read rather than the 10x the
  budget assumed — writes 65 KB in ~800 ms, and packs **4.7:1**. A frame
  is 65 KB, not 300, which is what slice two's viability over MacTCP turns
  on.

- **Files move both ways on NOW-68K** — the machine that previously
  discarded every bulk frame to stay in frame sync. Receiving a push is
  **emulator-verified**: a 4 MB file onto a Quadra 800 at 352 KB/s, pulled
  back off the disk image byte-identical, with the guest's `help` still
  answering in 0.05 s mid-transfer. Sending is now **emulator-verified**
  too, as a round trip: a pattern is pushed to the guest, the guest is
  asked to send that same file back, and the bytes the host still holds
  are compared against the bytes that came back — 4 MB byte-identical,
  and nothing in that comparison comes from the guest's own accounting.
  Neither direction has run on the **PowerBook 180c**, which is the
  machine that matters and the one whose numbers will differ.

  The wire-sharing rule was checked where only a real socket can check
  it: during a 4 MB send, 28 control requests were answered, none
  dropped, worst 0.10 s.

  The send half is deliberately **not a file sender**. It streams from a
  byte-source interface — fill this buffer, say how many and whether you
  are done — with a file as the first implementation, because a screen
  capture is ~300 KB against a 384 KB partition and can never exist as a
  buffer at all. Bulk and control share one wire under a rule written down
  once: bulk gets its own slot and never a control slot, a frame already
  going out finishes first, control drains before bulk, and back-pressure
  is the transport's short accept rather than the far side's progress
  reports. `put` is a verb on **both** faces here — unlike the PowerPC
  guest, where the host reaches the same capability through the `file.*`
  families — because this is the machine whose display has already failed
  mid-session. No contract schema changed: the whole family already
  existed and the host already served it.

- **A host can see what is on NOW-68K** — `file.list` / `file.listing`,
  and `ls` at either console. The Files module now has something to show
  against a 68K guest, which until this landed it did not. No contract
  schema changed: the messages, the host's decoder and the PowerPC
  guest's answer all already existed, so this was the guest's share of a
  family and nothing else.

  **Emulator-verified** on a Quadra 800, and the case worth naming is the
  one that could not be tested any other way: the test PUSHES two files
  and then asks the guest what is in its share, so browsing from a
  different root than receiving fails immediately. That exact bug cost a
  merge to find one direction earlier, and it is invisible to every test
  that does not touch a real disk. A twelve-file folder also walks across
  several pages losing nothing and duplicating nothing, and a folder that
  is not there comes back as a `file.refuse` with a reason rather than as
  a fifteen-second timeout.

  Pages are **small** here, deliberately: a 1024-byte control payload
  against the PowerPC guest's 4 KB, so a listing is assembled one page at
  a time and never as a buffer a 384 KB partition cannot hold. In the
  worst case — thirty-one accented characters in a name, each six bytes
  of `\uXXXX` — a page carries one entry, which is paging working rather
  than failing. `more` and `cursor` are the only things that say whether
  a folder ended.

  `ls` is the fourth NOW-68K command whose answer is a table, and the
  first that is not an exemption:
  [docs/command-parity.md](docs/command-parity.md) had already ruled that
  a fourth must be a result type holding rows rather than another special
  case, so the console reaches it by delegating and has no `ls` of its
  own. Nothing has browsed the **PowerBook 180c**.

- **A dev loop that does not need a Macintosh.** Neither guest can run its
  own suite, so the pure-C halves compile under the host `cc`:
  `scripts/test-native` runs all 28 across both guests in one command, and
  a test file missing from its manifest fails the run — a test nobody runs
  reads as coverage in a directory listing and proves nothing. The metal
  gates now **fail rather than skip** once a human has opted into a metal
  run, so a suite cannot go green having never reached a machine, and
  `tools/fakeguest.py` impersonates either guest so the harness itself can
  be exercised — including a guest that lies about `gone`, which is the
  one failure `quit` exists to catch and the one no real guest will
  perform on request.

## What does not work

- **NOW-68K implements a small part of the contract.** `launch`, `quit`,
  `help`, `ps`, `vprobe`, `screenshot`, `put`, `ls`, `cancel` and
  `process.list`, plus receiving a file, sending one, listing a folder,
  capturing the screen, cancelling a transfer in either direction, and
  the keepalive; everything else — census, streams, the process drive
  verbs, and the file family's PULL and MUTATIONS (`file.get`,
  `file.move`, `file.trash`, `file.mkdir`) — answers `unknown-command`
  or `refused`, which is the contract's own additive answer, not a
  failure. It can be browsed, told to send a file, sent one, asked for
  its screen, and told to stop; it will not change the shape of its own
  disk on request. **Receiving** decodes MacBinary, so an application and
  its resource fork can cross inbound; **sending** does not, so outbound
  is the data fork only. Every one of those it does serve is reachable
  from both its faces (the console and the wire), which
  [docs/command-parity.md](docs/command-parity.md) explains and
  `CommandParityTests` enforces.
- **NOW-68K's `screenshot` has captured exactly one kind of screen.** It is
  metal-verified on the 180c, but 4.7:1 is a quiet desktop with two windows
  on it; a screen full of dithered photographic content will pack far
  worse and nothing establishes a floor. It captures **8-bit screens
  only**, by refusal rather than conversion, and **its pixels do not cross
  the wire** — that is slice two. Its `encode` figure is a difference of
  two passes rather than a direct reading, so it carries both passes'
  noise.
- **The 180c's clock is not set.** Its screenshots are named
  `Screenshot 1904-01-01 23.49.05` — the Mac epoch, which is what the
  machine believes the time is. The same-instant collision guard is what
  keeps a second shot from overwriting the first there.
- **Receiving a file on NOW-68K is emulator-verified, not
  metal-verified.** A host can push into the Desktop, `data` or
  MacBinary, and 4 MB arrives byte-identical at ~350 KB/s on a Quadra
  800 under Mac OS 8.1. Nothing has run on the PowerBook 180c, which is
  the machine this is for — a 68030 with 4 MB against a 68040 with 128.
  There is also a live File Manager defect underneath it: on 8.1,
  `FSClose` of a written resource fork scribbles 77 bytes of catalog
  state into the fork, and the guest detects and repairs that rather
  than being able to prevent it. Whether System 7.1 does the same is
  **unknown and untested**; the shipped check is also the experiment.
  [docs/68k-file-receive.md](docs/68k-file-receive.md) is the record.
- **Sending a file from NOW-68K is emulator-verified, not
  metal-verified.** Round-tripped byte-identical to 4 MB on the same
  Quadra 800, with the control lane proved to survive a transfer
  (`gestalt` 0.05 s idle against 0.10 s during a 1 MB push). Nothing has
  sent a byte on the 180c. The sender takes an abstract byte source
  rather than a file, so a screen capture can feed the pipe in bands
  instead of buffering 300 KB against a 384 KB partition; a file is
  simply its first implementation.
- **Browsing NOW-68K is emulator-verified, not metal-verified**, and it
  has two limits worth knowing before pointing a Files module at it. A
  path with a non-ASCII character does not resolve: this guest has no
  UTF-8-to-MacRoman decoder, so a folder a person can see in the Finder
  answers `not-found` — truthful, and the same property the receive half
  already has, but a real gap the PowerPC guest does not share. And the
  cost of an indexed catalog read at a deep cursor is **unmeasured** on
  either machine, so a folder of a thousand entries may page slowly in a
  way nothing here has watched.
- **A transfer on NOW-68K can now be abandoned**, which until 2026-07-26
  it could not. `file.cancel` was in the contract and in the host and in
  the PowerPC guest, and nowhere in NOW-68K's dispatch: the guest
  answered `not-implemented` and went on holding the transfer. Because
  the lane is one transfer wide across both directions, and because
  nothing near a transfer carries a timer — the only clock is a 65 s
  no-traffic watchdog that the guest's own keepalive keeps from ever
  firing — a host that changed its mind left a guest that refused every
  later transfer for the life of the connection, while answering pings
  normally. Both directions now honour a cancel within one 4 KB chunk of
  its arrival, release the lane, and delete the staging file; that last
  claim is checked against the disk image rather than the guest's own
  report. It is also a **`cancel` verb**, on the guest's own console and
  over the wire from this side's console — one implementation, both
  faces, listed in `help` — because the person who most needs to end a
  transfer is standing at a machine whose host has stopped answering,
  which is exactly when the wire is not the face available.
  Emulator-verified, not metal-verified.
- **The two directions briefly disagreed about where files live**, and
  that is worth knowing because of what missed it. Receiving landed on
  the Desktop while sending read from the application's own folder — a
  disagreement no textual conflict marked and that 27 native tests, 508
  host tests, both Xcode configs and `-Werror` all passed over, because
  noticing it needs a real file system. The round-trip ladder on the
  emulator named it on all ten rungs. Both directions now read one
  published root. A cross-direction test could not exist while the two
  halves lived on separate branches.
- **NOW-68K's interactive console is metal-verified.** A second window (Windows > Console, Command-K, and it
  toggles) with an input line, history and scrollback. Watched working on a
  Quadra 800 under Mac OS 8.1 — including two redraw bugs found there and
  fixed, because a self-invalidated rectangle keeps its old pixels unless
  something erases it. The real target is a 68030 under System 7.1 with
  4 MB; `ps`, `help` and up/down history were all watched working there
  after the display was repaired. It costs
  ~15 KB (4.0% of the 384 KB partition) plus a `WindowRecord` and a `TERec`
  nobody has sized, it cannot copy text out, and its scrollback holds 32
  lines.

  It is a **deliberate exception** to this guest's one-page rule and to the
  Carbon guest's harder "a feature is a module, never a window". The reason
  is in `conwin.h` and the ledger; the next feature is still a page unless
  someone writes down a reason as good.
- **The host console's Tab completion depends on the guest answering
  `help`.** Both guests in this tree do; a guest built before this change
  answers `unknown-command`, and then there is no completion at all. That
  is deliberate — a fallback list would be the thing this change removed —
  but it means an old binary on the PowerBook has a shell with no
  discovery, and `help` there says so rather than listing anything.
- **A console line reaching a guest that predates `line` is misread, not
  refused.** That guest ignores the field and runs the command bare, so
  `ls Lab:Code` lists the root. The field is additive by the contract's
  rules and this is its one dishonest edge; it is stated in the contract
  next to the field.
- **Nothing verified against `tools/fakeguest.py` is evidence about a
  guest.** It is hand-written from `guest68k/src` and the contract, so it
  can only show that the harness reacts correctly to a peer that behaves a
  stated way. A test that construes it otherwise is testing one half
  twice, which is the defect class that has cost this project the most.
- **NOW-68K is not safe under Virtual Memory.** Its MacTCP parameter block
  and buffers are ordinary application BSS, and the Device Manager writes
  `ioResult` — and the driver copies inbound bytes — at interrupt time
  regardless of a NULL `ioCompletion`. Nothing in this tree calls
  `HoldMemory`, so the guest is safe only because VM is off on the test
  machine. That is a standing precondition, not a property of the design.

A "what works" list without its companion is a sales pitch.
[docs/contract-coverage.md](docs/contract-coverage.md) answers the other
half — **who serves what**, per guest, message by message and verb by
verb, with what is served kept separate from what has been proven. The
short version: the PowerPC guest serves 16 of the 17 command verbs and
14 hardware probes; NOW-68K serves 7 verbs and no probes at all, so it
cannot yet report its own CPU, RAM or ROM.
[docs/open-issues.md](docs/open-issues.md) is the ledger, organised
around **broken** versus **unverified** — the second is not the lesser
category, since most of the surprises so far came from code that looked
obviously correct and had never run on the real machine. The headlines:
resume-by-offset hangs, one large transfer in about six degrades badly,
and an unreachable host still presents as a hang rather than saying
which address it cannot reach. Guest-to-host transfers stream with
bounded memory, progress, and an end-to-end CRC; the path is
metal-verified through 4 MiB including MacBinary fork fidelity and
cancellation cleanup. That is bounded evidence, not transfer-rate
hardening, and an interrupted reverse transfer safely restarts from zero
rather than resuming.

Future host-product work is bounded by the
[NOW V1 host roadmap](docs/plans/2026-07-24-002-feat-now-v1-host-product-roadmap-plan.md).
It sequences a target catalog and host UI improvements after MCP V0 while
preserving the current guest-dials-host, one-port, single-session
transport. It is not a protocol migration or a multi-machine runtime.

The separately sequenced
[NOW MCP V0.5 guest-files roadmap](docs/plans/2026-07-24-003-feat-now-mcp-v0-5-files-command-roadmap-plan.md)
adds generic, root-scoped guest filesystem commands before projecting them
through MCP. Its implemented slices cover bounded capability/list/stat and a
create-only disk-backed staged upload; the upload still awaits attended
PowerBook verification. The reverse streaming prerequisite is integrated and
metal-verified through 4 MiB, but generic download remains a separate,
unimplemented command/policy/receipt/MCP design. CodeKitten may later consume
the generic commands but owns all project meaning; V0.5 adds no
project-specific or host-filesystem access.

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
