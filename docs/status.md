# Status: what works and what does not

This is the long form of the README's status table — every capability
with its evidence, and every gap with what is actually unknown about it.
It is deliberately exhaustive. A feature list without its companion is a
sales pitch, and the things this project got wrong were never in the
parts anyone demonstrated.

Read the verification words precisely (AGENTS.md): **builds** proves
nothing about behaviour, **tested** means the suites pass, and
**metal-verified** means someone watched it work on the real machine.

This file also uses a fourth word that AGENTS.md's three do not cover
and which is load-bearing in most of the 2026-08 entries below:
**emulator-verified** means someone watched it work under QEMU — a
`mac99` Power Mac G4 under OS 9.1, or a `q800` Quadra under OS 8.1. It
sits between *tested* and *metal-verified*: real Toolbox, real Open
Transport, real cooperative scheduling, and a machine that is faster
than any hardware this project targets, with an emulated bus. It is
never a substitute for metal, and every emulator-verified claim here
says so at the point of claim rather than in a footnote.

- [docs/mirror-state-of-play-2026-08-06.md](mirror-state-of-play-2026-08-06.md)
  is the short version **for the Mirror specifically** — what a person
  driving it will actually experience, good and bad, in the order they
  will meet it. Written as a handoff at the end of the 2026-08-05/06
  session. It is a dated snapshot, not a maintained index; this file and
  the ledger outrank it.
- [docs/open-issues.md](open-issues.md) is the ledger, organised around
  broken versus unverified. Its first section is a dated pointer list of
  the biggest OPEN items, which is the only part of it that is
  maintained rather than appended.
- [docs/mirror-element-coverage.md](mirror-element-coverage.md) is the
  element gap ledger — **190 of 308 corpus items carry
  `knowledge: unknown`**, which is the root of most remaining Mirror
  render defects, and the file carries the diagnosis as well as the
  count.
- [docs/gworld-probe-brief.md](gworld-probe-brief.md) was the open
  experiment behind most blank and hatched window interiors — whether an
  offscreen GWorld's drawing can be seen at all, or whether pixels are
  the only answer. **It is ANSWERED as of 2026-08-06** and the page says
  so at its top: the drawing is recoverable, and the composition arc
  shipped it. Read it as a brief that was closed, not as work waiting.
  The architecture that came out of it is
  [render-composition.md](render-composition.md).
- The two pages written as dated snapshots during the 2026-08-05/06
  session — [mirror-state-of-play-2026-08-06.md](mirror-state-of-play-2026-08-06.md)
  and [mirror-drive-loop.md](mirror-drive-loop.md) — both name blank
  window interiors as the largest live defect. **That was true when they
  were written and is superseded by the composition arc landing on the
  same day.** Each now carries a dated correction at the point of the
  claim; this file outranks both.
- [docs/contract-coverage.md](contract-coverage.md) is the inventory of
  who serves what, per guest, message by message.
- [docs/mcp-coverage.md](mcp-coverage.md) is the other half of that: what
  any host face can ask a guest to do, gap by gap, derived from the
  registry and gated by a test. **Read it rather than re-deriving it, and
  do not copy its numbers into prose** — including this file's.
- [docs/metal-and-ux-review.md](metal-and-ux-review.md) is the list of
  what a person still has to do. Everything built between 2026-07-29 and
  2026-07-31 is tested and not metal-verified, with two named exceptions,
  and that file is where each unproven thing waits.
- [docs/source-text-gates.md](source-text-gates.md) audits every gate in
  this repository that proves something by reading source text. Six were
  found not to prove what they claimed. Where this file says a test
  enforces something, that file says how much.

## What works today

- **A mirrored window has an interior** (2026-08-06, emulator only).
  Until this landed, the Mirror knew a window existed, where it was, and
  what controls it declared — and nothing about what the application had
  actually DRAWN inside it. The content plane carries that: the resident
  records QuickDraw operations into a 64 KiB ring in the armed process,
  the host drains it and replays them. Watched crossing the wire on
  mac99/OS 9.1 from a live CFM Finder and from Sherlock 2; the Finder
  capture is a committed fixture. `qdtrace` is the verb, and
  [contract-coverage.md](contract-coverage.md) expands it record by
  record.
- **An offscreen world can be joined to the window it lands in** (2026-08-06
  emulator proof; explicit diagnostic mode since 2026-08-08). This is the hard half. An application that composes
  its picture in a GWorld and blits the finished thing used to present
  as one opaque rectangle, and the after-the-fact chase that looked for
  the source could not reach a world created, drawn, blitted and
  disposed inside a single event pass — which is how Sherlock 2 and the
  Appearance control panels draw. The resident therefore patches
  In `probe` mode the resident patches `_QDExtensions` (`$AB1D`) in the target's own context and hooks each
  world **at creation**: `worldborn` when `NewGWorld` returns,
  `worlddied` at disposal, and a `blitsrc` record naming the source port
  before the `bits` that reveals its work. The host re-homes the held
  ops into the destination — nested worlds included, an inner world
  spliced into an outer one before the outer reaches the window.
  Measured against Sherlock 2 on the emulator: 77 born, 77 died, 0
  missed. On a PB1400c the offscreen tier becoming active correlated twice
  with Sherlock Type 1 crashes. Ordinary `record` therefore hooks only the
  exact requested window; no application is blacklisted. **The patch is never
  removed** — outside an armed probe its shim chains without selector wrapping
  — because a patch withdrawn while a caller is inside it is how you crash one.
