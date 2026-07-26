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
| `census.request` | ✅ | ⚠️ | 68K answers, with **zero probes** — always `refused` |
| `process.list` | ✅ | ✅ | |
| `process.front` | ✅ | ✅ | bring to front; both guests also serve a `front` VERB |
| `process.quit` | ✅ | ✅ | both guests also serve a `quit` VERB — PSN for a machine, name for a person |
| `process.shot` | ✅ | ❌ | per-window capture; 68K has no capture at all |
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

PPC handles 34 types; NOW-68K handles 16. (The first version of this
file said 33 for the PowerPC guest. Nothing changed on that side — the
number was hand-counted rather than derived, which is the failure mode
the two `grep`s at the top exist to prevent. Run them.) **That count
understates the difference** — see the next two sections, where two of
these rows open into 17 verbs and 14 hardware probes.

### `command.request` verbs

"The full registry" is not an answer, and the message-type table above
hides most of what a machine can be asked — the hardware, network, RAM
and ROM facts do not have message types of their own. They live behind
`gestalt` and `census`, one row each above and a whole subsystem below.

The registry is `x-commands` in the contract: **17 verbs.**

| Verb | What it asks the machine | PPC | 68K |
|---|---|:--:|:--:|
| `help` | what commands this machine serves | ✅ | ✅ |
| `vers` | build identity | ✅ | ❌ |
| `gestalt` | **CPU, memory, OS, network, hardware** — see below | ✅ | ❌ |
| `census` | the hardware census, probe by probe — see below | ✅ | ❌ |
| `catsearch` | catalog search across a volume | ✅ | ❌ |
| `sw` | installed software | ✅ | ❌ |
| `ls` | list a folder | ✅ | ❌ |
| `tail` | the end of a file | ✅ | ❌ |
| `reveal` | show an item in the Finder | ✅ | ❌ |
| `screenshot` | capture the screen | ✅ | ❌ |
| `vprobe` | framebuffer read cost | ✅ | ✅ |
| `ps` | running processes | ✅ | ✅ |
| `launch` | open an application | ✅ | ✅ |
| `quit` | ask an application to quit | ✅ | ✅ |
| `front` | bring an application forward | ✅ | ✅ |
| `put` | send a file from the guest | console only | ✅ |
| `putstat` | transfer diagnostics | ✅ | ❌ |

**PPC serves 16 of 17** (`put` is console-only there, deliberately —
the host reaches that capability through the `file.*` families).
**NOW-68K serves 7 of 17.** Both asymmetries are argued in
[command-parity.md](command-parity.md).

### `gestalt` — the machine's account of itself

Five groups, all PPC-only: **cpu**, **memory**, **os**, **network**,
**hw**, plus a `snapshot` summary. This is where "what CPU, how much
RAM, what ROM, what networking" is answered, and it is the single
biggest thing NOW-68K does not serve.

**The data already exists on the 68K side.** `guest68k/src/health.c`
samples machine identity, CPU type, System version, Virtual Memory,
MacTCP version, screen geometry and physical RAM once at startup, plus
free memory and largest free block on every panel redraw — all of it
cached, in fixed buffers, with the strings pre-built. It is drawn on the
guest's own panel and **no verb exposes it**. A `gestalt` on NOW-68K is
therefore closer to a rendering job than a measurement one, which makes
it the cheapest large gap on this list to close.

### `census` — the hardware census, probe by probe

The PowerPC guest implements **14 probes** (`k_probes` in
`guest/src/census_probes.c`):

`overview` `identity` `selectors` `video` `volumes` `drives` `drivers`
`adb` `ata` `pccard` `pram` `power` `pci` `scsi`

**NOW-68K implements none.** It serves `census.request` and answers
every one with `outcome: "refused"` and the note "no probes
implemented" — deliberately `refused` rather than `absent`, because
absent would mean the machine was asked and said no, which is not what
happened. That is honest and it is still zero coverage: **read the ✅
for `census.request` in the message table as "answers the message", not
as "has a census".**

### A message-type table is not a coverage table

Worth stating, because the first version of this file made the mistake.
Counting inbound message types put `census.request` and `command.request`
at one row each, which read as two ticks and hid 16 verbs and 14 hardware
probes behind them. **Two of the rows above are subsystems.** Any future
version of this document has to expand them or it will understate the gap
the same way.

## What NOW-68K's gaps mean in practice

- **No account of the machine.** No `gestalt`, no census probes, no
  `vers`. A host talking to NOW-68K cannot ask what CPU it is, how much
  RAM it has, what ROM, what is on the SCSI bus, or what its networking
  looks like — and the PowerBook 180c is precisely the machine where
  someone would want to know. The health data is already sampled locally
  (above), so `gestalt` is mostly a renderer; the census probes are real
  Toolbox work and would need doing per probe.
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
- **No software listing and no streams.** The process family is no
  longer on this list: `process.list`, `process.quit` and
  `process.front` are all served, and the two drive verbs have `quit`
  and `front` COMMANDS beside them so a person can type what the
  Processes module clicks. `process.shot` is the one that remains, and
  it is blocked on capture, not on the process family.

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
| `process.quit` / `process.front`, `isSelf`, the `front` verb | tested only |

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

Last derived: 2026-07-26, on the `claude/sleepy-wozniak-660add` branch
(parent `9773395`). The command registry came from
`x-commands` in `contract/asyncapi.yaml`, the PPC verb set from
`strcmp(name, ...)` in `guest/src/commands.c`, and the probe list from
`k_probes` in `guest/src/census_probes.c`.
