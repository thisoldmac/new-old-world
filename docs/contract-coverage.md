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

> **The scene family is the biggest asymmetry here, and it is a
> SUBSYSTEM, not a row (2026-08-06).** The PowerPC guest serves
> `scene.request` and answers with `scene.begin`/bulk/`scene.end`, or —
> since 2026-08-06 — with a delta or with `scene.same`. NOW-68K serves
> none of it, and not because deltas are hard: it has no `scene/`,
> `axwalk/`, `peek/` or `observe/` at all, so there is nothing for a
> delta to be a delta of. Adding it is greenfield, and the portable part
> is already portable — `scene_build.c`, `scene_json.c`, `scene_phase.c`
> and `scene_digest.c` are Toolbox-free and compile on a host cc today.
>
> **The delta design was sized for that machine anyway**, which is worth
> stating because a PowerBook 180c is the guest that would gain most: the
> per-scene state is one key and one hash per entity (a few kilobytes,
> nothing proportional to the document), the hash is 32-bit, and the
> comparison is a `strcmp` and an integer compare per row. What NOW-68K
> lacks is the walk, not the room.

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

> **Inbound `hello` was ticked for both guests while only one gated it
> (2026-08-06).** NOW-PPC's `on_hello` read `name` and `version` and
> served the session; the contract revision it was sent was never
> looked at, so the tick meant "reads the message", not "serves the
> rule". Both guests now gate it and both SEND `refuse` naming their own
> revision and the peer's — including for an ABSENT `contract`, which
> the contract's connection rules now state is a mismatch rather than a
> tolerance. Watched on an emulated Power Mac G4 (guest build
> `48a2af200ab7`): revision 1 refused, no revision refused, revision 2
> served. The permanent check is
> `WireLimitsAgreementTests.testBothGuestsGateTheContractRevisionInTheirHelloHandler`.

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

> **A machine can now open TWO connections, and only one of them is a
> guest (2026-08-06).** `hello.role` is `session` or `resident`, absent
> meaning `session` — which is every connection that existed before plan
> 012. A `resident` channel comes from the optional NOW Extension, is a
> claim about the MACHINE rather than about any application on it, and
> may send only `hello`, `ping` and `bye`; the host refuses anything else
> on it by name. It is also the one dial permitted to repeat a live
> session's name, because sharing that name is exactly how the host
> associates the two.
>
> **Which guest sends it: NEITHER, and that is not an asymmetry between
> them.** The resident component is not a guest application. It is a 68K
> INIT shared by both machines, it dials over MacTCP's `.IPP` driver
> through the Device Manager, and the connection it holds is filed by the
> host outside the guest registry entirely — never a guest, never
> offered a command, never counted against `maxGuests`. So this row
> belongs to the extension and the table below is unchanged by it.
>
> **What IS unverified, stated so it does not read as coverage.** The
> channel has been watched on an emulated G4 under OS 9 only. The same
> INIT on a 68K Macintosh under System 7.1 talks to real MacTCP rather
> than to Open Transport's compatibility driver, and nothing has run it
> there; the PowerBook 1400c under OS 9 is likewise untested. Plan 012
> § C expected the asymmetry to be OT-versus-MacTCP and it is not — the
> Device Manager route is the same code on both — but "the same code" is
> not "the same behaviour", and only one of the two has been watched.

## Inbound message types

What each guest does when the host sends it. ✅ served · ❌ not served.

