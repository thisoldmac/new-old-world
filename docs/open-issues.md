# Open issues

Things known to be wrong, unfinished, or unverified, with enough detail
to pick any one of them up cold. Nothing here is being worked on right
now; each is parked deliberately.

The distinction that matters in this list is **broken** (it does the
wrong thing) versus **unverified** (it may well be right, but no one has
watched it work on the PowerBook). Unverified is not a lesser problem —
several of tonight's bugs lived in code that looked obviously correct.

## Deferred by decision

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
    pins the ® round trip). **The same latent bug remains in the Files
    path commands** (mv/trash/untrash/ls in wire.c still use
    `find_string` for HFS paths) — flagged as a separate task, not swept
    in here because those are metal-verified. (2) **Selection hilite
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

## The host's receiving half is sender-only

Found by an altitude review 2026-07-20; the largest thing on this list.

The host as a SENDER got the full treatment: a resume token on the
offer, honouring `have`, an offset on `file.begin`, a CRC on `file.end`,
and a send window clocked on the guest's `file.progress`. The host as a
RECEIVER got none of it. It accumulates the whole file in memory,
writes once at the end, and checks only that the byte count matches. It
never sends `file.progress`, never offers a resume point, and never
verifies the CRC the sender may have sent.

The guest does all three. So the same `file.offer` behaves differently
depending on which machine receives it, which is exactly what the
contract says must not happen.

The consequence is not only symmetry. **A sender needs the receiver's
count to clock against**, and that clock is what stops the send buffer
backlogging into the 340 KB/s → 5 KB/s collapse that
`docs/large-transfers.md` explains. The host does not send progress, so
in the guest → host direction nothing bounds the guest's sending. The
fix for that pathology landed on one side of a symmetric protocol.

The shape of the fix is one job, not three: make the inbound side a
streaming sink — a file handle, a running CRC, a received count — and
progress, CRC verification, and eventually resume all fall out of it.
Two other things point at the same refactor: the bulk branch keeps THREE
parallel accumulators (a push, a pull, a capture) for a wire that
carries one transfer at a time, and `TransferIdentity.CRC32` is a
streaming checksum with no streaming caller, written for exactly this
and left when it was not built.

One contract edit goes with it: `FileProgress` says "sent by the guest
while it receives a put", which contradicts the symmetry the same
document asserts and is probably how this drifted. It should say
"sent by the receiver".

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

## Rough edges

**A send stages the whole file in RAM.** Pulling streams to disk, but
sending does not: `now_files_stage` builds the whole artifact in a
handle, so a large send fails on memory where a large receive succeeds.
It fails cleanly ("Not enough memory to send that file") rather than
crashing.

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