- **The render has Platinum's own numbers in it** (2026-08-06, tested).
  The 21 accent ramps come from the guest's `Apple platinum` theme file
  rather than from a spec or a guess, extracted straight off a disk
  image with no VM in the loop (`tools/extract-assets-offline`), and
  selection and highlight are read from the active ramp. The same route
  ships 914 per-application icons and 127 System-file icons, at 16×16
  beside 32×32 so a small slot gets small art instead of a downsample.
  Scrollbar arrows and cell grids are DERIVED — the grid from the
  drawing's own idiom, marked `drawing-derivation`, claiming no action.
  Where the host has no art it draws a placeholder graded to the
  evidence, never a claim stronger than what it knows
  ([render-composition.md](render-composition.md)).
- **The scene says where its own time went** (2026-08-06). Every scene

- **The scene says where its own time went** (2026-08-06, emulator-verified;
  the phase clock has never run on metal). Every scene
  carries `meta.phases`: eight non-overlapping phases in MICROSECONDS,
  plus the measurement's own weight so "cheap enough to leave on" is
  published rather than claimed. It replaced a single tick-quantised
  number that could not resolve anything under 17 ms — from which two
  confidently wrong answers were derived in one day, each blaming the
  wrong subsystem. Every performance claim in this file now comes from
  it.
- **The Mirror's guest-side cost is small and its lies are fewer**
  (2026-08-06, emulator only). A scene walk with NOW frontmost fell from
  ~1.1 s to **0.7–1.0 ms in the steady state**, and the focus-change
  scene — the worst case, and the one a person causes by clicking —
  from **886 ms to 0.7 ms**. Almost all of it was a `FindControl` grid
  sweep of NOW's own window; the fix was to stop discovering controls the
  application itself created, since the registry that records each
  control's kind already knows which exist. A separate false claim died
  alongside it: `FindControl` refuses an *inactive* window, so with
  another application in front the sweep probed 3,724 points, found
  nothing, and the mirror reported the window as empty — an absence it
  had never observed. The registry cannot answer for a window this
  application did not create, so the fix there is a different one:
  foreign windows **retract** the control plane rather than claim an
  empty one. **That retraction path is built and has not been watched
  run** — it is the one part of this bullet that is not
  emulator-verified. Idle wire traffic fell about 90% with scene deltas,
  whose baseline is a digest of what the consumer actually holds, so a
  drifted host repairs itself on the next round trip.
- **The frame no longer waits for the Finder** (2026-08-06,
  emulator-verified; **nothing here has run on metal, and a 1400c's
  Finder is slower than an emulated G4's, so every number below is the
  optimistic one**). The host's cycle used to hold a frame open until
  two paged AppleScript conversations with the guest's Finder came
  back — a priority inversion, since a frame is the product and an icon
  roster is enrichment, and a stalled frame lapsed the act plane's
  ten-second lease, which is how a slow Finder turned into acts that did
  not bind.

  Splitting the `decode_ms` bracket into its four stages named the
  culprit in one run, and it was not the one being argued about: the
  **visibility census, ~338 ms of a 353 ms median — about 96%** — paid
  every cycle for state that changes only when a process starts, quits,
  hides or shows. The icon roster measures **0 ms** until the layout
  changes, and 1.3–1.6 s when it does. This side's own CPU was 9 ms.

  The frame now publishes on decode and the complements fold in beside
  it. Across 258 cycles on a fresh clone, every one `outcome=ok`:
  `decode_ms` median **353 → 16 ms**, whole cycle **364 → 25 ms**, and a
  cycle in which a Finder window opened **1,936 → 26 ms**; the planes
  read 15/15 on 257 of 258 samples. The Finder still takes ~1.5 s to
  read a roster — that is the machine's nature and cannot be optimised —
  but a 1,478 ms roster read now sits *beside* a 26 ms cycle instead of
  becoming one, and the census fires 17 times in 62 cycles rather than
  62.

  Two honesty notes. A frame published before its roster **says so**: a
  `finder-items` coverage claim with a typed status and reason, and
  `awaiting icons` on the status line. And `runCommand` — the family
  every complement travels on — had **no watchdog at all**; it now has
  one at 20 s, deliberately longer than the guest's own 15 s script
  ceiling so a typed refusal always beats a bare host timeout, with
  `timeouts=N` reported on the cycle line. **The symptom that started
  this — Michelle's dialog act settling rather than refusing — has NOT
  been driven**; only the whole causal chain beneath it. And the
  watchdog has never been watched firing. Plan
  [014](plans/2026-08-06-014-feat-a-frame-that-does-not-wait-for-the-finder-plan.md).