| Message | PPC | 68K | Note |
|---|:--:|:--:|---|
| `hello`, `bye`, `pong`, `refuse`, `error` | ✅ | ✅ | the handshake and keepalive floor. What each guest SENDS in `hello` now differs — see the notes above |
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
| `scene.request` | ✅ | ❌ | the semantic walk — the Mirror's whole input. **NOW-68K serves no scene at all**: it has no `scene/`, no `axwalk/`, no `peek/` and no `observe/`, so a `scene.request` falls through to its unknown-message path. This is the single largest declared asymmetry in the contract and it is a subsystem, not a row |
| `scene.begin` / `scene.end` | ✅ | ❌ | the answer's transfer pair. `scene.begin` gained `digest` / `delta` / `baseline` / `wholeBytes` on 2026-08-06 |
| `scene.same` | ✅ | ❌ | the no-change answer, added 2026-08-06: a control frame with no transfer, sent only in answer to a request that quoted `since`. See [scene-deltas.md](scene-deltas.md) |
| `agent.access` | ❌ | ❌ | neither guest HANDLES one — it is guest-to-host only, and a host never sends it. PPC SENDS it when its consent tier changes; 68K has no tier to change |
| `cloud.report` / `cloud.listing` / `cloud.card` / `cloud.refuse` | ✅ | ❌ | the ASKER's half: the PPC guest consumes these as answers for its iCloud page and SENDS `cloud.services` / `cloud.list` / `cloud.detail` / `cloud.get` / `cloud.preview`. No guest serves the family — its subject is the host's own iCloud (contract `guestAsksCloud`), so these rows can never grow guest ticks |
| `chat.catalog` / `chat.delta` / `chat.status` / `chat.result` | ✅ | ❌ | the ASKER's half of the chat family (contract `guestAsksChat`): the PPC guest SENDS `chat.models` / `chat.send` / `chat.cancel` / `chat.reset` — from its Chat page and its console-only `chat` verb — and consumes these as answers; the host serves the family from its harness (`ChatWireService`). `chat.models` is TWO asks in one message and `chat.catalog` two answer shapes: without a provider it lists providers; with one it pages that provider's models (cursor/more, asked lazily on selection), each row carrying a HOST-MINTED `ref` that `chat.send` returns — a provider's model name never crosses the wire. Like cloud, its subject is the host's own model harness, so this row can never grow guest-SERVING ticks. 68K never asks, deliberately: the page is PPC-only and the family is a luxury a 384 KB partition does not buy |
| `preview.begin` / `preview.end` | ✅ | ❌ | the photo preview's transfer bracket, answering the PPC guest's own `cloud.preview`: raw indexed rows the HOST already dithered, landed in the iCloud page's pane by one CopyBits. Asker's half again — no guest will ever serve it |

PPC handles 39 inbound types; NOW-68K handles 23. **That count
understates the difference** — see the next two sections, where two of
these rows open into 41 command verbs and 14 hardware probes.

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

The registry is `x-commands` in the contract: **41 verbs.** Sixteen of
them landed on 2026-07-31 and are grouped at the foot of the table; the
Dialog Manager act joined that group on 2026-08-03: the
act plane, the reference layer that mints what it addresses, two verbs
about the machine's own state, the input plane's three, and the content
plane's reader. The transition plane's reader joined on 2026-08-05.

(That count read **36** here until 2026-08-05 while the paragraphs below
it already said 39, which is this file's own rule failing in the small:
a number nobody re-derived went stale beside numbers that had been.
Re-derived from the greps at the foot, all three of them, rather than
adjusted by one.)

**Three of those 38 were missing from this table when `hide` was added on
2026-08-05**, and the count read 35. `key` and `net` had landed without a
row; `hide` is the third. That is the drift this file's own opening
paragraph warns about — no test gates these tables — and it is worth
recording rather than quietly correcting, because it is the second time a
number here has been found wrong by re-deriving it.

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
| `hide` | hide or show an application, and read its visibility back | ✅ | ❌ — declared asymmetry, see below |
| `key` | post one keystroke, with no modifiers | ✅ | ❌ |
| `net` | this Mac's link, address and network hardware | ✅ | ❌ |
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
| `transitions` | what changed between two event passes, from the transition plane's ring | ✅ | ❌ |
| `key` | post one keystroke | ✅ | ❌ |
| `net` | this machine's networking, as it sees it | ✅ | ❌ |
| `mirror` | one NOW Extension: lifecycle/build and P1-P4 support, format, request, active, freshness, generation, degradation and refusal | ✅ | ❌ |

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

The GWorld probe arc has since moved `qdtrace` past that position on the
emulator: probe-mode drains on mac99/OS 9.1 (2026-08-06) carried real
records from a hooked offscreen port — 8 text, 24 rect, 11 rgn, 8 bits
across one Finder resize, with the true filenames at their true pens.

#### `qdtrace` is a SUBSYSTEM, not a row (2026-08-06)

The rule at the foot of this file — expand any row that is really a
subsystem — applies here, and the first version of this section broke
it: it named `blitsrc` and stopped, while three more additions had
landed the same day. `qdtrace` is four subcommands (`status`, `start`,
`stop`, `drain`) over a record vocabulary of **fourteen** ops, and the
vocabulary is where the arc's work actually shows. Derive it the way
this file derives everything else:

```
grep -oE 'case kNowContentOp[A-Za-z]+: *return "[a-z]+";' \
  now-guest-ppc/src/content/qdtrace_json.c
```

That prints fourteen lines, which is the count this section claims. It
is the guest's own `op_name()` table, so it cannot drift from what the
wire says the way a remembered list can.

