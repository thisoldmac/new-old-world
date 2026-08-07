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
| `now_observe_elements` | `elements` | `elements` | command |
| `now_mirror_open` | — | — | none; opens the host's own Mirror window and asks the Mac nothing. The row every other `now_mirror_*` assumed away: they read a state engine that only runs while that window is open, and until this landed the only ways to open one in a running host were a click on the host's own screen and `--open-mirror` at launch |
| `now_mirror_status` | — | — | none; reads the native Mirror state engine without another guest request |
| `now_mirror_snapshot` | — | — | none; reads the native Mirror state engine without another guest request |
| `now_mirror_find` | — | — | none; queries the native Mirror state engine without another guest request |
| `now_mirror_wait` | — | — | none; waits for the native Mirror state engine without another guest request |
| `now_mirror_metrics` | — | — | none; reads the host's own act and scene-cycle clocks, and asks the Mac nothing |
| `now_mirror_lifecycle` | — | — | none; reports the resident facts the host already read, and asks the Mac nothing |
| `now_mirror_journal` | — | — | none; reads the host's own operation journal, and asks the Mac nothing |
| `now_mirror_drive` | — | — | command; the verb depends on the gesture the plan resolves to (`winact`, `menuact`, `key`, or a Finder script), so the row declares no requirement: demanding all four would make a keystroke unavailable on a guest that serves `key` and not `script`. The executor's own refusal names the missing half. |
| `now_guest_log_tail` | `tail` | `tail` | command |
| `now_capture_screen` | `capture.request` | `capture.request` | message family |
| `now_stream_screen` | `stream.start`, `stream.stop`, `stream.refresh` | `stream.start`, `stream.stop`, `stream.refresh` | message family |
| `now_catalog_search` | `catsearch` | `catsearch` | command |
| `now_framebuffer_probe` | `vprobe` | `vprobe` | command |
| `now_capture_diagnostics` | `shotdiag` | `shotdiag` | command |
| `now_transfer_diagnostics` | `putstat` | `putstat` | command |
| `now_software_inventory` | `software.list` | `software.list` | message family |
| `now_launch_software` | `software.list`, `launch` | `launch` | message family plus command |
| `now_reveal_item` | `reveal` | `reveal` | command |
| `now_bring_to_front` | `process.list`, `process.front` | `process.front` | message family |
| `now_request_quit` | `process.list`, `process.quit` | `process.quit` | message family |
| `now_window_act` | `winact` | `winact` | command |
| `now_control_act` | `ctlact` | `ctlact` | command |
| `now_menu_act` | `menuact` | `menuact` | command |
| `now_text_get` | `textget` | `textget` | command |
| `now_text_set` | `textset` | `textset` | command |
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

### The act plane is six projected rows; direct dialog input comes first

**CORRECTED 2026-07-31.** This section was headed "Three rows are published
and no machine serves them" for most of that day, and both halves of that
sentence are now wrong: the plane is six rows, and the PowerPC guest serves
every command under it. The correction is dated rather than typed over
because the argument the old section made is still the reason these rows are
shaped the way they are — only its status changed.

**What the old section argued, and still holds.** `now_window_act`,
`now_text_get` and `now_text_set` were registered while nothing served them,
which sounds like the exact failure
`testEveryRequirementResolvesToTheContract` was written to prevent and is its
opposite. The difference is where the "no" comes from. An unresolvable
requirement fails nowhere: the ledger looks the name up among the message
families, misses, falls through to the command table, misses again, and the
tool goes dark for the life of every connection with a sentence that reads as
a fact about the machine. Declared in the contract's `x-commands`, the same
names resolve as **commands**, and a command's availability is settled
against the connected guest's own `help` table — so the row is unavailable
because the machine said so. That is what makes the plane PowerPC-only by
derivation, with nothing on the host side asking which guest answered,
exactly as with `reveal` and `tail`.

**What changed.** The PowerPC guest now serves `winact`, `textget`,
`textset`, `ctlact` and `menuact`, and — the piece that was actually blocking
— the reference layer beneath them. Three rows became six in the same day:

- `now_control_act` drives one control by answering the application's own
  `TrackControl`, so the application runs its real mouse-down handler.
- `now_menu_act` performs one menu command by answering its `MenuSelect`. It
  is the one row on this surface whose identity check is a coordinate rather
  than a reference — a menu press carries no handle, so `titleLeft` makes the
  press itself the identity, and a press anywhere else is the person's.
- `now_observe_elements` is the observation that MINTS the references the
  other five take. It is an observation and not an act: read-only tier,
  registered with the observations, and deliberately outside
  `MirrorActProjections.rows`.

On 2026-08-03 the guest gained a seventh act-plane command, `ditemact`,
for the native Mirror's direct keyboard-and-mouse path. It keeps a Dialog
Manager item distinct from the ControlRecord that may occupy the same box.
Its MCP projection is intentionally **planned after the human-input proof**
under U5/KTD11 of the [NOW Mirror UX completion plan](plans/2026-08-03-001-now-mirror-ux-completion-plan.md); the gap row below prevents that
sequencing choice from becoming an unnoticed omission.

Two consequences worth stating plainly:

