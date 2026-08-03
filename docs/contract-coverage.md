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
for `CommandParityTests` reading the source instead. **No test gates the
tables in this file** — see the last section. What does exist is
`MCPCoverageTests`, which reads these same four greps against the same
guest sources for a different document
([mcp-coverage.md](mcp-coverage.md)); the machinery is pointed at the
same place, but nothing here fails a build. Treat this as correct on the
date at the bottom and check it against the commands above before
relying on it.

The other half of the join lives in [mcp-coverage.md](mcp-coverage.md):
this file says what a **guest** serves, that one says what a **host
face** can ask for, gap by gap. Neither restates the other's tables.


> **Guest identity and addressing changed nothing here (2026-07-28).**
> Guests are now addressed by a host-assigned machine id mapped to the
> host-observed peer address, and the agent projections that carry a guest
> name it. All of it is host-side: the address arrives on the
> socket and the display name is already in `hello`. No message, no verb
> and no probe moved. The row that WOULD move is a guest-minted stable id
> in `hello`, which is deliberately not implemented — see
> docs/open-issues.md.
>
> That feature was also **unreachable over its own socket from 2026-07-28
> until 2026-07-29**: the local protocol's strict allowlist decoder had
> never learned `guestSelector` or the `notAddressed` response, so any
> request that actually named a machine was rejected as `invalid-request`
> and the one refusal that names the driven machine surfaced as a
> protocol error instead. Fixed in
> `now-host/Sources/NOWAgentIntegration/AgentIntegrationLocalProtocol.swift`;
> the tests added with the fix read the field list off the type by
> `Mirror` rather than naming fields, so the next field declared without a
> place in a second list fails on its own.

> **`hello` is no longer byte-identical between the guests (2026-07-30).**
> Inbound handling still is — every row in the table below is unchanged —
> but the PowerPC guest now SENDS two fields the 68K guest does not: a
> build stamp, and `agent`, the machine's own answer about what an agent
> companion may do to it (`disabled` / `read-only` / `full`, ordered,
> optional). The PowerPC guest's answer comes from its preferences file
> by way of `now_agent_access()`, and a person sets it on the MCP page of
> the Workshop; NOW-68K sends no `agent` field at all, and absence is not
> consent — it is a fact about the sender.
>
> **And `hello` is no longer the last word on it (2026-07-31).** The
> PowerPC guest also SENDS `agent.access`, which revises that answer on a
> link already up — `hello` is sent once per connection, so before it a
> tier changed mid-session did not reach the host until the link was
> rebuilt, and the host went on permitting what the person had just
> withdrawn. NOW-68K sends no revision because it has no switch to
> revise: no MCP module, no consent page, and nothing that could change
> the answer it never gives. That is a declared asymmetry and not a gap
> to close — a revision message on a guest with no tier to revise would
> be a verb with nothing behind it. The host's ceiling and
> what absence currently means are host-side and live in
> [mcp-coverage.md](mcp-coverage.md) and
> [agent-integration.md](agent-integration.md). **No guest has ever sent
> anything but `full`**, so the ceiling below `full` has never met a
> Macintosh.

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
| `hello`, `bye`, `pong`, `refuse`, `error` | ✅ | ✅ | the handshake and keepalive floor. What each guest SENDS in `hello` now differs — see the note above |
| `command.request` | ✅ | ✅ | verb sets differ — see below |
| `census.request` | ✅ | ✅ | both answer, probe by probe — the subsets differ, see below |
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
| `file.list` | ✅ | ✅ | browse; 68K also has it as an `ls` verb |
| `file.listing` | ✅ | ❌ | the reply half. 68K SENDS it and handles none inbound — it browses no one |
| `file.get` | ✅ | ❌ | host-initiated pull |
| `file.move` / `file.trash` / `file.restore` / `file.mkdir` | ✅ | ❌ | change |
| `capture.request` | ✅ | ✅ | 68K stages to disk, packs, then sends — `screenshot` verb too |
| `capture.accept` / `capture.refuse` / `capture.cancel` | ✅ | ❌ | the guest-OFFERS-a-capture handshake; 68K only answers requests |
| `stream.start` / `stream.stop` / `stream.refresh` | ✅ | ❌ | |
| `agent.access` | ❌ | ❌ | neither guest HANDLES one — it is guest-to-host only, and a host never sends it. PPC SENDS it when its consent tier changes; 68K has no tier to change |
| `cloud.report` / `cloud.listing` / `cloud.card` / `cloud.refuse` | ✅ | ❌ | the ASKER's half: the PPC guest consumes these as answers for its iCloud page and SENDS `cloud.services` / `cloud.list` / `cloud.detail` / `cloud.get`. No guest serves the family — its subject is the host's own iCloud (contract `guestAsksCloud`), so these rows can never grow guest ticks |