Eleven are the drawing ops that were there from the start — `text`,
`line`, `rect`, `rrect`, `oval`, `arc`, `poly`, `rgn`, `bits`,
`comment`, `state`. Three are the join, and all three are new:

| Record | What it carries | Why it exists |
|---|---|---|
| `blitsrc` (op 12) | `srcPort`, `srcPixmap` | Emitted immediately before a `bits` record whose source resolves to a port this plane hooked. `srcPort` is the join the host needs to re-home the offscreen ops into the window at the blit's destination. A separate record rather than a wider `bits` payload, so an older reader steps over it whole and loses only the join it never had. |
| `worldborn` (op 13) | `world`, `pixmap`, `rect` | An offscreen world hooked at the instant `NewGWorld` returned — before the application has drawn a thing into it. |
| `worlddied` (op 14) | `world` only | That world at disposal. It deliberately carries no shape: after `DisposeGWorld` there is nothing left to read, and a remembered rectangle would be a claim about a port that no longer exists. |

**The two `world` records come from a trap patch, not from a search.**
The resident patches `_QDExtensions` (`$AB1D`, a ToolTrap) in the
target's own context: selector 0 (`NewGWorld`) is wrapped at its tail so
the brand-new port is hooked at birth, selector 4 (`DisposeGWorld`) at
its head so the row is dropped and the port's `grafProcs` restored
before the world goes. It is never removed — disarming makes the note
function decline instead, which is the only safe shape for a patch in a
foreign process. This is what reaches a world created, drawn, blitted
and disposed inside one event pass, which the older sight-then-chase
route cannot reach by construction; that route stays probe-only, because
walking two heaps at draw time inside another process is not something
to arm by default.

**`status` gained a `qdext` object** — `installed`, `calls`,
`newGWorld`, `lastSelector`, `foreign`, `born`, `died`, `bornMissed` —
which is that patch's own account of itself, and the only way to tell a
patch that never installed from one that installed and never fired. It
is read back under a length gate (`qdtrace_read.c`), so a build talking
to an older resident reports the object absent rather than reading past
the block.

**Correction to what this file said before (2026-08-06):** the three new
records were described here, and in `contract/asyncapi.yaml`, as **probe
mode only**. They are not. All three are gated on
`content_mode_records()` in `ext/src/now_content.c`, which is record mode
**or** probe mode, and the QDExtensions patch is installed under the same
gate — while the host arms with `"mode": "record"`. Read literally, the
old wording said the host's own arming mode gets none of this, which is
backwards. The contract's prose has been corrected to match the code;
no schema, field or behaviour changed.

**How far it is proven.** 1000 `blitsrc` records crossed the wire
against the loop control on the emulator the same day — every one naming
the port the applet reported for itself, every one immediately preceding
its `bits` record — and one against the live CFM Finder, whose capture is
the committed fixture behind the host's slice-D test. The trap-patch path
was watched against Sherlock 2 on the same emulator: 77 born, 77 died, 0
missed. **Nothing here has touched metal**, and no `qdext` counter has
been read on a Macintosh.

**Served is not consumed.** Two of these are guest-side only today:
`srcPixmap` is printed by the guest and decoded by nothing on the host,
and the whole `qdext` object has **no host consumer** — it is
operator- and agent-facing, reachable from the console and over the
wire, and no Swift code reads it. That is a deliberate diagnosis surface
rather than a gap, but it is not the same as being used, and this file
should not let the tick imply otherwise.

`transitions` (2026-08-05) began in exactly that position and **no
longer is**, which is worth stating precisely because the distinction
this section draws is the one that moved. Served and PROVEN are separate
columns here, and this row now has both — but only for one of the four
record kinds.

The row read "no record from this ring has ever been observed crossing
the wire" until later the same day. Two defects stood between the verb
and its ring, both found by driving and neither by any suite: `start`
could not arm by any route (an arg key shadowing the envelope), and once
it could, `drain` stated `records` twice in one object so every
conforming parser dropped the array. With both fixed, on the live
emulated Power Mac G4:

- `start` resolved a real target — `resolvedVia: "name"`, `a5
  0x1f21cb60`, `process "New Old World"`;
- `activity.passes` moved (1071, 5572, 9005), which is the resident's
  own word that it ran INSIDE the armed process and agreed;
- `drain` returned **22 real records**, `seq` 1..22, `lost: 0`,
  `dropped: 0`, ticks exactly 60 apart.

