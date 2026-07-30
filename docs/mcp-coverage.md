# What an agent can ask for

[contract-coverage.md](contract-coverage.md) answers **what each guest
serves**. This file answers the other half: **what any host face can ask a
guest to do**, and — where those two differ — whether the difference is a
decision or an accident.

It exists because of drift nobody was watching for. The guests handle far more
inbound message types, command verbs and hardware census probes than any host
face can name, and **most of the difference is capability the guest already
has**. Some of that is deliberate and argued; some of it was simply never
noticed. **Those are different facts, and this file's whole job is to keep
them apart** — a gap with a reason and a gap by accident look identical in a
table that has one column for both, and the accidental ones survive by hiding
among the reasoned ones.

**The counts are in the tables, which are derived and gated; they are
deliberately not in this prose.** They used to be — "fourteen reach seven, the
other 36 are gaps, fourteen argued, thirteen planned and nine decided by
nobody" — which meant every capability that landed edited three sentences
nothing checked, in a published file, and a stale number here reads as a
finding. Count the rows if you need a number.

Read alongside:

| File | Its question |
|---|---|
| [contract-coverage.md](contract-coverage.md) | what each **guest** serves, and how far each served thing is proven |
| [agent-integration.md](agent-integration.md) | what the host projection layer **may be** — the boundary, the availability rules, the trust model |
| [command-parity.md](command-parity.md) | why a **guest** capability must reach both of its faces, and why the MCP is a client rather than a third one |
| this file | the **join**: guest capability against host reach, gap by gap |

**It does not restate the boundary.** Whether a projection may answer from
host state, how availability is decided, what a requirement means, and why
the companion is not a face all belong to `agent-integration.md` and are
linked, not copied.

## Derived, and gated by a test

`contract-coverage.md` says of itself that prose goes stale and that it has
no test enforcing it. That is the whole reason this file has one.

[`MCPCoverageTests`](../now-host/Tests/HostTests/MCPCoverageTests.swift)
reads the registry, the contract and both guests' dispatch, and **fails the
build** when they disagree with the tables below in a way those tables do
not declare. It is the deliverable; the prose is the readable rendering of
what it checks.

What it derives, and from where:

| Side | Source | How |
|---|---|---|
| host reach | `HostProjectionCatalog` → each row's `capability`, `requires` and `exposes` | the registry itself, in process — no parsing |
| host-initiated messages | `contract/asyncapi.yaml` → `operations` with `action: receive`, resolved to each message's wire `name` | `receive` means the guest receives it, so it is an ask |
| command verbs | `contract/asyncapi.yaml` → `x-commands` | the closed registry |
| census probes | `contract/asyncapi.yaml` → `x-census`/`x-probes` | the closed registry |
| which guest serves what | `now-guest-ppc/src/core/wire.c`, `now-guest-68k/src/core/wire68.c`, `now-guest-ppc/src/commands/commands.c`, `now-guest-68k/src/commands/commands68.c` | the same greps `contract-coverage.md` publishes, reused rather than reinvented |
| whether a requirement is **accounted for** | `AgentIntegrationCapabilityLedger.familyPolicy`, in process | a requirement that is a message family owes a row there; see below |

**One check is not about this document at all**, and it is here because this is
where the derivation lives.
`testEveryFamilyRequirementHasALedgerRow` classifies every requirement against
the contract — command, message family, or neither — and demands that a family
have a row in the capability ledger's `familyPolicy`. Without one, `state(of:)`
looks the requirement up among the families, misses, falls through to the
**command** table, and cannot find it there either, because `help` does not
list message families: so the tool reports itself `unavailable` against every
guest, for the life of every connection, in a sentence that reads as a fact
about the Macintosh. No projection test fails, because the projection is fine.
It was proven by removing `process.front`'s row: twenty-five tests across the
three most closely related suites stayed green and only this one spoke.

The guest-side greps are `contract-coverage.md`'s, unchanged:

```
grep -oE 'json_type_is\([a-z_]+, *"[a-z.]+"\)' now-guest-ppc/src/core/wire.c \
  | grep -oE '"[a-z.]+"' | tr -d '"' | sort -u
grep -o 'strcmp(type, "[a-z.]*")' now-guest-68k/src/core/wire68.c \
  | sed 's/.*"\(.*\)".*/\1/' | sort -u
```

## What the projections reach

One row per registered projection, in catalog order. Two columns, because a
row declares two different things and reading one as the other is the blind
spot this table used to have:

- **Requires** — the guest capabilities the row cannot work without. It
  decides availability against a partial guest.
- **Exposes** — the guest capabilities a caller can actually **ask about**
  through the row: obtain that capability's own answer, or direct its effect.
  It decides what counts as covered in the gap table below. Necessarily a
  subset of Requires — a projection cannot hand back an answer it had no
  grounds to ask for — and the test checks that too.

The test compares both against the code literally.