PPC handles 37 inbound types; NOW-68K handles 23. **That count
understates the difference** — see the next two sections, where two of
these rows open into 36 command verbs and 14 hardware probes.

(An earlier version of this file said 33 for the PowerPC guest and was
wrong: the number had been hand-counted. It is derived now, and that is
the whole argument for the two `grep`s at the top.)

**A ✅ here means the message is answered, not that both guests answer it
identically.** `software.list` is the row where that distinction is
sharpest and it is expanded below with the rest of the software family;
`census.request` is the same warning, and its Note column carries it
because the outcome differs probe by probe rather than message by
message.

### `command.request` verbs

"The full registry" is not an answer, and the message-type table above
hides most of what a machine can be asked — the hardware, network, RAM
and ROM facts do not have message types of their own. They live behind
`gestalt` and `census`, one row each above and a whole subsystem below.

The registry is `x-commands` in the contract: **36 verbs.** Sixteen of
them landed on 2026-07-31 and are grouped at the foot of the table; the
Dialog Manager act joined that group on 2026-08-03: the
act plane, the reference layer that mints what it addresses, two verbs
about the machine's own state, the input plane's three, and the content
plane's reader.

| Verb | What it asks the machine | PPC | 68K |
|---|---|:--:|:--:|
| `help` | what commands this machine serves | ✅ | ✅ |
| `vers` | build identity | ✅ | ❌ |
| `gestalt` | **CPU, memory, OS, network, hardware** — see below | ✅ | ❌ |
| `census` | the hardware census, probe by probe — see below | ✅ | ✅ |
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
| `observe` | walk the elements on screen, minting a reference for each | ✅ | ❌ |
| `axtree` | the same walk, to look at rather than to act on | ✅ | ❌ |
| `axsnap` | who is front, and how many references are live | ✅ | ❌ |
| `handle` | take one reference back to a live element, or refuse | ✅ | ❌ |
| `elements` | the act plane's door onto that walk, aimed at one process | ✅ | ❌ |
| `winact` | move, resize, zoom or close one window | ✅ | ❌ |
| `textget` | read one addressed text element | ✅ | ❌ |
| `textset` | replace one addressed text element's contents | ✅ | ❌ |
| `ctlact` | act on one control | ✅ | ❌ |
| `ditemact` | select one addressed Dialog Manager item | ✅ | ❌ |
| `menuact` | perform one menu command | ✅ | ❌ |
| `activate` | bring one process forward, by serial number | ✅ | ❌ |
| `actselftest` | prove the act plane's trap ABI in one process | ✅ | ❌ |
| `mouseloc` | where the pointer actually is | ✅ | ❌ |
| `script` | run one AppleScript | ✅ | ❌ |
| `aesend` | send one of four core Apple Events | ✅ | ❌ |
| `qdtrace` | what is drawing, from the content plane's ring | ✅ | ❌ |
| `mirror` | Mirror's three residents, its agent, and the port beside it | ✅ | ❌ |

Eleven of those seventeen — the act plane and the reference layer — are one
mechanism and are served together or not at all. They are PowerPC-only
today by derivation rather than by an ISA check: they read another
process's window records through the anchor plane, and nothing on the
host asks which guest answered. **Served is not proven** — this table's
own rule — and no NOW machine has been watched performing one of the
six acts.

