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

**A guest UI rework** is under way in codex thread
`019f8272-8aac-73a2-ad5c-c3f4884b587c` (Michelle, 2026-07-20). It will
need reconciling with `thread/files` when it lands, and it overlaps
`fork/carbon-ui-cleanup` — a Carbon UI correctness pass on the same
windows. Two independent passes over the same files is the expensive
merge; whichever lands second should expect to rebase rather than
merge, and the reconciler should read both before resolving anything.

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

**An unreachable host presents as a hang.** Diagnosed, not fixed. The
guest waits rather than saying it cannot reach anyone.

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
