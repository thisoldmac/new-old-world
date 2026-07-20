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
| `file.listing {id, path, entries[], more, cursor}` | guest→host | One page (≤16 entries — control frames cap at 4 KB). Entry: `name, kind(folder\|file), type, creator, dataBytes, rsrcBytes, modified`. |
| `file.get {id, path, container?}` | host→guest | Pull. `container`: `auto` (default) \| `data` \| `macbinary`. |
| `file.offer {id, name, path?, container, dataBytes, rsrcBytes, type?, creator?, overwrite?}` | either | Announce an incoming file. Host→guest: `path` = destination folder in the share. Guest→host: no `path`; it lands in the host's share folder. |
| `file.accept {id}` / `file.refuse {id, code, reason}` | answer | Codes: `busy`, `exists`, `bad-path`, `not-found`, `io-error`, `too-big`. `exists` invites a retry with `overwrite: true` after the human confirms. |
| `file.begin {id, transfer, container, bytes, ...metadata}` | sender | Announces the bulk stream (same shape family as capture.begin). |
| `file.end {id, transfer, ok, sendMs?}` | sender | Transfer complete. |
| `file.done {id, ok, code?, reason?}` | receiver of a put | The guest confirms the file is written and stamped (type/creator/dates) — a put isn't done until the File Manager says so. |
| `file.progress {id, received}` | receiver of a put | What the guest has actually taken off the wire, sent as each 32 KB write batch flushes. Advisory: dropped rather than queued when the control queue is busy, so it is a floor that may skip. |
| `file.cancel {transfer}` | either | Mirror of capture.cancel, same drain rule. |

`file.get` needs no accept — the requester is the receiver. The bulk
plane's contract prose ("carries capture pixel data only") is amended.

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

**Receiving is not the mirror of sending.** The send path stages a
whole file in a temp-mem handle, which the 6 MB app partition caps.
Receiving streams straight to disk as chunks arrive: no ceiling, and
cancel is just deleting what exists so far. MacBinary therefore decodes
INCREMENTALLY — a state machine over header (128 bytes) → data fork →
padding → resource fork — because there is no buffer to parse from.
(The send side's ceiling stays a known limit, not this slice's work.)

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

### Known blocker

The guest stages an entire file in RAM before sending, so **Send to
*name*** is capped by the app partition (6 MB) until the send path
streams from disk the way the receive path already streams to it. Small
files work today; the fix is being pursued with the large-transfer work.

### Phases

Each phase is independently testable on the machine and each leaves the
product usable.

**Phase 1 — the host serves, the guest sends.** Host: a share-folder
setting, then serving `file.list` and `file.get`, and accepting
`file.offer` with the reverse of the conversions already done in the
other direction (MacRoman names to UTF-8, classic epoch to Foundation
dates, MacBinary decoded on arrival). Guest: *Send to name…* in the File
Sharing panel, the boot-volume toggle, a downloads folder defaulting to
the Desktop, and `put <path>` in the console. No new windows on either
side. Done when a file picked on the classic Mac lands in the host's
share with its name, type and date intact. Capped at small files until
the staging fix lands — say so in the UI rather than failing
mysteriously.

**Phase 2 — the browser.** Data Browser list with Icon Services icons,
sortable columns, both selection styles, double-click / Cmd-Up /
Cmd-click path menu / type-select, the status line, and Get downloading
to the configured folder. **De-risk first:** Data Browser under
CarbonLib 1.6 on 9.1 is the unknown in this whole slice, so prove it
with a throwaway window of three hardcoded rows before building on it.
Done when the host's share can be browsed, sorted, and pulled from.

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

### Not done here

Copy (as opposed to move) within the share, and moving into a folder by
any route other than a drag — no "Move to…" picker yet. Undo is
last-first; reverting one change out of the middle of the stack would
need the guest to say whether the later ones still hold, which it
currently has no way to know. The history is not persisted across a host
restart — the mechanism would now survive it, but a stale list of
changes from days ago is a different feature than an undo stack, and it
should be chosen deliberately rather than fall out of this.