| MCP tool | Requires | Exposes | Guest plane |
|---|---|---|---|
| `now_session_health` | — | — | none; host listener state |
| `now_session_capabilities` | — | — | none; `help` plus bounded probes, described in agent-integration.md |
| `now_hardware_census` | `census.request` | `census.request` | message family |
| `now_machine_facts` | `gestalt` | `gestalt` | command |
| `now_list_processes` | `process.list` | `process.list` | message family |
| `now_guest_log_tail` | `tail` | `tail` | command |
| `now_capture_screen` | `capture.request` | `capture.request` | message family |
| `now_catalog_search` | `catsearch` | `catsearch` | command |
| `now_software_inventory` | `software.list` | `software.list` | message family |
| `now_launch_software` | `software.list`, `launch` | `launch` | message family plus command |
| `now_reveal_item` | `reveal` | `reveal` | command |
| `now_bring_to_front` | `process.list`, `process.front` | `process.front` | message family |
| `now_request_quit` | `process.list`, `process.quit` | `process.quit` | message family |
| `now_transfer_approved_artifact` | `file.put` | `file.put` | message family |
| `now_transfer_cancel` | `file.cancel` | `file.cancel` | message family |
| `now_guest_files_capabilities` | `file.list` | — | message family |
| `now_guest_files_list` | `file.list` | `file.list` | message family |
| `now_guest_files_stat` | `file.list` | `file.list` | message family |
| `now_guest_files_download` | `file.list`, `file.get` | `file.get` | message family |
| `now_guest_files_mutate` | `file.move`, `file.trash`, `file.restore`, `file.mkdir` | `file.move`, `file.trash`, `file.restore`, `file.mkdir` | message family |
| `now_guest_files_upload_begin` | — | — | none; host staging only |
| `now_guest_files_upload_append` | — | — | none; host staging only |
| `now_guest_files_upload_commit` | `file.put` | `file.put` | message family |

**The distinct capabilities those rows require is a shorter list than the row
count, and the ones they expose is shorter still.** Most of the rows above are
the guest-files family and the sessions pair, so the surface is narrower than
its tool count suggests — the same mistake `contract-coverage.md` made when it
counted message types, one layer in. Read both columns as sets rather than
counting ticks; the gap table below is derived from the second one.

That is also why this section is not called "what the thirteen reach", which
is what it was called until 2026-07-30: a heading naming the tool count meant
every new capability renamed a published heading **and** the test string that
matches it. The count belongs in the table, which is derived; a heading is
not the place to state a number that changes.

### Required and not exposed

The rows that consume a capability internally without handing its answer back.
Each is worth reading as a shape rather than an exception, and this table is
**derived and gated** — the test builds it from `requires` minus `exposes` and
fails naming a row that is missing or does not belong. Only the last column is
hand-written.

| Row | Required, not exposed | What the caller gets instead |
|---|---|---|
| `now_launch_software` | `software.list` | a launch of one exactly-named application; not one catalog entry. The row stays here — it still consumes the catalog and returns none of it — but the CAPABILITY is no longer unreachable: `now_software_inventory` exposes it |
| `now_bring_to_front` | `process.list` | a front switch, and whether a listing CONFIRMS it; the two listings are consumed to revalidate the reference and then to check the switch landed. No listing crosses back — which is why this row does not re-expose the `front` flag `now_list_processes` already returns |
| `now_request_quit` | `process.list` | a quit request; the listing is consumed to revalidate the opaque reference |
| `now_guest_files_capabilities` | `file.list` | the **host's** guestRoot policy and bounds; no directory entry crosses back |
| `now_guest_files_download` | `file.list` | one file, in host-owned private storage, and a receipt naming it. The listing is consumed to observe that item's fork sizes, which is how the size ceiling is applied *before* any byte moves rather than by watching one arrive |

**Every capability in the second column is exposed by some OTHER row**, which
is the reading this table is for: a row appearing here says something about
that row's shape, not about a hole in the surface. `process.list` and
`file.list` are covered because `now_list_processes` and
`now_guest_files_list` expose them; `software.list` joined them on 2026-07-30,
when `now_software_inventory` landed. **That was not true when this table was
written** — `software.list` was then required by one row, exposed by none, and
a gap the next section had to describe in prose. It is the case the whole
`exposes` split was built for, and it is now closed.

The table has one hole left that nothing here can fill, and it is worth
knowing rather than inferring: this section cannot tell you whether a
required-and-hidden capability is exposed elsewhere. That is the gap table's
job, and a capability missing from both is the thing to look for.

### One requirement is not a contract name

`file.put` is a host-side name for a lane the contract spells with several
messages. It is aliased rather than renamed, because the alias is where the
mismatch is visible.

| Host requirement | Contract origin |
|---|---|
| `file.put` | `file.offer` — the host→guest push (`file.offer` → `file.accept` → bulk → `file.end` → `file.done`). The contract declares no `file.put` message; `AgentIntegrationCapabilityNames.filePut` names the lane. |

The test resolves every requirement against the contract through this table,
so a requirement that is neither a contract name nor an aliased one fails.
That matters more than it looks: an unresolvable requirement does not error
anywhere at run time — the capability ledger falls through to the command
table, misses, and reports the tool permanently unavailable against every
guest.

### Covered is not the same as exposed — the limit, and how it was closed

**This was a stated limit of the check and is now a distinction the registry
carries.** The earlier version of this section said the check could see only
that a capability was *required by some projection*, and could not see whether
a caller could ask for that capability's own answer — so a capability consumed
internally read as coverage.