- **A call today still reaches no wire, and the missing half has moved to
  this side.** The host carries no act lane and no observation lane, so the
  protocol methods answer a typed `unavailable` naming what is missing
  (`now-act-lane-absent`, `now-observation-lane-absent`) — never a refusal,
  never an empty success. A caller reading either code has been told the gap
  is HERE, which is a different fact from a machine that answered "I do not
  serve that".
- **`CommandRegistryTests.servedByNoGuestYet` is empty**, and that is what
  the debt list was for. Its machinery stays, so the next verb declared ahead
  of a guest costs a written reason rather than a silent subtraction.

Four verbs of the reference layer — `observe`, `handle`, `axtree`, `axsnap` —
are served and reach no row. They are in the gap table below, where they
belong, rather than here.

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

### One capability is three rows, because availability is per row

The diagnostics — `vprobe`, `shotdiag`, `putstat` — are one item in the plan
(P1 #13), one local operation on the wire, and **three registry rows**. That
is the one place in this inventory where a single guest-facing lane deliberately
becomes three tools, so here is the reason.

They are not served by the same guests:

| verb | measures | Served |
|---|---|:--:|
| `vprobe` | framebuffer read cost by access method | both |
| `shotdiag` | where a staged capture read from | 68k |
| `putstat` | where a received file spent its time | ppc |

`requires` is a **conjunction**, and a row is the unit the capability ledger
answers for. So one row was not available:

| One row requiring… | What the ledger would report | Why it is wrong |
|---|---|---|
| all three | `unavailable` against every guest, forever | no guest serves all three, and the sentence reads as a fact about the Macintosh |
| `vprobe` only, exposing `vprobe` | available on both guests | the tool would still ANSWER the other two while this document went on calling them unreached — a lie the derived gap table cannot see |
| `vprobe` only, exposing all three | rejected by the seam | `exposes ⊆ requires` is enforced, and rightly |

**The census's two-levels-of-outcome shape does not rescue it**, and the reason
is worth keeping because it is easy to reach for. That shape works because a
census probe is an **argument**: it is in no command table, so the ledger could
not resolve it even if a row asked. These three are first-class commands in the
guest's own `help` table, which the ledger resolves one at a time — so wearing
the census's shape here would take three capabilities the ledger can answer for
individually and collapse them into one it must be wrong about.

Three rows, each requiring and exposing exactly its own command, makes each
exactly as available as the connected machine makes it — the same derivation
that already makes `gestalt`, `tail`, `catsearch` and `reveal` PowerPC-only
without anything on this side asking which guest answered. A caller learns
which of the three its machine answers the same two ways it learns anything
else here: `now_session_capabilities` before calling, and the guest's own
`unknown-command` refusal on calling anyway.

This is the same wall the `put` row below reports from the other side, and
these rows do **not** close it: a genuinely disjunctive requirement is still
unexpressible. What the trio shows is that the wall only bites when one
capability must span the alternatives. Three separate capabilities that happen
to share a lane do not need a disjunction at all.

### One row's result must not be read as another's

`now_framebuffer_probe` measures the framebuffer read path. **A failing row in
its answer says nothing about whether screen capture works**, and this is
recorded rather than left to be rediscovered: a `vprobe` run on the PowerBook
1400c reported `CopyBits failed`, and that failure does not reproduce through
`capture.request` (plan 005, Metal). Different paths.

Both faces carry the distinction rather than assuming a reader will infer it —
the tool description says it in as many words, and the app's card says it
before the probe is run rather than as a footnote under a number that has
already misled someone. Neither side parses the guest's rows to say it: which
row failed and what that means is the machine's account, and a host that
turned "CopyBits failed" into a typed field would be answering for the
machine and would go stale the first time the guest reworded it.

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
| `host.shown` | message | ppc | deliberate | The host's answer to a guest-initiated `host.show` — the PPC guest's dispatch RECEIVES it as the asker, which is what the Served column's derivation sees; no guest serves one. The host-surface family runs guest-to-host by definition — its subject is a WINDOW on the modern machine, which no classic Mac has — so no guest will ever serve one and there is nothing here for a projection to ask a guest for ([command-parity.md](command-parity.md), and the `guestAsksHostSurface` / `hostServesHostSurface` operations in the contract). The agent-facing reading of the same act is `now_mirror_open`, which is a projection over the HOST rather than over a guest. |
| `chat.catalog` | message | ppc | deliberate | The host's answer to a guest-initiated `chat.models` — the PPC guest's dispatch RECEIVES it as the asker, which is what the Served column's derivation sees; no guest serves one. The chat family runs guest-to-host by definition — its subject is the host's own model harness, which no classic Mac has — so no guest will ever serve one and there is nothing here for a projection to ask a guest for; the MCP is a client of guests, not of the host's own services ([command-parity.md](command-parity.md), and the `guestAsksChat` / `hostServesChat` operations in the contract). The agent-facing reading of the same harness is the chat face itself, not a projection. |
| `chat.delta` | message | ppc | deliberate | The streamed half of the host's answer to `chat.send` — same definitional direction as `chat.catalog`, same citation ([command-parity.md](command-parity.md)). |
| `chat.result` | message | ppc | deliberate | The terminal half of the same turn, same reason ([command-parity.md](command-parity.md)). |
| `chat.status` | message | ppc | deliberate | The transient liveness line of the same family, same reason ([command-parity.md](command-parity.md)). |
| `cloud.card` | message | ppc | deliberate | The host's answer to a guest-initiated `cloud.detail` — the PPC guest's dispatch RECEIVES it as the asker, which is what the Served column's derivation sees; no guest serves one. The cloud family runs guest-to-host by definition — its subject is the host's own iCloud, which no classic Mac has — so no guest will ever serve one and there is nothing here for a projection to ask a guest for; the MCP is a client of guests, not of the host's own services ([command-parity.md](command-parity.md), and the `guestAsksCloud` / `hostServesCloud` operations in the contract). |
| `cloud.listing` | message | ppc | deliberate | The host's answer to a guest-initiated `cloud.list` — same definitional direction as `cloud.card`, same citation ([command-parity.md](command-parity.md)). |
| `cloud.refuse` | message | ppc | deliberate | The refusal half of the same family, same reason ([command-parity.md](command-parity.md)). |
| `cloud.report` | message | ppc | deliberate | The host's answer to a guest-initiated `cloud.services` — same definitional direction as `cloud.card`, same citation ([command-parity.md](command-parity.md)). |
| `exec.cancel` | message | both | deliberate | Ends an exec, and is excluded with the rest of the console plane — [agent-integration.md](agent-integration.md). |
| `exec.input` | message | both | deliberate | Part of the console plane excluded under rule 3 — [agent-integration.md](agent-integration.md) and the parity slice plan. |
| `exec.request` | message | both | deliberate | The console plane. A shell is not user-initiable in any meaningful sense and is the one thing [agent-integration.md](agent-integration.md) is right to keep out. |
| `preview.begin` | message | ppc | deliberate | The transfer bracket answering a guest-initiated `cloud.preview` (the photo preview's raw indexed rows) — the PPC guest's dispatch RECEIVES it as the asker, exactly the `cloud.card` situation: the family runs guest-to-host by definition, no guest will ever serve one, and there is nothing here for a projection to ask a guest for ([command-parity.md](command-parity.md), the contract's `hostServesCloud`). |
| `preview.end` | message | ppc | deliberate | The closing half of the same bracket, same reason ([command-parity.md](command-parity.md)). |
| `process.shot` | message | ppc | deliberate | Excluded by name in the [parity slice plan](plans/2026-07-29-004-feat-now-tbt-classic-parity-slice-plan.md): PPC-only, and no consumer asked for a single-window capture. |
| `scene.request` | message | ppc | planned | M6 of the [mirror integration plan](plans/2026-07-31-007-feat-now-mirror-integration-plan.md). The wire half landed with M4/M5 — the guest walks and serves an IR-v1 scene as a transfer, the host decodes it and refuses an unknown major — and the projection is deliberately not part of that landing. A scene is the input an agent *acts* on, so what a row must decide is addressing, authority and how a scene renders to a caller; settling that inside the wire change would put a projection choice where the wire shape is argued, which [streaming-a-scene.md](streaming-a-scene.md) names as the thing not to do. Nothing about the ask is unnoticed: it is built, decodable, and waiting for a row. |
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
| `activate` | command | ppc | deliberate | The same capability as `front`, addressed by process serial instead of by name — and `now_bring_to_front` already needs the `process.front` **family** for the reason that row gives. One capability, one route per face ([command-parity.md](command-parity.md)). What `activate` adds over `front` is real but is a GUEST-side property: it takes the identity an observation minted, so a driver that has just walked the machine does not have to go back to a name that may match twice. The host's own action dispatcher sends it directly for exactly that reason. That is a second route for one capability, which is what this column exists to refuse. |
| `actselftest` | command | ppc | unnoticed | Proves the act plane's trap calling convention from inside one process, and it is the only instrument that reads the CALLER's side of the call — every other one reads ours. It matters more than its size, because a patch whose result lands in the wrong slot **does not crash, it lies**: every counter the plane owns reports success while the application reads a value we never wrote. Nobody has decided either way. What a row would have to settle first: whether an agent about to drive the act plane should be able to ask "is this machine's ABI the one you were built against" before it acts — the case for is that a silent wrong answer is the failure mode this plane actually has; the case against is that a host could simply call it once per session itself and never expose it. |
| `ditemact` | command | ppc | planned | U5/KTD11 of the [NOW Mirror UX completion plan](plans/2026-08-03-001-now-mirror-ux-completion-plan.md): prove the keyboard-and-mouse Mirror path first, then add MCP parity as a thin adapter over the same typed operation. The command selects one observation-minted, revalidated 1-based DITL item through the application's Dialog Manager path; projecting it before the direct UI is watched would invert that acceptance order. |
| `dragpress` | command | ppc | unnoticed | Presses the mouse button on an element and LEAVES IT DOWN, handing the gesture to the resident's Time Manager drag vehicle. Landed 2026-08-07 with the vehicle itself; nobody has decided whether an agent should be able to ask for it. **What a row would have to settle first, and it is not the usual question:** every other capability on this surface either reads a machine or asks an application to do something it already knows how to do. This one moves a PHYSICAL POINTER on somebody's Macintosh and holds its button down — so the question is not whether it is useful but whether a caller who is not looking at the screen should be able to start a gesture a person at that machine will be fighting. The resident's dead-man bounds the damage in TIME (it releases whether or not anyone asks, and clamps its own deadlines so a caller cannot switch it off), which is exactly the property that would make a row defensible; it does not bound it in SPACE. Deciding this means deciding all three drag verbs together, not one. |
| `dragmove` | command | ppc | unnoticed | Publishes a new pointer position for a held drag. Same landing, same undecided status, and it cannot be decided separately from `dragpress` — a press with no move is not a gesture. Its own distinguishing question is a smaller one: this verb is also what relays caller liveness, so a projection would be taking on the obligation to keep talking, and a tool that stopped mid-gesture would produce a dead-man release rather than an error. That is the honest failure and it is still a failure a caller has to be told about in advance. |
| `dragrelease` | command | ppc | unnoticed | Asks the resident to release a held drag. Same landing and same coupling to the other two. The one thing it adds to the decision: it reports that it ASKED and never that it released, because the resident's own deadline may have got there first — so a projection would have to carry a four-valued outcome (released-as-asked, dead-man-idle, dead-man-cap, session-lost) rather than a boolean, and a tool that flattened it would be asserting an outcome nobody observed. |
| `aesend` | command | ppc | unnoticed | One of four core Apple Events — quit, oapp, odoc, pdoc — to a process named by its serial. A closed vocabulary, not a class/id pipe, which is what makes it a candidate at all. Nobody has decided. What a row would have to settle first: `quit` overlaps `now_request_quit` outright, so a row would either drop that op or be a second route to a capability already projected; and the two document ops are the only way this product can open or print a file on the guest, which is a capability no tool has and nobody has asked for. Deciding it means deciding those two questions separately, not deciding one verb. |
| `key` | command | ppc | planned | **W3** of the parity slice. **The pane face landed 2026-08-01; this row tracks the MCP face, which has not.** One keystroke, posted through the Event Manager — the ground `now_text_set` cannot cover: a dialog that answers only keystrokes, and keys that carry no text (Return, Escape, the arrows). **The row that landed is the human-facing one, and it is `mods`-gated rather than blanket.** `ActionModel.availability(.key)` is now a function of `mods`: `mods == 0` answers `.available(command: "key")` and routes through `AgentIntegrationHostAdapter.key` → `AgentIntegrationActControl.key` (reads the input plane's own lower-case `posted` row, not the act plane's `Dispatch`); `mods != 0` still answers `.unavailable`, refused before a request is built. `MirrorModuleView`'s drawing captures a `keyDown` (`MirrorKeyCaptureView`, an AppKit view because `.onKeyPress` needs macOS 14 and this app supports 13) and `ActionModel.paneKeystroke` translates it, folding Shift into the character rather than into `mods` — the guest's own key table is case-sensitive on the char, not on a bit. **Not landed:** the *agent*-facing row — no `KeyProjection.swift`, no `AgentIntegrationClient.key` on the protocol, no MCP/`appIntents` face — so an MCP caller still gets no `key` tool. **Not verified:** the capture view's AppKit/SwiftUI integration has not been run in the built app (no display attached to this work); `docs/pane-keys-audit.md` names the specific risk and the check that would retire it. What a row must still decide for the modified half is the honest limit stated here since: an event's modifiers live on the Event Manager's queue element, and the only call that returns it is `PPostEvent`, which is `CALL_NOT_IN_CARBON` — so this verb refuses `mods != 0` outright rather than posting a bare key and reporting success ([input-plane-decisions.md](input-plane-decisions.md)). |
| `cycle` | command | ppc | unnoticed | Brings each faced application forward in turn with the anchor plane held armed, so each executes its own event loop once and the resident captures its anchor, then restores the previously frontmost application. Landed 2026-08-07 (plan 018 slice 15) as the guest half only. **The gap is honest rather than argued: nobody has decided whether an agent should be able to ask for it.** **What a row would have to settle first:** this verb DISTURBS THE MACHINE on purpose — windows come forward and flash past — so exposing it to an agent is a question about consent and surprise rather than about plumbing. It is the one verb on this surface whose whole point is a visible side effect, and the argument against a tool is that an agent could invoke it while a person is working; the argument for is that an agent facing a freshly booted Mac currently sees one window and has no way to fix it, which is exactly the hole that drove agents to macOS accessibility scripting. The capability itself is not in doubt. |
| `mirror` | command | ppc | unnoticed | What this Mac can say about MIRROR - whether each of its three resident extensions is loaded, whether its agent is running, and which port the file beside the agent names. Landed 2026-08-02 as the guest half only, and the gap is honest rather than argued: nobody has decided whether an agent should be able to ask it. **What a row would have to settle first:** Mirror is a SEPARATE application that happens to run on the same Macintosh, so a tool here would be NOW reporting on a neighbour - which is defensible (the host's own Mirror page does exactly that, one step less truthfully, off a folder listing) but is a boundary question rather than a plumbing one. The capability itself is not in doubt: residency is a Gestalt answer and the guest is the only side that can give it, which is why the verb exists at all ([contract-coverage.md](contract-coverage.md)). The pane face is owed the same upgrade and has not had it either - the host page still lists the Extensions folder, so today NEITHER face reads this verb. |
| `mouseloc` | command | ppc | deliberate | Where the pointer IS — an instrument, not a capability. It exists because an emulator's relative mouse is acceleration-distorted, so the host's own drag plane positions by reading this and correcting; every hop calibration closes its loop against it. A caller that is not driving a pointer has nothing to do with the answer, and a caller that IS driving one is the host, which calls it directly rather than through a tool. Projecting it would put a calibration read on a surface whose other rows are capabilities. The closed loop it is the far end of is described in [emu-readiness.md](emu-readiness.md), which is also where the probes that depend on it are listed. |
| `net` | command | ppc | unnoticed | What a Mac says about its own networking: the link it holds to this host, its TCP/IP configuration, its network ports, and — last — why a list of that machine's connections is not among them. **Landed 2026-08-01 as a spike, guest page and host pane, with no projection deliberately.** Nobody has decided whether an agent should get it. What a row would have to settle first: nearly all of it is *read-only and harmless*, which argues for a plain row — but the fourth group is a statement about an API rather than about a machine, and a capability report that says "this Mac cannot list its connections" would be the wrong shape of true. A tool would have to carry that distinction into typed unavailability, or drop the group and answer three. There is also a real question of whether `now_hardware_census` already covers the hardware half, which would make a `net` row a second route to a capability already projected — the thing this column exists to refuse. PowerPC only: it is built on Open Transport, and the 68K guest speaks MacTCP ([ot-networking-surface.md](ot-networking-surface.md)). |
| `wirestat` | command | ppc | deliberate | How long the guest takes to NOTICE a request — the interval between its own wire service passes, and the delay from Open Transport announcing data to its event loop reading it — and the two knobs that change them. **An instrument, not a capability, and the same disposition as `mouseloc` for the same reason.** It answers a question about the wire this host is holding, so the only caller that can use the answer is the one already on the other end of it; a tool would put a measurement of the instrument on a surface whose other rows are things a Mac can DO. The half that decides it is the setting half: `sleep N` changes the guest's event-loop sleep and `wake off` its Open Transport wake, which makes a row a **configuration** surface rather than a capability one — and the setting it would expose is the one that starves every other application on a cooperatively scheduled Macintosh if a caller sets it wrong. Landed 2026-08-06 with the wire-latency arc; the numbers it produced are in [open-issues.md](open-issues.md). Revisit if an agent ever needs to defend its own latency budget to a caller, which is the one case that would argue for the reading half alone. |
| `qdtrace` | command | ppc | deliberate | What is drawing on the machine, read from the content plane's ring. **No row until the plane has run once.** The verb is reachable and its reader is tested natively, but the WRITER — the resident half that fills the ring at draw time — has never run on a Macintosh, so on every machine that exists today this verb correctly answers `content-plane-absent`. A tool row would be a tool that always refuses, and the capability report would say the machine cannot do it, which is true and is not what a row is for. This disposition is a schedule, not a judgement about the capability: revisit it the day a drain returns a record. What has and has not run is in [emu-readiness.md](emu-readiness.md). |
| `transitions` | command | ppc | deliberate | What CHANGED between two of the machine's own event passes, read from the transition plane's ring. **Guest-only on purpose for now, and it is a schedule rather than a judgement** — the same disposition and the same reasoning as `qdtrace` below. The verb landed 2026-08-05 as slice 5b's delivery half, guest side only, and the split is argued rather than incidental: [docs/plans/2026-08-05-010-feat-closing-the-headless-mirror-plan.md](plans/2026-08-05-010-feat-closing-the-headless-mirror-plan.md) records that workstream F "stops at the guest's wire and console faces" because the host consumer would have collided with two other workstreams editing host files the same day, and is a later slice. The case for a row is the strongest on this surface: the whole argument for the plane is that a ~2.2 s poll cannot see anything shorter than 2.2 s, so an agent that drives the machine and then reads back what happened is exactly the caller it was built for — "arm the tail, perform the action, capture the moment, read the tail" turns a corpus capture from a moment into a transaction. **What a row must settle first is not whether, but shape:** `start` takes a ProcessSerialNumber and a deadline, so a tool has to decide whether an agent arms a process by name (the console's route) or by the serial `now_observe_elements` already hands it, and whether a drain is a tool call per poll or a subscription the host keeps warm. Unlike `qdtrace` below, this plane's writer IS installed and running — the fifth plane was confirmed reporting live at generation 0 on 2026-08-05 — so the "no row until it has run once" bar it would inherit is nearly met: what has never happened is a record crossing the wire, because until this verb existed nothing armed the ring. Revisit the day a drain returns one. |
| `script` | command | ppc | unnoticed | One AppleScript through the guest's own OSA component, and the largest undecided question on this surface. Nobody has decided. What a row would have to settle first, and they are three separate questions: whether arbitrary guest-side code execution belongs behind a tool at all, given that every other row on this surface is a bounded capability with a stated effect; what consent tier it sits above, since the tiers today are read-only and full and this is plainly not the former; and whether the guest-side refusal of a whole-disk Finder search — a script that wedged a real machine for twelve minutes and is refused rather than warned about — is a sufficient guardrail or merely the one hazard that has already been paid for. |
| `axsnap` | command | ppc | unnoticed | The cheap one: who is front, whether the reference layer can see it, and how many references are live. It performs no walk and mints nothing, which makes it **the one call on this surface that is safe to poll** — and that is exactly what makes it a real candidate rather than a duplicate of `now_observe_elements`. Nobody has decided either way. What a row would have to settle first: whether a caller polling the front process belongs on a tool surface at all, given that `now_list_processes` already answers most of the question and this adds the reference table's own health. |
| `axtree` | command | ppc | deliberate | The read surface over the same walk `now_observe_elements` projects — the contract's own reference-layer preamble is explicit that `observe`, `elements` and `axtree` are three doors onto ONE walk with one emitter. Projecting a second door is "two ways to name a target is not two faces" ([command-parity.md](command-parity.md)), the same rule that keeps `ls`, `ps`, `census` and `screenshot` off this surface. Note what it is NOT: it is not a read-only spelling of the tree. It performs the same walk and therefore mints, and the contract says so rather than letting a reader assume a quieter minter exists. |
| `handle` | command | ppc | unnoticed | Take ONE reference back to a live element, or refuse precisely — and **the refusal is the product**: `ok` stays true for every verdict, including the four that resolve to nothing, because "your reference is stale" is an answer that tells the caller to observe again rather than to retry. Nobody has decided whether that belongs on this surface. The case for a row is that it is the only way to ask "is this still addressable" without acting; the case against is that every act already revalidates at the guest, so a caller that checks first has learnt something that may be false by the time it acts. That is the question a row has to answer, and it has not been asked. |
| `observe` | command | ppc | deliberate | The scope-aimed door onto the same walk `now_observe_elements` projects by process — one minter, one walk, one emitter, three doors (the reference-layer preamble in `contract/asyncapi.yaml`). `elements` is the door a caller who is about to ACT has, because it takes the process serial an act's target lives in; `observe` takes a scope. One capability, one route per face — [command-parity.md](command-parity.md). |
| `cancel` | command | 68k | deliberate | The 68K guest's console spelling of transfer cancel, and `now_transfer_cancel` needs the `file.cancel` **message** rather than this verb: the message is what both guests dispatch, and requiring the verb would make a capability both guests serve read as 68K-only — rule 4 of the [parity slice plan](plans/2026-07-29-004-feat-now-tbt-classic-parity-slice-plan.md). The verb exists so a person at a PowerBook whose host has stopped answering can still end a transfer, which is a reason for the GUEST to have two faces, not a second mechanism for the host to pick between — [command-parity.md](command-parity.md). |
| `census` | command | both | deliberate | The console spelling of `census.request`, which is projected as `now_hardware_census`. `now_hardware_census` needs the **family** and not this verb, for the reason `front` and `quit` give: the verb is the flat single-page read a person types at the machine, and the family is the one that paginates and carries a per-probe outcome — which is the whole capability. One capability, one route per face — [command-parity.md](command-parity.md). |
| `front` | command | both | deliberate | `now_bring_to_front` needs the `process.front` **family**, not this command, for the reason `quit` gives below: the command takes a NAME, and the opaque-reference and PSN-revalidation model the tool stands on has nothing to stand on without the message. The name form is the console's, by contract — one capability, one route per face ([command-parity.md](command-parity.md)). |
| `desktop` | command | ppc | unnoticed | What the guest's desktop is actually drawn from — the Appearance Manager's theme collection rather than the `ppat` resource nobody updates. It landed 2026-08-07 for the RENDERER's benefit, under [plan 018](plans/2026-08-06-018-feat-stable-honest-render-plan.md) slice 5, and no projection was written either way; nobody has decided whether an agent should get it. What a row would have to settle first: **it is a fact about the machine's appearance, and this surface has no other row of that kind** — every neighbour is either a capability with an effect or an inventory of hardware, and "what does this Mac look like" sits with neither. It is also the first row whose most useful answer may not be a tool at all: the host already consumes it internally to draw the mirror, which is a projection of a different sort, and a second route to it would need an argument that a caller wants the pattern's identity for something the render does not already do. Read-only and harmless, so the risk questions `script` and `hide` carry do not apply here — this one is purely about shape. PowerPC only, and the 68K answer would have to come through the opposite mechanism ([contract-coverage.md](contract-coverage.md)). |
| `hide` | command | ppc | unnoticed | Hide or show a running application, and read back whether it is visible — the Application menu's own effect, through the Process Manager's `ShowHideProcess`. It landed 2026-08-05 with no projection, deliberately: the arc that built it stops at the guest's two faces. Nobody has decided whether an agent should get it. What a row would have to settle first, and none of it is settled by the verb existing: **the target is a NAME**, so a row would face `front`'s and `quit`'s question — the opaque-reference and PSN-revalidation model has nothing to stand on without a `process.*` family message, and there is no `process.hide` on the wire, so a row here means either relaxing that model or adding the family first. **Availability is per-machine rather than per-guest**: the call needs CarbonLib 1.5, and a guest whose CarbonLib is older answers `unavailable` at runtime — which a capability report built from `help` cannot see, because `help` lists the verb either way. And **the read half may be the more useful one**: `--status` is the only route on a classic Mac to whether an application is hidden at all, since `ProcessInfoRec` carries no visibility field, so a row might reasonably project the read and refuse the write. Three questions, one verb; deciding it means deciding them separately. |
| `help` | command | both | deliberate | Already sent, once per connection, to build the capability report — its answer *is* `now_session_capabilities` ([agent-integration.md](agent-integration.md)). A second route would be the same answer twice. |
| `ls` | command | both | deliberate | The console spelling of `file.list`, which is projected. One capability, one route — [command-parity.md](command-parity.md) ("two ways to name a target is not two faces"). |
| `ps` | command | both | deliberate | The console spelling of `process.list`, which is projected — same rule as `ls`, [command-parity.md](command-parity.md). |
| `put` | command | 68k | planned | W1 #4, and the half of it that did not land. `now_guest_files_download` closed the `file.get` message; this verb is the same capability by the other mechanism — guest-initiated, a leaf name inside the same share root `ls` lists (`now68k_desktop_folder`, "ONE root, both ways"). What blocks it is host machinery rather than the guest or authority: a row's `requires` is a **conjunction**, so a row cannot say "the family OR the verb". Requiring both switches the tool off against every guest; requiring neither overstates; and routing to the verb behind a row that requires the family would make the tool work exactly where the capability report says it cannot. A disjunctive requirement in `HostProjectionCatalog`'s contract is what closes this, plus the reported bound that the verb cannot express a subfolder path. |
| `quit` | command | both | deliberate | `now_request_quit` needs the `process.quit` **family**, not this command: the opaque-reference and PSN-revalidation model has nothing to stand on without it, and is not relaxed to make a tool work ([agent-integration.md](agent-integration.md)). |
| `screenshot` | command | both | deliberate | The console spelling of `capture.request`, which is projected as `now_capture_screen`. One capability, one route — [command-parity.md](command-parity.md) ("two ways to name a target is not two faces"), the same rule that keeps `ls` and `ps` off this surface. |
| `sw` | command | both | deliberate | The console spelling of `software.list`, which is projected as `now_software_inventory` — so the same rule as `ls`, `ps` and `census`: one capability, one route per face ([command-parity.md](command-parity.md), "two ways to name a target is not two faces"). It was `planned` beside the message row until 2026-07-30, and closing the message is what settled the verb. **One thing this verb has that the family does not**, recorded rather than left to be discovered: `sw` with no domain runs an OVERVIEW — per-domain counts rather than items — and `software.list` has no domainless form to project it with. That is a separate capability with a separate shape, and whether it belongs on this surface is a decision for whoever wants it, not one this row makes by omission. |
| `vers` | command | ppc | deliberate | Build identity. `hello` already carries name, version and OS, and `now_session_health` reports all three ([agent-integration.md](agent-integration.md)). |

### The unnoticed rows, named together

**`actselftest`, `aesend`, `axsnap`, `cycle`, `desktop`, `dragmove`,
`dragpress`, `dragrelease`, `handle`, `hide`, `mirror`, `net` and
`script`** — thirteen rows, all served by the PowerPC guest, none decided
either way. Their rows above say what a decision would have to settle.

*(This list was **two** lists for the length of one merge. The
`018-desktop-pattern` and `018-anchor-acquisition` lanes each added a
verb and each honestly rewrote this paragraph; a clean textual merge
kept both, and the result named `desktop` in one and `cycle` in the
other with neither naming both — the exact 2026-08-05 defect the
[AGENTS.md](../AGENTS.md) section "Enumerated lists rot at merges" was
written about, reproduced two days later by two authors who did nothing
careless. It happened a **third** time merging `018-drag` into
`019-cursor-follow`, which is why the derivation is written down:*
`awk -F'|' '/^\| `[a-z]/ && $5 ~ /unnoticed/ {gsub(/[ `]/,"",$2); print $2}' docs/mcp-coverage.md | sort -u`*.)*

`desktop` joined on 2026-08-07, and it is the only one here whose
undecidedness is about **what kind of thing this surface is for**: every
other row is a capability with an effect or an inventory of hardware, and
"what does this Mac look like" is neither. It also arrived already
consumed — the host reads it to draw the mirror — so unlike the rest, the
question is not whether the capability is safe to expose but whether a
caller wants it for anything the render does not already do.

The three `drag*` verbs joined the same day the vehicle landed, and they
are the first rows here whose undecidedness is about **physical effect on
somebody else's desk** rather than about risk, shape or whose machine.
Every other capability on this surface reads a Macintosh or asks an
application to do something it already knows how to do; these move a
pointer and hold its button down, and a person sitting at that machine
would be fighting them. They must also be decided **together** — a press
with no move is not a gesture — which is why there are three rows and one
question.

`mirror` joined on 2026-08-02, the day its verb landed, and it is the only
one here whose undecidedness is about WHOSE MACHINE rather than about risk
or shape: it reports on a separate application that happens to run on the
same Macintosh, so the question a row must answer first is whether NOW
should describe a neighbour to a caller at all. Its pane face is owed the
same decision and has not had it either — the host's Mirror page still
reads a folder listing — so this is currently a verb both faces ignore.

`cycle` joined on 2026-08-07, the day its verb landed, and it is the only
one here whose undecidedness is about SURPRISE rather than risk, shape or
whose machine: it works by visibly disturbing the Mac, bringing each
application forward in turn. Every other verb on this surface answers a
question; this one rearranges the room to make the answer possible. So the
question a row must settle is not whether an agent may know something but
whether it may interrupt someone.

`hide` joined on 2026-08-05, the day the verb landed, and it is the one here
whose undecidedness is partly about the MACHINE rather than about the
capability: the call it rides on needs CarbonLib 1.5, so availability varies
between guests that answer `help` identically — a shape no row on this
surface has had to carry before.

`net` joined on 2026-08-01 with the networking spike, and it is the only
one here whose undecidedness is about SHAPE rather than about risk: almost
all of it is read-only and harmless, but one of its four groups reports why
Open Transport cannot answer a question, and a capability report that turns
that into "this Mac cannot" would be the wrong shape of true.

The last three joined on 2026-07-31, when six verbs that had been built and
dispatched by nothing were registered. Three of the six are argued in the
table above (`activate` is a second route to a projected capability,
`mouseloc` is an instrument rather than a capability, `qdtrace` reads a
plane whose writer has never run); three are not, and `script` is the
largest undecided question on this surface — it is the only row here that
would put arbitrary guest-side code execution behind a tool.

**CORRECTED 2026-07-31:** this paragraph read "The list is empty, and that is
a status rather than an achievement" until the reference layer landed four
new verbs the same day. Two of them are argued (`observe` and `axtree` are
other doors onto the walk `now_observe_elements` already projects) and two
are not. The emptiness lasted about a day, which is roughly what the closing
paragraph below predicted would happen and why the mechanism rather than the
list is the part worth trusting.

Gated against the table's own `unnoticed` column, so closing one is a
two-place edit and the test names the second place. The three ways a name
leaves this list have all been used, and keeping them straight is what makes
the short list mean anything:

- **Decided.** `capture.cancel` — argued in its own row, never built, and no
  longer a question.
- **Built.** `gestalt` was the largest of them and `now_machine_facts` exposes
  it; the three diagnostics went the same way and all at once.
- **Built, last, and hardest.** The live-stream bracket — `stream.start`,
  `stream.stop`, `stream.refresh` — closed by `now_stream_screen` on
  2026-07-31.

The bracket is worth a sentence on the way out, because its old row said it
might not belong on a tool surface at all and that hypothesis turned out to be
half right. **A stream is not one capability per message and never was**: the
stop and the refresh take the id the start minted, so three tools would have
been one usable one and two that cannot be reached first. It is one row with
three intentions, the shape `now_capture_screen` already used for take, page
and abandon. What the old row correctly saw as the hard part was not the
messages but the *bracket* — a lane held open across calls, by an agent that
can vanish between them — and that is answered by an ownership rule rather
than by a tool shape: the host ends an agent's stream when the process that
opened it goes away, and equally when it stops calling. Both, because a live
companion that has stopped reading is just as expensive as a dead one, and
neither check catches the other's case.

An empty list is the state to be suspicious of rather than proud of: it is
also what a stale document looks like. What keeps it honest is that the list
is derived from the table above and the table is derived from the registry,
the contract and both guests' dispatch — so a new guest capability nobody
projects reappears here without anybody remembering to write it down. That is
the `process.list` drift `command-parity.md` was written for, one layer out,
and the mechanism rather than the list is what answers it.

**It worked, and that is the note this section most needed.** The reference
layer landed four verbs on 2026-07-31 and two of them arrived here the same
day, undecided, without anybody choosing to write them down —
`MCPCoverageTests.testTheGapTableIsExactlyWhatNoProjectionReaches` named all
four by hand and refused to pass until each had a row and a disposition. The
list did not stay empty because it was never the list doing the work.

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

Last derived: 2026-07-30, on `claude/tbt-parity-slice` with the phase
complete — twelve capabilities wired across twenty-six registry rows. The last
was diagnostics, where one plan item and one wire operation became **three**
registry rows on purpose, because availability is per row and `vprobe`,
`shotdiag` and `putstat` do not co-occur on any guest. Before it,
`now_software_inventory` closed the gap this document's `exposes` split was
built to find; `now_machine_facts` removed the largest name from the unnoticed
list by building it; `now_hardware_census` expanded the census into fourteen
probe rows.

Every branch stamped this line with its own name. The integration is what the
tables describe, so this says so instead. The stamp no longer carries a
registry count: the previous one said sixteen while the registry held
seventeen, which is what a hand-typed number beside a derived table costs.
Its predecessor integrated `now_reveal_item`,
`now_transfer_cancel`, `now_guest_files_mutate` and
`now_guest_files_download` — each stamped this line on its own branch, and the
integration is what the tables actually describe. Re-derive by
running `swift test --filter MCPCoverage` rather than by reading — if the
tables and the code disagree, the code is right and the test says so.
