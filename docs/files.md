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
3. **Drag-out + guest-initiated:** file promises, the guest's
   `put` (NavGetFile → offer), the guest's `get` (needs the host to
   serve a share — see below), conversion badges everywhere.

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