- **Finder interiors no longer use P3** (2026-08-08, **tested, not
  metal-verified after the change**). The PB1400c proved that tracing Finder's
  drawing can restart Finder. `qdtrace start` now accepts only a classified
  process selector, permanently refuses Finder, and rejects raw A5 because it
  cannot carry the identity needed to enforce that rule. The host has the same
  gate and strips historical Finder display state.

  Finder folder windows are now semantic surfaces. Their asynchronous bounded
  pages carry the displayed HFS path, measured view word (`icon`, `name`, or
  `small icon`), Finder enumeration order, live item bounds, and front-window
  selection. Cache joins use process incarnation plus exact WindowRecord
  address, not title; duplicate titles refuse rather than cross-join. Name and
  small-icon views draw their names host-side instead of depending on P3 text.
  Navigation is not limited to the Files module's shared tree: any directory
  Finder opens on the guest can be read. The safety boundary is current
  container only — no `entire contents` search, the operation that previously
  wedged hardware for about twelve minutes. The front Finder container is read
  before the desktop, its complete semantic roster publishes before optional
  type/creator icon-art enrichment, and ordinary pages start at sixteen rows
  with an eight-row overflow fallback. Generic host-side icons therefore do
  not wait for extracted asset matching. A front Finder folder window again
  carries its resize handle; application grow boxes remain withheld until a
  target-context probe can establish their WDEF variant. Ordinary application
  P3 remains experimental and off by default. The latency and resize changes
  are host-tested but have not yet been rerun on metal.

  The Finder interior is now host-owned as interaction state too, not merely
  a semantic layer painted after a guest snapshot. A folder window becomes a
  blank host Finder surface immediately; each roster page adds individually
  rendered asset-pack or generic icons as it arrives. Selection is an exact
  per-window set projected locally before the guest act: ordinary click
  replaces, control-click or right-click toggles, shift-click extends from an
  anchor, and dragging empty content makes a rubber-band selection. Name-view
  rows target their full visible row, using the same inferred view as the
  renderer, so a row cannot fall through to generic window activation.
  Command-A selects all, Command-O opens the exact selection, Return or Enter
  begins an inline rename, and Escape cancels it or clears the selection. Scroll arrows,
  pages, wheel steps, and resident thumb drags translate the cached items and
  thumb on the host immediately, then yield when the guest reports its new
  control value. Scroll and window movement no longer invalidate the directory
  roster or start another Finder AppleScript; resize, view-header changes, and
  a successful rename do. Completed rosters are tracked per container, so a
  failed desktop read cannot make a successful front folder repeat forever.
  Existing item drag remains single-item even when several items are selected;
  grouped Finder drags and host context menus are later slices. These additions
  are tested, not metal-verified.

  **Correction 2026-08-09:** host emulation owns Finder interiors, not Finder
  windows. The observed guest window remains the only shell and supplies its
  title, rectangle, z-order, visibility and chrome; the host swaps in semantic
  items and interaction state. Position/size synchronization also follows
  guest open/close so it cannot leave a second window set. Desktop emulation is
  an independent toggle. When off, the live Finder roster and positions are
  preserved; when on, the bounded Desktop Folder catalog is laid out locally.
  The roster now explicitly requests disks and Trash with live bounds, merges
  rather than replaces structural system items, and reapplies cached folder
  rosters after the state-engine projection. These corrections are host-tested
  and still await a Wallstreet/PB1400c run. The final build was also
  emulator-verified against OS 9.1: Finder returned 19 desktop rows including
  a correctly classified `Macintosh HD` disk and Trash, and the open disk
  window retained all 13 semantic items in guest-follow mode.
- **The guest is woken by its socket, not by a timer expiring**
  (2026-08-06, emulator-verified; **a metal pass is owed and this is the
  change most likely to behave differently there**). A request arriving
  into a quiet connection used to sit readable while `WaitNextEvent`
  finished a six-tick (~100 ms) sleep: the round trip was 86 ms and
  ~100% of the unexplained time was the guest not having looked yet. An
  Open Transport notifier that stamps the clock and calls `WakeUpProcess`
  takes it to **10 ms idle, 15 ms mid-drive**, while *keeping* the long
  idle sleep — a shorter sleep fixes the latency too, and pays for it by
  running the loop 37 times a second on a machine that is usually idle,
  which is the cost plan 013 exists to stop paying on a 1400c. The
  notifier runs at interrupt time, where a mistake is a crash rather
  than a slow answer; failure modes are graceful by construction, and
  `wirestat wake off` restores the shipped behaviour from either face
  without a rebuild.
- **A resident component answers for the machine while every application
  is starved** (2026-08-06, emulator-verified on a mac99 G4 under OS 9;
  **never on real hardware and never on 68K/System 7.1**). The optional
  NOW Extension dials its own MacTCP connection, says `role: resident`
  on it, and pings through a starvation that stops every application on
  the machine. An application starved 108.8 s kept its session — and the
  claim is worth its evidence, because it was **proven by mutation**: a
  build that never publishes the endpoint lost its session to the same
  wedge. Separately, and needing no extension at all, the guest was
  **killing its own session**: its dead-link clock counted wall time,
  including time it was not scheduled, so it tore down a link for a
  silence that was its own.
- **Acts keep binding while the host is talking** (2026-08-06,
  emulator-verified). The anchor plane's OWNER lease is ten seconds and
  only a `scene.request` renewed it, so any reason the host stopped
  asking inside ten seconds disarmed the planes silently. Renewal now
  rides any inbound host frame — gated, so that "connected" does not
  become "armed forever" — and a scene waits briefly for the arm echo
  instead of walking blind and reporting the blindness as an empty
  screen. Two symptoms that looked like guest defects were this: a
  quit-time modal that appeared to be missing, and a Cancel button that
  appeared to refuse.
- **A command that succeeded no longer reads as a failure at the guest's
  own console** (2026-08-06, emulator-verified at both faces). The
  console's fallback renderer read a top-level `message` out of the reply
  and called its absence a failure — and no PowerPC verb carries one on
  success, so the branch that ran for every command that WORKED was the
  failure branch. Six verbs were measured that way. One renderer now
  serves every reply shape (`console_reply.c`, Toolbox-free and natively
  tested), and both faces size a reply from one constant instead of 3072
  bytes on the wire and 512 at the keyboard.
- **An alert renders its real buttons, they answer clicks, and its
  message text crosses the wire** (2026-08-06; **tested, and the guest
  half watched on a live machine — but NO drive has watched the repaired
  alert in the Mirror window, so the "after" is an offscreen render**).
  This was recorded as "the Mail alert shows the wrong default button".
  It was worse and it was more general: wrong buttonS, which did nothing
  when clicked, and no message text at all — and it is the **alert path
  generally**, not one application (re-observed on Internet Explorer).
  **One defect, and the act plane was innocent.** The guest reported
  everything correctly except the text; items 7 and 8 of the alert are
  `userItem`s — the Dialog Manager's default-outline slots — and item 7
  *wraps* item 1's rect. The renderer drew "Visual unavailable" for
  every kind it could not draw, so item 7 hatched over the OK button and
  item 8 invented a second box: two placeholders where the machine has
  one button. The dead clicks were a *consequence* — the hit tester
  returns the topmost item, which was a placeholder with no action and
  no ref, so the interaction policy refused it. Proven by sending the
  act straight at item 1, which dismissed the alert. The missing text
  was its own bug: a DITL carries the resource **template**, and
  `SetDialogItemText` writes into the item's handle instead, so the walk
  was reading an empty template; it now reads back through
  `GetDialogItemText`. Header arithmetic was tried first and produced
  nothing *silently* — the QEMU oracle said why, and
  `now-guest-ppc/src/scene/dialog_text.h` records it. Four rules now
  hold: a `userItem` draws nothing, no placeholder covers an item it
  contains, clicks resolve to the topmost **answerable** item, and a
  disabled item wears no ring. Five tests, each watched failing, plus
  `axditl_test.c` as the DITL walk's first native coverage; evidence in
  [mirror-renders.md](mirror-renders.md). **Not closed:** the alert's
  icon is still a hatched placeholder, and Set Time Zone's default ring
  is *withheld* on a disabled default rather than moved — `isDefault` is
  the DialogRecord's `aDefItem`, which only `SetDialogDefaultItem`
  moves, so it goes stale exactly when an app greys its first button.
  The authoritative fix needs a flag in `NowPeekSemanticClassRecord`.
