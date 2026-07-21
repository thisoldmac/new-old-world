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
once. **Unverified on metal**; the emulator forgives the synchronous
form, so only the PowerBook (or the 3400c) can prove it, and the chip
build `now-chip` exists for exactly that: launched with no prefs it
dials the gateway, and the UI must stay alive.

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

A root control got the field to *focus* but it still took no mouse or
keys - the Appearance edit-text control simply does not work for entry
in this WaitNextEvent app, which is the same wall the Console hit and
why it hand-rolled its input. So the edit-text controls are gone from
the page. Address and port are now drawn **read-only**, and an **Edit**
button opens a movable-modal **dialog** (`conn_edit_dialog.c`, DLOG/
DITL 301) whose text entry the **Dialog Manager** drives - `GetNewDialog`
+ `ModalDialog(now_pump_modal_filter())` + `GetDialogItemText` on
`editText` items. That is the exact mechanism the original Connection
dialog used before the Workshop rewrite, proven on this PowerBook; the
filter pumps the wire so a long edit never drops the link. Validation
stays in `conn_fields.c`.

The root control and the `FindControlUnderMouse` conversion (Screenshots,
Files share, Console, Connection) stay - they are correct regardless,
fixed focus and Tab, and cannot regress the leaf-control pages.
`confirm.c` keeps `FindControl` on its own dialog window.

**Unverified on metal.** Build clean, host suite and native tests
green. Left to watch on the machine: the Edit dialog opens, its fields
take clicks and keys, Save writes back and the page redraws the new
target; and that Screenshots/Files/Console still take their clicks
under the root control. Re-check all four pages.

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

- **The whole Processes page** (2026-07-21, spec in
  `processes-and-peek.md`): the Data Browser list with its
  icon-and-text column and compare callback, the detail pane and its
  memory bar, Bring to Front, and Ask to Quit's whole ladder -
  confirm, AE send, `(quitting...)`, the 10-second `(no reply)`
  timeout, and the walk noticing the exit. The pure geometry and
  formatters are native-tested (watched failing by mutation); nothing
  Toolbox-facing has run anywhere yet, including the emulator. Known
  soft spots to watch first on metal: `SetDataBrowserItemDataIcon` on
  CarbonLib 1.6, the compare callback actually sorting, and selection
  surviving a list rebuild mid-click.
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
