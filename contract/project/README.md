# CodeKitten Project Contract 1

`Project.ckp` is the portable description of a classic Macintosh software
project. It is data, not an instruction stream: neither NOW nor CodeKitten may
interpret a field as shell, MPW, AppleScript, or ToolServer command text.

The first line is exactly `CKPROJECT 1`. Remaining non-empty lines are UTF-8
`key=value` records. Readers accept CR, LF, and CRLF line endings. Unknown keys
are retained when possible and ignored when their meaning is not required;
unsupported major versions are refused.

## Required records

| Key | Cardinality | Meaning |
|---|---:|---|
| `id` | 1 | Stable opaque lower-case hexadecimal project identifier. |
| `name` | 1 | Human-facing project name, 1-64 Unicode scalars. |
| `target` | 1+ | Opaque target identifier. |
| `configuration` | 1+ | Opaque configuration identifier. |
| `toolchain` | 1 | Qualified guest toolchain pin, encoded `id@version`. |
| `product` | 1+ | Project-relative output path. |
| `file` | 1+ | Project-relative source or resource path. |

Optional records are `type`, `creator`, `architecture`, `entry`, `include`,
`define`, `compiler-option`, `linker-option`, `package`, `file-info`, and
`build-action`.
Repeated records retain their file order. Four-character `type` and `creator`
values are MacRoman byte identities represented as four ASCII characters.

`file-info` makes classic file identity part of the portable project instead
of asking a build backend to infer it from a suffix. Its value is
`TYPE|CREATOR|FLAGS|path`: type and creator are four printable MacRoman bytes,
flags are four lower-case hexadecimal digits containing the Finder flags, and
the remainder is one declared `file` path. Splitting from the left preserves a
literal `|` in a valid path. A path may have at most one `file-info` record.
Legacy projects without these records remain readable, but a publisher that
cannot otherwise preserve the real file metadata must refuse rather than
invent it.

Resource-fork bytes remain a fork of the named `file`; they are not encoded in
`Project.ckp` and do not become a second source path. Project stores and agent
surfaces expose data and resource forks as two bounded views of the same file.
History digests and candidate receipts bind both forks, type, creator and
Finder flags. Transfer through a data-only lane therefore uses MacBinary; a
plain data-fork transfer is not a complete Development file.

Paths always use `/` separators and are relative to the directory containing
`Project.ckp`. Empty segments, dot-prefixed components, a leading `/`, `\`,
NUL, and a trailing `/` are invalid. Dot files are reserved for private project
state and are never source. A consumer must additionally refuse any filesystem
alias or symbolic-link traversal that would leave the project root.

`Build/` is the reserved top-level artifact directory. A `product` may name an
item beneath it, but a `file` record may not. Source manifests and project tree
digests exclude `Build/`, so ToolServer transcripts, objects and products do
not turn a verified source revision into apparent out-of-band source drift.
`.now-classic/` is the host Git adapter's internal,
complete MacBinary archive of each logical file; normal Git paths remain plain
data-fork blobs while this tree makes resource forks and Finder identity
recoverable from the same commit.

`build-action` is a pipe-delimited declarative record. Its first component is
one of `compile`, `rez`, `link`, `copy`, `stage`, or `metadata`; remaining
components are typed project- or toolchain-relative operands defined by the
selected backend. No component is executable text.

## Project home and working state

Project home is catalog state, not portable project data. `host` means the
authoritative working tree is beneath NOW's application-owned Projects root.
`guest` means it is beneath the human-selected Projects root on the connected
classic Mac. A guest project's host history mirror and agent workspaces do not
change its home.

Workspace, candidate, build, promotion, and run records are JSON receipts with
`schema` values from this family:

- `ckproject.problem/1`
- `ckproject.revision-receipt/1`
- `ckproject.workspace/1`
- `ckproject.stage-receipt/1`
- `ckproject.promotion-receipt/1`
- `ckproject.build-receipt/1`
- `ckproject.run-receipt/1`

Every receipt carries opaque identities rather than host paths. A build binds
the actual guest source digest, project revision, qualified toolchain, product
fork measurements, and terminal state. A run binds the exact product digest
and is never implied by build success.

## Legacy conversion

`Project.o9p` beginning `O9PROJECT 1` or `O9PROJECT 2` remains readable by
CodeKitten. Opening one must not rewrite it. Explicit **Save As CodeKitten
Project** converts the known vocabulary to `CKPROJECT 1`, preserves stable IDs
where valid, reports fields that could not be represented, and writes a new
`Project.ckp` beside a human-selected destination.

The files in `fixtures/` are the compatibility seam. NOW's Swift and guest C
readers and CodeKitten's pure core must accept the valid fixtures and reject
the invalid fixtures before a shared implementation is extracted.
