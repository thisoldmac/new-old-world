---
search:
  exclude: true
---

<!-- now-doc-provenance: generated reviewed=false -->

# Files module — spec

Move files between the guest and the host with smooth interop: automatic
conversion where it helps, honest containers where conversion can't help,
drag and drop in both directions, and a share boundary the guest's human
chose. Slice plan at the bottom; this document is the design of record
for the arc.

## Principles

- **One transfer lane.** File transfers ride the existing bulk plane
  under the same rules as captures: one transfer at a time, refused busy
  during a stream, progress and cancel via the existing machinery,
  aborts drain to the frame boundary.
- **Guest stays simple; smarts live host-side.** The conversion registry
  is host code. The guest's only format capability is MacBinary
  (encode and decode), because fork access is native there. Text
  encodings, line endings, and future image conversion are host work.
- **The share root is structural.** Wire paths are RELATIVE to the
  guest's configured root; a path outside the share is inexpressible,
  not rejected. Reads and writes are both allowed anywhere under the
  root (decided 2026-07-20): set the root to `Lab:` and a project can be
  dropped into `Lab:Code`.
- **Automatic never means opaque.** The browser badges what a transfer
  will do ("converts line endings", "MacBinary") before it happens.

## Whose point of view? (naming rule)

`get` and `put` are fine verbs; the trap is that they only mean
something relative to a frame, and this stack has three surfaces with
two different ones. The rule, decided 2026-07-20:

| Surface | Frame | Reads as |
|---|---|---|
| **Guest console** and the host's **remote shell** | **Guest-first** — the console is a shell *into* the guest, where `ls` lists the guest's disk and `screenshot` captures its screen | `put <path>` = the guest puts a file to the host. `get <name>` = the guest gets a file from the host. |
| **Host UI / future host CLI** | **Host-native** | "Download" (host obtains a file from the Mac), "Upload" / "Send to Mac". |
| **Wire messages** | **Requester-centric**, like HTTP | `file.get` is the host asking to obtain a file; `file.put` (slice 2) is the host asking to place one. |

The host's console is guest-first even though the human is sitting at
the host, because it is a shell into the other machine: what runs there
runs *on the guest*. Anything that is a host affordance rather than a
guest command — buttons, menu items, a host CLI — speaks host-native.

## Path model

- Relative colon-free segments joined with `:` — `""` is the root,
  `Code:TBT` is a subfolder. The guest resolves against its root via
  FSMakeFSSpec.
- Any empty segment (`::` — parent traversal in colon-path semantics) is
  refused with `bad-path`. Segment length > 31 refused. The root itself
  is chosen guest-side (NavChooseFolder), default = boot volume root,
  persisted in prefs.
- Guest never discloses absolute paths; the share root's display name is
  in the hello-adjacent listing of `""` only as a label.

## Wire (contract additions)

One handshake family serves both push directions; `file.get` is the
solicited pull. All transfers then use `file.begin` → bulk chunks →
`file.end` with the standard transfer id, regardless of direction.
Host→guest bulk is new: the guest gains a bulk RX path (today it drops
non-control frames).

| Message | Direction | Purpose |
|---|---|---|
| `file.list {id, path, cursor?}` | host→guest | List a folder. |
| `file.listing {id, path, entries[], more, cursor}` | guest→host | One page (≤16 entries — control frames cap at 4 KB). Entry: `name, kind(folder\|file), type, creator, dataBytes, rsrcBytes, modified, identity?`; identity is an opaque observation precondition, not authority. |
| `file.get {id, path, container?}` | host→guest | Pull. `container`: `auto` (default) \| `data` \| `macbinary`. |
| `file.offer {id, name, path?, container, dataBytes, rsrcBytes, type?, creator?, overwrite?, createParents?}` | either | Announce an incoming file. Host→guest: `path` = destination folder in the share. Guest→host: no `path`; it lands in the host's share folder. `createParents` defaults true for the existing human Files flow; V0.5 create-only upload sets it false so a missing destination folder refuses rather than quietly implementing `mkdir`. |
| `file.accept {id, have?, freeBytes?, reservedBytes?, staging?}` / `file.refuse {id, code, reason}` | answer | An accept may report resume offset plus observed free space, successfully reserved stream bytes, and `same-folder-temp` staging. Codes: `busy`, `exists`, `bad-path`, `not-found`, `io-error`, `too-big`. Existing Files UI may offer a human-confirmed overwrite retry; V0.5 generic upload never does. |
| `file.begin {id, transfer, container, bytes, ...metadata}` | sender | Announces the bulk stream (same shape family as capture.begin). |
| `file.end {id, transfer, ok, sendMs?}` | sender | Transfer complete. |
| `file.done {id, ok, code?, reason?, received?, crc32?, finalization?, cleanup?}` | receiver of a put | The guest confirms the receiver outcome. Success can name receiver-confirmed bytes, CRC, same-folder rename, and temp cleanup; failure can name confirmed bytes and retained/discarded staging. A put is not done until the File Manager says so. |
| `file.progress {id, received}` | receiver of a put | What the guest has actually taken off the wire, sent as each 32 KB write batch flushes. Advisory: dropped rather than queued when the control queue is busy, so it is a floor that may skip. |
| `file.cancel {transfer}` | either | Mirror of capture.cancel, same drain rule. |

