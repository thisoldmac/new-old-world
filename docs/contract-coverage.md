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
`json_type_is(reply, "...")` in `now-guest-ppc/src/core/wire.c` and
`strcmp(type, "...")` in `now-guest-68k/src/core/wire68.c`. Re-derive it the same
way rather than editing from memory:

```
grep -oE 'json_type_is\([a-z_]+, *"[a-z.]+"\)' now-guest-ppc/src/core/wire.c \
  | grep -oE '"[a-z.]+"' | tr -d '"' | sort -u
grep -o 'strcmp(type, "[a-z.]*")' now-guest-68k/src/core/wire68.c \
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
| `process.shot` | ✅ | ❌ | per-window capture; 68K captures the whole screen only |
| `software.list` | ✅ | ✅ | whole-volume sweep; 68K also has it as a `sw` verb, serves six of the eight entry fields — see below |
| `exec.request` | ✅ | ✅ | the console plane — one opaque line, the guest's own console text back |
| `exec.cancel` | ✅ | ✅ | always answered, even for an id the guest does not have |
| `exec.input` | ✅ | ✅ | answers a guest that is waiting; a guest that was not drops it |
| `file.offer` / `file.begin` / `file.end` | ✅ | ✅ | receiving a push |
| `file.accept` / `file.refuse` / `file.done` | ✅ | ✅ | the reply half, both directions |
| `file.progress` | ✅ | ❌ | 68K SENDS it and handles none inbound |
| `file.cancel` | ✅ | ✅ | either direction; 68K also has it as a `cancel` verb |
| `file.list` / `file.listing` | ✅ | ✅ | browse; 68K also has it as an `ls` verb |
| `file.get` | ✅ | ❌ | host-initiated pull |
| `file.move` / `file.trash` / `file.restore` / `file.mkdir` | ✅ | ❌ | change |
| `capture.request` | ✅ | ✅ | 68K stages to disk, packs, then sends — `screenshot` verb too |
| `capture.accept` / `capture.refuse` / `capture.cancel` | ✅ | ❌ | the guest-OFFERS-a-capture handshake; 68K only answers requests |
| `stream.start` / `stream.stop` / `stream.refresh` | ✅ | ❌ | |

PPC handles 37 inbound types; NOW-68K handles 23. **That count
understates the difference** — see the next two sections, where two of
these rows open into 19 command verbs and 14 hardware probes.

(An earlier version of this file said 33 for the PowerPC guest and was
wrong: the number had been hand-counted. It is derived now, and that is
the whole argument for the two `grep`s at the top.)

**A ✅ here means the message is answered, not that both guests answer it
identically.** `software.list` is the row where that distinction is
sharpest and it is expanded below with the rest of the software family;
`census.request`'s ⚠️ is the same warning made visible.

### `command.request` verbs

"The full registry" is not an answer, and the message-type table above
hides most of what a machine can be asked — the hardware, network, RAM
and ROM facts do not have message types of their own. They live behind
`gestalt` and `census`, one row each above and a whole subsystem below.

The registry is `x-commands` in the contract: **19 verbs.**

| Verb | What it asks the machine | PPC | 68K |
|---|---|:--:|:--:|
| `help` | what commands this machine serves | ✅ | ✅ |
| `vers` | build identity | ✅ | ❌ |
| `gestalt` | **CPU, memory, OS, network, hardware** — see below | ✅ | ❌ |
| `census` | the hardware census, probe by probe — see below | ✅ | ❌ |
| `catsearch` | catalog search across a volume | ✅ | ❌ |
| `sw` | installed software | ✅ | ✅ |
| `ls` | list a folder | ✅ | ✅ |
| `tail` | the end of a file | ✅ | ❌ |
| `reveal` | show an item in the Finder | ✅ | ❌ |
| `screenshot` | capture the screen | ✅ | ✅ |
| `vprobe` | framebuffer read cost | ✅ | ✅ |
| `shotdiag` | where a staged capture read from | ❌ | ✅ |
| `ps` | running processes | ✅ | ✅ |
| `launch` | open an application | ✅ | ✅ |
| `quit` | ask an application to quit | ✅ | ✅ |
| `front` | bring an application forward | ✅ | ✅ |
| `put` | send a file from the guest | console only | ✅ |
| `cancel` | stop the transfer in flight, either way | via UI / `file.cancel` | ✅ |
| `putstat` | transfer diagnostics | ✅ | ❌ |

**PPC serves 16 of 19.** `put` is console-only there and `cancel` is
not a verb at all, both deliberately: the host reaches those
capabilities through the `file.*` families and that guest's own
Workshop. `shotdiag` is the third, and the newest: it diagnoses a raw
framebuffer walk the PowerPC guest does not have.

**NOW-68K serves 12 of 19** — `help`, `ls`, `sw`, `put`, `cancel`,
`vprobe`, `screenshot`, `shotdiag`, `ps`, `launch`, `quit`, `front`. The
seven it does not: `gestalt`, `census`, `catsearch`, `tail`, `reveal`,
`vers`, `putstat`.

Every asymmetry is argued in [command-parity.md](command-parity.md) and
named with its reason in `CommandRegistryTests.notOnThePowerPCGuest`.

### `software.list` — one message, two amounts of answer

The row above says both guests serve it, and that is true. It is also
the row where "served" hides the most, so this expands it the way
`census` and `gestalt` are expanded: a message type is not a coverage
unit when the two guests can answer it with different numbers of facts.

`SoftwareEntry` has eight fields. **The PowerPC guest fills all eight.
NOW-68K fills six** — `name`, `path`, `type`, `creator`, `sizeK`, `off`
— and omits two, deliberately and with the schema's blessing (both are
optional, and both have "absent" as a defined reading):

| Field | Why NOW-68K omits it |
|---|---|
| `version` | one resource-fork open per served entry. The contract calls that "an explicitly bounded cost" and on a 1400c it is; on a 68030 with 4 MB and a 384 KB partition it is a resource map per file in a heap with no slack. Absent, never `""`. |
| `running` | the join against the process list is a Process Manager walk per page, on the machine where `ps` is already the slowest thing a person types. Absent, never `false` — `false` would be a claim. |

**This is an asymmetry in the ANSWER, not in the contract**, and the
difference matters: the two guests mean the same thing by
`software.list` and by every field they both send. A host reading a
NOW-68K listing gets fewer facts, and reads their absence as absence,
which is what the schema already says absence means. A guest that had
sent `"version":""` would have been the contract violation.

Two more limits are NOW-68K's alone and are reported in the listing's
`note` rather than left to be inferred:

- **the inventory is bounded at 48 applications** (`apps` domain). A
  whole-volume sweep can find hundreds; this machine holds 48 FSSpecs
  and stops, saying so. The folder domains have no such bound — they
  page live off the catalog and run to the end.
- **`PBCatSearch` is not available on every System 7.1 volume**, and the
  fallback walks the startup volume's ROOT only. An `apps` answer from
  the fallback is NARROWER, not merely shorter, and says which.

### `gestalt` — the machine's account of itself

Five groups, all PPC-only: **cpu**, **memory**, **os**, **network**,
**hw**, plus a `snapshot` summary. This is where "what CPU, how much
RAM, what ROM, what networking" is answered, and it is the single
biggest thing NOW-68K does not serve.

**The data already exists on the 68K side.** `now-guest-68k/src/ui/health.c`
samples machine identity, CPU type, System version, Virtual Memory,
MacTCP version, screen geometry and physical RAM once at startup, plus
free memory and largest free block on every panel redraw — all of it
cached, in fixed buffers, with the strings pre-built. It is drawn on the
guest's own panel and **no verb exposes it**. A `gestalt` on NOW-68K is
therefore closer to a rendering job than a measurement one, which makes
it the cheapest large gap on this list to close.

### `census` — the hardware census, probe by probe

The PowerPC guest implements **14 probes** (`k_probes` in
`now-guest-ppc/src/census/census_probes.c`):

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
at one row each, which read as two ticks and hid 19 verbs and 14 hardware
probes behind them. **Two of the rows above are subsystems.** Any future
version of this document has to expand them or it will understate the gap
the same way.

## What NOW-68K's gaps mean in practice

Rewritten 2026-07-26 after five branches landed together. Three bullets
that stood here that morning — no capture, no browse, no cancel — were
all false by the evening, which is the argument for deriving this file
rather than editing it.

- **No account of the machine.** No `gestalt`, no census probes, no
  `vers`. A host talking to NOW-68K cannot ask what CPU it is, how much
  RAM it has, what ROM, what is on the SCSI bus, or what its networking
  looks like — and the PowerBook 180c is precisely the machine where
  someone would want to know. The health data is already sampled locally
  (above), so `gestalt` is mostly a renderer; the census probes are real
  Toolbox work and would need doing per probe. **This is now the largest
  gap on the list.**
- **Capture answers, but does not offer.** `capture.request` is served —
  the guest stages the screen to disk, packs it, and sends the staged
  file as the bulk payload, so the byte count `capture.begin` promises is
  a fact rather than an estimate. What is missing is the other direction:
  `capture.accept` / `capture.refuse` / `capture.cancel`, the handshake
  for a guest OFFERING a capture, and `process.shot`, a single window
  rather than the screen.
- **Browse, but no pull and no mutations.** A host can list the machine
  (`file.list`, and `ls` for a person) and move a file in either
  direction, but `file.get` — a host asking the guest to send a named
  file — is not served, and neither are `file.move`, `file.trash`,
  `file.restore` or `file.mkdir`. NOW-68K will say what is there and
  carry bytes both ways; it will not change the shape of its own disk on
  request.
- **No streams.** The software family is no longer on this list:
  `software.list` is served and `sw` is a verb, with the two omitted
  entry fields and the two bounds set out above — a host can ask
  NOW-68K what is installed on it and get a launchable path back.
  `stream.start` / `.stop` / `.refresh` remain unserved.
- The process family is no longer on this list either:
  `process.list`, `process.quit` and
  `process.front` are all served, and the two drive verbs have `quit`
  and `front` COMMANDS beside them so a person can type what the
  Processes module clicks. `process.shot` is the one that remains, and
  it is blocked on capture's offer half, not on the process family.

None of these are failures in the contract's terms — an unimplemented
message answers `unknown-command` or `refused`, which is the additive
answer both sides already understand. The agent companion derives tool
availability from capability rather than guest identity for exactly this
reason (`command-parity.md`, "The MCP is a client, not a face").

## How far each served thing is proven

**PPC guest** — the capture, census, files, processes and software arcs
are metal-verified on the PowerBook 1400c; see the ledger for which
specific paths. The **exec console plane is the exception**: built and
tested, never run on the 1400c, and not yet on a PowerPC emulator
either — only NOW-68K's half of it has faced a live guest.

**NOW-68K:**

| Area | Status |
|---|---|
| dial, handshake, keepalive, health, logging, clean quit | metal-verified (180c) |
| `launch`, the `gone` path of `quit` | metal-verified |
| `ps` | metal-verified |
| `vprobe` | metal-verified — but see the addressing note below |
| interactive console | metal-verified |
| **receive a file** (incl. MacBinary, Desktop landing) | emulator-verified only |
| **send a file** (byte source, CRC, control lane) | emulator-verified only |
| `put` on the console | tested only |
| **cancel a transfer** (both directions, both faces) | emulator-verified only |
| `process.quit` / `process.front`, `isSelf`, the `front` verb | tested only |
| **browse** (`file.list`, the `ls` verb) | emulator-verified only |
| **installed software** (`software.list`, the `sw` verb) | **tested only** — no guest has run the sweep |
| **capture to the guest's own disk** (`screenshot`) | **metal-verified (180c)** |
| **capture across the wire** (`capture.request` -> bulk) | emulator-verified only |
| `shotdiag` (where the staged walk read from) | **metal-verified (180c)** — it answered, and named 24-bit addressing |
| the 24-bit addressing fix it produced | tested only — unrun on the 180c |
| **the exec console plane** (`exec.request` / `.cancel` / `.input`) | emulator-verified only (Q800, 8/8 `MetalExecTests`) |

`shotdiag` did the job it was written for. Run on the 180c on
2026-07-28 it reported `Addressing 24-bit (!)`, base `0xFC080000`
stripping to `0x00080000`, and `DIFFERS at byte 0 - wrong memory`: the
machine was in 24-bit addressing and every raw framebuffer read went to
main RAM. The fix (`SwapMMUMode` around the VRAM copy alone,
`core/screen68.c`) is **tested only** — it has not been back to the
machine.

**`vprobe`'s metal row needs the same asterisk.** Its bandwidth numbers
are unaffected by addressing (reading the wrong memory costs the same),
but its *Fidelity* row was measured in a 32-bit session and reported
480/480 differing when re-run in a 24-bit one. It now emits an
**Addressing** row so a number from it is quotable; that row is
tested only. NOW-68K serves no `census` probes at all, which is why
this fact lives in `vprobe` and `shotdiag` rather than in a census
probe — adding the census subsystem to this guest is its own arc.

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

Last derived: 2026-07-28, on `claude/68k-software-list-sw`, when NOW-68K
gained `software.list` and `sw`. The two counts at the top of the
message table (37 / 23) were re-derived with the `grep`s above and had
both drifted — the file said 34 / 19, from before the exec console plane
landed, which is the fifth time this document has been wrong about a
number it did not derive. The command registry came from `x-commands` in
`contract/asyncapi.yaml`, the PPC verb set from `strcmp(name, ...)` in
`now-guest-ppc/src/commands/commands.c`, the 68K verb set from the table in
`now-guest-68k/src/commands/commands68.c`, and the probe list from `k_probes` in
`now-guest-ppc/src/census/census_probes.c`.