- **The Workshop** — the guest is one window: a sidebar rail of pages
  with Logs and Connection pinned at the bottom behind a divider and a
  status lamp, a header placard per page, a status placard below, and
  the View menu to switch — Cmd-1..9, then Cmd-0 for the tenth page
  (iCloud) when the digits ran out, with the pinned pair unkeyed.
  Twelve pages today, and the roster is the enum in
  `now-guest-ppc/src/workshop/workshop_module.h`, not this sentence —
  which read "four" for a while after the machine served more. The five
  separate windows and the Connection dialog are gone. Metal-verified
  on the PB1400c as the four-page shell it landed as — a live listing,
  a pull, a capture with its preview, streaming start/stop, and the
  in-canvas Console prompt; every page added since carries its own
  verification status in its own entry.
- **iCloud** (2026-08-01, extended 08-02) — the host serves its own
  Drive, Photos and Contacts to the guest's iCloud page over the
  additive `cloud.*` family. Drive is a real browser: Name/Kind/Size/
  Modified columns with native icons, Back/Forward/Up and breadcrumbs
  on one row above the listing, a chooseable download destination.
  Photos list with preview-on-select (host-dithered to the guest's
  depth) and download at 640/1024/1600 by longest edge or the
  original, HEIC transcoded on the way. Contacts are grouped cards
  with a lazy photo. Live filter-as-you-type on every page. Photos and
  Contacts stay off until switched on host-side and granted — the
  hardened-runtime entitlements are required, and their absence looks
  exactly like a broken button ([icloud.md](icloud.md)).
  Metal-verified through 08-01; the 08-02 layout pass is tested only.
- **Persistent connection** — the guest dials the host and holds one TCP
  connection with a guest-driven heartbeat, reconnect on a cadence the
  guest picks (capped backoff, or a fixed interval from the Connection
  page — the contract asks only for a 1s floor), and orderly
  goodbyes. Control messages ride a retry queue so flow control on a
  saturated wire can never silently eat a protocol word. Connecting on
  launch is now a checkbox — off means the Connection page is the only
  dialer, and a Save never dials by surprise.
- **Console** — one command table on the guest, reachable from the
  machine's own console (a Workshop page on the PowerPC guest, its own
  window on NOW-68K) and as a shell from this side. The host console is
  a **dumb
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
  like the rest, with a parity test that fails on the next one. That test
  read only one of NOW-68K's two console dispatch sites until 2026-07-31,
  when a console-only verb added to the other passed it unnoticed; it now
  walks both and fails when the set of sites changes
  ([docs/source-text-gates.md](source-text-gates.md)). Tested
  here, and the PowerPC and 68K guests both build; **the PowerBook run is
  pending**.
- **`launch` and `quit`, by name** — open an application on the classic Mac,
  and ask a running one to quit, naming it the way `ps` names it. `quit`
  composes list → match → quit → **re-list**, and reports `gone` apart from
  `still-running`: a 'quit' Apple Event is a request, and an application
  with an unsaved document stops to ask and stays running, which comes back
  as a failure rather than a success. Emulator-verified end to end
  (console and wire); **the PowerBook run is pending** — see
  [docs/open-issues.md](open-issues.md).

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
  see [docs/open-issues.md](open-issues.md).
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
- **Optional agent integration** — a separate, client-launched stdio MCP
  companion reaches this Mac's guest through a private same-user socket.
  It is a **client, not a third face**: it can ask for nothing the app's
  own UI could not, because both are rendered from one registry of
  capability rows, and a row arrives on every face together. What those
  rows reach — and every guest capability no row exposes yet, with a
  reason or an admission of not having noticed — is
  [docs/mcp-coverage.md](mcp-coverage.md), derived from the registry
  in-process and gated by `MCPCoverageTests`. The boundary, the
  availability rules and the trust model are
  [docs/agent-integration.md](agent-integration.md). Neither is restated
  here and neither is counted here.

  The properties worth stating in a status file are the ones that bound
  it. Availability against a partial guest is derived from that guest's
  own `help` table plus observed and bounded-probed message families —
  **never from which guest it is**, which a gate enforces over three
  source trees. `unproven` is a third state meaning nobody has asked yet
  and does not mean "no". Guest paths never cross the adapter for the
  approval-receipt path, uploads are create-only and never overwrite, and
  every invocation goes through one dispatch, which is what makes an
  audit event unskippable. Everything the companion did is on the host's
  MCP page and in the host log.

  **Tested here. Two things have been driven against a real Macintosh**:
  `now_capture_screen` end to end, and guest addressing in four of its
  five cases — both on the PowerBook 1400c on 2026-07-29. Everything else
  added on this arc is **tested and not metal-verified**; see the two
  entries below and [docs/metal-and-ux-review.md](metal-and-ux-review.md).