`file.get` needs no accept — the requester is the receiver. The bulk
plane's contract prose ("carries capture pixel data only") is amended.

### Mirror copy-on-drop

Mirror reuses this same symmetric family rather than inventing a second bulk
transport. A human drag adds one closed routing identity:

- `file.get.mirrorSource` names a regular file on the guest desktop or in an
  observed Finder window, with the exact HFS folder path for the latter;
- `file.offer.mirrorDrop` names the guest desktop, an exact Finder folder, a
  live application process, or an application creator.

The PPC receiver resolves that identity before accepting. Host conversion is
the ordinary text/MacBinary conversion, transfer progress is the ordinary
file event stream, and an application receives `kAEOpenDocuments` only after
the copied file settles. No field asks the source to move, and no Mirror drop
overwrites an existing item. This first lane transfers regular files only and
is installed on `LiveMirrorView`, not on Continuity's screen-edge input path.

## Agent-approved artifact lane

The optional host-side agent companion reuses this exact host-to-guest
put path; it is not a file API and adds no wire message. A human first
uses the Files page's **Approve One-Time Agent Transfer…** action in the
intended guest folder. NOW opens one regular source file without following
links, copies at most 4 MiB into private mode-`0400` staging, and copies an
opaque receipt. The MCP receives only that receipt: never the source path,
guest path, staging path, or a way to browse any of them.

The receipt is bound to the current session and Files destination, expires
after ten minutes, and is consumed by its first redemption attempt.
Redemption rechecks the staged inode, device, owner, link count, size, mode,
timestamps, and SHA-256 before joining the existing one-at-a-time lane.
`overwrite` is always false; `busy`, collision, expiry, disconnect, and a
negative or missing `file.done` return no delivery receipt. A positive
receipt means the matching guest write was acknowledged. It records hashes
of the selected source bytes and the bytes handed to NOW, which can differ
after text conversion, but explicitly does not claim a destination
read-back hash.

## V0.5 root-scoped staged upload

The generic V0.5 upload is a NOW command, not a generic host filesystem API.
Its caller declares one canonical destination below the persisted
`guestRoot`, size, SHA-256, container, and optional classic metadata. NOW
reserves private host disk while retaining five percent of currently available
important-usage capacity, accepts ordered chunks of at most 8 KiB, verifies
the complete digest, seals the stage read-only, then streams it through the
existing one-at-a-time put state machine. No command accepts a host path.

The guest checks free space and the `SetEOF` reservation result before
accepting, writes through its existing 32 KiB buffer to a same-folder
temporary item, and renames only after length/CRC/fork/metadata finalization.
Receipts separate local send progress from receiver-confirmed bytes and report
reservation, elapsed/rate/stall, integrity, finalization, and cleanup evidence.
Stages expire after ten minutes and are one-attempt; duplicate or concurrent
commit conflicts rather than issuing a second offer. V0.5 upload is
create-only: its parent must already exist, a late collision cannot replace or
delete that item, and success requires matching guest-reported length, CRC,
same-folder rename, and temp cleanup. A host staging cleanup failure is reported
as `cleanup-needed` and retained for recovery rather than claimed as removed.
Host stage writes and outbound file reads run off the UI actor in bounded
chunks. Update, mkdir, delete, move, deployment, and prune remain separate
future commands behind observation preconditions.