**The ring's reader and writer have met on a machine.** What is still
unproven is the part that matters most: every record ever observed is
`kind 4 heartbeat`, the resident's one-a-second pulse. **No
`windowList`, `frontProcess` or `menuList` record has been seen on any
machine.** One attempt to force a `frontProcess` transition instead
produced the first live sighting of the sampler's own stated limit — a
190-tick gap where the switch was, because the armed process was
backgrounded and its event passes never saw the change. See
[open-issues.md](open-issues.md).

**PPC serves 38 of 41.** `put` is console-only there and `cancel` is
not a verb at all, both deliberately: the host reaches those
capabilities through the `file.*` families and that guest's own
Workshop. `shotdiag` is the third, and the newest: it diagnoses a raw
framebuffer walk the PowerPC guest does not have.

**NOW-68K serves 13 of 41** — `help`, `ls`, `sw`, `census`, `put`,
`cancel`, `vprobe`, `screenshot`, `shotdiag`, `ps`, `launch`, `quit`,
`front`. The twenty-eight it does not: `gestalt`, `catsearch`, `tail`,
`reveal`, `vers`, `putstat`, `key`, `net`, `mirror`, `hide`, the eleven of the
act plane and the reference layer, the six registered on 2026-07-31 —
`activate`, `actselftest`, `mouseloc`, `script`, `aesend`, `qdtrace` —
and `transitions`.

`transitions` is a **declared asymmetry, not an omission**, and it is
the same one `qdtrace` and `mirror` already carry: all three read the
NOW Extension, and the NOW Extension is a PowerPC-era resident this
project has never built for a System 7.1 machine. NOW-68K has no shared
table to find a block address in, so the verb would have nothing to read
and no way to say so beyond `unknown-command` — which is what it
correctly answers today. If the resident ever reaches that machine, this
row is where the debt comes back.

The rest are not a 68K debt either: they reach for OSA, Apple Events, a
content-plane ring or an Open Transport stack that guest does not carry,
and no one has asked for them there.

Every asymmetry is argued in [command-parity.md](command-parity.md) and
named with its reason in `CommandRegistryTests.notOnThePowerPCGuest`.

### `hide` is PowerPC-only, and the reason is not "Carbon"

The lazy version of this row would say the call is a Carbon one and the
68K guest is not Carbon. That is true and it is not the reason, so it is
worth stating what is.

`ShowHideProcess` (Process Manager, selector `0x0060` under `_OSDispatch`,
`$A88F`) is declared in Universal Interfaces 3.4.1 as **CarbonLib 1.5 and
later, Non-Carbon CFM: not available**. The PowerPC guest reaches it as a
weak CFM import from CarbonLib. NOW-68K cannot: there is no CarbonLib on a
System 7.1 machine, so the only route from a 68K application is the trap
inline the same header carries — a raw `_OSDispatch` with selector
`0x0060`.

**That route is refused rather than untried, and the refusal is the
finding.** Apple's `_OSDispatch` does no bounds check on the selector: an
unimplemented one does not return an error, it `rts`es into whatever
follows the dispatch table, and there is no way to probe first. Nobody
here knows whether System 7.1's Process Manager implements `0x0060` — the
capability plainly existed, since 7.1's own Application menu hides
applications, but whether the SELECTOR was public then is exactly the fact
the CarbonLib-1.5 availability line makes doubtful. Calling it to find out
risks a jump into arbitrary code on a 4 MB machine, to learn something a
document could tell us.

So the asymmetry is: **the PowerPC guest serves `hide`, NOW-68K does not,
and it stays that way until the selector's presence under System 7.1 comes
from a document rather than from an experiment.** That is a decision with a
reason, not a to-do.

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

### `mirror` — one resident contract, and why NOW-68K's ❌ is an answer

The PowerPC guest serves it from the validated `NWex` table used by the
Workshop page. The reply has schema 1 and names exactly one resident plus the
four unified planes; it contains no AXPeek/QDPeek/Portal, agent, or forwarded-
port inventory. The host and guest therefore cannot diagnose a valid unified
boot as missing retired software.

NOW-68K does not serve the command because the resident table and its P1-P4
contracts are a PowerPC/Carbon guest capability today. A host asking that guest
gets `unknown-command`, which the host must treat as unsupported rather than as
evidence that an extension is absent. If the shared resident contract crosses
to the 68K sibling, the verb crosses with it; until then a fabricated all-zero
P1-P4 object would overstate what that guest observed.

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