- **A Diagnostics page on the host** — the three probes that measure the
  machine itself rather than anything on it: framebuffer read cost
  (`vprobe`), where a staged capture actually read from (`shotdiag`) and
  transfer diagnostics (`putstat`). No two guests serve the same subset,
  so the page asks the connected machine what it serves and says which
  card that machine cannot run — naming the sibling guest that can,
  rather than presenting a button that silently does nothing. A guest's
  refusal is shown in the guest's own words, and an unknown-command
  refusal reads as absence rather than as an error. Rows are drawn
  verbatim and in order. **Built and tested; nobody has looked at it, and
  no reading in it has come off a real machine through this page.**

- **An MCP page on the host** — the Agent page until the rename
  (`ModuleRegistry.renamedIDs` carries the forwarding address, because
  the saved selection is by id): the server an agent reaches this Mac
  through, and what a companion is doing to it. Four parts: the server
  itself — running or not, its socket's endpoint, and the switch to
  stop it — whether a companion is attached and what it has done, the
  connected machine's own consent answer, and a bounded newest-first
  audit stream of every call with the capability's own words and a
  badge on the ones that change the Mac. It is a glance and not the
  record: the stream is per launch and in memory, holds no arguments,
  paths or payloads, and the log is what survives. The one switch it
  offers is the server's own lifecycle; consent has none here, because
  that is the guest's answer, not a host preference.
  **Built and tested; see below for what that does not cover.**

Measured on the real PB1400c: ~4.9 fps at 8-bit with predictive +
interlace over 802.11b, and file transfers byte-exact at ~227 KB/s.

Each side calls the other by the name it sent during the handshake:
"guest" and "host" are words for the protocol, not for the person using
it, and "the Mac" identifies nothing when both machines are Macs. The measurement story behind the design lives in
[docs/vram-readout.md](vram-readout.md) and the TimBotTu corpus.

- **NOW-68K** — a second guest for pre-PowerPC machines, built and
  metal-proven on a PowerBook 180c (33 MHz 68030, 4 MB RAM, System 7.1,
  MacTCP over a BlueSCSI-emulated DaynaPORT). Retro68 68K, non-Carbon
  Toolbox C, a 384 KB partition with ~231 KB of free application heap.
  Metal-verified: it dials out, completes the hello handshake, holds a
  keepalive at a **33 ms** round trip, reports the machine honestly
  (`mach=71 68030 sys=7.1.0 VM=off 640x480x8 row=640 RAM=4MB`), writes
  one timestamped log per launch into `logs:`, quits cleanly, and — at
  that first pass — served two commands, `launch` and `quit`, the latter
  answering `gone` after confirming by re-listing rather than trusting
  the Apple Event's return. The verb roster has grown well past two
  since; [docs/contract-coverage.md](contract-coverage.md) is the
  inventory and this file does not repeat its counts.
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
  — and `now-guest-68k/src/commands/n68_cmdresult.c` renders that either as the
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
  the roster is in [docs/contract-coverage.md](contract-coverage.md) —
  because the two faces failing at different
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
  [docs/vram-readout-68k.md](vram-readout-68k.md).

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
  [docs/command-parity.md](command-parity.md) had already ruled that
  a fourth must be a result type holding rows rather than another special
  case, so the console reaches it by delegating and has no `ls` of its
  own. Nothing has browsed the **PowerBook 180c**.

- **A dev loop that does not need a Macintosh.** Neither guest can run its
  own suite, so the pure-C halves compile under the host `cc`:
  `scripts/test-native` runs every one of them across both guests in one
  command and prints the tally itself, and
  a test file missing from its manifest fails the run — a test nobody runs
  reads as coverage in a directory listing and proves nothing. That check
  greps its own text by substring, comments included, so it holds today
  because no basename sits only in a comment rather than because it
  cannot be fooled ([docs/source-text-gates.md](source-text-gates.md)). The metal
  gates now **fail rather than skip** once a human has opted into a metal
  run, so a suite cannot go green having never reached a machine, and
  `tools/fakeguest.py` impersonates either guest so the harness itself can
  be exercised — including a guest that lies about `gone`, which is the
  one failure `quit` exists to catch and the one no real guest will
  perform on request.

- **A metal run whose result can be attributed.** Two host sessions once
  shared one PowerBook and produced a stall nothing could explain, so a
  68K metal suite now establishes that the machine is FREE before it
  binds anything — nothing else holding the port, nothing else talking
  to the machine — and fails in about a second naming the process
  instead of reporting a number nobody can trust. The procedure is
  [docs/68k-metal-runbook.md](68k-metal-runbook.md); what a run
  should record, and why one sample from that machine is an anecdote, is
  [docs/68k-metal-baseline.md](68k-metal-baseline.md). It cannot
  ask the guest whether it is mid-transfer — `xfer` knows, and is
  console-only — which is in the ledger rather than papered over.

## What does not work

- **No part of the content plane has touched metal** (2026-08-06). Every
  claim in the three interior bullets above is emulator-verified on
  mac99/OS 9.1 and nothing more. The resident that writes the ring has
  never run on a Macintosh; no `qdext` counter has been read on one; and
  **the live host application has never been watched composing an
  interior** — the composition is proven by replaying committed captures
  inside tests, which is a different and weaker thing. A PowerBook 1400c
  is far slower than the emulator and the trap patch is the most
  invasive thing this project installs in a foreign process, so this is
  the gap most worth closing next.
- **The content plane needs the optional resident, and NOW-68K will
  never have it** (2026-08-06). Without the NOW Extension there is no
  interior at all — the verb answers `content-plane-absent`, correctly,
  rather than an empty picture. On System 7.1 there is no resident to
  install, so `qdtrace` answers `unknown-command`: a declared asymmetry,
  not a to-do.
