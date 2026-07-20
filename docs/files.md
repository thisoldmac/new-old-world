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
2. **Put + drag-in:** `file.offer/accept/refuse/done` host→guest, guest
   bulk RX, writes under root, MacBinary decode, name sanitization,
   host→guest text conversion, overwrite confirmation flow.
3. **Drag-out + send:** file promises, guest Send File to Host… +
   `send` command (guest→host offer), conversion badges everywhere.