## Containers and conversion

Decision table (chosen with Michelle, 2026-07-20):

| Case | Guest → Host | Host → Guest |
|---|---|---|
| `TEXT` type / text UTI or extension | Raw data fork on the wire; HOST converts MacRoman→UTF-8, CR→LF | HOST converts UTF-8→MacRoman (unmappable chars substituted), LF/CRLF→CR before sending; guest stamps `TEXT`/`ttxt` |
| Resource fork empty | Plain data fork | Plain file; guest stamps type/creator from the extension map when known |
| Data fork empty, resource fork not | MacBinary (the only honest container — a decomposed app is a 0-byte file wearing xattr jewelry) | — |
| Both forks populated | Data fork by default; "Download as MacBinary" alternate action | — |
| `.bin` (MacBinary) | Stored as-is | GUEST auto-decodes to a real forked file with type/creator (Rumpus behavior) — the classic-software-delivery case |
| Everything else | Raw data fork | Raw; name sanitized |

- **Name mapping host→guest:** UTF-8 → MacRoman, colons stripped, then
  truncated to 31 chars preserving the extension; collision after
  truncation → refuse `exists` (never silent-rename).
- **Converter registry (host):** keyed by (type/creator) and UTI —
  `text`, `macbinary-passthrough`, `identity` now; PICT→PNG and
  PNG→PICT are future registrants, not special cases.

### Classic date compatibility boundary

Every host→guest file lane shares one deployed-guest constraint: the
wire's optional `modified` value is classic Mac seconds since 1904 and
can describe an unsigned 32-bit value, but the current guest reads that
JSON number through `strtol` into a signed 32-bit `long`. Values above
`2,147,483,647` therefore saturate before the File Manager sees them.
A contemporary host date can otherwise arrive as January 1972.

The canonical safe behavior is to omit `modified` when the converted
classic value is not in `1...2,147,483,647`. The guest then preserves
the honest date of the file it created instead of stamping fabricated
metadata. Host decoding may still accept the full classic unsigned range
`1...4,294,967,294`; this narrower bound applies only when encoding a
date for the deployed guest.

This is one compatibility rule for every host→guest path: Files drag or
picker sends, host-share pulls served to the guest, and agent-approved
artifact delivery. Any new lane must call the same bounded conversion,
and its regression test must watch a modern date become an absent
`modified` field. `FileConverterTests` owns the numeric boundary and the
approved-artifact integration test proves the wire offer omits it.

## Guest surface

- `files.c`: list/resolve/read/write under the root, MacBinary
  encode/decode, fork rule. One implementation behind both faces.
- **File Sharing… dialog** (File menu): shows the current root, Choose…
  via NavChooseFolder, persisted (prefs v6).
- **Send File to Host…** (File menu): NavGetFile → `file.offer` → the
  host's share folder. Console: `ls [path]`, `send <path>`.
- Incoming puts: written to the offered path under the root, then
  stamped; `file.done` only after both forks land.
- Refusals a human caused (bad name, exists) surface via the shot-note
  hook pattern, not silence.

## Host surface — the Files module

The browser is the module's centerpiece and gets the polish budget:

- SwiftUI `Table`, sortable columns (Name, Kind, Size, Modified), icons
  mapped from type/creator/extension, breadcrumb path bar, back/up,
  double-click to descend, listing cache + explicit Refresh, loading /
  empty / error states designed rather than defaulted.
- Context menu: Download, Download as MacBinary, Copy Path.
- **Drag out** (browser → Finder): NSFilePromiseProvider — the transfer
  runs when Finder redeems the promise; progress surfaces in the module.
- **Drag in** (Finder → browser): drop onto a folder row or the current
  folder = `file.offer` to that path; conversion badge shown during
  drag-over; `exists` refusal → overwrite confirmation.
- Settings (in the module, collapsible like Screenshots): the host
  **share folder** — destination for guest-initiated sends and the
  default Download target (default ~/Downloads).
- Transfers panel row: filename, direction, progress, cancel — shared
  visual language with the Screenshots progress bar.

## Exclusivity and limits

- Listing is control-plane only: allowed anytime, including mid-stream.
- Transfers share the one lane: refused `busy` during a stream or
  another transfer, exactly like captures.
