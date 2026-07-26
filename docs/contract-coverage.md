# Who serves what

Two guests speak this contract and they serve different amounts of it.
This is the inventory: every message type each guest handles, what it
does not, and — separately, because they are different questions — how
far each served thing has actually been proven.

It exists because "NOW-68K implements a small part of the contract" was
the only written answer, and a reader could not tell from it whether
screenshots were coming, whether a host could browse the machine, or
whether a transfer could be cancelled. All three are answerable and the
answers are below.

**Derived from the guests' own source**, not from intent:
`json_type_is(reply, "...")` in `guest/src/wire.c` and
`strcmp(type, "...")` in `guest68k/src/wire68.c`. Re-derive it the same
way rather than editing from memory:

```
grep -oE 'json_type_is\([a-z_]+, *"[a-z.]+"\)' guest/src/wire.c \
  | grep -oE '"[a-z.]+"' | tr -d '"' | sort -u
grep -o 'strcmp(type, "[a-z.]*")' guest68k/src/wire68.c \
  | sed 's/.*"\(.*\)".*/\1/' | sort -u
```

Prose goes stale, which is the argument `docs/command-parity.md` makes
for `CommandParityTests` reading the source instead. **This file has no
such test yet** — see the last section. Until it does, treat it as
correct on the date at the bottom and check it against the two commands
above before relying on it.

## Verification status is not coverage

Two independent axes, and conflating them is how this project has
misread its own progress before:

- **Served** — the guest handles the message rather than answering
  `unknown-command` or `refused`.
- **Proven** — builds / tested / emulator-verified / metal-verified
  (`AGENTS.md`: verification is a status, not an adjective).

A thing can be served and completely unproven. Most of the 68K file
family is exactly that today.

## Inbound message types

What each guest does when the host sends it. ✅ served · ❌ not served.

| Message | PPC | 68K | Note |
|---|:--:|:--:|---|
| `hello`, `bye`, `pong`, `refuse`, `error` | ✅ | ✅ | the handshake and keepalive floor |
| `command.request` | ✅ | ✅ | verb sets differ — see below |
| `census.request` | ✅ | ✅ | |
| `process.list` | ✅ | ✅ | |
| `process.front` | ✅ | ❌ | bring to front |
| `process.quit` | ✅ | ❌ | 68K quits via the `quit` COMMAND, not this family |
| `process.shot` | ✅ | ❌ | per-window capture |
| `software.list` | ✅ | ❌ | whole-volume sweep |
| `file.offer` / `file.begin` / `file.end` | ✅ | ✅ | receiving a push |
| `file.accept` / `file.refuse` / `file.done` | ✅ | ✅ | the reply half, both directions |
| `file.progress` | ✅ | ❌ | 68K SENDS it and handles none inbound |
| **`file.cancel`** | ✅ | ❌ | **a host cannot abort a 68K transfer in flight** |
| `file.list` / `file.listing` | ✅ | ❌ | browse |
| `file.get` | ✅ | ❌ | host-initiated pull |
| `file.move` / `file.trash` / `file.restore` / `file.mkdir` | ✅ | ❌ | change |
| `capture.request` / `capture.accept` / `capture.refuse` / `capture.cancel` | ✅ | ❌ | **no screenshots on 68K at all** |
| `stream.start` / `stream.stop` / `stream.refresh` | ✅ | ❌ | |

PPC handles 33 types; NOW-68K handles 14.

### `command.request` verbs

| | Verbs |
|---|---|
| PPC | the full registry (`CommandRegistryTests` is the list) |
| 68K | `help` `launch` `ps` `put` `quit` `vprobe` |

`put` is the one verb NOW-68K serves that the PowerPC guest does not,
and that asymmetry is deliberate and argued in
[command-parity.md](command-parity.md).

## What NOW-68K's gaps mean in practice

- **No capture.** The 68K guest cannot be asked for a screenshot. This
  is the largest single gap and it is blocked on a measurement, not on
  code: the framebuffer read is 159 ms for a 300 KB frame
  ([vram-readout-68k.md](vram-readout-68k.md)), and the PackBits encode
  cost and compression ratio on a 33 MHz 68030 are **unmeasured**. The
  ratio decides whether capture is viable over MacTCP at all. The
  sender it would feed already exists and takes an abstract byte source
  (`n68_bytesrc.h`), so a capture can stream in bands rather than
  buffer 300 KB against a 384 KB partition — no second send path
  needed.
- **No browse and no pull.** A host can push a file to NOW-68K and ask
  NOW-68K to push one back, but cannot list the machine or fetch by
  name. The Files module therefore has nothing to show against a 68K
  guest.
- **No cancel.** `file.cancel` is not in the 68K dispatch, so a host
  that abandons a 4 MB push has no way to tell the guest. Worth
  confirming what the guest actually does with the abandoned transfer
  before designing the fix.
- **No software listing, no streams, no process drive** beyond `launch`
  and `quit`.

None of these are failures in the contract's terms — an unimplemented
message answers `unknown-command` or `refused`, which is the additive
answer both sides already understand. The agent companion derives tool
availability from capability rather than guest identity for exactly this
reason (`command-parity.md`, "The MCP is a client, not a face").

## How far each served thing is proven

**PPC guest** — the capture, census, files, processes and software arcs
are metal-verified on the PowerBook 1400c; see the ledger for which
specific paths.

**NOW-68K:**

| Area | Status |
|---|---|
| dial, handshake, keepalive, health, logging, clean quit | metal-verified (180c) |
| `launch`, the `gone` path of `quit` | metal-verified |
| `ps`, `vprobe` | metal-verified |
| interactive console | metal-verified |
| **receive a file** (incl. MacBinary, Desktop landing) | emulator-verified only |
| **send a file** (byte source, CRC, control lane) | emulator-verified only |
| `put` on the console | tested only |

The whole file family — both directions, the largest thing NOW-68K
serves — has never moved a byte on the 180c. A Quadra 800 under 8.1
with 128 MB is not a 68030 under 7.1 with 4 MB; correctness carries
over, timing does not.

## This file should not be maintained by hand

The precedent is `CommandParityTests`, which reads the guests' source
and fails the build rather than trusting prose. The same is possible
here: parse both dispatches, compare against this table, fail on drift.
Until that exists, this document is a snapshot and the two `grep`
commands at the top are the source of truth.

Last derived: 2026-07-26, at `bb54ab3`.