- **A busy application can outrun the ring** (2026-08-06). It is 64 KiB
  and the host drains twelve pages a cycle, each page bounded by the
  4096-byte control frame rather than by a record count. The drain
  reports what it lost instead of presenting a gap as a picture, which
  is the honest behaviour and not a fix — a window that repaints faster
  than the drain still renders incomplete.
- **How close the render actually LOOKS is measured once and is not
  good** (2026-08-06). Every gate before that day proved that strings
  cross, not that the window resembles the window.
  [fidelity-sweep-2026-08-06.md](fidelity-sweep-2026-08-06.md) is the
  first pass that judged appearance — eleven windows against the
  machine's own pixels — and its deliverable is a RED LIST that is open
  work. Note that its scores describe a deliberately pinned tree taken
  *before* the icon pack grew from 186 to 914, so every icon row there is
  expected to move.
- **Two things the plane produces have no consumer** (2026-08-06).
  `srcPixmap` is printed by the guest and decoded by nothing on the
  host, and the whole `qdext` counter object is operator- and
  agent-facing only — no Swift code reads it. Reachable is not the same
  as used, and a tick in a coverage table should not imply otherwise.
- **A Mirror round trip waits ~115 ms before it works for 3–8 ms**
  (2026-08-06, emulator). The guest's event loop sleeps up to 100 ms
  before it notices a request, so a zero-byte "nothing changed" answer
  costs the same as a whole document. Every other cost on this path was
  measured and reduced the same day — the scene walk from ~1.1 s to
  3–8 ms, idle wire bytes by about 90% — which is precisely why the
  wait is now what a person feels. Under investigation.

- **A modal owned by the FINDER ITSELF stops everything, and no
  host-side repair can help** (2026-08-06, emulator, reproduced
  deliberately). The Finder inside `ModalDialog` services no Apple
  events, and on a cooperatively scheduled Macintosh it starves NOW as
  well: `outcome=starved`, `decode_ms=0`, and the anchor worker stopped
  answering even `hello`, so the machine could not be driven at all.
  This is a **different and worse case** than the one plan 014 repaired
  — Michelle's own modal belonged to a *foreign* application, and her
  log shows `request_ms=82` beside `decode_ms=12457`, NOW answering
  promptly while the Finder was merely busy. Anyone measuring 014
  against a Finder-owned modal will see it change nothing, correctly,
  and should not conclude the fix did nothing. The only door is getting
  a modal in front of the operator, which is
  [open-issues.md](open-issues.md) item 2 under *"one modal wedges the
  whole Mirror"* and is still shut.

  *(This bullet replaced "the host's own cycle is the dominant cost and
  its shape is a priority inversion", which was true when written and
  was fixed the same day — see "The frame no longer waits for the
  Finder" under What works today. That bullet had in turn replaced "a
  Mirror round trip waits ~115 ms before it works for 3–8 ms". Two
  bottlenecks removed in one day, each exposing the next.)*

  *(A third correction, 2026-08-06 later: **a foreign application's
  modal is a 20× tax, not a wedge.** Raised in a real application
  through `ctlact` so the application runs its own handler, a modal took
  the scene median from **21 ms idle to 413 ms** (n=145) and starved
  nothing — acts work straight through it, and `ctlact` on the modal's
  own Cancel answered in 0.7 s and it was gone from the next scene. The
  Finder-owned case above is unchanged and still reproduced; it is the
  *foreign* case that turns out to be merely expensive. The number that
  was doing the work in the "12 seconds under a modal" story is the next
  bullet, and it is not a modal at all.)*
- **FIXED, emulator only: the 9–12 second Mirror loops had a named cause
  on our own side, and closing it spent a safety argument** (2026-08-06).
  The guest's
  act client waits for a target to take an armed act in two phases,
  `now_act_submit` then `now_act_await_fired`, each bounded by
  `kNowActDeadlineTicks` = 300 ticks = **5 s**, and each spinning on
  `act_yield()` — a nested `WaitNextEvent` loop that **does not pump the
  wire**. That is one of the two AGENTS.md non-negotiables, violated in
  the act client. So an act the target never takes holds `conn_service`
  off for ~10 s, and every `scene.request` in that window reports the
  act's duration as its own: measured, an act refused `act-not-taken`
  after **6.6 s** and a `scene.request` issued in the same instant
  answered in **6634 ms**, the same number twice. Two phases plus
  overhead is **11.7–12.5 s**, so Michelle's `request_ms=12041` and her
  act's `guest 12099ms` are **one event seen from both ends**, not two
  problems. It is also self-sustaining: the anchor plane's ten-second
  owner lease is renewed by host traffic *through `conn_service`*, so a
  ~10 s act lapses the very lease "Acts keep binding while the host is
  talking" repaired, and the next act refuses `plane absent` — which is
  the "refused the first time, worked the second" report.

  **What fixing it cost.** `act_yield` now calls `now_wire_pump()`.
  Re-measured on the same shape (guest `04f5dba645ad`, wire 5630): the
  act still runs its whole deadline — **5.07 s**, as it must, because the
  machine still will not take it — and **80 scene requests were answered
  during it, median 65 ms**, where there used to be one at 6634 ms. A
  taken act is unchanged at 0.08–0.20 s, and the owner lease read 7/7
  across the act.

  But pumping inside an armed window means serving requests while an act
  is armed, which is exactly the re-entrancy the no-hijack work exists to
  prevent — and NOW's act plane is a **single cell** whose only
  protection was that this wait did not service the wire.
  [no-hijack-criterion.md](no-hijack-criterion.md) said so in writing and
  named this change as the one that would remove it. **Michelle took the
  decision and the protection was spent.** What stands in its place is
  narrower: a one-act-at-a-time interlock that refuses a second act with
  `act-busy` before it can write a field. It was watched firing on a
  machine — two `ctlact`s sent back to back answered `act-timeout` and
  `act-busy` — which is simultaneously proof that the new hazard is real
  and that the guard meets it. It covers the act cell and **nothing
  else**: scene walks, census and file transfers now all run while a trap
  patch is live in every process, and nothing has measured whether that
  is safe.

  A second thing is still open beside it: **the act ceiling is stated
  nowhere once** — 5 s per phase here, against plan 014's 20 s host
  watchdog, which was chosen against the *script* ceiling with nothing
  naming this one. [nested-loops.md](nested-loops.md) carries the row
  this loop spent weeks missing, and [open-issues.md](open-issues.md)
  both measurements and what the trade does not cover.