`software.list` was the live instance, and it is the reason the fix landed
rather than the limit surviving another phase. `now_launch_software` requires
it and sweeps the catalog to match one name; no tool returns a listing. An
agent could launch an application it could already name exactly and could not
ask what was installed. That is a real gap, and under a `requires`-derived
check it wore a tick.

The fix is the one the earlier text named: **`exposes` beside `requires` on the
row protocol**, and coverage derived from `exposes`. Two consequences, both
visible in the tables:

- `software.list` moved from covered to a **planned** gap (W1 #3), where it
  joined the `sw` verb that is the same capability's console spelling. **It is
  now closed** — `now_software_inventory` (P1 #3) exposes the family, and the
  `sw` verb's row moved to `deliberate` for the reason `ps` and `ls` are
  there. The whole arc is what this section describes: a capability wore a
  tick, the split took the tick away, and the gap it revealed was built.
- `process.list` and `file.list` stayed covered — they are consumed internally
  by one row each *and* exposed by another. The distinction narrows coverage to
  what is genuinely askable; it does not simply reclassify everything a
  composition touches.

It was done at twelve rows rather than after the wide phase for a reason worth
recording: at twenty-one rows it is a twenty-one-row edit, and every row added
in between would have inherited the blindness and been documented as covered.

What remains true, and is now a narrower claim: a `COVERED` reading means "some
projection returns this capability's answer or directs its effect". It still
says nothing about how much of that answer, under what bound, or whether it has
ever run against a Macintosh — see Status.

### One row's answer is not JSON

`now_capture_screen` is the first, and it changed one thing in the seam rather
than in this inventory: `HostProjectionValue` gained an **attachment** beside
its encodable part, and the MCP face renders it as that protocol's `image`
content block. The bytes are deliberately absent from the structured result,
because that face serialises the structured result into the text block beside
it — a picture in a JSON field would be sent to its caller twice.

Two paging problems sit under one call, and **a caller sees neither**:

| Where | Bound | Who absorbs it |
|---|---|---|
| guest → host | the capture transport's chunked `capture.begin` / bulk / `capture.end` | `GuestListener`, as it always did for the app |
| host → face | 16 KiB per local request and response | `CaptureScreenProjection`, which pages the PNG out of a host-staged capture and hashes the result against the digest the host declared |

The cost of hiding it, so nobody has to discover it: one tool call is N+1
local round trips (a 200 KB screen is 26), a caller cannot resume a partial
fetch, and a fetch that fails halfway is reported as a failed capture rather
than as something retryable. That is the same trade the sibling TBT project
made when it collapsed its `screenshot` and `shotdata` verbs into one image
result.

### One row changes the screen and cannot confirm that it did

`now_reveal_item` is the first capability whose whole effect is on the
**person's** side of the machine, and the first whose success cannot be
checked from here. The guest asks its Finder to show an item with one
`kAEMakeObjectsVisible` Apple Event sent `kAENoReply`, then calls
`SetFrontProcess` on it. So a completed answer means the machine was
**asked**: nothing on this wire can say the Finder obeyed, that the right item
is selected, or that the Finder is frontmost yet — the switch is cooperative
and lands when the Finder next yields.

The row states that in its schema and claims nothing more. It does **not**
re-list to confirm, though the confirmable half is cheap and real — a fresh
`process.list` entry with `kind: "finder"` and `front: true` — because the
shared row-report result five verbs answer in has nowhere to carry a
host-derived outcome, and a round trip whose result cannot be reported is
worse than not taking it. Two named consequences rather than one silent one:

| | Today | What would change it |
|---|---|---|
| asked vs confirmed | reported as asked, in the schema's words | a field on `AgentIntegrationGuestRowReport`, which serves five capabilities |
| "the Finder is not running" vs "no such item" | the guest's own sentence, forwarded verbatim under one code | a distinct guest error code — `reveal` answers every refusal as `reveal-refused`, and typing them apart by reading the prose would be the host deciding |

Rule 3 is carried by two lines and not by the answer: the dispatch's audit
event (face, capability, machine, outcome) and a host line under `sw` naming
the target, because for this capability the target **is** the event — the same
reason the guest-Files family logs its paths.

### One row costs four seconds of somebody's machine, and is not gated for it

`now_software_inventory`'s `apps` domain rebuilds its inventory with a
whole-volume `PBCatSearch` sweep — about four seconds on a PowerBook doing
nothing else, which is the cost `now_catalog_search` exists to measure. The
capability ledger will **not** spend that on its own: it probes `software.list`
only when a caller passes `probeCostly`, on the stated grounds that four
seconds of someone's machine is spent on purpose
([agent-integration.md](agent-integration.md)).

**That gate stays on the ledger and is deliberately not repeated as a flag on
the tool**, and the reason is worth stating because the sibling row reached the
same conclusion by an argument that does not transfer:

| | `now_catalog_search` | `now_software_inventory` |
|---|---|---|
| plane | command — availability comes off `help`, free | **message family** — availability can only be settled by sending a request |
| could anything spend the cost incidentally? | **No.** No report can reach a command's cost, so the only way to pay is to call the tool | **Yes, and that is what `probeCostly` gates** — the capability report faced a real choice between four seconds and `unproven` |
| why no flag on the tool anyway | the only caller is already asking on purpose | the sweep is not a side effect of the answer, it **is** the answer |

So the structural half of catalog search's argument inverts here. What carries
is the other half: `probeCostly` guards **incidental** spending, and a caller
asking what is installed has asked for the sweep in the same sense as a caller
asking what the sweep costs. A required acknowledgement on top would guard a
door with nothing behind it while making the honest answer harder to obtain.

What the cost earns instead is disclosure that is sharper than a per-call flag
could be, because **the cost is per domain and per page rather than per call**:

| Ask | What it costs the machine |
|---|---|
| `apps`, cursor absent or 1 | the whole sweep, ~4 s measured |
| `apps`, a later cursor | pages the same cached inventory; no second sweep |
| `extensions` / `cdevs` / `startup` / `apple` | dozens of catalog reads, enumerated live |

One consequence runs the other way and is a reason the gate belongs where it
is: an ordinary call to this tool **settles the family** as a side effect
(`GuestListener.listSoftware` records the outcome), so one real call moves the
row in the capability report from `unproven` to the guest's own answer and
makes a later `probeCostly` report free. The ledger's probe answers a question
nobody asked; this tool's caller asked it.

### One row's answer is smaller on one guest, and every way it is smaller says so

The same row is where rule 4 — degrade the ANSWER, not the message — is most
concrete, because the degradation is enumerable.
[contract-coverage.md](contract-coverage.md) has the per-guest account; what
belongs here is what a CALLER sees, and there are three shapes of it:

| What is smaller | How the caller learns it |
|---|---|
| two of eight entry fields | `version` and `running` are **absent keys**. NOW-68K omits them deliberately — a resource-fork open per entry, a Process Manager walk per page — so absent means the machine did not look. Never `""`, never `false`: `false` would be indistinguishable from the truth on the guest that does look. |
| the `apps` inventory stops at 48 | the guest's own `note`, verbatim: `"the inventory stopped at this Mac's bound of 48 items"`. |
| `PBCatSearch` was unusable, so only the volume root was walked | the guest's own `note` again — and this one makes the answer **narrower rather than shorter**, because a root-only walk cannot see an application inside a folder. |

**The host does not parse any of those into a typed field of its own.** A
`partial: true` derived by reading the guest's prose would go stale the first
time a guest reworded a note, and deciding out of a sentence that an inventory
was incomplete is the host answering a question about somebody's Macintosh out
of its own state. The one bound this side applies to a note is its LENGTH, and
it is sized over both guests' note buffers so it cannot be the thing that
shortens a guest's declaration of its own bound.

### One row can change the machine

`now_guest_files_mutate` is the first mutating guest-Files row, and it closed
four gap rows at once because the four contract messages are one lane: they
share the path space beneath `guestRoot`, the one `file.result` code
vocabulary, and one authorization — and `file.restore` consumes what
`file.trash` answered. It **requires all four together**, which is not
tidiness: a guest serving `trash` without `restore` would offer a deletion
the row could not undo, and that pairing is the safety property rather than a
convenience. Where the four are not served the row is unavailable in typed
form; nothing partial is offered.

Two facts the gap table can no longer carry, now that those rows are closed,
and one bound worth knowing:

- **Only one guest serves the four** — the `Served` column read `ppc` for all
  of them. The row is therefore reachable in practice against the PowerPC
  guest only, and that follows from what the guest answers rather than from
  anything the host knows about it (`agent-integration.md`, "Availability is
  decided by capability, never by identity").
- **There is no `delete` on this surface and there is not meant to be.** The
  contract's verbs are `trash` and `restore`; the projection cannot express an
  unlink, never sets `file.move`'s `overwrite` flag, and refuses an argument
  that asks for it — so a collision refuses rather than replacing. That is
  what makes "everything an agent removes from a path is recoverable" a
  property of the code rather than a hope.
- **A caller must keep what a trash answers.** `trashedAs` is the only key a
  restore takes, it is not always the name the item had, and neither side
  remembers it ([files.md](files.md#changing-the-share-from-the-host)).

### One row returns text the machine wrote, and names no file

`now_guest_log_tail` is the first row whose answer is prose the guest
composed rather than facts about the machine, so what it may be pointed at is
worth stating here rather than only in its own source.

**It may be pointed at nothing.** The `tail` verb takes one argument and it
is a count (`x-commands.tail`: `lines`, default 20, most 40). What it reads
is the guest application's own in-memory ring for the launch it is in — the
same text the person at that machine has on its Logs page — and there is no
path in the verb, none in the local operation, and none in the tool's input
schema. The decision behind that:

| | |
|---|---|
| Why not a path | This row returns BYTES, which `file.list` and `reveal` do not. The Files family is confined to the host-owned `guestRoot`; `reveal` leaves that confinement only because it hands nothing back. "Tail any file on the volume" is a materially wider authority than anything on this surface has, and it is not the host's to grant in any case — the verb would have to grow an argument, which is a guest change, which means it was never a projection. |
| What already covers the named case | `now_guest_files_download`, under `guestRoot`, with the authority that belongs there. |
| What it can still disclose | A log line is prose, and some of that prose contains paths: the `get`, `put` and `files` areas log the items they handled by design ([logging.md](logging.md)). So a caller can learn the NAMES of items the machine touched, including outside `guestRoot`. The bound is the guest's own editorial judgement about its log, and it is the same text the person at the machine reads — but it is a widening over the Files family and is recorded rather than discovered later. |
| Who chooses how much | The caller, between 1 and 40. Above 40 is refused rather than clamped: the guest cannot fit more in one 4 KB control frame, and a silently smaller answer to a bigger question reads as a machine that went quiet. |
| How the bound stays visible | The guest's own `log` group says it — `shown` reads `"12 of 20 (older ones did not fit)"` when its frame budget dropped the oldest lines. That row is carried through untouched, and it is also the cross-check on the host's rendering bounds, which are sized from the guest's own buffers so they cannot bite first. |
| Encoding | Settled on the guest, not guessed here: it maps its MacRoman high range through its own table and emits `\uXXXX`, so nothing undecodable reaches this side. CR endings are gone before that — the ring holds lines without terminators. A control character *inside* a line is written `\xNN` so it is neither dropped nor passed through to corrupt a row. |

**One host-side limit this row found, which is not about `tail`.**
`CommandRequest.args` is `[String: String]`, so every typed argument reaches
the wire quoted, and the guest reads an integer argument with `strtol` on the
byte after the colon — `strtol("\"40\"")` is 0. `tail` is the first verb whose
typed argument is an integer, so nothing had met that edge. The count
therefore travels on the `line` field, which the contract declares for this
verb (`x-line`: "the first integer on the line is the count"). Widening the
args map to carry typed values is a shared-file, both-guests change; it is
recorded here and in the row's source, not made from inside one capability.

## Every gap, with its disposition

The complete list of host-askable guest capability that no projection
**exposes** — see the section above for why that is the right test and
`requires` is not. `Served` is derived from each guest's own dispatch:
**both** · **ppc** · **68k** · **none**.

Three dispositions, and the difference between them is this file's reason
to exist:

- **deliberate** — argued somewhere, with the argument cited. The test
  requires the citation, so a row cannot be promoted to "decided" by
  someone typing the word.
- **planned** — a named item in a plan, with its number. Noticed, costed,
  not built.
- **unnoticed** — nobody has decided this either way. **These are the
  rows this document was written to surface**; they are named together
  below, from this column.

| Guest capability | Kind | Served | Disposition | Why |
|---|---|:--:|---|---|
| `capture.accept` | message | ppc | deliberate | Answering a guest-initiated capture offer is the paired host's own handshake obligation, not a capability an agent asks for — [command-parity.md](command-parity.md) ("the MCP is a client, not a face"). |
| `capture.cancel` | message | ppc | deliberate | Abandoning a capture in flight, and the caller-facing half of it **is** reachable: `now_capture_screen`'s `abandon` releases the connection's one transfer lane. What a caller directs there is the host's WAIT, not this message — `GuestListener.cancelCapture` settles the request locally whether or not the guest honours the wire message, and the answer never reports which happened. Requiring it would also make a capability both guests serve read as PowerPC-only, which rule 4 of the [parity slice plan](plans/2026-07-29-004-feat-now-tbt-classic-parity-slice-plan.md) refuses: degrade the answer, not the message. |
| `capture.refuse` | message | ppc | deliberate | The refusal half of the same handshake, and the same reason — [command-parity.md](command-parity.md). |
| `exec.cancel` | message | both | deliberate | Ends an exec, and is excluded with the rest of the console plane — [agent-integration.md](agent-integration.md). |
| `exec.input` | message | both | deliberate | Part of the console plane excluded under rule 3 — [agent-integration.md](agent-integration.md) and the parity slice plan. |
| `exec.request` | message | both | deliberate | The console plane. A shell is not user-initiable in any meaningful sense and is the one thing [agent-integration.md](agent-integration.md) is right to keep out. |
| `process.shot` | message | ppc | deliberate | Excluded by name in the [parity slice plan](plans/2026-07-29-004-feat-now-tbt-classic-parity-slice-plan.md): PPC-only, and no consumer asked for a single-window capture. |
| `stream.refresh` | message | ppc | unnoticed | Part of the live-stream bracket; see `stream.start`. |
| `stream.start` | message | ppc | unnoticed | A stream is a continuous host-owned bracket rather than one bounded call, so it may well not belong on a tool surface at all — but **that is a hypothesis, not a decision**: nothing argues it, and the host app's live view owning it today is a fact about what exists rather than a reason. |
| `stream.stop` | message | ppc | unnoticed | The other end of the same bracket; see `stream.start`. |
| `overview` | probe | none | deliberate | Reachable as `now_hardware_census`'s `probe` argument, like the thirteen below it — read the probe note under this table for why `Served` says `none` for all fourteen. The synthesis, in plain words: model, CPU, RAM, System, display, storage. Both guests answer it; NOW-68K adds addressing and free memory ([contract-coverage.md](contract-coverage.md)). |
| `identity` | probe | none | deliberate | The curated dozen — model, CPU and clock, RAM, ROM, OS, CarbonLib, QuickDraw, keyboard, networking. Both guests answer; NOW-68K adds **Addressing**, which is where the 24-bit mode fact lives rather than in a fifteenth probe ([contract-coverage.md](contract-coverage.md)). |
| `selectors` | probe | none | deliberate | The documented Gestalt walk. **PPC answers, NOW-68K answers `refused`** — 32 KB of selector names does not fit a 384 KB partition — and an agent gets that refusal as a completed call saying the machine declined to look, never as an absence ([contract-coverage.md](contract-coverage.md)). |
| `video` | probe | none | deliberate | The GDevice walk, one record per display. Both; `absent` on a Mac with only original QuickDraw, which is a finding about the hardware ([contract-coverage.md](contract-coverage.md)). |
| `volumes` | probe | none | deliberate | Mounted volumes via indexed `PBHGetVInfo`. Both guests ([contract-coverage.md](contract-coverage.md)). |
| `drives` | probe | none | deliberate | The drive queue, zero bus I/O. Both guests ([contract-coverage.md](contract-coverage.md)). |
| `drivers` | probe | none | deliberate | The Device Manager unit table, with an in-ROM check. Both guests ([contract-coverage.md](contract-coverage.md)). |
| `adb` | probe | none | deliberate | The ADB device table. Both guests ([contract-coverage.md](contract-coverage.md)). |
| `ata` | probe | none | deliberate | IDENTIFY DEVICE through the ATA Manager — the IDE boot disk a SCSI scan cannot see. PPC answers; **NOW-68K answers `absent`**, Gestalt-gated, because that machine's internal disk is SCSI ([contract-coverage.md](contract-coverage.md)). |
| `pccard` | probe | none | deliberate | Card Services' version and socket count; touches no socket and reads no CIS. PPC answers; **NOW-68K answers `absent`** — PCMCIA arrived after that Mac ([contract-coverage.md](contract-coverage.md)). |
| `pram` | probe | none | deliberate | Parameter RAM. **PPC answers `partial`** (20 of 256 bytes is all `GetSysPPtr` reaches) where NOW-68K reads all 256 — the one probe where the 68K guest reaches further, and the note says what was out of reach ([contract-coverage.md](contract-coverage.md)). |
| `power` | probe | none | deliberate | The Power Manager's battery view, Gestalt-gated. Both guests; a desktop answers `absent` ([contract-coverage.md](contract-coverage.md)). |
| `pci` | probe | none | deliberate | The Name Registry device tree. **`absent` on both** — the 1400c is pre-PCI and no 68K Mac has a Name Registry — which is a fact about the hardware and the clearest case for why `absent` is not `refused` ([contract-coverage.md](contract-coverage.md)). |
| `scsi` | probe | none | deliberate | An INQUIRY bus scan: the contract's one declared exception to passive-by-rule, paced at one target per page. PPC answers; **NOW-68K answers `refused`** because active bus I/O is never unattended there. This is the probe a caller must read the outcome of rather than the rows ([contract-coverage.md](contract-coverage.md)). |
| `cancel` | command | 68k | deliberate | The 68K guest's console spelling of transfer cancel, and `now_transfer_cancel` needs the `file.cancel` **message** rather than this verb: the message is what both guests dispatch, and requiring the verb would make a capability both guests serve read as 68K-only — rule 4 of the [parity slice plan](plans/2026-07-29-004-feat-now-tbt-classic-parity-slice-plan.md). The verb exists so a person at a PowerBook whose host has stopped answering can still end a transfer, which is a reason for the GUEST to have two faces, not a second mechanism for the host to pick between — [command-parity.md](command-parity.md). |
| `census` | command | both | deliberate | The console spelling of `census.request`, which is projected as `now_hardware_census`. `now_hardware_census` needs the **family** and not this verb, for the reason `front` and `quit` give: the verb is the flat single-page read a person types at the machine, and the family is the one that paginates and carries a per-probe outcome — which is the whole capability. One capability, one route per face — [command-parity.md](command-parity.md). |
| `front` | command | both | deliberate | `now_bring_to_front` needs the `process.front` **family**, not this command, for the reason `quit` gives below: the command takes a NAME, and the opaque-reference and PSN-revalidation model the tool stands on has nothing to stand on without the message. The name form is the console's, by contract — one capability, one route per face ([command-parity.md](command-parity.md)). |
| `help` | command | both | deliberate | Already sent, once per connection, to build the capability report — its answer *is* `now_session_capabilities` ([agent-integration.md](agent-integration.md)). A second route would be the same answer twice. |
| `ls` | command | both | deliberate | The console spelling of `file.list`, which is projected. One capability, one route — [command-parity.md](command-parity.md) ("two ways to name a target is not two faces"). |
| `ps` | command | both | deliberate | The console spelling of `process.list`, which is projected — same rule as `ls`, [command-parity.md](command-parity.md). |
| `put` | command | 68k | planned | W1 #4, and the half of it that did not land. `now_guest_files_download` closed the `file.get` message; this verb is the same capability by the other mechanism — guest-initiated, a leaf name inside the same share root `ls` lists (`now68k_desktop_folder`, "ONE root, both ways"). What blocks it is host machinery rather than the guest or authority: a row's `requires` is a **conjunction**, so a row cannot say "the family OR the verb". Requiring both switches the tool off against every guest; requiring neither overstates; and routing to the verb behind a row that requires the family would make the tool work exactly where the capability report says it cannot. A disjunctive requirement in `HostProjectionCatalog`'s contract is what closes this, plus the reported bound that the verb cannot express a subfolder path. |
| `putstat` | command | ppc | unnoticed | Transfer diagnostics. The host reads them internally to size a transfer; whether an agent should be able to is undecided. |
| `quit` | command | both | deliberate | `now_request_quit` needs the `process.quit` **family**, not this command: the opaque-reference and PSN-revalidation model has nothing to stand on without it, and is not relaxed to make a tool work ([agent-integration.md](agent-integration.md)). |
| `screenshot` | command | both | deliberate | The console spelling of `capture.request`, which is projected as `now_capture_screen`. One capability, one route — [command-parity.md](command-parity.md) ("two ways to name a target is not two faces"), the same rule that keeps `ls` and `ps` off this surface. |
| `shotdiag` | command | 68k | unnoticed | Where a staged capture read from. It found the 24-bit addressing defect on the 180c and is reachable from no host face. |
| `sw` | command | both | deliberate | The console spelling of `software.list`, which is projected as `now_software_inventory` — so the same rule as `ls`, `ps` and `census`: one capability, one route per face ([command-parity.md](command-parity.md), "two ways to name a target is not two faces"). It was `planned` beside the message row until 2026-07-30, and closing the message is what settled the verb. **One thing this verb has that the family does not**, recorded rather than left to be discovered: `sw` with no domain runs an OVERVIEW — per-domain counts rather than items — and `software.list` has no domainless form to project it with. That is a separate capability with a separate shape, and whether it belongs on this surface is a decision for whoever wants it, not one this row makes by omission. |
| `vers` | command | ppc | deliberate | Build identity. `hello` already carries name, version and OS, and `now_session_health` reports all three ([agent-integration.md](agent-integration.md)). |
| `vprobe` | command | both | unnoticed | Framebuffer read cost. A ~12 s measurement on the guest, which is a reason to gate it, not a reason it is absent — nothing has decided either way. |

### The unnoticed rows, named together

Because they are the point: `stream.start`, `stream.stop`,
`stream.refresh`, `putstat`, `shotdiag`, `vprobe`.

Gated against the table's own `unnoticed` column, so closing one of these is
a two-place edit and the test names the second place. `capture.cancel` used to
be on the list and left it by being **decided** rather than by being built —
see its row; that is the other way a name leaves. `gestalt` left it the third
way, by being **built**: it was the largest of them, and
`now_machine_facts` now exposes it, so its gap row is gone rather than
re-dispositioned.

Every one of them is served by a guest right now. Nothing in this repository
argued for their absence; they are absent because the question never came
up. That is exactly the shape of the `process.list` drift
`command-parity.md` was written for, one layer out.

### The census probes were one row and are now fourteen

`contract-coverage.md`'s hard-learned rule is that a row which is a
subsystem gets expanded, because `census.request` as a single tick hid the
fact that NOW-68K could not report its own CPU. While no host face reached
the census, fourteen rows here would have carried nothing a single row did
not — so the test encoded the expansion as a **condition** rather than a
judgement, adding the 14 probes to the universe it demands rows for the
moment any projection exposed `census.request`.

**That fired when `now_hardware_census` landed, and this is the fourteen.**
They are in the contract's registry order rather than alphabetically, so
they read beside `contract-coverage.md`'s per-guest table.

Two things about those rows are worth reading before quoting them:

- **Every one is `deliberate` and every one is reachable.** A probe is an
  ARGUMENT of `now_hardware_census`, not a capability of its own: the probe
  argument is required, the registry is the guest's, and the row bounds a
  probe name without enumerating it — so a probe a newer guest grows is
  reachable the day it ships, with no host release. What each row's Why
  states is therefore not an absence but the **outcome** an agent gets, per
  guest, which is the thing a single tick hid.
- **`Served` says `none` for all fourteen, and that is a fact about the
  DERIVATION rather than about the guests.** Both guests answer all
  fourteen. The Served column is derived from the four dispatch greps at the
  top of this file, which read each guest's message and command tables; the
  probe tables are neither, and live in `now-guest-ppc/src/census/
  census_probes.c` and `now-guest-68k/src/census/census68.c`. So `none`
  here means "no dispatch table names it", and the per-guest truth is
  `contract-coverage.md`'s census section, which derives from those probe
  tables and is pinned by `CensusProbeRegistryTests`. Read the two together;
  neither column is wrong about its own question.

### One row hands its caller the cursor

`now_hardware_census` is the second paginated capability and it makes the
opposite choice from the first, deliberately.

| | `now_capture_screen` | `now_hardware_census` |
|---|---|---|
| paging | hidden; the row fetches every page | exposed; one call is one page |
| why | the answer is one picture, and a half-fetched PNG is nothing | the page boundary is **semantic** — the contract paces `scsi` at ONE target per page so a wedged target stalls one frame turnaround |

Looping until `more` went false would collapse that pacing back into one
unbounded call and hand a caller an answer it had no way to stop. So
`hasMore` and `nextCursor` are required fields of the answer, and a page
carrying more than the contract's 16 rows is **refused rather than
trimmed** — a short page under a `hasMore` that says it is whole is the one
failure a paginated answer must not be able to have.

### Two levels of outcome, and neither is the other

The census is the first capability where "it worked" has two answers, and
`x-census` exists to keep them apart:

| Level | Vocabulary | Says |
|---|---|---|
| the CALL | `completed` / `refused` / `unavailable` | whether a Macintosh answered at all |
| the PROBE, inside a completed call | `present` / `absent` / `partial` / `refused` / `failed` / `not-attempted` | what that machine found when it looked |

A probe answering `refused` — NOW-68K's `selectors` and `scsi` — is a
**completed call** whose report says the machine declined to look. A probe
answering `absent` — `pci` on both guests — is a **finding about the
hardware**, rendered as content with zero rows. Flattening either into the
call's `refused` arm would tell a caller nothing reached the machine, which
is both false and unfixable by retrying; flattening `absent` into an empty
success would claim the host had looked and found nothing.

The same discipline covers what the guest did not say: `total`, `note` and
`nextCursor` are absent keys rather than `0`, `""` and `0`. A zero the
guest never sent is a claim about somebody's Macintosh.

### `gestalt` and the census answer adjacent questions by different routes

`gestalt` — projected as `now_machine_facts`, and until it landed the
largest single unnoticed gap — overlaps the
census's `identity` and `selectors` probes: both reach Gestalt selectors,
and on the PowerPC guest both can answer CPU, memory and OS. They are not
unified and should not be — the overlap is **two capabilities answering
adjacent questions**, which is fine, where composing one out of the other
would not be. Three concrete differences an integrator should see rather
than reconcile:

| | the census | `gestalt` |
|---|---|---|
| plane | message family, both guests | command, PPC only ([contract-coverage.md](contract-coverage.md): the verb answers `unknown-command` on NOW-68K) |
| shape | paged, per-probe outcome, raw beside decoded | one command result, every group |
| what absence means | a typed probe outcome the caller reads | the verb's own refusal, or `now_machine_facts` unavailable |

**What `now_machine_facts` being PowerPC-only does not say** is that the 68K
machine cannot answer these questions. It largely can: `health.c` samples
identity, CPU, System, VM, MacTCP, geometry and RAM at startup for its own
panel, and the census reports most of the same facts under `identity` and
`overview` on both guests. What is missing there is the VERB — the one-call
grouped rendering — which [contract-coverage.md](contract-coverage.md) calls
"closer to a rendering job than a measurement one" and "the cheapest large gap
left". Deferred, not refused, and the tool's own unavailability sentence points
a caller at the census rather than implying a mute machine.

The census's `selectors` probe **is** the documented Gestalt walk on the
machines that can afford it, and says so in its own outcome where it cannot
— which is why a host that answered `gestalt` out of a census page, or
vice versa, would be composing a fact rather than carrying one.

### Asks the operations section does not mark

One capability is host-askable and is not in a `receive` operation, because
the family is symmetric — whoever receives a `census.request` answers for
its own machine. The test requires each row here to genuinely appear in a
`send` operation, so this table cannot be used to smuggle in an ordinary
host ask.

| Guest capability | Contract operation | Why the host asks it |
|---|---|---|
| `census.request` | `censusExchange` (`action: send`) | Symmetric by definition; in practice the host asks and the guest — the machine with hardware worth asking about — serves. |

## Status

**Tested, not metal-verified.** Nothing in this file has been read against a
Macintosh; it is a derivation over source and a contract, and the guest-side
`Served` column claims only what a guest's dispatch answers — never that any
of it has run. `contract-coverage.md`'s "how far each served thing is
proven" is the axis for that and is not duplicated here.

The test is proven by mutation: adding a registry row without a table entry,
and declaring a gap for a capability a projection exposes, both fail naming the
capability. The `exposes` distinction was proven the same way — making
`now_launch_software` claim it exposes the `software.list` it only consumes
makes the `software.list` gap row fail as a phantom, naming it. The three
checks added on 2026-07-30 were proven the same way and each was watched
failing: removing `process.front`'s ledger row, removing `now_request_quit`
from the required-and-not-exposed table, and adding a name to the unnoticed
paragraph that the table does not mark unnoticed. The last of those found a
real defect in its own first draft — reading the whole section rather than its
first paragraph collected the two names the explanation mentions *because* they
are not on the list.

Last derived: 2026-07-30, on `claude/tbt-parity-slice` with eleven
projections landed. The two most recent were `now_software_inventory` — which
**closed the gap this document's `exposes` split was built to find**: the
`software.list` row left the gap table, the `sw` verb moved from `planned` to
`deliberate`, and `now_launch_software`'s required-and-not-exposed row stayed
exactly where it was, because that row still consumes a catalog and returns
none of it — and `now_machine_facts`, which removed the largest name from the
unnoticed list by building it. Before those, `now_hardware_census` expanded the
census into fourteen probe rows.

Each branch stamped this line with its own name; the integration is what the
tables actually describe, so this says so instead. The stamp no longer carries a
registry count: the previous one said sixteen while the registry held
seventeen, which is what a hand-typed number beside a derived table costs.
Its predecessor integrated `now_reveal_item`,
`now_transfer_cancel`, `now_guest_files_mutate` and
`now_guest_files_download` — each stamped this line on its own branch, and the
integration is what the tables actually describe. Re-derive by
running `swift test --filter MCPCoverage` rather than by reading — if the
tables and the code disagree, the code is right and the test says so.