- No hard size cap in v1; the UI shows size before pulling, `too-big`
  exists in the vocabulary for a future guest-side guard (RAM is not
  the constraint — the wire at ~227 KB/s is: ~4.5 min for 60 MB).

## Slices

1. **Browse + pull:** contract `file.list/listing/get/begin/end/cancel`,
   `files.c` (root, relative paths, fork rule, MacBinary encode),
   prefs v6 root + File Sharing dialog, host module with the polished
   table + Download (+ as-MacBinary), text conversion, share-folder
   setting, `ls` command.
2. **Put + drag-in** — settled 2026-07-20, detailed below.
3. **Drag-out + guest-initiated** — drag-out done; the rest is
   detailed under "Slice 3" below.

## Slice 2 design (settled 2026-07-20)

**What a share means.** A share bounds what the OTHER machine can reach
on its own initiative — list, pull, write into. It never bounds what
you deliberately send: a push takes any file the human picks, from
anywhere on disk. So slice 2 needs no new folder setting; the source is
wherever the drag came from and the destination is the drop target,
which is inside the guest's share because that is all the browser can
show. A menu-driven send with no drop target defaults to the share
root rather than inventing an inbox.

**Receiving and sending are both streams now.** The receive path writes
chunks straight to disk. The send path opens the source forks only after
the receiver accepts and fills one protocol frame at a time; MacBinary
is emitted as header → data fork → padding → resource fork without a
whole-artifact handle. The 6 MB application partition therefore no
longer caps either direction. The host mirrors this with a same-folder
temporary sink and running CRC. These reverse-path changes are tested
locally but not yet metal-verified.

**Bytes land under a temp name** in the destination folder and are
renamed on `file.end ok:true`. A truncated file never appears under the
real name, which matters most on the guest, where a half-written
application is something a human might double-click.

**The guest stays passive.** The host offers with a destination path;
the guest accepts if the path is inside its share and writable, and
otherwise refuses with a typed code. No confirmation prompt on the
guest — it is not necessarily attended. Arrivals show as a line in the
File Sharing panel; the file appearing in the Finder is the rest of the
feedback.

**Multi-file drops queue** host-side and go one at a time, because the
wire carries one transfer at a time. The queue is visible, and
cancelling one does not abandon the rest.

**Folder drops are in scope**, built up to rather than rushed: a drop
becomes files with relative subpaths (`Code:Proj:src:main.c`), and the
guest creates missing parents inside its share or refuses. Empty
folders do not survive — nothing carries them — and an explicit
`file.mkdir` is deferred until something needs it.

**Text conversion inbound** (UTF-8 → MacRoman, LF/CRLF → CR, stamped
`TEXT`/`ttxt`) is automatic by extension and can be switched off in the
Files module's settings. Converting a file that should not be is
destructive in a way the download direction is not, so it gets an off
switch rather than only a badge.

**Build order**, each rung testable on metal: bulk RX with a single
file → sanitization, collisions, conversion → the queue → subpaths and
directory creation.

**Slice 3's `get` is the immediate follow-on**, and it is what
introduces the host's share folder: one setting per machine meaning
"what the other Mac can see", the same thing the guest's share root
already means.

## Slice 3 design (settled 2026-07-20)

### The protocol becomes symmetric

Three requirements — Send to *host*, Browse *host*, and a share the
human picks — all point the same way: the host must serve a share, and
the guest must be able to browse and push to it. So the file family
stops being "host asks, guest serves" and becomes direction-agnostic:
`file.list`, `file.get`, `file.offer` and their answers mean the same
thing whichever side sends them, and **whoever receives a request serves
its own share**.

That collapses three features into one change, and it gives the host's
share folder exactly the meaning the guest's share root already has:
*what the other machine can reach on its own initiative*. The rule from
slice 2 is unchanged and now applies both ways — a share bounds
unattended reach, never what a human deliberately sends.

### Guest surface

**File Sharing panel** gains:

- **Send to *name*…** — NavGetFile, then an offer into the host's share.
  The button names the machine, like every other surface (see the
  naming rule above).