The six added at the foot on 2026-07-31 were **built, compiled, and
dispatched by nothing** until that day: each porting agent left its
registration written out in a header rather than performing it, because
the three halves are one shared surface. They are now reachable. That is
a statement about the dispatch chain and about nothing else — `qdtrace`
in particular reads a ring **whose writer has never run on a
Macintosh**, so a `status` on any machine today answers
`content-plane-absent`, correctly, and that is the whole of what it has
been seen to do.

**PPC serves 33 of 36.** `put` is console-only there and `cancel` is
not a verb at all, both deliberately: the host reaches those
capabilities through the `file.*` families and that guest's own
Workshop. `shotdiag` is the third, and the newest: it diagnoses a raw
framebuffer walk the PowerPC guest does not have.

**NOW-68K serves 13 of 36** — `help`, `ls`, `sw`, `census`, `put`,
`cancel`, `vprobe`, `screenshot`, `shotdiag`, `ps`, `launch`, `quit`,
`front`. The twenty-three it does not: `gestalt`, `catsearch`, `tail`,
`reveal`, `vers`, `putstat`, the eleven of the act plane and the reference
layer, and the six registered on 2026-07-31 — `activate`,
`actselftest`, `mouseloc`, `script`, `aesend`, `qdtrace`. The last six
are not a 68K debt: four of them reach for OSA, Apple Events or a
content-plane ring that guest does not carry, and no one has asked for
them there.

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
RAM, what ROM, what networking" is answered in ONE verb, and it is now
the largest thing NOW-68K does not serve — the census below closed the
other half of that sentence on 2026-07-28.

**The data already exists on the 68K side.** `now-guest-68k/src/ui/health.c`
samples machine identity, CPU type, System version, Virtual Memory,
MacTCP version, screen geometry and physical RAM once at startup, plus
free memory and largest free block on every panel redraw — all of it
cached, in fixed buffers, with the strings pre-built. It is drawn on the
guest's own panel, and the census now reports most of the same facts
under `identity` and `overview` — but the `gestalt` VERB still does not
exist here, and a host that asks for it by name gets
`unknown-command`. A `gestalt` on NOW-68K is closer to a rendering job
than a measurement one, which makes it the cheapest large gap left.

### `mirror` — and why NOW-68K's ❌ is an answer, not a gap

The PowerPC guest serves it; NOW-68K does not, and **should not**. This
is a declared asymmetry rather than a debt, and the reason is not
capability: the 68K guest could call Gestalt as easily as the Carbon one.

Mirror does not run on that machine. Its agent is a PowerPC/CFM
application whose build **refuses** the 68K toolchain outright, because
Open Transport cannot link under Retro68/68K
(`mirror/guest/app/CMakeLists.txt`). Its three residents exist to serve
that agent. So a `mirror` verb on NOW-68K would answer "absent, absent,
absent, no agent" about a machine where absence is the only possible
state — a row that reads as a finding and is a tautology.

A host asking NOW-68K for it gets `unknown-command`, which is the honest
answer: this Mac has nothing to say about Mirror. If Mirror is ever
ported to 68K, the verb crosses with it and this paragraph goes.

### `census` — the hardware census, probe by probe

The registry is CLOSED and lives in the contract (`x-census/x-probes`):
**14 probes**, and both guests answer all fourteen. What differs is the
OUTCOME, and that is the point of the table below rather than a tick.

Derive it from each guest's own dispatch table:

```
grep -A 20 'k_probes\[\] = {' now-guest-ppc/src/census/census_probes.c \
  | grep -oE '"[a-z]+"' | tr -d '"'
grep -A 20 'k_probes68\[\] = {' now-guest-68k/src/census/census68.c \
  | grep -oE '"[a-z]+"' | tr -d '"'
```

`CensusProbeRegistryTests` fails the build if either table drifts from
the contract or from the other's order.

