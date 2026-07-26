# Open issues

Things known to be wrong, unfinished, or unverified, with enough detail
to pick any one of them up cold. Nothing here is being worked on right
now; each is parked deliberately.

The distinction that matters in this list is **broken** (it does the
wrong thing) versus **unverified** (it may well be right, but no one has
watched it work on the PowerBook). Unverified is not a lesser problem —
several of tonight's bugs lived in code that looked obviously correct.

## Deferred by decision

**NOW agent-integration V0 is complete** (2026-07-24). All five bounded
projections are implemented, tested, and covered by one combined
PowerBook acceptance receipt: `now_session_health`,
`now_list_processes`, exact safe launch, revalidated cooperative quit,
and receipt-only approved artifact transfer through the existing put
lane. The pass also observed typed host absence, automatic guest redial,
new session identity, stale-reference refusal, and unchanged ordinary
Files/Connection UI. Exact evidence and limits live in
[`agent-integration.md`](agent-integration.md).

The artifact pass found one compatibility defect and closed it before
V0 closeout: modern classic-epoch dates saturated the deployed guest's
signed 32-bit JSON reader and stamped January 1972. Host→guest lanes now
omit an optional date outside the deployed reader's range; the numeric
guard, wire omission, mutation failure, and corrected live listing are
recorded in [`files.md`](files.md#classic-date-compatibility-boundary).
The first disposable evidence file retains its bad stamp; no destructive
cleanup was attempted.

The companion still has no guest component, lifecycle control, raw-path
input, shell or general filesystem surface, force-quit surface, or
CodeKitten/shared-transport dependency. Sustained load,
destination-byte read-back, and any shared-transport extraction remain
outside V0 rather than hidden completion claims.

**Guest-initiated change controls.** The browser on the classic side can
list, navigate and pull, but offers no rename, delete, new folder or
move. Michelle punted this 2026-07-20: write and overwrite were the
goals of the slice and both work.

Worth knowing before anyone reopens it: `file.move`, `file.trash`,
`file.restore` and `file.mkdir` already exist in the contract, the guest
already SERVES all four, and `HostShare` learned to serve them too
(2026-07-20, 13 tests). So the wire and both servers are done and the
only missing piece is guest UI — plus a decision about undo, which the
host side keeps on whoever initiated the action. **That host-side
implementation currently has no client.** It is tested and symmetric,
and it is also unused code until this is picked up; anyone auditing for
dead weight should know it was built deliberately, not left over.

## In flight elsewhere

**The unified Workshop landed** on `claude/guest-workshop-unified-a3aab9`
(2026-07-21): one window, a hand-drawn sidebar rail, and all four
modules (Screenshots, Files, Console, Connection) behind the
`WorkshopModuleOps` contract. The five old windows and the Connection
dialog are deleted, and all four pages were watched working on the
PowerBook the same night. The codex branch `codex/guest-console-invert`
is **abandoned by decision** (Michelle, 2026-07-21) — do not merge it.
Its one still-valuable idea, the **async OT connect path** (`160ed85`),
was reimplemented against `claude/processes-module-cb2d9c` on
2026-07-21 (see "An unreachable host presents as a hang" below); the
branch itself stays abandoned.

**The Processes page landed and is metal-verified** (2026-07-21,
`main` at `22f129a`; spec in `processes-and-peek.md`). The fifth
Workshop module: a split view with a Data Browser process list
(icon-and-text column, header sort) on the left and a detail pane
(kind, type/creator, memory text + partition bar, launch date) on the
right, plus Bring to Front and Ask to Quit (confirm -> quit Apple
Event -> keep the PSN until the walk proves the process gone ->
`(no reply)` after 10 s). The `peek.h` seam ships answering "NOW
Extension not installed"; the group box renders it. Watched working on
the PowerBook the same day. This is **rung 0** of the extension ladder
- everything above it (the NOW Extension itself, `process.*`/`peek.*`
wire families, the semantic mirror) is still ahead.

The detour that dominated the arc was NOT the Processes page - it was
reaching the Connection settings to repoint a chip that was listening
on the wrong port. That exposed two real, now-fixed defects, both
metal-verified: the async-connect launch wedge, and Connection field
editing (see below). The Processes page itself was good across those
rounds.

**NOW Extension M0 is metal-verified** (2026-07-21, rung 1, `ext/`).
The guest's first resident code: a 68K INIT publishing the shared
table, registering Gestalt `'NWex'`, and chaining a jGNE heartbeat
filter. Booted on the PB1400c at 9.1; the app's `now_peek_status()`
probed it and the Processes group box read "NOW Extension active."
That proves install, DetachResource residency, Gestalt registration,
table validation across the compiler boundary, and a live jGNE chain -
the whole of M0. Size ~48 KB (Retro68 flat runtime), loads at 9.1;
8.6 loader ceiling still unprobed (waits on the 3400c). The recovery
drill (Shift-boot off, drag-out) and the QEMU-clone pre-check remain
good practice for the next resident change but M0 itself is done.

**Rung 2a is metal-verified** (2026-07-21) - the anchor plane and the
first foreign-memory read. The extension's jGNE filter, once the
Processes page arms the plane, records each process's low-memory
CurrentA5/WindowList/MenuList into A5-keyed slots. Clicking a process in
NOW's list reads THAT process's front-window global bounds (the
per-process `axtree` behaviour): PSN -> partition
(`GetProcessInformation`) -> the fresh anchor whose A5 lies in that
partition (the correlation, validated by containment) -> `strucRgn` ->
`rgnBBox`, every foreign pointer checked inside the partition OR the
system heap before it is dereferenced (`peek_validate.c`, native-tested
+ mutation-checked), byte reads at fixed classic offsets. Watched on the
PB1400c: NOW's own window read correct, and Finder read "516 x 557 at
(7, 25)" - a real other process's window - once the validation was
widened to accept the system heap (partition-only read "unreadable",
exactly tbt's axtree lesson). The foreign read lives in the app, never
the extension.

Known texture, not a defect and not fixable: the readout is only as
fresh as the target process's last event-loop pass. Window state is a
SNAPSHOT captured by the filter when the process pumps - classic Mac OS
has no cross-process live window feed (`axtree` had the identical
limit), so no reader can re-take it on demand. There is deliberately no
time-based freshness gate on WHETHER to read: the A5-in-partition match
and the fail-closed validation, not a clock, prove a slot is this
process's, and the app carries the last good read across a stale blip.
But staleness is surfaced HONESTLY (the AXPeek/qdpeek discipline, which
hit this same wall): the reader reports the anchor's capture tick, and
the detail's Windows header shows "as of a moment ago" / "as of N min
ago" once the snapshot ages past ~3 s - an actively-pumping app stays
live with no marker. An app that never pumped since arming reads "no
anchor yet" until it does; an app with no windows reads "none open". Still open for a later pass: whether any app keeps its
window structures in a zone neither the partition nor the system heap
covers (would read "unreadable"); and rung 2b, cropping the actual Front
& Capture to the rect.

**Rung 2b - Front & Capture is metal-verified** (2026-07-21). The first
USE of the window bounds, and the anchor plane's first real artifact: a
"Front & Capture" button in the NOW Extension group box brings the
selected process forward, DEFERS the capture to a later idle (~0.75 s, so
nothing nests an event loop - the main loop's WaitNextEvent yields let
the target come forward and redraw), reads the now-front window's fresh
bounds, crops the capture to them (`capture_screen_rect` - one blit,
clamped to the screen), saves a PICT to the Desktop, and restores NOW.
Watched on the PB1400c: a captured window PICT, well-formed 8-bit with
its CLUT and PackBits rows, opened as the real window. So the whole rung
proves out end to end: extension captures anchors -> app validates and
reads bounds -> app crops a genuine screenshot to them.

**Rung 3 - the `process.*` wire family is metal-verified, host Processes
module metal-verified** (2026-07-21). The contract
gained
`process.list`/`process.listing` (symmetric, paginated by a 1-based
cursor, entries capped at 24 a page). The guest serves its own Process
Manager walk on request (`serve_process_list` in `wire.c`: name, kind of
application/background/finder, code/creator 4CCs, sizeKB, front). The
host answers the mirror direction with its own running apps
(`HostProcesses` off `NSWorkspace` - the degraded plane: modern macOS
gives no OSType code/creator and no classic partition size, so those
fields are honestly absent), and can ASK via `GuestListener.listProcesses`.
Tested here: a byte-accurate guest fixture (multi-`snprintf`, so the
conformance check names it as needing one), a `process.list`/`.listing`
round-trip, and the conformance known-partial set. A `NOW_METAL` test
(`MetalProcessTests`) pages the real PowerBook's process table onto the
host and prints it; run on the PB1400c (2026-07-21) it read 8 processes
correctly classified - the `appe` faceless-background set (Control Strip,
Folder Actions, ORiNOCO Monitor, tbt-appe), the Finder by `FNDR`, three
`APPL`s, and the guest itself flagged front. The host now DISPLAYS it: a
read-only Processes module (`ProcessesModel`/`ProcessesModuleView`) that
pages the whole table in on refresh, groups it into Applications (with
the Finder) and Background, flags the front process, captions each row
with kind/4CCs/partition size, and reads as the snapshot it is ("as of
HH:MM:SS"). Metal-verified on the PB1400c: the pane drew the machine's 7
processes correctly grouped and flagged.

**The one-way direction is by design, not a gap.** NOW drives old-from-
new - the host is the cockpit, the guest the operated machine - so
host-sees-guest is the product and guest-sees-host is a non-goal. The
guest issues no verbs at the host and has no ASK/UI for the host's
processes, on purpose. The wire family stays symmetric in MEANING, but
the host serves nothing back: the dead `HostProcesses`/`NSWorkspace`
serve was removed rather than kept as ballast (2026-07-22).

**Drive verbs added (2026-07-22).** The Processes pane grew three actions
on the selected row, all host->guest: Bring to Front (`process.front` ->
`SetFrontProcess`), Ask to Quit (`process.quit` -> a 'quit' Apple Event it
may decline), and Screenshot App. Each names its target by the PSN the
listing now carries (`psnHigh`/`psnLow`); the guest re-validates the PSN
against a live process before acting, and refuses a quit of NOW itself -
that would sever the wire mid-reply. `process.front`/`.quit` share one
`process.result` reply; their Toolbox calls are factored into
`proc_actions.c` so the guest page and the wire handler use one
implementation. **Front, Quit, and the self-quit refusal are
metal-verified on the PB1400c.**

Screenshot App is its own verb, `process.shot`: the guest fronts the
process, waits ~0.75 s for it to repaint (a deferred service pass, like
the page's Front & Capture), reads its front window's fresh bounds off
the anchor plane, captures ONLY that rectangle (`capture_screen_rect`),
restores NOW, and delivers the crop over the capture transport - it
reuses `arm_transfer`/capture.begin so the host receives it exactly as
any capture, landing in the Screenshots module. The guest owns the
timing, so the host-side delay hack is gone. **Metal-verified cropping
Finder and Strider on the PB1400c** (2026-07-22). When the window bounds
cannot be read - a genuinely windowless process - it falls back to a
full-screen capture rather than erroring: the app is front, so the screen
with it on it is a truthful answer.

**Self-read fixed** (2026-07-22): NOW reading its OWN windows returned
"unreadable" (in the detail pane and to `process.shot`, which then failed
"capture ended without a begin"). Cause: the anchor plane walks foreign
memory at the classic 68K `WindowRecord` offsets, and NOW is a Carbon app
whose own window records do not sit there. `now_peek_windows_for_psn` /
`now_peek_window_count` now special-case self (`SameProcess` with
`GetCurrentProcess`) and read NOW's own windows straight from the Window
Manager (`FrontWindow`/`GetNextWindow`/`GetWindowBounds`/`GetWTitle`) -
no reason to go foreign for oneself. So self now crops like any other
process; the full-screen fallback remains only for the truly windowless.
**Metal-verified on the PB1400c** (2026-07-22): the detail pane reads
NOW's own windows and Screenshot App crops NOW's Workshop window.

With that, the whole drive arc is metal-verified: Bring to Front, Ask to
Quit, the self-quit refusal, and Screenshot App cropping Finder, Strider,
and NOW itself.

**Smell, now fixed (tested, not yet metal-verified):** the host's process
list could hold stale PSNs across a guest relaunch, and a drive verb on a
stale PSN failed (safely - the guest re-validated and answered ok:false /
capture.end ok:false) until a manual Refresh. The list now notices the
connection itself: `ProcessesModel` drops its whole table the instant the
connection leaves `.connected` (rows belong to one connection, and the
next guest reconnects with fresh PSNs), and the view re-reads on any
transition back to connected - so a reconnect, or a pane reopened after
one, reads afresh without a manual Refresh. Clearing on disconnect also
covers the case the view's `.onChange` cannot see, a reconnect that
happens while the Processes pane is closed. Host suite passes and the app
builds; still needs a metal pass (relaunch the guest, confirm the list
updates and the three drive verbs work with no Refresh). `process.launch`
(opening an
app that is not yet running) is the honest next verb; it needs a
path/signature to name an unlaunched app, not a PSN. Everything is tested
(contract round-trips incl. `process.shot`, a guest `process.result`
fixture, the drivable/PSN decode) and builds clean on both halves.

**Metal found one rung-0 bug, now fixed:** the detail pane's "Launched"
line read "1/1/04" for every process. `ProcessInfoRec.processLaunchDate`
is ticks since boot, not a 1904-epoch date, so `LongDateString` clamped
it. Now rendered as elapsed time via `proc_uptime_text` (pure, native-
tested, watched failing by mutation): "3 min ago", "2 hr 14 min ago".

**Workshop follow-ups, deliberately not done in the arc:** a CarbonLib
1.6 launch gate (wire.c still surfaces `kConnNeedsCarbonLib` at connect
time instead); the capture disclosure's expanded state is session-only,
not persisted; the Files page's Send File button sits in the share block
rather than the header placard the spec drew; and the sidebar has no
focus ring, so Tab reaches controls but never the rail (arrows work
whenever no field has focus).

## Broken

**Hard system crash (error 10) on quit — root-caused and fixed, metal
soak pending (2026-07-23).** Twice, quitting NOW hard-crashed the guest
(error 10, a Line-F/unimplemented-instruction exception) and required a
reboot; not every quit, and the app logged its own clean "stopped"
first. Root cause: a shutdown use-after-free in every Data Browser
module. `workshop_close` disposes each module (`g_ops[i]->dispose()`)
BEFORE `DisposeWindow`, but each module's dispose freed its Data Browser
item-data/notification/compare UPPs while the browser control was still
live in the window — on the belief that "the window took the controls
with it," which the call order makes false. `DisposeWindow` then tore
down that live browser, which fires item notifications (removal, a
deselect) through the now-freed UPPs. On PPC a UPP is a transition
vector; once freed and reused, that call lands in garbage — an illegal
instruction that corrupts the system heap, hence the reboot. Intermittent
because it depends on whether the freed block was reused yet and whether
the browser still held items to notify on. Fixed in all four DB modules
(software, processes, census, files_browser_view): `DisposeControl` the
browser FIRST — while its UPPs and model are still valid — then free the
UPPs, then the model. Builds clean under `-Werror`. **Unverified:** an
intermittent crash cannot be proven gone by one quit; it needs a soak of
repeated quits from each Data Browser page on the PowerBook. The Processes
page was "metal-verified" and still carried this — the verification never
included a quit-crash soak, which the ledger should now expect. To make a
recurrence diagnosable, teardown now leaves a FLUSHED breadcrumb before
each step (`quit: closing connection` → `stopping pump` → `removing
handlers` → `disposing window` → `clean`) and closes the log LAST: a
crash log that ends at `quit: disposing window` says the fix did not
hold; one that reaches `quit: clean`/`stopped` is a clean teardown.
Ordinary log lines sit in the disk cache and a crash loses them, so the
breadcrumbs force `FlushVol` (`now_log_flush`), the same guarantee
`now_log` already gives an error line.

**Resume by offset hangs.** A transfer resumed against a matching
partial does not complete. The failing test is committed rather than
skipped (`MetalLargeTransferTests`), which is the right shape: the
feature announces its own absence. See `docs/large-transfers.md`.

**One large transfer in about six degrades badly.** 12 MB normally lands
at ~293 KB/s; occasionally a run collapses anyway. The mechanism behind
the common case is understood and fixed — this residual says the
understanding is not complete. Measured, not reasoned about; the numbers
are in `docs/large-transfers.md`.

**An unreachable host presents as a hang.** Reimplemented on
`claude/processes-module-cb2d9c` (2026-07-21) after the wedge bit again
on metal: `now-guest-processes` decoded under a fresh name, found no
prefs, dialed `10.0.2.2`, and a synchronous `OTConnect` to an address
that never answers blocks INSIDE the call — before the first update
event, so the window stays blank and only a force quit ends it. The fix
is the codex branch's shape (`160ed85`) rebuilt against this tree: the
endpoint goes asynchronous for the dial only, a notifier publishes one
flag, the main loop finishes or fails the connect, and the endpoint
returns to synchronous before the hello. `now_log_open()` also moved
above `conn_init()` so this failure finally leaves a log.
`ot_connect_source_test.py` pins the sequence — it was watched failing
against the pre-patch sources — because this fix has now been lost
once. **Metal-verified 2026-07-21** on the PB1400c: launched with no
prefs it dials the gateway and the UI stays alive and drivable, where
before it wedged blank. (The emulator forgives the synchronous form,
so this could only ever be proven on hardware.)

**The Connection fields were dead once Connection became a page**
(fixed 2026-07-21, `claude/processes-module-cb2d9c`). Address and port
took no clicks. The real cause, after two wrong guesses: the Workshop
window had **no root control**, so it had no control-embedding
hierarchy, so `SetKeyboardFocus` could not work and an edit-text
control could take neither focus, clicks, nor keystrokes. This is the
same wall the Console hit on metal - "the edit-text field never took a
keystroke" - which is why it hand-rolled its input. Connection is the
only page that uses edit-text controls; every other page's controls
(buttons, checkboxes, popups, Data Browser, scrollbar) respond through
`TrackControl`/`HandleControlClick`, which need no focus, so only
Connection was affected.

Two dead ends before the fix, both worth recording because they are
the wrong instinct:

1. `FindControlUnderMouse` instead of `FindControl` - no effect, because
   the window had no embedding hierarchy to be wrong about.
2. Adding a root control to the window. It got the field to *focus* but
   it still took no mouse or keys (the Appearance edit-text control just
   does not work for entry in this WaitNextEvent app), AND it **broke
   every other control in the group**: a root control turns the
   group-box control into an embedder, and an embedded control only
   receives clicks when HIToolbox's standard Carbon Event handler routes
   them, which this app deliberately does not install. So the retry
   popup and checkbox - which had worked - went dead too. The root
   control was removed.

The fix that holds: no root control anywhere (controls stay flat
siblings the classic Control Manager hit-tests directly, with plain
`FindControl`), and text entry moved out of the page entirely. Address
and port are drawn **read-only**; an **Edit** button opens a
movable-modal **dialog** (`conn_edit_dialog.c`, DLOG/DITL 301) whose
entry the **Dialog Manager** drives - `GetNewDialog` +
`ModalDialog(now_pump_modal_filter())` + `GetDialogItemText` on
`editText` items. That is the exact mechanism the original Connection
dialog used before the Workshop rewrite, proven on this PowerBook; its
own window has its own text handling, independent of the Workshop
window. The filter pumps the wire; validation stays in `conn_fields.c`.

Net change from the last metal-verified state is only the Connection
dialog: every page's control handling is back to no-root + `FindControl`.

**Metal-verified 2026-07-21** on the PB1400c: the "Other Mac"
popup/checkbox/Edit button click, the Edit dialog's fields take clicks
and keys, and Save repoints the connection - which is how the
wrong-port chip got corrected. Screenshots/Files/Console unchanged.

**Type-select does nothing in the browser list.** Selection,
double-click and header sorting all work; typing a letter does not jump.
`SetKeyboardFocus` is set and the key reaches the control. Universal
Interfaces 3.4 has no type-select column flag, so the likely answer is
that Data Browser wants the Carbon Event path — which means an event-
model migration, and the Carbon UI skill explicitly warns against
running two competing top-level loops in a mature `WaitNextEvent` app.
Not load-bearing; parked as a known gap rather than chased.

## Unverified on the machine

Everything here builds and passes its tests. None of it has been watched
working on the PowerBook.

- **`ps` on NOW-68K's wire** (2026-07-25, branch
  `claude/host-console-remote-shell`). The dumb-shell console landed and
  `ps` still came back `unknown-command` from a 68K guest that ran it
  perfectly at its own keyboard: it had been added to `conwin.c` alone,
  reading the `process.list` family the wire already served. A message
  family serves a module, not a person — the host console sends commands
  and nothing else — so `ps` is now in `commands68.c`'s table and its
  reply is built by `n68_proclist_render_ps()` from the same
  `proc_list_rows()` walk that feeds `process.listing` and the guest's
  own console text.

  Tested here: the new renderer's shape, its empty case, its refusal at a
  hopeless cap and its worst-case row bound (`test_proclist.c`, and the
  truncation guard watched failing by mutation); two host fixtures for
  the reply as the guest writes it; and a new parity test,
  `testEveryVerbTheSixtyEightKConsoleAnswersIsAlsoOnItsWire`, watched
  naming exactly this bug when `ps` is pulled back out. The 68K guest
  cross-compiles clean. **Unverified:** nobody has typed `ps` into the
  host console against a real 68K Mac. Two things to watch when someone
  does — the truncation row (`["...", "N more not shown"]`) appears only
  on a machine running more processes than a 1 KB control frame holds,
  which is roughly a dozen and may never happen on a 7.1 machine; and the
  detail column is meant to read identically to the PowerPC guest's, which
  no run has yet compared side by side.

- **The dumb-shell console, both guests** (2026-07-25, branch
  `thread/host-menu-dumb-console`). The host console no longer knows what
  commands the guest has: it sends `command.request` with `line` — the raw
  text a human typed — and renders whatever comes back. Every argument
  grammar moved to the machine that serves the verb
  (`guest/src/cmd_line.c`, natively tested by mutation), `help` became an
  x-command answered from the one doc table each guest already showed its
  own console (`guest/src/cmd_help.c`,
  `guest68k/src/commands68.c`), and the host's Tab completion is that
  answer at runtime.

  Tested here: 459 host tests, the two new native guest tests, and both
  guests cross-compile clean at `-Wall -Wextra -Werror`. **Nothing has
  been typed into a console on either machine.** What that leaves
  specifically unverified:

  - `gestalt` slicing now happens guest-side from the line (`--full`,
    `--cpu`, …). Absent-`line` behaviour is unchanged for modules, but no
    human has typed `gestalt --memory` at a PowerBook.
  - `screenshot --depth 8 --no-save` and `tail 40` parse from the line
    for the first time; the old host-side parsers are gone.
  - `help` on the PowerPC guest builds a ~1.2 KB reply against a 4 KB
    control frame with a byte-budget truncation row. The budget is
    reasoned, not measured on the wire.
  - `help` on NOW-68K builds into a 512-byte payload buffer and measures
    ~260 by hand-count. It has never been sent.
  - The MacRoman decode of an accented path typed as a console line
    (`ls Café:Notes`) is covered by a native test on the decoder, not by
    a file with that name on a real HFS volume.

- **⌘Q's farewell, on metal** (2026-07-25, same branch). The host now
  returns `terminateLater` and waits for `bye shutting-down` to reach the
  socket before the process ends, bounded at 0.5 s. Tested here by
  sequencing (mutation-verified: a shutDown that reports synchronously
  fails), and the menu bar and its Quit item were driven live through
  accessibility on this Mac. **Not verified:** that the ⌘Q *keystroke*
  dispatches (script-driven activation is refused in this environment, so
  the item was clicked rather than typed), and that a PowerBook watching
  the wire draws the right conclusion — the guest's own "host went away"
  handling has not been observed against a real quit.

- **`quit <name>` — the deploy loop's missing half** (2026-07-25,
  branch `thread/guest-quit-command`). A console command and x-command
  that composes `process.list` → match by name → re-validate →
  `process.quit` → **re-list**, so it can report `gone` apart from
  `still-running`. Design, outcome table and the decisions behind each
  case: [`processes-and-peek.md`](processes-and-peek.md#quit-name--the-same-action-named-the-way-a-person-names-it).

  **Emulator-verified, end to end, on mac99 / OS 9.1 / CarbonLib 1.6** —
  both invocation paths, and every outcome the composition can produce:

  | Watched | Result |
  |---|---|
  | Guest console `quit SimpleText` | `"SimpleText" is gone (0.3 s)` |
  | Guest console `quit --no-wait SimpleText` | `asked "SimpleText" to quit; NOT confirmed (--no-wait)` |
  | Guest console `help quit` | renders |
  | Wire `quit SimpleText` | `gone (0.1 s)`, and confirmed absent by an independent `process.list` |
  | Wire, dirty document | `[quit-declined] … is STILL RUNNING after 4 s`, with SimpleText visibly sitting on its Save dialog |
  | Wire, nothing of that name | `not-running`, `ok:true` |
  | Wire, its own name | `[quit-refused]`, and still there afterwards |
  | Wire, no target / unknown flag | `[quit-bad-args]` |

  The acceptance driver is committed: `MetalQuitTests` (`NOW_METAL=1`,
  plus `NOW_QUIT_DIRTY=1` for the human-in-the-loop declined case).

  **What the PowerBook still has to settle.** The emulator says nothing
  about *timing* on a 117 MHz 603e: SimpleText answered in 0.1–0.3 s
  there, and the 6 s default was chosen for a slower machine, not
  measured on one. Nor has the deliberate stall been felt on metal — for
  up to `--wait N` the guest's window does not repaint (it keeps
  servicing the wire; see [`nested-loops.md`](nested-loops.md)), and
  "does that read as a hang?" is a question about a real screen. An
  isolated copy is staged at `Lab:now-quit` on the 1400c (its own name,
  so its own preferences; fork sizes verified against the local
  MacBinary, 565127 / 2439). Being non-canonical it starts with no
  preferences and dials 10.0.2.2, so the **console** path needs no host
  at all — that is the one to run first. The real target is NetPresenz
  on a 180c, which is a different machine and a different client.

- **`catsearch` — the Software module's feasibility probe** (2026-07-22).
  Times a whole-volume `PBCatSearch` sweep for APPL files on the startup
  volume, in 15-tick slices, cold then warm. Console verb on both sides
  (contract `x-commands`, guest `commands.c`, host `ConsoleModel`).
  **Metal-verified on the 1400c** (guest console path; same-day emulator
  run agreed in shape): 22,127 files / 2,411 folders, 601 APPL hits,
  cold sweep **228 ticks = 3.8 s in 184 slices**, warm 172 ticks =
  2.9 s, longest slice 3 ticks against the 15-tick budget, zero
  restarts. Two conclusions the Software module can build on: a full
  inventory sweep is affordable as background `idle()` work (~50 ms
  worst slice), and 184 slices ≈ the catalog arriving one 16 KB opt
  buffer per call — so the buffer size, not `ioSearchTime`, is the
  real slice-length dial. Warm is barely cheaper than cold; do not
  design around the cache. The host-console invocation was watched
  working too (2026-07-22, post-merge build), so both invocation paths
  are metal-verified — including MacRoman-high-byte names in
  `First hits` crossing the wire through the `\uXXXX` escaper.

- **Software rung 3 begins: the page is registered and appears**
  (2026-07-22, spec in `software-module.md`, mock in
  `mockups/software-mockup.html`). The six-edit registration for a new
  nav module landed and is **emulator-verified**: Software shows as the
  6th rail row (a boxed-app-tiles `ics#` 136) between Hardware and the
  pinned Logs/Connection pair, Cmd-6 selects it, and it draws the live
  installed-software overview (139 extensions, 33 control panels, …).
  The delicate part — inserting Software as id 6 pushed Logs 6→7 and
  Connection 7→8, the first insert to move an existing non-pinned id —
  bumped prefs to **format 14** with a remap lifting both; the
  save/load round-trip is verified (quit + relaunch reopened on
  Software). Two supporting pieces are host-cc tested and integrated:
  `software_layout.c` (split-view geometry) and `sw_vers_parse.c` +
  `now_software_read_version()` (the `'vers'` parse extracted to a unit
  with a mutation watched failing under ASan; the per-row primitive the
  trickle will call). **Still ahead on this rung** (the frame is drawn,
  these land on it): the interactive Data Browser with the FSSpec-
  bearing item model, the domain popup, live search, the launch/front/
  quit/reveal buttons, and the idle-paced version trickle. None of that
  is metal-verified yet — only the emulator, and only the page's
  appearance + prefs migration.
  - **Interactive cut (2026-07-22):** first version was hand-drawn and
    metal-tested the same day; the second metal round found real
    problems, all fixed and re-verified in the emulator:
    - **The module leaked port state.** Three `RGBBackColor(white)`
      calls on the one shared Workshop window turned EVERY page's
      background white. Fixed by rule, not by restore: the module
      never touches the background color — white interiors are
      fore-painted with `PaintRect`. Watched fixed (Hardware gray
      again after visiting Software).
    - **The list is a real Data Browser now** (the processes_module
      pattern): Platinum header buttons, native four-column sort,
      native truncation/scrolling. Loading appends items and versions
      update one cell — the flashing was the hand-drawn list's
      invalidation model, and it is gone with the list.
    - **Domains cache in memory for the run** (lazy NewPtr each);
      switching rebuilds the browser from the cache, never the disk;
      Rescan is the only re-read; the apps sweep is resumable across
      switches. Watched: Extensions ↔ Applications both ways, the
      restore instant with versions intact.
    - The search field takes its click (focus ring); the detail pane
      is a group box with theme fonts and the selection's icon
      (`GetIconRef` on first selection only, cached for the run).
    **Emulator-watched:** sweep→browser fill, version cells trickling,
    live search (8 of 205), the domain popup driven by a genuine held
    QMP drag, cache restores, page-switch persistence, the bg fix.
    **Not watched, needs a human click:** row click-to-select and the
    search focus ring — a control experiment showed the metal-verified
    Processes browser ALSO ignores injected clicks (atomic and
    QMP-held), so this is an injection-vs-DataBrowser artifact, not a
    known defect; still, only a hand on a mouse closes it.
  - **Fourth round (2026-07-22):** the third metal round's four asks.
    The residual flashing was batched *sorted* inserts shuffling
    visible rows — the browser is now fed nothing mid-sweep (the
    placard counts arrivals) and populates ONCE at sweep end, watched.
    **Duplicate groups**: same-name items collapse under a container
    row (disclosure in the Name column, "N items", aggregate size,
    running-if-any; parents disclose, never select) — watched as
    "now-guest · 2 items · 1.0M · running" with indented per-version
    children, isolated by search ("2 of 206"). **Where:** the full
    path, wrapped, in the detail — watched, computed on selection
    never in draw. **Show in Finder**: alias in a 'misc'/'mvis' Apple
    Event, Finder fronted — watched revealing Note Pad in Apple
    Extras, matching the detail exactly. **Bring to Front / Quit**:
    wired over the metal-verified `proc_actions` with a fresh
    at-act-time PSN join; unwatched as buttons (the VM's only running
    singleton is the injection channel itself). Also unwatched:
    groups' collapsed-default on the unfiltered list. Nothing in this
    round is metal-verified yet.
  - **Metal feedback on the host page (2026-07-23), two fixes.**
    (1) **The `®` was passed down poorly.** A launch/reveal from the
    host against an app with a non-ASCII name ("Adobe Photoshop® 5.0")
    came back "no such file", the echoed path double-mangled to `¬Æ`.
    Cause: the host sends HFS names as UTF-8 (® = `0xC2 0xAE`), but
    `run_launch`/`run_vers`/`run_reveal` read `target` with
    `now_json_find_string` (a raw byte copy), so `FSMakeFSSpec` never
    saw the MacRoman byte (`0xA8`). Fixed by reading `target` with
    `now_json_find_text` — the inbound half of `now_json_escape`, which
    decodes `\u` and raw UTF-8 back to MacRoman (a json_native_test case
    pins the ® round trip). **The same latent bug in the Files path
    commands** (mv/trash/restore/mkdir/offer/list/get in wire.c, console
    `ls`) was fixed in the same defect class by a parallel task — see
    "Non-ASCII paths INBOUND" in the Files section, guarded by
    `test_inbound_hfs_path` and a source-reading conformance test.
    (2) **Selection hilite
    hugged the text.** The Data Browser's default
    `kDataBrowserTableViewMinimalHilite` draws the selection only behind
    each cell's glyphs, so a selected row read as three disconnected
    patches; switched to `kDataBrowserTableViewFillHilite` for one
    continuous full-row bar (CarbonLib 1.1+, we floor at 1.6). Guest
    builds clean under `-Werror`; both **unverified on metal** — the
    reveal round trip needs the connected session, and the hilite is a
    visual change to watch on the PowerBook.
  - **Host page reaches parity: split-pane, detail, reveal
    (2026-07-22).** The host Software page grew a second half. It is now
    an `HSplitView` — the inventory Table on the left, a detail pane on
    the right carrying the selected item's version, size, state, kind,
    and full path (selectable), with **Launch** and **Show in Finder**
    beneath it. Search was already there; it stays, above the split.
    "Show in Finder" is a **new wire verb, `reveal`** — launch's
    read-only twin: it resolves a target exactly as launch and vers do
    (path / `#n` / bare name) but reveals ANY item (an extension, a
    control panel), since it opens nothing. The guest serves it by
    sending its OWN Finder a `kAEMakeObjectsVisible` for the item's
    alias then fronting the Finder — the same `now_software_reveal` the
    guest page's own button uses, now reachable from the host and the
    console (`reveal <name|path|#n>`). Contract-first: the `reveal`
    x-command is declared, answered in `commands.c`, and offered by the
    host console — `CommandRegistryTests`' three-way agreement holds.
    Host suite green (276) incl. a reveal test; guest builds clean under
    `-Werror`; audit clean. **Never run live**: like rung 4, the reveal
    round trip and the split-pane page both await a connected session
    with both new builds. `reveal` from the host console against a live
    guest, and the detail pane's two buttons, are the one-sitting check.
  - **Rung 4 lands (2026-07-22): versions on the wire + the host
    Software page.** `serve_software_list` now fills each served
    entry's version (a page's worth of fork opens per request, bounded,
    explicitly asked for); the contract, fixture, and Swift docs agree.
    `SoftwareModel`/`SoftwareModuleView` mirror the guest page
    host-side — domain picker over a Table, client-side search, Launch
    by the entry's path (the guest's words shown either way), the
    listing's `note` surfaced verbatim — registered between Hardware
    and the footer. Host suite green incl. `SoftwareModelTests` and the
    updated registry manifest. **Never run live, all of it**: the
    `software.list` round trip (and now the version enrichment and the
    page on top of it) awaits the first connected session with both new
    builds — `swpage extensions` in the host console, then the Software
    page itself, is the one-sitting check.
  - **Fifth round (2026-07-22):** the metal report "a collapsed group
    will not re-expand" was a real contract miss: closing a container
    REMOVES its children (the Data Browser's own behavior) and
    item_notify ignored container notifications, so reopen had nothing
    to show. Fixed: kDataBrowserContainerOpened re-adds the group's
    children, idempotent via GetDataBrowserItemCount. **Unwatched** —
    the disclosure triangle defeats click injection; the repro is on
    the PowerBook. Also added: a **draggable splitter** between the
    panes (gray XOR outline, own StillDown loop pumping the wire —
    nested-loops.md row added — clamps tested host-cc, session-only
    width). **Watched end to end** in the emulator. Bonus close: a
    press-MOVE-release drives the Data Browser under injection, so
    **row click-to-select is now watched** (previously the oldest gap).
    Known nit: below ~260px list width the fixed columns clip; a
    tighter clamp is a one-liner when it bothers. The whole-window
    redraw on module switch is spun off as its own task (parent
    container, not this module).
  - **Sixth round (2026-07-22):** the search field repainted the whole
    module per keystroke — Remove-all/Add-all, an unconditional detail
    invalidation, the group qsort, and a catalog walk, every key.
    Typing now refilters by DIFF against a view set (delta rows only,
    groups leave children-first), the detail is touched only when the
    selection actually changed, and there is no auto-pick mid-typing.
    The full rebuild remains for content changes. Per the redraw
    contract added to `classic-mac-carbon-ui` the same day. Emulator-
    watched: the selection and detail pane SURVIVE keystrokes
    untouched; a filtered-out selection clears once. The reduced
    repaint itself, like all flicker, only reads on metal.
    - The field itself still blinked (whole-field invalidate + full
      white repaint per key). Typing now echoes the DELTA directly —
      the contract's immediate-feedback exception: erase from the end
      of the unchanged prefix only, draw the tail + caret, clip
      restored, nothing invalidated; draw_search reproduces the same
      pixels at any real update. Emulator-watched ("quicktime" typed
      and backspaced entirely through the echo path).

- **Software rungs 1–2: resumable sweep, `vers`, running tags, and the
  `software.list` family** (2026-07-22, spec in `software-module.md`).
  Rung 1 is **emulator-verified**: `sw extensions` tagged exactly the
  three running `appe` files the harness's process list names
  (Control Strip Extension, DVD AutoLauncher, FBC Indexing Scheduler),
  and `vers SimpleText` read Version 1.4 / "1.4.0 final" / the Get Info
  string / Product 1.1 by name-search resolution. Known texture:
  Application Switcher runs but is untagged — its process appSpec
  evidently names the System file, and the strict FSSpec compare
  declines to guess; that is the join being honest, not a defect.
  Rung 2 (the wire family, served from a one-domain cache with
  full-path launch keys) **builds and is host-tested** — fixtures pin
  the piecemeal listing including a MacRoman ® — but has **never run
  live end to end**: it needs the new host build connected to the new
  guest build, driven by the host console's `swpage [domain] [cursor]`.
  - **First metal round (2026-07-22, partial):** `sw apps` and `vers`
    ran on the 1400c from the host console. Two findings, both closed
    the same day: `launch` from the host dispatched as unknown-command
    — the host sorts JSON keys, `args` precedes `name`, and the guest
    scans frames FLAT, so launch's arg named "name" was read as the
    command name (arg renamed `target`; the never-shadow-an-envelope-key
    rule now lives in the contract's x-commands preamble); and `vers`
    on a bare name met the disk's several SimpleTexts — it now shows
    every match path-first instead of refusing, `launch`'s ambiguity
    refusal names the paths, and a duplicate finder (same/different
    version, user-driven consolidation) is marked in the spec as later
    work.
  - **Second metal round (2026-07-22, same day):** the multi-match
    view worked but truncated paths mid-folder, and retyping a full
    HFS path to disambiguate is brutal. Both fixed: matches print as
    a **numbered list whose paths wrap** across continuation rows,
    the list is **stored on the guest**, and `launch #2` / `vers #2`
    pick from it — either console, one wire frame. launch's ambiguity
    answers a distinct `launch-ambiguous` code for a future host UI.
    Emulator-verified with a manufactured duplicate (two now-guests:
    refusal listed both full paths, `vers #2` read the picked copy,
    `launch #1` launched).
  - **Third metal round → launch redesign (2026-07-22, same day):**
    the numbered-pick flow worked on the 1400c but read as too much
    ceremony for "just open it." `launch <name>` now launches the
    **highest-versioned** copy and names it in the reply (a visible
    answer, not a hidden guess); `launch <name> <version>` forces a
    copy by its short version string; full path and `#n` still work.
    The whole arg is tried as a literal name first, so "Sherlock 2"
    stays whole. Emulator-verified (newest-of-2, version pick,
    wrong-version message, single-match plain launch).
  - **Fourth round → `-v` flag (2026-07-22):** launch-newest became
    too surprising to reason about (which version won?), so the shape
    settled: `launch [-v VERSION] NAME`, NAME the whole remainder
    (spaces need no quotes; quotes stripped if used), a bare ambiguous
    name launches the FIRST found and names its version (one fork
    open, no walk), `-v` forces a copy, positional `Name 1.2.3` retired
    with a "did you mean -v" hint. Emulator-verified: quote-strip,
    first-of-2-with-version, the hint. The `-v` launch flag is
    **metal-verified** (Michelle, 2026-07-22, human-typed — the
    emulator keystroke injection had dropped its leading chars, an
    input artifact, never the code). The `software.list` wire family
    (`swpage`) remains the one never-run-live path — it needs a host
    linked to the guest, deferred until the guest page is dialed in.

- **`sw` and `launch` — the software family's first verbs** (2026-07-22).
  The Software module's data layer (`software.c`) surfaced as console
  verbs on both sides before the page exists. `sw` inventories the
  special folders live (Extensions Manager's disabled siblings tagged
  "(off)") and pages applications via the catsearch-verified APPL sweep,
  stopped at one page; `launch` opens an application by exact-name
  search or full HFS path, refuses ambiguous names, and logs outcomes
  under `sw` — it is the family's one mutation. Versions are
  deliberately absent: one `'vers'` read per file is the expensive
  path, deferred to the module's lazy detail.
  **Emulator-verified** (OS 9.1 clone): overview counts (139/33/0/13),
  `sw extensions` with types+sizes, `sw apps` page with the more
  marker, and `launch SimpleText` bringing a live SimpleText to front.
  **Not yet watched on the 1400c**, and the guest's LOCAL `launch`
  intentionally does not log (only the wire path does — same rule as
  `ls`/`ps`); the host-console invocations of both verbs are
  host-tested but unrun live.

- **A page switch paints once, and only what changed** (2026-07-22).
  Michelle watched Workshop page switches repaint the whole window on
  the PowerBook — rail, placards, everything. The investigation found
  the container's *invalidation* was already scoped (header/body/status
  plus the two selection rows); the churn was in the *painting*, three
  ways: `HideControl`/`ShowControl` draw immediately, so
  `show(false)`/`show(true)` repainted the pane piecemeal before the
  update event repainted it again; the update handler's full-port
  `EraseRect` painted the invalidated rail rows theme-gray a beat before
  the rail's own white erase; and `DrawControls` followed by
  `UpdateControls` drew every control twice per update. All three fixed
  in `workshop_window.c` alone: the swap runs under an empty clip and
  paints exactly once at the coalesced update, the erase narrowed to the
  body plus the sidebar gutter outside the rail panel (the placards and
  the rail fill their own faces), and one `UpdateControls` pass.
  Emulator-verified: all seven pages cycle with no stale pixels, zoom
  leaves the gutter clean, controls still track after switches. **Watch
  on metal:** that the rail genuinely stops flashing at the machine's
  real drawing speed — the emulator is too fast to show a flash either
  way. One module-side offender remains, out of the container's scope:
  the copy-pasted `set_status` in screenshots/census/connection
  invalidates a full-width bottom strip (port bounds, bottom 23 px) that
  crosses the rail's foot, so the Connection row can still flick when a
  module's status line changes. The module fix is to invalidate the
  status placard's rect, not the port's.
- **The Logs page, both machines** (2026-07-22). A Monaco dump of the
  in-memory log ring that follows the tail live like a terminal, with
  Invert and Log-to-disk switches. The **guest** page was watched working
  on the PB1400c; the footer move, the invert switch, and the whole
  **host** module are built and tested but unrun since.
  - **Placement.** Pinned in the footer below the divider, directly above
    Connection — a `logs_row` on the guest (id 6, Connection 7), a
    `.footer` descriptor before `settings` on the host. The host footer
    row now shows link status only for the row that IS the link.
  - **Guest scrollback.** The ring grew 200 -> 2000 lines (`kLogKept`),
    ~240 KB of statics against a 6 MB partition. `run_tail`'s stack index
    was decoupled from `kLogKept` so it stays 48, not 2000, pointers.
  - **Disk toggle.** `now_log_set_disk`/`now_log_disk_on` (guest) and
    `HostLog.setPersistsToDisk` gate the file at runtime; the ring is
    always live. Default on (crash survival is the point). Both switches
    reflect the ACTUAL state, so a failed open reads as off. On the host
    the file is now a switch, not opened at launch — `LogsModel` applies
    the saved choice.
  - **Invert.** A dark canvas like Console, saved per page. Guest prefs
    reached format 13 for it (12 was the disk field + Connection renumber);
    the host keeps `logsInvert` in UserDefaults.
  - **Watch on metal:** the host module unrun entirely; on the guest, that
    the invert switch redraws cleanly and the footer pair (Logs above
    Connection, under the divider) lays out at 640x480.
- **`ps` and `census` console commands + guest verb logging**
  (2026-07-22). The two new modules — Processes and Hardware/census —
  had no console verb and logged nothing; both are now closed.
  - **Console.** `ps` (flat process list, the reading of `process.list`
    the Processes module drives) and `census [probe]` (one probe page,
    the flat cousin of `censusExchange`) were added across all three
    halves — contract `x-commands`, guest `commands.c` dispatch, host
    `ConsoleModel` offer + help — the way `ls` is to `file.list`.
    `CommandRegistryTests` reads all three and is green, so the set
    agrees and every offered command has help. The guest's own console
    (`console_model.c`) renders both locally too.
  - **Logging.** The guest drive verbs (`process.front`/`quit`/`shot`),
    census outcomes, and the process-list refresh now log their shape
    with the wire id (areas `proc`, `census`). The refusal *reasons*
    that used to live only on the wire now reach the log. `process.list`
    logs once per refresh (cursor 1), never per page, to stay off the
    per-chunk heartbeat rule.
  - **Verified only here:** host suite (263 tests) green, `audit_source.py`
    clean, the census/json header chains compile under
    `cc -Wall -Wextra -Werror`. **Not** cross-compiled — no Retro68
    toolchain this session, so the guest-only additions (`run_ps`,
    `run_census`, the two console handlers, the `wire.c` log lines) are
    not even at *builds* yet. First metal run should confirm `ps`,
    `census pci`/`ata`/etc., and that a declined `quit` shows in the log.
- **The Processes page's product pass** (2026-07-21) - built and
  suite-green, unrun on metal. All app-side (extension unchanged):
  - **Kind grouping.** Processes are classed from `processMode`
    (`modeOnlyBackground`), not guessed from the `'appe'` type. The list
    sorts front-process first, then applications, a divider row, then
    background-only - kind and front-ness are the sort axes, never
    window state, so a row never jumps when a window opens/closes.
  - **Row badges.** Front app reads "(front)"; apps show their window
    count ("3 windows"); windowless and background rows show none - the
    windowed/windowless distinction, visible without selecting.
  - **Richer detail.** CPU time (`processActiveTime`), accurate Kind
    with "(frontmost)", and a Windows section listing each window's
    title + size (up to 3, "...and N more"), read through the anchor
    plane's validated foreign path (now walking the `nextWindow` chain
    and reading `titleHandle`). Menus line is a reserved STUB - the
    anchor captures `MenuList`, the walk is a later pass.

  **Watch on metal:** the **divider row** is a non-process sentinel item
  in the Data Browser (`kDividerItem`), non-selectable by bouncing the
  selection off it - the one bit of fake-row territory in an otherwise
  proven-DB design; confirm it draws between the groups and cannot be
  selected. Also that window titles read correctly (another foreign
  pointer hop, `titleHandle`), and that per-app window-count reads every
  second don't cost visible time on the 33 MHz metal.