- **Browse *name*…** — opens the browser window described below.
- **Share entire boot volume** — a toggle. While set, the share is the
  boot volume root and Choose Folder is disabled; the panel still shows
  which volume that is. The chosen folder is *remembered*, not
  discarded, so unchecking restores it rather than making the human
  pick again.
- **Downloads land** on the Desktop by default, and the folder is
  configurable.

### The browser window: native, not approximately native

The point of building our own instead of mounting a volume (see below)
is that it can behave correctly. That means using the controls Mac OS
provides rather than drawing a list by hand:

- **Data Browser** (`kDataBrowserListView`) is the control. It gives
  column headers with click-to-sort, real selection semantics
  (shift-range, cmd-toggle), keyboard navigation, scrolling, and
  Appearance-correct drawing. The List Manager alternative means
  reimplementing all of that slightly wrong. Data Browser has sharp
  edges under CarbonLib; they are worth paying for, because a browser
  that *looks* right and *behaves* foreign is the failure mode this
  slice exists to avoid.
- **Icon Services** for the icons: every listing entry carries type and
  creator, so `GetIconRefFromTypeInfo` + `PlotIconRef` shows the real
  system icon — the actual application icon, the actual document icon.
  This is most of the difference between a list of filenames and a
  Finder window.
- **Behaviours**, which are cheap once the control is right:
  double-click to descend; **Cmd-click the title for the path
  hierarchy** (the classic Finder gesture); Cmd-Up for the enclosing
  folder; type-select; Return to open; a status line reading
  "23 items, 1.2 GB available", which the listing and the host's own
  free space already supply.
- **Then**: drag and drop with the Finder, via the Drag Manager's
  promised-HFS flavour — the direct ancestor of the file promises the
  host side already uses. Dragging out of the browser makes the Finder
  ask for the file on drop. Sequenced after the browser proper, not
  skipped.

### Why not mount the host as a volume

Considered and declined, recorded so it is not re-litigated from
scratch:

- **AFP** is the native mechanism — OS 9 mounts AppleShare volumes with
  forks and type/creator intact. But macOS no longer serves AFP, so it
  needs netatalk: a third-party daemon rather than our app, and it
  bypasses this layer entirely (no line-ending conversion, no badges,
  no progress, no shared cancel).
- **WebDAV** is a maybe — OS 9 shipped a client for iDisk and the host
  could embed a server. How much of that client is general rather than
  iDisk-specific is untested; Goliath existed because the built-in
  support was thin. Same conversion loss, plus AppleDouble sidecars.
- **A File System Manager plug-in** — making our own wire appear as a
  mounted volume — is the "proper" answer and the worst fit. It is an
  extension rather than an app, so it leaves the one-app-per-side design
  and goes below the line; and File Manager calls are synchronous while
  this wire is asynchronous and sometimes seconds slow, so the Finder
  would block on directory reads with no way to show progress or ask
  "replace?" from inside a filesystem call.

Native mounting stays available to a human who wants it — netatalk
alongside, deliberately, the way Rumpus is used for deploys. The
conversion point cuts both ways: a mounted volume never gets line-ending
or type/creator handling, which is most of what makes a file usable
across these two machines.

### Closed memory blocker and remaining boundary

The guest no longer stages an entire outbound file in RAM. The integrated
reverse path reads bounded frames from disk, and the host receives them into a
private disk sink with progress, CRC, interruption cleanup, and atomic
finalization. That path is metal-verified through 4 MiB; it has not been
qualified for longer-than-two-minute transfers, larger files, source mutation,
resume, or transfer-rate hardening. See
[reverse-file-streaming.md](reverse-file-streaming.md).

This transport prerequisite does not itself expose generic agent download.
That remains gated on a separate typed NOW command, `guestRoot` and size
policy, receipts, audit, tests, and an explicit MCP projection.

### Phases

Each phase is independently testable on the machine and each leaves the
product usable.

**Phase 1 — the host serves, the guest sends.** *Done 2026-07-20:
metal-verified on the PB1400c — a file picked on the classic Mac lands
in the host's share. 198 host tests green.* Host: a share-folder
setting, then serving `file.list` and `file.get`, and accepting
`file.offer` with the reverse of the conversions already done in the
other direction (MacRoman names to UTF-8, classic epoch to Foundation
dates, MacBinary decoded on arrival). Guest: *Send to name…* in the File
Sharing panel, the boot-volume toggle, a downloads folder defaulting to
the Desktop, and `put <path>` in the console. No new windows on either
side. Done when a file picked on the classic Mac lands in the host's
share with its name, type and date intact. This phase originally shipped with
the documented small-file cap; the later reverse-streaming integration removed
that memory-bound staging cap subject to the bounded verification limits
above.

