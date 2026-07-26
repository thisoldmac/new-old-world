# Receiving a file on NOW-68K

How a host push lands on a 68K Macintosh, and the File Manager defect
that made the first working version quietly wrong.

Everything measured here is on the **Quadra 800 emulator under Mac OS
8.1** (`scripts/q800-68k`). The real target is a PowerBook 180c under
System 7.1 with 4 MB. Read every number as emulator-verified and none of
it as metal-verified — the distinction is the whole of AGENTS.md's
"verification is a status, not an adjective", and it matters more than
usual here because the central defect may well be an 8.1 defect.

## What it does

The contract's `hostPutsFiles` sequence, receive half only: `file.offer`
→ `file.accept` → `file.begin` → bulk frames → `file.end` → `file.done`,
with `file.progress` throughout. No contract change was needed; the
family was already symmetric and this guest simply was not serving its
share. `file.list`, `file.move` and the pull direction still answer the
generic not-implemented error.

| | |
|---|---|
| Containers | `data` and `macbinary`. An unrecognised container is **refused**, not treated as `data` |
| Destination | the **Desktop**, via `FindFolder`. `path` from the offer resolves under it, ungated |
| Resume | none. `have` is never reported, which the contract reads as "start at zero" |
| Integrity | CRC-32 over the wire bytes, compared against `file.end.crc32` |
| Staging | `NOW incoming <hex>` in the destination folder, renamed on success |

### Sizes, measured

| Size | Result |
|---|---|
| 0, 1, 8191, 8192, 8193 B | ok — the boundaries either side of one host frame |
| 64 KB / 256 KB / 1 MB | ok — 299 / 348 / 357 KB/s |
| **4 MB** | **ok — 11.6 s, 352 KB/s, 512 progress reports** |
| MacBinary, 6 shapes to 212 KB | ok — including 12 KB data + 200 KB resource |

Byte-verified by searching the **raw disk image** for the expected
pattern, not through any HFS tool. Largest observed gap between progress
reports was 8440 B against the host's 24 KB window.

## Three things that are load-bearing and not obvious

**The progress step is flow control.** The host parks its sender once it
is `outboundWindowBytes` (24 KB) ahead of the last `file.progress`, so a
receiver acking more coarsely than the host's 8 KB frame **deadlocks**
it — the transfer stops dead and the guest looks healthy throughout,
because it is: it is waiting for bytes the sender decided not to send.
`kN68PutProgressStep` is 8192 for that reason and no other.
`test_putrx.c` re-implements the host's park rule and runs the real
receiver against it; mutating the step to 32768 makes it name the
deadlock at 32768/1048576, which is the shape `large-transfers.md`
measured on the 1400c.

**The CRC is over the arriving bytes, not the written ones.** They are
the same thing for a `data` container and are *not* for MacBinary: the
contract checksums the whole file's wire bytes, and an envelope's
128-byte header and its inter-fork padding reach neither fork. A
receiver that checksummed what it wrote would disagree with every sender
on every MacBinary file and report `corrupt` for perfect ones. A test
pins that a fork-only checksum is **rejected**, so both cannot be
satisfied by one implementation.

**Reservation is `SetEOF`, not `Allocate`.** `Allocate`/`PBAllocate`
extend only the physical EOF; moving the logical EOF past the physical
one is the idiom Inside Macintosh recommends when the size is known
ahead of time, and it is what the PowerPC guest does. An intermediate
version set the logical EOF back to 0 after reserving, which hands the
blocks straight back — the File Manager deallocates when the logical EOF
drops more than an allocation block below the physical one — so the
reservation reserved nothing and a full disk would again have surfaced
at 3.9 MB of 4 MB.

## The fork scribble

**`FSClose` of a written resource fork splices 77 bytes of File Manager
catalog state into the fork's first block, at offset 48.**

Deterministic on this emulator: every MacBinary file carrying a resource
fork, every run. Data forks never. A MacBinary file whose data fork is
empty is never affected — which is the asymmetry that pointed at the
close path rather than at allocation.

The spliced bytes are a record for the staging file — its `NOW incoming
<hex>` name, the `BINA`/`NW68` type and creator `FSpCreate` gave it, and
both fork lengths — in an **in-memory** layout: Str31-padded name,
unified 32-byte Finder info, adjacent logical fork lengths. That layout
matches no on-disk HFS structure; the real on-disk record for the same
file, recovered from catalog slack, differs field by field.

### How it was pinned, and what each step ruled out

The evidence that mattered was structural, and it was available from the
first dump:

- **The splice is sub-sector.** Bytes 0–47 of the fork's first sector are
  correct, 48–125 are foreign, 126+ correct. Disks — emulated or real —
  write 512-byte units, so no misdirected block I/O, stale allocation
  bitmap, or cross-linked extent can produce it. **The bytes were wrong
  in RAM**, in whichever buffer was flushed. That kills every
  allocation-level theory outright.
- **The splice dates itself.** It carries the staging name and `BINA`
  (so: before the rename and before `FSpSetFInfo`) and both final fork
  lengths (so: after the last resource-fork write). That brackets the
  corrupting write to the close/flush window — which is why disabling
  `Allocate`, `SetEOF`, `FSpRename`, `FSpSetFInfo` and `PBSetCatInfo`
  one at a time all missed. **None of them was in the window.**
- **Read-back probes made it exact.** Before the close the fork reads
  clean through the open refnum; after the close a fresh open reads the
  splice. 5/5 resource-carrying files, every run, both directions
  deterministic.

A stale cache-buffer reference in the close-time catalog update is the
only shape that fits all three.

### The false trail, kept because it will tempt the next person

An instrumented build that **logged** after each probe produced 5/5
clean forks. That reads as "the read-backs prevent it". They do not. The
log write between the last fork write and the close made the log's cache
block the hot one, so the stray record landed **there** instead — and
that same build's log file showed the mangled run-together tail which is
what that looks like from the other end. Interleaved I/O relocates the
corruption; nothing available from application code prevents it.

Two hypotheses died on the way and are worth naming so they are not
re-proposed: that the resource fork's block overlapped the catalog file
(it does not — the fork sits in allocation block 332, the catalog's only
extent is blocks 64–127), and that a hard power-off was tearing the
volume (the corruption is present on disk while the VM is still running,
read immediately after the guest's own `FlushVol`).

### What ships

`n68_putfile.c` keeps the resource fork's first 512 bytes as written
(+516 bytes of BSS, in `wire68.c`'s static budget). After the close —
and again after the rename, which is itself a catalog update — it
re-reads the head through a fresh open, `memcmp`s it against what was
written, **rewrites it** if it diverged, and re-verifies through another
fresh open, because the repair refnum's own close runs the same
scribbling path. Three rounds, then honest failure.

A head that cannot be made right fails the transfer **before** the
rename, while the bytes are still staging debris. After the rename, the
file is **deleted** rather than left under its real name for a human to
double-click — on this machine that name is frequently an application.

Measured: detected at close 5/5, repaired in one round 5/5, raw disk
clean, both forks byte-identical on extraction including the 200 KB one.

The check is a `memcmp` against the written bytes, not a scan for the
known signature, so any divergence in the head is caught. Past the first
512 bytes it is blind; every observed splice sat at offset 48.

## What is not established

1. **Whether System 7.1 on the real 180c does this.** The in-memory
   record layout smells like 8.1's rewritten HFS+-capable catalog code,
   which 7.x predates — but the lab's 7.5.3 image has no MacTCP, so the
   OS discriminator is unrun. **The shipped probes are that experiment**:
   deploy to the 180c, push one MacBinary file, and the log either says
   `rsrc head scribbled at close` or stays silent. Either answer is
   safe, because the repair is already in the path.
2. **Whether QEMU contributes.** The cache logic is guest code and the
   behaviour is deterministic, which points at the OS, but nothing here
   separates 8.1-on-metal from 8.1-on-QEMU.
3. **Whether the PowerPC guest has it.** Its resource forks have never
   been byte-verified — the acceptance test launches a deployed
   application, which is strong evidence and not proof. OS 9.1's File
   Manager descends from 8.1's; three years of fixes is a plausible
   reason it does not show, not an established one.

## corpus_impact

`corpus_impact: hfs-close-scribbles-resource-fork` — filed in the parent
TimBotTu corpus. The durable claim is the defect and its bracket, not
this guest's workaround.

## Where the code is

| | |
|---|---|
| Decisions, no Toolbox | `guest68k/src/n68_putrx.h` / `.c` |
| File Manager, no decisions | `guest68k/src/n68_putfile.h` / `.c` |
| CRC-32 | `guest68k/src/n68_crc32.c` |
| Bulk delivery | `guest68k/src/n68_reader.c` (`N68_RS_BULK`) |
| The wire | `guest68k/src/wire68.c`, the file family block |
| The console's face | `guest68k/src/conwin.c`, `xfer` |
| Off-metal tests | `guest68k/tests/test_putrx.c`, `test_crc32.c` |
| Emulator rig | `scripts/q800-68k` |
| On-wire tests | `host/Tests/HostTests/Metal68KPutTests.swift` |