| Probe | PPC | 68K | What 68K answers, and why |
|---|:--:|:--:|---|
| `overview` | ✅ | ✅ | model, CPU, RAM, System, display, addressing, free memory |
| `identity` | ✅ | ✅ | the curated dozen, plus **Addressing** — see below |
| `selectors` | ✅ | ⛔ | **refused**: the documented-selector table is 32 KB of names in a 384 KB partition |
| `video` | ✅ | ✅ | the GDevice walk; `absent` on a Mac with only original QuickDraw |
| `volumes` | ✅ | ✅ | indexed `PBHGetVInfo` |
| `drives` | ✅ | ✅ | the drive queue, zero bus I/O |
| `drivers` | ✅ | ✅ | the Device Manager unit table |
| `adb` | ✅ | ✅ | plain traps here, where Carbon has to resolve them by name |
| `ata` | ✅ | 🚫 | **absent**, gated on Gestalt: this Mac's internal disk is SCSI |
| `pccard` | ✅ | 🚫 | **absent**, gated on Gestalt: PCMCIA arrived after this Mac |
| `pram` | partial | ✅ | **partial** — 20 of 256 bytes, and the one that matters most here |
| `power` | ✅ | ✅ | the Power Manager; `absent` on a desktop |
| `pci` | 🚫 | 🚫 | **absent** on both: no 68K Mac has a Name Registry |
| `scsi` | ✅ | ⛔ | **refused**: an INQUIRY scan is active bus I/O, never attended here |

✅ answers with rows · 🚫 the MACHINE said no (`absent`) · ⛔ THIS BUILD
declined (`refused`, with its reason in the note)

**The two symbols are not interchangeable and that is the whole design.**
`absent` is a finding about the hardware, rendered as content; `refused`
is this build saying it did not look. A ❌ that means "this machine
cannot" reads differently from a ❌ that means "not built yet", and until
this arc NOW-68K answered every probe `refused` — honest, and zero
coverage.

**The two probes worth more here than on the PowerPC target:**

- **`pram`.** This PowerBook's PRAM battery is dead, so the 32-bit
  addressing switch — which lives in Parameter RAM — resets on every
  power cycle, and every raw framebuffer read then lands in main RAM.
  That cost a full investigation and a purpose-built diagnostic
  (`shotdiag`) to find. The probe reads `valid` (the byte the OS writes
  when PRAM is being retained), says plainly when it is not, and adds
  the consequence beside it. `partial` because 20 bytes is what
  `GetSysPPtr` reaches: the 256-byte XPRAM behind `_ReadXPRam` is a
  register-based trap these Universal Interfaces do not declare, and
  reaching it means hand-written inline assembly testable nowhere but on
  the machine.
- **`power`.** It is a battery-powered laptop. Gated on
  `gestaltPowerMgrAttr`, and which call it makes is a capability
  question rather than a preference: `GetScaledBatteryInfo` only where
  Gestalt says the Power Manager dispatcher exists, the classic
  `BatteryStatus` otherwise. A dispatch selector an older Power Manager
  does not implement is a crash, not a slow path.