What Phase 1 cost, and what it bought
-------------------------------------

Three bugs, and they rhyme: each was a place where **one half assumed
what the other half does**, and no test spanned the two.

**The guest sent frames the host could not decode.** `file.offer` had no
`path`; `file.begin` had no `name` or `container`. All contract-required.
The host's decoder threw on the first frame of every send and closed the
connection, so the symptom — "drops, reconnects, no file" — pointed
nowhere near the cause. Eight tests covered this path and none caught
it, because every one built messages as Swift values: they proved the
host agrees with itself. `GuestWireFixtureTests` now decodes the literal
strings `wire.c` emits, and is the only place in the suite where the
guest's bytes meet the host's decoder. **A test that constructs the
message it is about to parse tests one half twice.**

An unreadable frame is no longer fatal either. These halves ship
separately; a verb one side has learned and the other has not should not
brick the older peer. Loud and survivable beats strict and dead.

**The panel meant to make a send visible starved it.** It read a
preferences file, called `HiliteControl` three times, and invalidated
the whole window on *every* event-loop pass — and during a transfer that
loop runs with no sleep. `HiliteControl` redraws whatever it is passed,
so the "is it enabled" check was itself a flicker loop. On a 603e the
instrument consumed what it was measuring. Idle work on this machine has
to be free unless something changed: read no files, draw nothing,
invalidate the smallest rectangle that differs.

**A send reported into the wrong window.** It narrated through
`note_shot`, the Screenshots panel's hook, so the File Sharing panel was
silent — and silent is indistinguishable from broken, which is how it
was reported. Feedback that lands somewhere other than where the human
is looking is not feedback.

Two escapes the host's serving side had, both caught by its own tests
before the guest ever saw them, both from the same root: a path that
means one thing on the wire and another on this file system. A segment
containing `/` spelled a path outside the share through the separator
the other machine does not use, and a symlink inside the share named
anything on this disk while looking local. Resolution now rejects the
first and compares what a path actually reaches — not what it says —
for the second.

**Phase 2 — the browser.** *Rungs 1 and 2 done 2026-07-20,
metal-verified: the guest browses the host's share in a real Data
Browser list, and push and pull both work from the classic side. A
pulled file lands in a chosen downloads folder, outside the share, and
the window says which one and opens it in the Finder. Remaining:
HostShare learning move / trash / restore / mkdir, so the browser gets
the controls — no new verbs for any of it, they are already in the
contract and the guest already serves them.* Data Browser list with Icon Services icons,
sortable columns, both selection styles, double-click / Cmd-Up /
Cmd-click path menu / type-select, the status line, and Get downloading
to the configured folder. **De-risk first:** Data Browser under
CarbonLib 1.6 on 9.1 is the unknown in this whole slice, so prove it
with a throwaway window of three hardcoded rows before building on it.
Done when the host's share can be browsed, sorted, and pulled from.

### What rung 1 cost

Two bugs, both latent for weeks, both found only because a new message
was the first big one to travel.

**A receiver's buffer has to be the contract's limit.** The guest held
1200 bytes of inbound control while the contract allows 4096, and a
frame that did not fit returned the same code as a malformed one — so
the reader called it a protocol error and hung up. Everything arriving
until then was a pong or a request. The listing was the first message
big enough to notice, and the symptom (the connection dropping when you
open a window) pointed nowhere near the cause. The limit now lives in
one place that both the sender and the receiver read, and a message too
big to hold is skipped rather than fatal — losing one message costs one
message.

**This file system hands out decomposed names.** "café" is "cafe" plus a
combining accent, and MacRoman has the accented letter but not the mark,
so every accented name became "cafe_" on the way over. Silently, and in
the download path since slice 1. It was found by accident: a debug print
in a size test showed a name nobody had asked about. The assertion that
would have caught it deliberately now exists.