**`hide` is the weakest row on this page and is listed so it cannot be
mistaken for one of the arcs above.** It COMPILES, and that is not one of
the three levels. Its argument grammar and its outcome vocabulary are
native-tested; the weak-import guard is verified only as far as the
generated PowerPC and the PEF loader section — the two symbols are import
class `0x82` (weak) in a `0x40` (weak) CarbonLib entry, and the guard
loads the TOC word CFM fills and compares it against zero. **No Macintosh,
emulated or metal, has been watched hiding anything**, so nothing is known
about the two questions only a machine can answer: whether
`ShowHideProcess` accepts the frontmost process, and what it returns for
the ones it is documented to decline. Until that is watched, Hide is
UNBUILT in the ledger rather than fixed.

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

Last re-derived: **2026-08-05**, on `claude/transitions-arg-key`, by
running all three commands at the foot while fixing two `transitions`
defects. **The counts were correct: 41 / 38 / 13**, and nothing on
either side had drifted — the first derivation in four not to find an
error, which is worth recording as plainly as the failures.

What changed was a verb's DECLARATION without changing what any guest
serves: `transitions`'s target arg is now `target` (it was `name`, which
shadowed the envelope), and its drain reply gained `count` (its record
count was `records`, which shadowed its own array). Neither moves a
row. What did move is the `transitions` row's PROVEN status, above —
records from that ring have now been observed crossing the wire, and the
paragraph saying they never had is corrected rather than deleted.

A note for the next derivation, since this file is now three-for-four on
finding its own errors: the check that keeps working is counting the
table against the registry rather than the registry against itself, and
the check that has never yet been run is whether a row's PROVEN column
still matches what anyone has actually watched. This one was stale by a
day.

The derivation before that: **2026-08-05**, on `claude/hide-showhideprocess`, by
running the commands above while adding `hide`. The verb registry was
**35 in this file and 38 in the contract** — `key` and `net` had each
landed without a row, and neither the counts nor the roster paragraphs
had been re-derived since. Both are rows now, the counts are 38 / 35 /
13, and the 68K roster is unchanged. Everything else checked out.

That is the second consecutive derivation to find the same class of
error, and both times it was a verb count that had been *maintained* — by
hand, at the moment a verb landed — rather than derived. The counts have
never been wrong in the direction that flatters the project; they have
been wrong in the direction of the last person who edited them.

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

Last re-derived: **2026-08-05**, on `claude/p5-transitions-delivery`, by
running the commands at the foot. The command registry contains **40**
verbs, the PowerPC dispatch serves **37**, and NOW-68K serves **13** and
remains the documented strict subset. `transitions` is the new one; `key`
and `net` were ALREADY served by the PowerPC guest and already declared
in the contract, and had simply never been given rows — which is why the
registry line said 36 while the paragraphs under it said 39, and why
"PPC serves 36 of 39" happened to read correctly out of two numbers that
were each wrong by the same two. The table now derives row-for-row
against `x-commands` with nothing on either side, which is the check that
would have caught it: **count the table against the registry, not the
registry against itself.**

The derivation before that: **2026-08-04**, on
`codex/recover-ptolemy-ux-loop`, by
running the commands above. The inbound dispatches contain 42 unique PowerPC
types and 23 unique NOW-68K types. The command registry contains 39 verbs; the
PowerPC dispatch serves 36 and NOW-68K remains the documented strict subset.
The `mirror` row was also re-read from both the command and console dispatches
after its schema-1 one-extension cut. The previous derivation also found one
grouped row that did not match: `file.list` / `file.listing` had been a single
✅/✅ row, and NOW-68K handles no `file.listing` inbound. They are two rows now.
What changed since that derivation is what each guest **sends** in `hello`,
which is recorded at the top.

The earlier derivation was 2026-07-28, at the merge of
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

## Re-derived 2026-08-06

Every command above was run again against this tree. What the numbers
are today:

| | Derived | Was |
|---|---|---|
| PowerPC inbound message types | **48** | 42 |
| NOW-68K inbound message types | **23** | 23 |
| `x-commands` registry | **41** | 39 |
| PowerPC verbs served | **38** | 36 |
| NOW-68K verbs served | **13** | 13 |

**The tables were right and the counts at the foot were stale**, which is
worth recording because it is the less obvious direction for this file to
drift. The six inbound types are the `chat.*` family (four) and
`preview.begin` / `preview.end` (two); all six already have rows in the
inbound table above, and both new registry verbs (`qdtrace`,
`transitions`) already have rows in the verb table. Nobody who read the
tables was misled — only someone who quoted a total was. A count is the
part of this document that no reader can check by looking at the row
next to it, so it is the part most worth re-running.

`qdtrace` is now expanded as a subsystem above, per this file's own rule.
It was ticked as one row while its record vocabulary had grown by three
and its `status` by a whole object.