- **Twelve verbs render correctly at the guest's console and cannot be
  given an argument** (2026-08-06, emulator). `console_model.c` handles
  27 verbs with a `strcmp` of its own and falls through for eighteen
  others, and the fall-through passes `NULL` as the whole request — so
  the verb sees no arguments at all and twelve of the eighteen can only
  ever answer a validation refusal, however carefully a person types.
  The renderer half of this seam was fixed the same day (above); the
  argument half was not. This is a
  [command-parity.md](command-parity.md) violation of the kind that
  gate cannot see: **a dispatch table says a verb is PRESENT, never that
  it WORKS**, which is now written into that document as a stated limit
  rather than discovered again.
- **The guest serves no Apple menu of its own** (2026-08-06). Apple menu
  items did nothing, and the act was never the missing part — it
  dispatched correctly and fell off the end of a switch in
  `handle_menu_choice`, which has no Apple case. The host routing was
  fixed (only "Key Caps" had been going down the working path) and is
  **UNVERIFIED by any drive**. The guest half is genuinely open, and
  not merely unwritten: the obvious call, `OpenDeskAcc`, **is not in
  CarbonLib at all**, so what the guest should serve there, and through
  what, is an unanswered design question rather than a to-do.
- **A backgrounded application cannot be armed for content capture at
  all** (2026-08-06). Not slowly — never: the arm completes when the
  target next pumps its event loop, and a process the Process Manager is
  not scheduling never does. Proven by fronting the target mid-wait
  without re-requesting, which armed it in 40 ms, six times of six. The
  handshake itself is ~15 ms once the target is frontmost, so there is
  nothing in the handshake to fix. *(2026-08-06, later: "nothing to fix"
  is right about the handshake and wrong about the **wait**. When the
  arm does not complete, the client sits in `act_yield` for its full 5 s
  per phase — so the case this bullet describes is precisely the case
  that cost the Mirror ten seconds. That wait now pumps the wire, so it
  no longer costs the Mirror anything but the act's own time. The
  underlying inability to arm a background application is unchanged. See
  the act wait bullet above; the fast path was never the problem.)*
- **Ten of the twelve capabilities added on this arc have never crossed a
  real wire.** They are `now_hardware_census`, `now_machine_facts`,
  `now_software_inventory`, `now_catalog_search`, `now_guest_log_tail`,
  `now_bring_to_front`, `now_reveal_item`, `now_guest_files_download`,
  `now_guest_files_mutate` and `now_transfer_cancel`. The three
  diagnostics rows have not run through their page either. Exactly one
  has: `now_capture_screen`, end to end on the PowerBook 1400c on
  2026-07-29. Everything else is **tested** — the suites pass and no
  Macintosh has been involved — and this is the same class of gap that
  has produced most of this project's surprises, since code that has
  never met a real machine is where they all came from.

  Two hazards are known in advance rather than discovered on the day.
  `now_guest_files_mutate` has a **2-second local receive window against
  a 20-second guest-side watchdog**, so a slow `PBCatMove` can time out
  locally on a call the machine then completes. And a **download cannot
  be cancelled on the wire before `file.begin`** at all: the host frees
  its lane while the guest may keep sending and holding its own — the
  exact wedge `cancel` exists to prevent, and the app's own Cancel button
  has it too. Each capability's own watch-for is in
  [docs/metal-and-ux-review.md](metal-and-ux-review.md).

- **No person has looked at the MCP page**, including its resting
  state — which is what it shows on most machines for most of their
  lives, because on most of them no companion has ever attached. That
  state is the one most likely to read as *broken* rather than as *idle*,
  and it is deliberately built to show no counters at all, on the
  argument that "0 companions, 0 calls, last seen never" is the visual
  shape of something that failed to load. Whether that argument is right
  is a judgement nobody has made. The same is true of the presence decay
  from active to idle, which happens on a timer with no event behind it,
  and of the Diagnostics page's not-served card. Assertions about them
  are arithmetic over model state; none of it is a person's eyes.

- **The guest consent field has never met a Macintosh.** `hello` carries
  `agent` (`disabled` / `read-only` / `full`) and the host enforces a
  ceiling from it, but the only guest that sends the field sends a
  hardcoded `full` — so every tier below the top, and every refusal path,
  has only ever been exercised against a test double. NOW-68K sends
  nothing, and absence currently fails **open**, which is a dated
  decision (2026-07-30) rather than a property of the design. Untested on
  a machine: that `disabled` refuses everything as a JSON-RPC error
  distinguishable from a capability being unavailable, that `read-only`
  admits exactly the read rows, that an unrecognised token refuses
  everything, and that a refusal reaches the audit line and the Agent
  page. **Nobody has read an agent audit line out of a real run** — not
  from the log, not from the page — and a person being able to see what
  an agent did is the whole point of the rule that produces it.

- **Guest addressing was unreachable over its own socket for a day.**
  Host-assigned machine ids shipped 2026-07-28 and were broken from that
  moment until 2026-07-29 by the local protocol's own strict decoder,
  which had never learned the request field that names a machine or the
  refusal that names the one being driven instead. Any request that
  actually addressed a guest was rejected as malformed, and the honest
  refusal surfaced as a protocol error telling the caller to retry.
  Everything on both sides of that decoder was correct and tested. It is
  fixed, and the tests added with the fix read the field list off the
  type rather than naming fields, so the next field declared without a
  place in a second list fails on its own. Four of the five addressing
  cases are metal-verified; the fifth — *connected but not driven* —
  cannot be exercised by one machine and needs a second guest on the same
  listener.