**Phase 3 — drag and drop, and the sharp edges.** Drag out of the
browser to the Finder via the Drag Manager's promised-HFS flavour, drag
in from the Finder, then what only matters once people use it:
multi-select operations, progress inside the browser, and errors that do
not interrupt. Genuinely optional — everything works without it, which
makes it the right place to stop if the arc needs to end.

## Changing the share from the host

Browsing was read-only, which made the browser a viewer rather than a
place to work. Move, rename, delete and new-folder close that, and the
whole design follows from three decisions.

**Delete means the Trash, not unlink.** `FSpDelete` is one call and no
way back; `PBCatMove` into the volume's Trash folder is what the Finder
does, what a person expects to be able to reverse, and the only honest
basis for an undo. Emptying it stays a human's decision on that machine.

**Undoing a delete is a move-undo.** The first cut gave the guest a
session-lived table of trashed items and handed back an opaque token,
which meant delete-undo silently became the one operation that died with
the guest process. It did not need to. The Trash is a real folder, so a
name inside it says "that item" as durably as a path says it anywhere
else: `file.trash` reports the name the item landed under, and
`file.restore` takes that name plus the path it came from. Both halves
are names, nothing is remembered on either side, and every undo — move,
delete, new folder — outlives a restart of either machine.

The reported name matters because it is not always the name the item
had. Two files deleted from different folders can share a name, so the
guest picks a free one in the Trash the way the Finder does. Recording
the name we *asked* for rather than the one it *got* would eventually
put something else back.

**The host owns the history, the guest owns the mechanism.** The guest
performs one change and answers; it holds no notion of a session, an
order, or an undo stack — and now no notion of a trashed item either.
The host stacks the reversals, which is what lets a multi-select move
fail on item three and leave the first two undoable individually.

### Shape on the wire

Four requests, one answer type. `file.move` carries the entire
destination path including the new name — a rename and a move are the
same File Manager operation, and splitting them into two messages would
have invented a distinction the file system does not have. Missing
parent folders are **not** created: a typo in a folder name should fail
rather than quietly build the wrong tree. `file.trash` reports the name the
item landed under in the Trash; `file.restore` takes that plus where it
belongs. `file.mkdir` makes one folder. All four answer `file.result`,
and an older guest that does not know them answers `file.refuse`, which
settles the request just the same.

| Request | Answers with | Undone by |
| --- | --- | --- |
| `file.move` | `file.result` | `file.move` back |
| `file.trash` | `file.result` + trashed name | `file.restore` |
| `file.mkdir` | `file.result` | `file.trash` |
| `file.restore` | `file.result` | — |

### Rename first, then move

`PBCatMove` carries the item's **current** name into the destination, so
a move into a folder that already holds that name fails `dupFNErr` (-48)
before any later rename can help. Every move here therefore renames the
item *in place* to a name free in both folders, and only then moves it.
This is not theoretical: the first live run against a real volume failed
exactly this way on the second delete of the same name, and the corpus
had already recorded the same shape from the Q950 move verb.

An `io-error` answer carries the File Manager's own number in its
reason. "The File Manager refused" names no cause and cannot be debugged
from the other side of a wire; -48 said immediately what was wrong.

### In the app

Renaming is an edit of the name in the row. Moving is a drag onto a
folder row, which is why local drags are `.move` while drags out to the
Finder stay `.copy`. Deleting and moving are confirmed in a sheet that
says in words what is about to happen and to how many items — a
confirmation nobody reads is not a confirmation, so the safe button is
the default and the wording names the items. Renaming is confirmed too;
it is cheap to undo but easy to trigger by accident from a stray
double-click.

The Undo control is a split button: pressing it reverses the last
change, and its menu lists what this window has done this session. The
history is capped at 50 entries and cleared when the app quits — it is a
record of this window's work, not a journal of the volume. An undo that
comes back `not-found` (the Trash was emptied, or the item dragged out
by hand) drops off the stack, since it will never work again; any other
failure stays, because it might.

Console parity: `mv <path> <new path>`, `trash <path>`,
`untrash <trash name> <path>`, `mkdir <path>`, each documented in
`help`. `trash` prints the name the item landed under, which is what
`untrash` wants.

### The agent surface reaches the same four