**Addressing mode went into `identity` and `pram`, not into a probe of
its own** — a deliberate decision, reconsidered rather than inherited.
The registry is closed and declared in the contract, so a fifteenth
name would be a contract change and a host-registry change for a fact
that is already what `identity` is for ("the machine in a curated
dozen"). It appears twice on purpose: in `identity` as what the machine
is right now, and in `pram` as the reason it will not stay that way.

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

- **A census, but still no `gestalt` and no `vers`.** The census half of
  this bullet closed on 2026-07-28: a host can now ask NOW-68K what CPU
  it is, how much RAM and ROM it has, what is mounted, what is on the ADB
  bus, whether its PRAM is being retained and what its battery is doing —
  fourteen probes, several of them honestly `absent`. What remains is
  `gestalt` (five groups and a snapshot, and mostly a RENDERER here: the
  data is already sampled by `health.c` and now again by the census) and
  `vers`. **Every census probe on this guest is unproven** — see the
  table below; nothing in that subsystem has run on a Macintosh.
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

**This section is about the guest's own verbs and messages, and about
nothing else.** A host projection row that reaches one of them is a
separate artifact with a separate proof: `vprobe` is metal-verified on
the 180c while `now_framebuffer_probe`, the row over it, has never
crossed a wire. Do not read one as evidence about the other — the row
adds a schema, a bound, a timeout and an availability rule, none of which
the guest knows about. What has been driven from a host face, and what
has not, is [metal-and-ux-review.md](metal-and-ux-review.md).

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
| **the census** (`census.request`, the `census` verb, all 14 probes) | **tested only — the pure half.** The page, the paging arithmetic, the `census.report` bytes and the row collapse are native-tested (`test_census.c`); every PROBE is Toolbox calls no gate here can reach. Not one of them has run on a Macintosh, emulated or metal. |

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
tested only. That arc has now run: NOW-68K serves the census, and the
addressing fact has a home in it — `identity` reports the mode the
machine is in, and `pram` reports whether the switch will survive the
next power cycle. Neither row has been read on the 180c.

The whole file family — both directions, the largest thing NOW-68K
serves — has never moved a byte on the 180c. A Quadra 800 under 8.1
with 128 MB is not a 68030 under 7.1 with 4 MB; correctness carries
over, timing does not.

## This file should not be maintained by hand

The precedent is `CommandParityTests`, which reads the guests' source
and fails the build rather than trusting prose. The same is possible
here: parse both dispatches, compare against this table, fail on drift.
`MCPCoverageTests` already does the reading half — it runs these greps
and fails the build when its own tables disagree with them — so what is
missing is a consumer for this file's tables, not a derivation.
Until that exists, this document is a snapshot and the two `grep`
commands at the top are the source of truth.

**A gate that reads source text proves less than its name suggests**, and
six in this repository were found on 2026-07-31 not to prove what they
claimed — including the one that keeps `MCPCoverageTests`' Served column
honest, which had been satisfied by a `strcmp` left behind in a comment.
They are fixed or documented; the audit, and what a text scan can never
catch, is [source-text-gates.md](source-text-gates.md). It is the reason
this file's own future gate should be planned as a bounded check with its
blind spots written down rather than as a guarantee.

Updated **2026-07-31** on `thread/p2-unify-refs`, by hand and not by
re-derivation: the act plane and the reference layer took the verb count
from 19 to 29 and the PowerPC guest's from 16 to 26. Updated again the
same day on `thread/emu-ready`, also by hand: registering the six verbs
that were built and dispatched by nothing took the registry from 29 to
35 and the PowerPC guest from 26 to 32. The counts above are therefore
owed a run of the commands at the top of this file before anyone quotes
them as derived.

Updated **2026-08-03** on `codex/recover-ptolemy-ux-loop`: `ditemact`
took the registry from 35 to 36 and the PowerPC guest from 32 to 33. It
keeps Dialog Manager selection distinct from `ctlact`; emulator
verification is recorded by the UX loop rather than inferred from this
served count.

Last re-derived: **2026-07-31**, on `claude/tbt-parity-slice`, by running
the commands above. Every count in this file still checked out as it
stood then — 37 and 23 inbound types, 19 verbs, 16 and 13 served, 14
probes — and one
grouped row did not: `file.list` / `file.listing` had been a single ✅/✅
row, and NOW-68K handles no `file.listing` inbound. They are two rows
now. What changed since the previous derivation is what each guest
**sends** in `hello`, which is recorded at the top.

The previous derivation was 2026-07-28, at the merge of
`claude/68k-software-list-sw` and `claude/68k-census-probes`, which gave
NOW-68K `sw` and the census section above. **Re-derived at the merge
rather than taken from either side.** Each branch counted the roster
knowing only its own new verb, so both said "12 of 19" with different
lists; the truth is 13. That is this file's own rule biting exactly where
it was aimed - derive it, do not remember it - and a merge is now a known
place for it to go wrong, because two correct-in-isolation counts do not
add up to a correct one.
The command registry came from `x-commands` in
`contract/asyncapi.yaml`, the PPC verb set from `strcmp(name, ...)` in
`now-guest-ppc/src/commands/commands.c`, the 68K verb set from the table in
`now-guest-68k/src/commands/commands68.c`, and the probe list from `k_probes` in
`now-guest-ppc/src/census/census_probes.c` with NOW-68K's beside it from
`k_probes68` in `now-guest-68k/src/census/census68.c`.