- **Some gates in this repository prove less than their names claim.** An
  audit on 2026-07-31 found **six** that did not establish the property
  they asserted, on top of seven found earlier, all sharing one failure
  mode: a comment that names the identifier satisfies a scan of the raw
  text, so the better the comment the more reliably it hides the
  deletion. Among them: an audit sink that records nothing passed the
  check that the companion is handed a real one, and a filtered map
  dropping a capability from the MCP tool list passed the check that the
  face is derived from the registry. They are fixed or documented, but
  the general lesson stands and applies to every "and a test enforces it"
  in this file: **mutation-proving is only as strong as the mutation
  somebody thought to try**, and a gate's own author is the worst-placed
  person to imagine the one that defeats it. Some limits are inherent —
  a text scan cannot tell a live call from a dead one, an argument from a
  token in a body, or what a name is bound to — and where that is so, the
  gate says so at the site of its claim instead of pretending.
  [docs/source-text-gates.md](source-text-gates.md) is the audit.

- **NOW-68K implements a small part of the contract**, and the exact part
  is [docs/contract-coverage.md](contract-coverage.md) — derived from
  both guests' dispatch source, re-derived on 2026-07-31, and not
  duplicated here, because a second copy of a derived roster is the thing
  that goes stale next. In shape: it can be browsed, told to send a file,
  sent one, asked for its screen, asked what hardware it is, asked what
  software is on it, told to launch, quit or front an application, and
  told to stop. What it will not do is change the shape of its own disk
  on request — no `file.get`, no move, trash, restore or mkdir — and it
  serves no streams, no per-window capture, no capture it offers rather
  than answers, and no `gestalt`, so the one verb that reports the whole
  machine in a breath is still missing even though the census now reports
  most of the same facts. Everything unserved answers `unknown-command`
  or `refused`, which is the contract's own additive answer, not a
  failure. **Receiving** decodes MacBinary, so an application and
  its resource fork can cross inbound; **sending** does not, so outbound
  is the data fork only. Every one of those it does serve is reachable
  from both its faces (the console and the wire), which
  [docs/command-parity.md](command-parity.md) explains and
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
- **NOW-68K 0.22 on the PowerBook 180c: the control plane is
  metal-verified, the file family is not.** Dial, handshake, keepalive,
  the bounded catalog search, farewell and redial all pass on the real
  machine (50.8 s), as does the contract suite — refusals, a second
  request during a confirm wait, an oversized control frame costing one
  message rather than the wire (72.7 s). **No transfer ladder has
  completed on that machine in either direction**, so every transfer
  number in this file is an emulator's. A serial multi-megabyte push
  wedged its MacTCP after 606 KB and, later the same evening, the
  display began to flicker: this is 33-year-old hardware with no thermal
  protection of any kind, and sustained bulk load is what it dislikes.
  Ladders belong on the emulator; the metal answers what an emulator
  cannot. See [docs/open-issues.md](open-issues.md).
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
  [docs/68k-file-receive.md](68k-file-receive.md) is the record.
- **Sending a file from NOW-68K is emulator-verified, not
  metal-verified.** Round-tripped byte-identical to 4 MB on the same
  Quadra 800, with the control lane proved to survive a transfer
  (`help` 0.05 s idle against 0.10 s during a 1 MB push — the probe is
  `help`, not `gestalt`, which NOW-68K does not serve). Nothing has
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
- **NOW-68K's interactive console is metal-verified.** ⚠️ *This word is
  contested inside this file and was not resolved on 2026-08-06: two
  other entries here call the same console **emulator-verified on a
  Quadra 800 under OS 8.1**, and `q800` is an emulator model in the
  corpus's machine registry, not a machine on the desk. Either this
  heading overclaims or the "watched working there" below refers to the
  68030 under System 7.1 and the Quadra sentence is the emulator half.
  Whoever next touches a 68K machine should settle it and delete this
  note; until then do not quote this line as metal.* A second window (Windows > Console, Command-K, and it
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
  guest.** It is hand-written from `now-guest-68k/src` and the contract, so it
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
[docs/contract-coverage.md](contract-coverage.md) answers the other
half — **who serves what**, per guest, message by message and verb by
verb, with what is served kept separate from what has been proven; and
[docs/mcp-coverage.md](mcp-coverage.md) answers what a host face can ask
for, gap by gap. Both are derived tables and both are read rather than
summarised here: this file used to carry their numbers in prose, and
carried a stale one for days after NOW-68K gained a census and could
report its own CPU, RAM and ROM.
[docs/open-issues.md](open-issues.md) is the ledger, organised
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
[NOW V1 host roadmap](plans/2026-07-24-002-feat-now-v1-host-product-roadmap-plan.md).
It sequences a target catalog and host UI improvements after MCP V0 while
preserving the current guest-dials-host, one-port, single-session
transport. It is not a protocol migration or a multi-machine runtime.

The separately sequenced
[NOW MCP V0.5 guest-files roadmap](plans/2026-07-24-003-feat-now-mcp-v0-5-files-command-roadmap-plan.md)
adds generic, root-scoped guest filesystem commands before projecting them
through MCP. Its implemented slices cover bounded capability/list/stat and a
create-only disk-backed staged upload; the upload still awaits attended
PowerBook verification. The reverse streaming prerequisite is integrated and
metal-verified through 4 MiB, but generic download remains a separate,
unimplemented command/policy/receipt/MCP design. CodeKitten may later consume
the generic commands but owns all project meaning; V0.5 adds no
project-specific or host-filesystem access.