`now_guest_files_mutate` projects these four messages for a host face other
than the browser (`agent-integration.md`, P1 #7). It is the same guest
mechanism and the same three decisions above — the Trash rather than unlink, a
name-based undo, the host holding the history — with two bounds the human lane
does not need because a person can see what they clicked:

- every path is composed beneath the host-owned `guestRoot`, and the root
  itself is never the target;
- `overwrite` is unreachable. The human lane can pass it; the agent lane has
  no spelling for it, so a collision refuses rather than replaces.

One item per call, one wire request, no created parents. The trashed name goes
back to the caller because that is the only thing a restore takes — the same
reason the browser's Undo stack keeps it.

### Verified on a real volume

`NOW_LIVE=1 swift test --filter LiveChangeTests` drives a connected
machine through the whole arc — make, rename, move, refuse a collision,
refuse a missing parent, trash, restore, trash the same name twice,
restore both, refuse an item the Trash no longer holds — and leaves the
volume as it found it. It passed on the mac99 emulator guest
(2026-07-20), including the suffixing path: the second delete landed as
"Renamed 2" and the third as "Renamed 3".

What that run actually settles, none of which a unit test could:
`FindFolder(shareVol, kTrashFolderType, kCreateFolder, …)` gives a Trash
that `PBCatMove` accepts; an item moved there comes back out to a named
path; and a name already taken in the Trash is worked around rather than
failed. Metal retest still pending.

### Not done here

Copy (as opposed to move) within the share, and moving into a folder by
any route other than a drag — no "Move to…" picker yet. Undo is
last-first; reverting one change out of the middle of the stack would
need the guest to say whether the later ones still hold, which it
currently has no way to know. The history is not persisted across a host
restart — the mechanism would now survive it, but a stale list of
changes from days ago is a different feature than an undo stack, and it
should be chosen deliberately rather than fall out of this.

## The name bridge (ClassicName)

The share's names cross an encoding boundary in both directions, and
the rule is stated once, in `now-host/Sources/Host/ClassicName.swift`:
**every name a listing shows must work when it comes back** — in a
`file.get`, a mutation, or a destination. A listing that mangles names
one way and looks them up verbatim advertises files the other machine
cannot reach, which is exactly the defect the bridge replaced.

- A name that already fits HFS — 31 MacRoman **bytes**, no colon, not
  hidden — passes through untouched (composed; this file system stores
  names decomposed and MacRoman cannot spell a combining mark).
- Anything else is projected the way classic Mac OS itself projected
  HFS+ long names at its 31-character APIs: stem truncated, `#` and a
  hex fingerprint of the whole original name, extension kept. The
  fingerprint is what keeps two long names distinct and makes a rename
  visible.
- Projection is deterministic and stateless. Resolution re-projects the
  real directory and matches — there is no mapping table to persist,
  drift, or lose across restarts.
- A directory is projected **whole**, so a projection that collides
  with a sibling (case-insensitively — HFS is) widens its fingerprint.
  A name that fits as-is is never altered; only mangled names give way.

`OutboundFile.hfsName` delegates to the same projection, so the name a
push invents and the name a listing shows cannot disagree.

## Sharing iCloud Drive

Pointing the share at iCloud Drive is the travel visa made literal: the
classic Mac browses the modern world's folder, and the host does all
the crossing. The Sharing picker offers iCloud Drive whenever this Mac
is signed in; nothing else is iCloud-specific — the share learned to
see any folder *logically*, and a folder with no placeholders behaves
exactly as before.

- What is not downloaded exists on disk as a hidden `.name.icloud`
  stub. A listing shows the file it stands for — logical name, the
  size the stub promises (its plist first, the promised-item API
  second, zero rather than an invention), one entry even mid-download.
- A `file.get` for an unmaterialized file starts the download and
  refuses `busy` with the reason. The wire never waits on the weather;
  the person at the guest asks again and gets bytes. The 68K lesson
  applies: a refusal with a reason is an answer, not a failure.
- The name bridge composes: iCloud names are long, Unicode, and
  occasionally coloned, and a mangled placeholder name still reaches
  its stub.
- Serving stays ungated (decided 2026-08-01): choosing iCloud Drive in
  the picker is the consent act, same as any share root.

Status: **tested** against fabricated stubs only. Behaviour against a
signed-in iCloud Drive — real stub format, promised sizes, the
download trigger — is on the open-issues ledger until tried on this
Mac, and metal-verified is further still.