- **Prefs v10 module renumbering.** Connection moved 4 to 5; a v9 file
  should reopen on the page the person had (the remap is three lines
  in `now_prefs_load`), exercised only by reasoning - same status as
  the v9 note below.
- **Corners of the Workshop no one has exercised anywhere:** the send
  progress bar actually moving, and the preview well at 16/32-bit
  depths. (The first metal pass found two bugs - a mute Console
  edit-text and Modified dates clamped to 1/19/72 by signed
  DateString - both fixed the same night and metal-verified the next
  morning, 2026-07-21.)
- **Prefs v9.** Reads v1-v8 files and seeds the Console page from a
  legacy console_open flag; exercised only by reasoning, not by an old
  prefs file on the machine.
- **The host serving move / trash / restore / mkdir.** 13 tests, zero
  minutes of machine time. No client asks for it yet (see above).
- **Accented file names.** macOS stores names decomposed, so "café" is
  "cafe" plus a combining accent, and MacRoman has the letter but not
  the mark — every accented name was arriving as "cafe_". The fix
  composes first. Nobody has pulled an accented file to the PowerBook.
- **Non-ASCII paths INBOUND, host to guest.** The complement of the
  above, and the same defect class as the Software fix: the host sends
  every path UTF-8 (® is `0xC2 0xAE`), but `FSMakeFSSpec` wants the
  MacRoman byte (`0xA8`). The guest's file-op verbs were pulling
  `path`/`toPath`/`trashedAs` with `now_json_find_string`, which does
  not convert, so a move/trash/restore/mkdir/list of any non-ASCII name
  looked for a file that does not exist. Fixed by switching those
  extractors (and `file.offer`'s `name`, and console `ls`) to
  `now_json_find_text`; `container`/`fileType`/`creator`/tokens stay
  find_string, ASCII by contract. Guarded two ways —
  `json_native_test.c :: test_inbound_hfs_path` proves `café®` decodes
  to `0x8E 0xA8` (and that find_string leaves the raw four bytes), and
  `GuestWireConformanceTests :: testHfsPathArgumentsAreTextDecoded`
  reads the C and fails if any of those keys reverts to find_string
  (mutation-verified). **Tested, not metal-verified:** no one has moved
  or trashed an accented file from the host to the PowerBook.
- **The Finder reveal button.** "Open" in the browser sends `odoc` to
  the Finder with an alias to the downloads folder. Standard, and
  untested on metal; it is `kAENoReply` so it should not block, but that
  is reasoning rather than evidence.
- **The Hardware census module (slice 1).** New Workshop page: a passive
  census of this Mac, three Carbon-clean probes (gestalt full
  selector-table walk, video GDevice walk, volumes PBHGetVInfo), served
  over the new symmetric `census.request`/`census.report` family and
  shown in a split pane (probe list left, rows right). Builds clean
  (whole guest links; the ics# 133 chip icon compiles) and the host
  suite is green (242 tests), including a guest→host refusal round trip,
  the census.report fixture, and a mutation-checked serializer. **Not
  watched on the PowerBook.** Specific unknowns for the first metal pass:
  (1) two Data Browsers in one window — one is proven by the Files page,
  two side by side is not; (2) the full ~203-selector Gestalt walk
  paging 16 at a time; (3) the chip icon actually plotting from `ics#`
  133 rather than losing to a System family at that id. See
  docs/adding-a-workshop-module.md.
- **The host Hardware module — runs and reads the GUEST's census**
  (2026-07-22). A native macOS dossier: a `census` module in the sidebar
  (`CensusModel` + `CensusModuleView`), a probe list on the left and the
  selected probe's rows on the right, a Run Census sweep and per-probe
  rerun. It is a REQUESTER only — it asks the guest and displays the
  reports, following the `more`/`cursor` pagination to accumulate a
  probe's rows one page per request. The host probe registry
  (`CensusProbes.all`) is a copy of the guest's `k_probes[]` and the
  contract's `x-probes`; `CensusProbeRegistryTests` pins the set to the
  contract and the order to the guest, so a probe grown on one side and
  forgotten here fails a test. **Tested, not seen against a real guest.**
  `CensusModuleModelTests` drives the whole request→report path over the
  loopback listener with a scripted guest (pagination, cursor threading,
  outcome/note propagation, the full sweep, the disconnected guard, and
  rerun-replaces-not-appends); the SwiftUI view itself has not been run
  against a connected PowerBook.
- **The host does NOT serve its own census, by design.** The `census`
  family is symmetric in the contract, but the guest is the machine with
  hardware worth asking about; the host is the requester. When the guest
  sends the host a `census.request`, the host answers `refused` ("the
  host does not serve a census yet"). That is a deliberate, permanent-
  feeling asymmetry now, not a scheduled stub — a host self-census (IOKit/
  sysctl) is not planned as part of this feature.
- **The `ata` and `pccard` probes reach 68K-trap-only managers through a
  metal-proven Mixed Mode dispatch** (`census_trap.c`, 2026-07-22). The
  1400c's ATA Manager ($AAF1) and PC Card Manager ($AAF0) are trap-only
  — no CFM fragment, and `gestaltATAAttr` answers falsely absent — so a
  PowerPC Carbon app cannot import them. `census_trap.c` reaches them the
  way the parent project proved safe after four machine wedges (corpus
  `cis-metal-safe-mixed-mode-fix`): a hand-built M68K `RoutineDescriptor`
  so `CallUniversalProc` thunks PPC→68K, `CallUniversalProc` resolved from
  InterfaceLib and called **variadically** (a fixed-arg pointer leaves the
  args in registers → Type 1 bus error), and each thunk keeping its RTS
  return address on the stack. The mechanism itself is **metal-verified**
  by `spikes/census-trap`: selftest `$4242`, then real traps.
  - `pccard` (CSGetCardServicesInfo, selector 7) is **metal-verified** on
    the 1400c: CS 2.01, 4 sockets, Apple vendor string. Read-only, touches
    no socket or card, so it runs in the sweep. A card's own identity
    (its CIS) stays OUT until a gated design — the CIS is what froze the
    1400c historically (`pb1400-pccard-trap-only`).
  - `ata` (IDENTIFY DEVICE) reaches the manager and it answers `noErr`,
    but on the 1400c internal drive the IDENTIFY buffer comes back
    **empty** (metal, 2026-07-22 — buffer dumped all-zeros for the one
    device that answers, device id `$0000`). So the row honestly reports
    the device *present* without a model. A drive that fills the buffer
    decodes into model/capacity/firmware; that path is **builds-only**.
    Getting model/serial off *this* drive is a separate follow-up
    (`kATAMgrBusInquiry` enumeration, or `kATAMgrExecIO` issuing a raw
    IDENTIFY task file rather than the manager's empty DriveIdentify) —
    deferred, banked with the wins per Michelle's call.
  - The whole integrated page — `pccard`/`ata` running inside the census
    sweep and rail — is **tested and builds** here; it has **not** yet
    been metal-verified as a page (only the underlying trap calls have).
- **The `power` probe.** Slice-2 follow-up (2026-07-21). Carbon-clean
  (BatteryCount / GetScaledBatteryInfo, gated on `gestaltPowerMgrAttr`)
  and low-risk. Compiles, links and passes its decoder unit tests; has
  not run in the page on metal.
- **`network` and `software` probes, deferred as future modules**
  (decided 2026-07-21). Network (Open Transport interfaces and TCP/IP
  config) and installed-software (extensions and control panels with
  their `vers`) are both Carbon-clean and were scoped OUT of the census
  probe rail — Michelle's call was to grow them as their own future
  Workshop pages rather than more rows on Hardware. Not built; recorded
  so the intent is not lost.
- **The rail has no scroll bar.** At fourteen probes the hand-drawn probe
  rail fits the standard window (~371px of rail for 352px of rows at
  25px/row) but overflows below about the minimum window. `draw_rail` now
  clips the row list to the rail rect, so the tail truncates cleanly
  instead of painting over the button strip — but truncated rows are then
  unreachable. This is the point where the rail needs a real vertical
  scroll bar rather than shorter rows; it lands with the extension
  "witness" tier that adds the next probes.

## Reverse file streaming is bounded and verified on the machine

The 2026-07-24 reverse-path pass removed both whole-artifact buffers.
The guest now opens the source forks only after acceptance and emits one
bounded frame at a time, including MacBinary header/fork/padding
segments. The host writes each frame to a same-folder temporary file,
preflights free space, computes CRC-32 incrementally, sends batched
`file.progress`, verifies count and optional checksum, and only then
moves or stream-converts the result into place. Cancel, truncation,
checksum failure, write failure, and disconnect all delete the partial.

The native host suite exercises 256 KiB, 2 MiB, and 16 MiB payloads with
a fixed 32 KiB append bound, CRC/truncation/overrun/cancel cleanup,
atomic materialization, and text conversion across a chunk boundary.
Both guest send entry points have a source gate against whole-file
allocation, and the Retro68 guest build passes.

The bounded path is **metal-verified** on the PowerBook 1400c
(2026-07-24). A separately named guest on port 5252 preserved the
canonical pairing and persistent preferences. Data-fork pulls at 32767,
32768, 32769, 256 KiB, 1 MiB, and 4 MiB matched their generated content
and independent CRC-32. MacRoman/CR conversion and explicit MacBinary
data/resource-fork fidelity passed. Cancelling a 4 MiB pull removed its
host partial and left the session responsive. The guest process
partition was 6506 KB before and after; the 4 MiB pull added 2.23 MiB
peak host RSS and 1.94 MiB live malloc bytes.

Those numbers are bounded observations, not a transfer-rate guarantee.
The metal pass did not exceed 4 MiB, run longer than two minutes, mutate
a source during transfer, or measure guest free heap. It does not prove
rate hardening.

Reverse resume remains deliberately absent. A deployed guest supplies
no source identity before the receiver chooses an offset, so the host
cannot prove a retained partial belongs to the current source. An
interruption therefore deletes the partial and retries from zero. Adding
resume safely needs an additive guest-issued source token (and fixtures
for old peers), not an offset guessed from a filename and size.

## Structural work deferred on the host

A cleanup pass (2026-07-20) applied what was cheap and left three
extractions from `GuestListener.swift`, which is 2094 lines:

- `Session` is built with 28 `on...` closures, 25 of which only forward
  to a listener method. A `weak var owner` or a delegate protocol
  collapses about 180 lines, and adding a message stops meaning edits in
  four places.
- The share-serving block (~140 lines) touches only `share`, `session`
  and `state`. It is a file server living inside a listener.
- The outbound write path (~400 lines) shares one invariant — nothing
  may write to the connection while a bulk frame is half-written —
  currently enforced by a flag two unrelated methods must remember to
  check. As its own type the flag cannot be forgotten.

These were skipped on purpose. Two reviews proposed DIFFERENT
reorganisations of the same file, and the receiving-half work above
implies a third (one transfer sink rather than three accumulators).
Doing any one now makes the others harder, and only the receiving half
has a consequence beyond tidiness. Whoever takes that should take these
with it.

## V1 host product work is planned, not implemented

The [NOW V1 host product roadmap](plans/2026-07-24-002-feat-now-v1-host-product-roadmap-plan.md)
starts only after the optional MCP companion V0 is complete. It commits a
persistent target catalog and host-side improvements to Files, Processes,
Software, the menu bar, quit policy, and Settings while retaining the
current guest-dials-host, one-port, single-session transport.

V1 explicitly defers a guest listener, multi-session runtime, mobile
transport, and shared protocol service. Any common-protocol extraction
waits for CodeKitten's separate listener, pairing/security,
health/latency, recovery, cooperative-loop, and adversarial multi-peer
proof and would begin in another worktree. The exact target-switcher
information architecture, pairing-conflict UX, thumbnail and history
retention, inventory analyses, local-browser defaults, and remembered
module-state policies remain intentionally open.

## MCP V0.5 guest Files command seam has a tested staged-upload slice

The approved
[NOW MCP V0.5 guest-files roadmap](plans/2026-07-24-003-feat-now-mcp-v0-5-files-command-roadmap-plan.md)
now has its first host-owned command slices: an explicit, persisted and versioned
root-relative `guestRoot` policy; canonical HFS path validation; capability,
one-page listing, and bounded exact-stat commands; typed receipts; and normal
host audit lines. It also has a create-only staged upload command: private
disk-aware reservation, ordered 8 KiB-or-smaller chunks, SHA-256 sealing, a
file-backed sender through the existing transfer lane, and bounded progress,
reservation, finalization, integrity, and cleanup evidence. No host path crosses
the API. The destination parent must already exist: this slice does not
implicitly implement `mkdir`. The existing private local socket and
client-launched stdio companion
project those completed commands; download, mkdir, overwrite, move, delete,
tree deployment, and prune remain unavailable.

The read-only slice composes the existing `file.list` exchange and therefore
adds no guest message or guest code. It is **tested** against fake paired
sessions, including root escape, invalid policy recovery, empty and populated
listings, paging bounds, stale sessions, concurrency, and host-product
noninterference, plus local-schema and stdio validation. A bounded
2026-07-24 PowerBook 1400c acceptance verified capability discovery, two
16-entry root pages with cursors 17 and 33, and exact stat. The first live
page exposed one legal HFS name containing control bytes; path validation now
keeps those exact MacRoman names addressable, rejects only untransportable
NUL, and escapes them in audit text. Download and every broader mutation remain
unverified and unavailable.

The staged-upload slice is **tested**, including host-space refusal, ordered
offsets, integrity failure cleanup, dead-process orphan recovery, root escape,
unavailable/stale sessions, replay, concurrent commit, malformed local/MCP
requests and MacBinary, strict guest completion evidence, late-collision
preservation, stale-accept invalidation, cleanup-needed recovery, guest refusal
evidence, and unchanged one-at-a-time transfer ownership. Host staging and
outbound reads use bounded off-UI-actor disk I/O. The host builds and the
Retro68 guest cross-builds cleanly. It is
**not metal-verified**: no new disposable upload was sent to the PowerBook in
this slice, so real-volume reservation values, Finder-visible finalization,
fork/type/creator fidelity, interruption cleanup, and live throughput remain
open.

The reconciliation also exposed two pre-metal hardening gaps. Host byte
reservation does not yet cap the number of active stages, so repeated
zero-byte or tiny begins can retain bounded-lifetime records without consuming
meaningful byte quota. A stage is bound to session and policy version but not
to an opaque active-share identity, so a human share change between begin and
commit is not yet a typed stale condition. Both must be resolved and tested
before staged upload advances to attended PowerBook acceptance.

Invalid persisted `guestRoot` recovery currently rejects the malformed value,
logs the event, and restores the approved share-root default. That is the
implemented and tested behavior, but it can broaden a future narrowed policy.
Fail-closed recovery versus explicit rebinding remains a policy decision before
an Integrations UI can configure narrower roots.

The reverse-streaming prerequisite is now integrated: the guest reads outbound
forks one bounded frame at a time, and the host receives into a private disk
sink with progress, length/CRC validation, interruption cleanup, and atomic
finalization. This does not expose arbitrary download. That capability remains
gated on a typed NOW command, root/size policy, deterministic receipts and
audit, and an explicit MCP projection. Reverse resume also remains separately
deferred pending a contract-first guest source-identity rule.

The combined V0.5 tree—root-scoped capability/list/stat, create-only staged
upload, and reverse streaming—has been reconciled and promoted to local
`main`. The read-only commands and reverse transport carry the bounded metal
evidence stated above; staged upload is implemented and tested but remains
unrun on the PowerBook. This integration did not add download, mkdir,
overwrite, move, delete, tree deployment, prune, broad host filesystem access,
plugin infrastructure, resume, or transfer-rate hardening.

Mutation is gated separately on guest-side revalidation of an opaque file
observation. Listings now carry a responder-generated opaque catalog identity,
and the host mints short-lived session/root-bound observation references, but
no mutation accepts them yet. The current move/Trash/restore/mkdir messages
still act by path alone; host-only precondition checks would permit a changed
item to be acted on between check and use. The exact guest-side revalidation
field and command behavior remain the next contract-first mutation gate. Tree
deployment and mandatory-preview manifest prune follow only after it.

## The companion against a partial guest: capability-derived, unverified on metal

NOW has two guests now, and the agent-integration companion was written
against one of them. It is now guest-agnostic — but only two of its
projections have ever been watched against a guest that implements part of
the contract, and neither of those was the new one.

**What changed.** A twelfth tool, `now_session_capabilities`, reports what
the connected guest can do and therefore which tools are available against
it. The derivation has exactly two sources and neither is identity:

- **Commands** come from `help`, which both guests serve on the wire, one
  fetch per connection. It is the same live source the host console's Tab
  completion already uses, so a guest that grows a verb becomes usable
  without a companion release.
- **Message families** are not in any command table — that gap is how `ps`
  shipped wire-only here — so they are established by asking. Every family
  request the host makes records its own outcome as it settles, and the
  report additionally probes the read-only families it can settle cheaply
  (`process.list`, `file.list`). It never probes a family whose smallest
  request changes the guest (`process.quit`, `file.put`), and it probes
  `software.list` only on request because that first page is a whole-volume
  sweep. Those stay **`unproven`**, a third state that explicitly does not
  mean "no" — collapsing it into "no" is how a report would start
  understating a machine it never asked.

`AgentIntegrationCapabilityTests` fails the build if any deciding file in
the companion surface reads a hello field or names a guest. That guard
exists because the same mistake already happened in the other direction:
`MetalQuitTests` derived a guest's abilities from its hello name and went
stale the same afternoon that guest grew `process.list`, understating its
own evidence with nothing failing.

**The refusal path, which was half-built.** `GuestListener.recordGuestError`
claimed to route a guest `error` to "every waiter" and routed three of the
six maps. Process listings, software listings and process results — exactly
what a partial guest refuses — still sat on their 15 s and 30 s watchdogs
and arrived with `timeout` instead of the guest's reason. All six are routed
now. The mutation that removed three of them reproduced the original
symptom: 15 s, 30 s and 15 s waits, each arriving as `timeout`.

That mutation also exposed a hazard in the first version of the fix: it
cleared the watchdog before routing, so a waiter kind the function forgot
would have had neither an answer nor a timeout and would have hung forever
rather than merely slowly. The watchdog is now cleared only when a waiter
was actually answered.

**What this does NOT change.** No safety property moved. Opaque
session-bound references, revalidation before use, one-use receipts,
create-only uploads, and the rule that no guest path or PSN crosses the
adapter are all as they were. In particular `now_request_quit` was **not**
made to work against a guest without `process.quit`: the opaque-reference
and PSN-revalidation model has nothing to stand on there, so the tool is
unavailable in typed form and that is the whole answer.

**Unverified.** All of it is **tested** here — twelve projections, 490 host
tests, both xcodebuild configurations — and none of it is
**metal-verified**. Specifically open:

- No capability report has been taken against the PowerBook 180c. The
  fake partial guest in the tests answers `not-implemented` the way
  `guest68k/src/wire68.c` does, but a fake guest proves the host's half
  twice and the guest's half not at all.
- `now_list_processes` against NOW-68K is the tool this arc claims is newly
  possible, and it has not been called against that machine. The 68K's
  `process.listing` does carry PSNs, so references will be minted there —
  what happens when one is offered to `now_request_quit` and the guest
  refuses `process.quit` is tested against a fake and unobserved for real.
- The `help` command table parse is exercised against a synthetic table.
  Neither guest's real `help` output has been fed to the ledger.
- `software.list` probing is opt-in on the stated grounds that a guest which
  does not implement it refuses instantly. That asymmetry is reasoning, not
  a measurement; the ~4 s figure for a guest that does implement it comes
  from the earlier 1400c catalog sweeps, not from this code path.
- The local protocol moved to v6 and the capabilities call gets a 90 s
  response window because it may wait on several guest-side watchdogs in
  turn. That number is a sum of the existing bounds, not an observed one.

## NOW-68K: what has not been on the machine

The 68K guest for the PowerBook 180c is metal-proven for dial, handshake,
keepalive, health, logging, clean quit, `launch` and the `gone` path of
`quit`. Everything below has been built and cross-compiled and has never
run **on a Macintosh** — some of it now runs under host-compiled native
tests, which is a different and lesser thing, and each entry says which.
Listed because "we shipped it and here is what we still do not know" is
the useful half.

- **The interactive console is a SECOND WINDOW, by decision, and that is
  a standing exception rather than drift** (2026-07-25). Every other
  statement this project makes about guest UI says the opposite: the
  Carbon guest's rule is that a new feature is a Workshop module and
  never a window (`docs/adding-a-workshop-module.md`), `window.h` and
  this README both describe NOW-68K as one page with no tabs, and
  `guest68k.r`'s `SIZE` comment agrees. Michelle asked for the console
  in its own window on this guest, and it is implemented that way.

  The reason it is defensible: the main window's console pane is a **log
  viewer** — it shows what the wire and the status line said, it takes no
  input, and this change leaves it exactly as it was. An interactive
  console needs a keyboard focus, an edit field, an insertion point and a
  key-by-key event path, and the one 512×300 page already carries three
  connection fields, two controls, a status line and a health readout.
  Making it carry both would mean shrinking the log viewer to a few rows
  or growing the window past the 180c's 640×480 panel.

  **The next feature is still a page on the main window** unless someone
  writes down a reason this good. `conwin.h`'s header comment carries the
  same paragraph so it is read by whoever edits the code, not only by
  whoever reads the ledger.

- **The console runs the command table, not a copy of it — and only the
  seam is tested** (2026-07-25). `commands68.c` used to run a command and
  emit its `command.result` JSON in one pass, which is fine with one
  reader and impossible with two. It now fills an `N68CmdResult` (the
  facts, no formatting) via `now68k_commands_run()`, and
  `guest68k/src/n68_cmdresult.c` holds **both** renderers side by side:
  JSON for the wire, text for the console. Adding a command means one
  case in `now68k_commands_run` and nothing else — it appears in both
  places in the same commit. This is deliberately aimed at the parent
  corpus finding `two-halves-never-met-in-a-test`.

  What is proven: `guest68k/tests/test_cmdresult.c` (50 checks) pins the
  JSON bytes for all three reply shapes against literals written out in
  full — not assembled from the renderer's own pieces — and walks six
  outcomes through both renderers asserting they never disagree about the
  `ok` bit or the error code. `guest68k/tests/test_history.c` (37 checks)
  covers the arrow-key history, including the two cases that are wrong in
  most first attempts: "nothing further that way" must leave the field
  alone rather than clear it, and a walk must not re-capture a recalled
  entry as the half-typed line.

  **The wire did not change, and that was checked differentially rather
  than assumed.** A scratch harness ran the *old* `finish_error` /
  `finish_ok_row1` / `finish_ok_row2`, extracted verbatim from `4a7703f`,
  beside the new renderer over 1,092 combinations of reply shape ×
  message × error code × output capacity (512 down to 0, including the
  caps where the compact fallback fires): **0 differences**, in both the
  bytes and the returned length. The harness first reported 37, which was
  a real finding — the new `N68CmdResult` copies the message into a fixed
  160-byte member where the old builders took an unbounded pointer, so a
  message longer than 159 bytes now truncates instead of falling back.
  That case is structurally unreachable (`kDetailCap` is *defined as*
  `kN68CmdTextCap`, and every message source is one of those buffers),
  and it is written down in `n68_cmdresult.h` rather than left for
  someone to rediscover.

  What is **not** proven anywhere: that `launch` and `quit` behave the
  same when driven from the console as from the wire. Both paths call the
  same `now68k_commands_run`, which is the point of the design, but no
  test drives the console path (it needs a Toolbox) and no metal run has
  done it by hand. That is the first thing to check on the machine.

- **The console has never run on the PowerBook.** It builds under the 68K
  toolchain at `-O2 -Wall -Wextra -Werror` and its Toolbox-free halves
  pass their native tests; nothing more. Specifically unproven on metal:

  - **Up/Down history.** The interception happens before `TEKey` because
    TextEdit given `kUpArrowCharCode`/`kDownArrowCharCode` moves the
    insertion point between display lines, which is a no-op in a one-line
    field. That reading is verified-document (Events.h constants read
    from the installed Universal Interfaces: up 30, down 31), not
    verified-target.
  - **Left/right cursor movement**, which is deliberately handed to
    `TEKey` rather than reimplemented. Same evidence level.
  - **Option-Up/Option-Down scrollback.** `kPageUpCharCode` /
    `kPageDownCharCode` (11, 12) are also accepted, but the 180c's
    built-in keyboard has no dedicated page keys, so Option-arrow is the
    binding that has to work on the target and it has never been pressed
    there. Command-arrow was not available: `MenuKey` in `main.c`
    consumes every Command chord first.
  - **The two-window event routing.** `main.c` now routes update,
    activate, click and key events by the window they name rather than
    assuming one exists. A mistake here does not crash — it draws the
    wrong window or types into the wrong field — and nothing off-metal
    catches that.
  - **The memory cost — measured at link time, not on the machine.**
    Against `4a7703f` built the same way, the console and the seam it
    needed cost **text +4,428 and bss +10,954 = +15,382 bytes, +4.0% of
    the 384 KB partition** (`m68k-apple-macos-size` over the object
    files). The BSS is an 8.2 KB scrollback ring plus a 2.3 KB history,
    beside `window.c`'s existing 9,186 bytes. What that does NOT include,
    and what nobody has sized: the `WindowRecord` and the `TERec` plus
    its text Handle that the Toolbox allocates out of the application
    heap when the window is opened. With ~231 KB free that is very
    probably fine and it has not been watched.

- **The console cannot copy text out, and its scrollback is 32 lines.**
  The output pane is drawn text, not a `TERec`, so a click in it does
  nothing and there is no way to get a result off the machine except by
  reading it. The 32-line ring is `n68_console_ring.h`'s compile-time
  capacity, shared with the main window's log viewer; Option-arrow paging
  makes all 32 reachable, but a long `quit` transcript still ages out.
  Both are deliberate: a selectable output pane means a second `TERec`
  and its text Handle, and a deeper ring is 256 bytes a line.

- **The declined quit — METAL-VERIFIED 2026-07-25.** The whole re-list
  composition exists so a target that stops to ask about an unsaved
  document answers `ok:false` / `quit-declined` rather than claiming
  success, and it had never run anywhere. On the 180c, against a
  TeachText holding typed-but-unsaved text:
  `[quit-declined] quit: TeachText is still running - declined, or busy`.
  `MetalQuitTests :: testADirtyDocumentDeclinesAndSaysSo`
  (`NOW_QUIT_DIRTY=1 NOW_QUIT_NO_LAUNCH=1 NOW_QUIT_APP=TeachText`).

  Two things the run taught that the design had not:

  **`quit-ambiguous` also ran, by accident, and was right.** The test
  launches its victim before quitting it; against a TeachText a human had
  already opened, that produced a second copy, and `quit` refused the
  whole request rather than guess which one was meant. Correct behaviour,
  never previously exercised — and a test that manufactured the very
  ambiguity it then failed on. Hence `NOW_QUIT_NO_LAUNCH`.

  **The 68K re-check WAS weaker than the sentence "still running"
  suggests** — true when written, and fixed since by `process.list`. With no `process.list`, confirmation is a second `quit`
  through the same subsystem, and it came back "asked TeachText; not
  confirmed (wait_ticks <= 0)". The assertion that holds is only that the
  target did not answer `not-running`. That is real evidence and it is
  not corroboration; the run says so in its own output.
- **The farewell — METAL-VERIFIED 2026-07-25.** A menu quit on the 180c
  produced `now-68k is shutting down` on the host, which is the bye path;
  the abortive one reads `Connection lost`. `Metal68KTests
  :: testTheFarewellIsOrderly` (`NOW_68K_BYE=1`, human at the keyboard,
  because the guest refuses to quit itself).
- **The redial — METAL-VERIFIED 2026-07-25.** Host dropped mid-session
  and restarted; the guest redialled and re-helloed in 15.5 s.
  `Metal68KTests :: testTheGuestComesBackAfterTheHostGoesAway`
  (`NOW_68K_REDIAL=1`; the cadence is human-armed by design, so the
  checkbox is part of the test's precondition). The reconnect
  re-handshakes, as the contract requires.
- **Oversized control frames — now tested, still never sent.** The
  skip-not-fatal path (a frame larger than our 4 KB buffer but inside the
  protocol's 32 KB) is covered off-metal since 2026-07-25: the reader
  moved to `guest68k/src/n68_reader.c` behind an ops table, and
  `guest68k/tests/test_reader.c` drives it through a scripted transport —
  the oversized frame is skipped **and the next frame still parses**,
  which is the actual claim, under four chunkings plus a stall at every
  one of ~380 byte offsets. What that does not prove: **nothing in NOW
  has ever sent one.** The host does not produce a control frame over
  4 KB, so the reader's contract is proven and the host's honouring of it
  is not.
- **FIXED 2026-07-25 — `launch` of a name not on the disk never answered.**
  Watched broken on the 180c three times (60 s, 150 s, 300 s), then
  watched fixed on the same machine: `NOW-68K 0.6` answers in **2.5 s**
  with "nothing named X is on the startup volume". Kept in full below
  because the diagnosis was wrong twice before it was right, and the
  wrong turns are the reusable part.

  The cause was one limit stated three times in two units, smallest
  winning: the builder's buffer 512 (a literal in `wire68.c`), the
  module's documented floor 320 (`commands68.h` prose), the outbound slot
  160 (sized by a comment reading "hello (~110), ping (~30), or an error
  reply (~95)" — true when this guest had no commands, never revisited
  when `launch` and `quit` arrived). The reply built correctly at 166
  bytes; `commands68.c`'s compact fallback never fired, because from the
  builder's side nothing was wrong; the slot dropped it. Both numbers now
  come from `commands68.h` (`NOW68K_COMMAND_RESULT_CAP`), +704 bytes BSS.

  The original diagnosis, retained:

  What the guest's own log says: `cmd: launch refused -50`, then
  `command.result dropped, outbound queue full`. So the search RAN and
  RETURNED — `launch` is not hanging — and the reply was built and then
  thrown away on the way to the wire.

  Two theories died on the way to that, both worth keeping because each
  cost a metal run. **(1) The guest goes deaf inside `PBCatSearchSync`
  and writes its reply to a socket the host's idle timeout already
  killed.** Refuted: the metal test now watches the wire during the
  search, and it stayed up for the whole 150 s with keepalives answered —
  `yield_ticks(0)` pumps between slices exactly as intended. **(2) The
  reply is too long for the 160-byte outbound slot.** "Refuted" by
  reading `commands68.c`'s compact fallback — and this refutation was
  itself wrong, which is the lesson worth keeping. The fallback exists
  and would have fitted; it never ran, because the builder had 512 bytes
  and succeeded. Reading one half of a size mismatch and concluding the
  other half is fine is how the mismatch survived in the first place.

  What is actually established is narrower: `enqueue_control_send`
  refused the payload, and its 0 return covers **two** different failures
  — payload too big for a slot, and both slots busy
  (`kWireOutQueueDepth` is 2) — which every caller logged with the same
  sentence. That is why the log could not settle it. 0.5 logged them
  apart, and the very next run on the machine said it outright:
  `wire: send dropped - payload too big for a slot, bytes 166`.

  **The method note, which is the transferable part.** Two theories, two
  metal runs, both wrong, and the thing that ended it was not a better
  theory — it was making the log able to tell two causes apart. One
  message covering two failures is what turned a five-minute question
  into an hour, and the fix for that was three lines. When a log cannot
  distinguish the candidates, instrument before theorising again.

- **`launch` at scale.** The catalog search is double-bounded on purpose —
  a whole-volume Finder search has hard-wedged this fleet before — but it
  has only resolved an application sitting in an obvious place. The
  truncation branch is still unproven: the one metal attempt at it never
  got its answer back (above), so whether the bound reports honestly is
  exactly as unknown as it was this morning.
- **The confirm wait under load.** It yields with an event mask of zero and
  pumps the wire each pass, with a re-entrancy guard so a command arriving
  mid-wait cannot recurse into it. Neither the pump nor the guard has been
  observed under a second concurrent request.

- **`error` has a fixture and has still never been emitted.** (2026-07-25,
  closing the old "`hello`, `ping` and `error` are not conformance-checked"
  entry.) All three now have hand-written fixtures in
  `GuestWireFixtureTests`, derived by compiling the guest's own emitters
  with the host `cc` rather than by reading the C — a fixture written from
  the decoder's side would test one half twice. `hello` and `ping` have
  also run live against a real host. `error` has not, anywhere: reaching
  it needs the host to send a live-state message type NOW-68K does not
  handle, which nothing does today. The fixture is a claim about
  `send_error_reply`, not evidence from a capture. Its negative-id echo is
  reachable in principle and has never been observed.

  Worth correcting in the same breath, because it was written down wrong
  here: `unknown-command` and `refused` are **not** `error` shapes on this
  guest. `unknown-command` is a `command.result` error object and
  `refused` a `census.report` outcome; `wire68.c` routes both away from
  `send_error_reply` on purpose, because the wrong envelope leaves a
  different waiter blocked. The `error` emitter has one code,
  `not-implemented`, in two shapes. `command.result` is the one message
  still in the cannot-check set with no fixture at all.

- **Three oddities in the 68K frame reader, found and deliberately not
  fixed** (2026-07-25, during the extraction to `n68_reader.c`). The
  extraction was kept pure because the code is metal-proven and no
  PowerBook was on the LAN to re-verify a behaviour change against; these
  are the things a fix would have quietly changed. (1) `RS_HEADER` and
  `RS_BODY` return on a short read while `RS_SKIP` loops and calls `take`
  once more — harmless, one no-op call per drained bulk frame, and it is
  why `n68_reader_drain()` means "one event-loop pass" rather than "read
  everything available". (2) `handle_control_message`'s empty-frame branch
  is dead: the reader short-circuits zero-length control frames before
  dispatch, so there are two copies of that log string and one cannot
  fire. (3) `frames_in` counts skipped frames but not the fatal
  oversized one, so it means "frames whose header we accepted" rather than
  "frames received" — probably intended, but the stat's name does not say
  so.

- **The extraction is METAL-VERIFIED (2026-07-25).** It was
  argued-faithful only — structure, call order and a clean `-O2 -Werror`
  build — until `NOW-68K 0.4` ran on the 180c: handshake, one
  guest-driven keepalive answered after the 30 s silence, and a control
  frame round trip afterwards. `Metal68KTests
  :: testTheWireStillWorksAfterTheReaderExtraction`. The version bump is
  what makes it attributable — 0.3 predates the extraction and the wire
  carries no other way to tell two builds apart.

Both of the things that were known-wrong here are fixed (2026-07-25):

- **The metal gate no longer reads green when it never ran.** Under
  `NOW_METAL=1`, the port being held and no Mac dialling in are two
  distinct failures with distinct messages rather than skips; the only
  skips left are the opt-ins themselves (`NOW_METAL`, and `NOW_QUIT_DIRTY`
  for the case that needs a human at the keyboard). Guest identity now
  comes from the hello handshake, and where NOW-68K cannot serve the
  independent `process.list` confirmation the run says **WEAKER** out loud
  in its output and in every failure string. Watched directly: unset skips
  3 clean, `NOW_METAL=1` with nothing dialling in fails at 120.1 s, and a
  deliberately lying guest is caught on both the strong and the weak path.
  It is **tested**, not metal-verified — the guests were simulated by
  `tools/fakeguest.py`, which is a claim about the harness and never about
  a guest.

- **The contract's reconnect clause is amended.** Cadence is guest policy,
  capped backoff is the reference default, and the one surviving
  obligation is a ≥1 s floor between dial attempts. No revision bump:
  nothing changes shape and an older peer cannot tell. NOW-68K already
  clamped to the floor; the PowerPC guest reached it only incidentally
  through a prefs range check and now enforces it at the wire.

## vprobe on the 180c: measured, and what it does not cover

`vprobe` is **metal-verified** on the PB180c (2026-07-25, `NOW-68K 0.16`):
ran in 3.0 s, whole-frame on every row, answered in one frame, and the
wire survived it. Numbers and their reading:
[vram-readout-68k.md](vram-readout-68k.md).

The hypothesis it was built around resolved cleanly and in the direction
that costs us: `MOVEM.L` does **not** burst on this machine (6% over
unrolled `move.l`), and the reread row explains it — the VRAM is uncached,
and burst fills are cache-line fills. The unexpected result is a **~16-bit
width ceiling**: 8→16-bit more than doubles the rate, 16→32-bit buys 12%.
The 1400c's "the bus charges per transaction" does not transfer.

Unverified, and worth naming because the numbers will get quoted:

- **The CopyBits row is fifteen banded calls, not one blit.** Best raw
  beats it 1.54×, which is the opposite of the 1400c result — but an
  unknown share of that gap is per-call overhead. It is a floor on the
  margin, not the margin.
- **Nothing at a non-native depth was measured.** That is precisely where
  the 1400c's raw-vs-CopyBits margin evaporated, so the one number most
  likely to mislead a future capture stage is the one not taken.
- **`fmove.d` is content-dependent** — extended conversion, and a 68882
  handles denormals slowly — so it is what an FPU reader costs on that
  screen, not a bus figure.
- **`Microseconds()` has no availability gate.** Its trap is assumed
  present on 7.1 from documentation; a wrong availability test fails in
  the wrong direction (disabling vprobe where it works), so none was
  added. It answered with 37 µs resolution on the 180c, which settles the
  assumption for this machine and no other.
- **`fmovem.x` was not measured** — no conversion, no exception path, and
  the one row that might have rescued the FPU result. The reply cannot
  carry a 17th row; the honest next step if the `fmove.d` number ever
  looks wrong.

## `screenshot` on NOW-68K: metal-verified, and what it measured

`screenshot` slice one is implemented on NOW-68K
(`shot68.c` / `n68_shot.c`, contract-declared already — nothing in
`contract/asyncapi.yaml` changed to add it). It captures the screen,
encodes a packed 8-bit PICT, writes it to the guest's own desktop as
`Screenshot YYYY-MM-DD HH.MM.SS` (type `PICT`, creator `ttxt`), and
returns the measurement rows. No pixels cross the wire; that is slice
two and belongs to the bulk-send work.

**Metal-verified on the PowerBook 180c** (System 7.1, 640x480x8, 4 MB,
2026-07-26) — deployed as a spike (`NOW-68K shot 0.14+shot`, its own
folder and its own dev-settings file so the current build's 5252 was never
touched), launched by asking the running build to `launch` it by path, and
driven over the wire on 5050. Three captures: one `--no-save` and two
saves. Both files landed on the guest's desktop with distinct names, and
one was pulled back over FTP and **decoded here** — 640x480, `pixelSize`
8, 256-entry colour table, and the 180c's own screen, correctly. The
capture ran inside the partition with room to spare (the guest reported
`free=489K max=179K` at the time; the capture's ceiling is ~21 KB).

**The numbers, which are the point of the slice:**

| | 180c (metal) | notes |
|---|---|---|
| read | 187–227 ms | matches vprobe's ~200 ms banded CopyBits |
| pack | 431–542 ms | **the unknown this slice existed to measure** |
| write | ~800 ms | 65 KB to the internal disk |
| output | 65,648–65,692 B | full 640x480x8 frame |
| ratio | **4.7:1** | |

**Packing costs about 2.4x the read, not 10x.** The worst case in
`shot68.c` was written assuming up to 10x and is therefore conservative by
a wide margin: a whole capture is ~1.5 s wall clock, against a ~65 s
death timer. And **4.7:1 on a real desktop means a frame is 65 KB**, not
300 — which is the number slice two turns on, and it is a far friendlier
number than the emulator's 2.2:1 suggested (the emulator's desktop was
busier; a real 180c desktop packs better).

**The 180c's clock is not set.** Both captures were named
`Screenshot 1904-01-01 23.49.0x` — the Mac epoch, which is what `GetTime`
returned. The naming code is doing the right thing with the wrong input,
and the per-second collision guard is carrying more weight than expected
on this machine: every session after a restart starts near the same
instant, so the tick-stamped fallback is the thing keeping shots from
overwriting each other. Setting the PowerBook's clock is the real fix.

**Also verified on the Quadra 800 emulator** (OS 8.1, 640x480x8, 2026-07-25):
run from the guest's own console, three captures in one session
(`--no-save`, then two saves), the app survived all three, both files
landed with distinct names, and one of them was pulled off the disk image
with `hfsutils` and **decoded on the host** — 640x480, `pixelSize` 8, a
256-entry colour table, and pixel-for-pixel the screen at the moment of
the command with the cursor shielded out of it. That is the strongest
statement available short of hardware: the picture is not merely a file,
it is the right picture.

**The emulator settled nothing about TIME, and said so at the time.** It
reported `read 0 ms, pack 23 ms, write 8 ms` — a 68040 with a
host-memory framebuffer. Its 2.2:1 ratio also did not carry: the 180c's
own desktop packs to 4.7:1. Both were correctly labelled as proving the
code RUNS and produces the right picture, and nothing more; the metal run
is what produced numbers.

Still unverified, and named because these are the ones that will bite:

- **Only one screen has been captured, and it was quiet.** 4.7:1 is a
  desktop with two windows on it. A screen full of dithered photographic
  content will pack far worse, and nothing here establishes a floor.
- **The timing split is a difference of two passes.** `read_ms` is a real
  banded-CopyBits measurement (vprobe's, on vprobe's band); `encode_ms`
  is the recording pass minus the read minus the write, so it carries
  both passes' noise. On a machine where packing dominates that is fine;
  if the two ever land close together the number degrades to noise, and
  it is floored at zero rather than allowed to go negative.
- **8-bit only, by refusal.** A screen at any other depth is declined
  with a sentence naming the depth. `CopyBits` would convert for free but
  the 1400c showed a non-native path eats the whole margin
  (`vram-readout.md`), and nobody has measured that here.
- **The capture does not pump the wire.** Bounded by arithmetic at ~10 s
  worst case against the host's ~65 s death timer (`kShotWorstCaseMs`) —
  measured at ~1.5 s, so the bound is conservative by ~7x,
  deliberately, because a pumped event can move a window mid-recording
  and tear the picture. If a real 180c ever exceeds that bound the fix is
  to band the PUMP, not the picture.

One refactor rode along with this and is worth naming: **`vprobe`'s walk
to the framebuffer and its one-band GWorld moved out of `vprobe68.c` into
`screen68.c`**, unchanged, because `screenshot` needed the same three
answers and a second copy of a fail-closed geometry check is one copy
that falls behind. `vprobe` is metal-verified on the 180c; the moved
version is not, and the move was verbatim rather than a rewrite, but
"verbatim" is a claim about the diff and not about the machine.

### The banded recording that had to be abandoned — worth knowing

The first implementation recorded the picture **a band at a time** into a
640x32 offscreen port, which is the obvious way to bound memory and is
what the task was scoped around. On System 8.1 it **killed the
application on the third band, every time**, while QuickDraw was writing
that band's colour table. It was bisected on the emulator against the
guest's own log:

- not the file: `--no-save` (no `FSWrite` at all) died identically;
- not the geometry: removing `SetOrigin` and recording every band at the
  port's top died identically;
- not the partition: 2 MB instead of 384 KB died identically;
- not the put proc: it was entered correctly and had already streamed
  6.7 KB across two good bands, and the partial PICT recovered from the
  disk image decodes as two valid `PackBitsRect` opcodes.

The cure was to stop banding the *destination* at all, which the design
did not need: **a picture being recorded is never drawn into.** QuickDraw
diverts the bottleneck and hands the source pixels to the put proc, so
the destination port supplies only a coordinate space, a depth and a clip
— and the Window Manager's colour port is all three for free. One
recording `CopyBits` over the whole frame, one colour table instead of
fifteen, ~21 KB ceiling, and none of the above. The root cause inside
QuickDraw was never identified; if anyone reopens banded recording, that
is the thing to find first.

## The 180c, 2026-07-25 evening: everything automated is green

The display came back (a via that wiggled against its pad, found by
beeping continuity, reflowed). `NOW-68K 0.14` landed itself by handoff and
every automated gate passed against it: the reader extraction, `ps`, the
bounded `launch` search, the redial, the `error` refusal, the
oversized-frame skip with frame sync surviving, two overlapping requests,
and `quit`'s whole outcome table including the self-refusal.

**`quit`'s confirmation on this guest is now STRONG.** With
`process.list` served, a disappearance is re-checked against a different
code path instead of by re-asking `quit`. `MetalQuitTests` probes for the
capability rather than deriving it from the hello name, because deriving
it meant the file kept understating its own evidence the moment the guest
grew.

**Three defects were in the GATES, not the guest**, and the worst of them
had been reading green:

- The self-refusal case quit `now68k-guest` — the CMake target name —
  while a deployed build runs as `NOW-68K 0.14`, its MacBinary name. It
  asked to quit a process that does not exist, got "nothing named that is
  running", asserted nothing, and passed. It had never once tested the
  behaviour it is named for.
- The harness raced its own teardown: `stop()` reports `.idle` while
  `NWListener` cancels asynchronously, so the next test in a suite bound a
  port its predecessor still held. Two of five failing while three passed
  against the same live guest is a race, not a busy port.
- The strength banner was printed before the capability probe ran, so it
  announced the strength assumed rather than the one measured.

Understating evidence is the same species of dishonesty as overstating it,
and it is harder to catch because nothing fails.

## The console, and what it is not verified to do

- **NOW-68K's interactive console is METAL-VERIFIED** (2026-07-25,
  evening). Watched by a human at the 180c after its display was
  repaired: `ps`, `help` (rendering the shared command table plus the
  console-local verbs), and **up/down history** — the last of which had
  never been observed anywhere, on metal or in an emulator, and was the
  feature the console was asked for.

  The two redraw bugs found in the q800 emulator earlier the same day
  were one cause: `draw_output` and `draw_input` drew without erasing
  first, and the Window Manager erases only what it newly exposes, so a
  rectangle the app invalidates itself keeps its old pixels. The command
  stayed on screen after Return looking unrun — inviting a second Return,
  which for `quit` or `launch` repeats a real action — and `clear`
  appeared broken while working perfectly. Neither was reachable by a
  native test; they are pixels.

- **The console pane cannot be copied out.** A click in the output pane
  does nothing on purpose: it is drawn text, not a TERec. Reading a long
  result means retyping it. Real gap, not a decision anyone would defend
  on its merits.

## Rough edges

**A console line reaching a guest older than `line` is misread, not
refused.** Such a guest ignores the field and runs the command bare, so
`ls Lab:Code` lists the share root and says nothing about the path it
dropped. The field is additive by the contract's own rules — an unknown
field is ignored — and this is the one place that politeness costs
honesty. Both guests in this tree read it; the exposure is an older
binary still sitting on a machine, which is a realistic state for the
PowerBook. Stated beside the field in `contract/asyncapi.yaml` rather
than only here.

**No `help`, no completion.** Tab completion is the guest's own answer,
so a guest that does not serve `help` has none — deliberately, because a
host-side fallback list is exactly what was removed. It does mean a shell
that offers nothing until the guest is updated, and `help` there answers
`unknown-command`, which reads as an error rather than as "this build is
old".

**Reverse streaming still needs longer and adversarial metal evidence.**
The PowerBook ladder now covers direct data-fork and MacBinary pulls
through 4 MiB plus cancellation. It does not yet cover a transfer longer
than two minutes, a file larger than 4 MiB, source mutation during a
pull, or direct guest free-heap measurement.

**The build stamp can read a few minutes early.** CMake touches
`build_stamp.c` at the END of a build, so the stamp reflects when that
file was last compiled rather than when the binary was linked. It has
already caused one "is this the build I think it is?" moment, and the
verification ritual depends on it. `touch guest/src/build_stamp.c`
before a build forces it current.

**The wire fixtures are transcribed by hand.** `GuestWireFixtureTests`
holds copies of the strings `wire.c` emits. `GuestWireConformanceTests`
reads the source directly and needs no maintenance, but it cannot
reconstruct the three messages built across several `snprintf` calls
(`file.listing`, `file.result`, `command.result`), which is why the
hand-written copies exist. They can drift.

**The browser stops at 128 rows** (`kMaxRows`) and says so in its status
line rather than paging further.

**No icons in the browser list.** `GetIconRef` is present on the machine
(the type/creator lookup a listing off the wire needs, since it has no
file to ask about) and `GetIconRefFromTypeInfo` is absent. Nothing uses
either yet; the list is text-only.
