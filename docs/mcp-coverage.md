<!-- now-doc-provenance: generated reviewed=false -->

# What an agent can ask for

[contract-coverage.md](contract-coverage.md) answers **what each guest
serves**. This file answers the other half: **what any host face can ask a
guest to do, plus the deliberately separate host-owned Projects authority**,
and — where those two differ — whether the difference is a
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

**A second check is not about this document either, and it exists because
every table below was true while seven of the tools they describe could not
reach a Macintosh.** On 2026-08-07 a surface audit found that
`SocketAgentIntegrationClient` — the client every MCP call travels through —
never overrode `observeElements`, `mirrorDrive` or `tailGuestLog`. All three
landed on the protocol default in `AgentIntegrationClient`, so
`now_observe_elements`, `now_semantic_ui_act` and `now_guest_log_tail` answered
"no lane" from a healthy host; and because the observation is the **only**
producer of the `now-element-…` references the act rows take,
`now_window_act`, `now_control_act`, `now_text_get` and `now_text_set` were
unreachable for want of a legal argument.

Nothing here could see it, and that is the point worth keeping. This file
derives what a projection **declares** — its `capability`, its `requires`,
its `exposes` — and all seven declarations were correct. What was missing was
four lines one layer below the projection, in a file this document does not
read. So the gate is
[`MCPClientForwardingTests`](../now-host/Tests/NOWMCPTests/MCPClientForwardingTests.swift),
which derives two sets from source — every `client.<method>(` the projections
call, and every requirement the client protocol declares — and fails when
either contains a name `SocketAgentIntegrationClient` does not declare a
`func` for. Neither set is maintained by hand, for the reason AGENTS.md gives
about enumerations: the same day this was found, three separate hand-kept
lists in this repository were wrong, and none of them by carelessness.

**The drive that verified the fix found a larger defect than the one it was
sent for**, and it belongs beside this one because it has the same shape.
The MCP stdio loop read `FileHandle.standardInput.readData(ofLength: 4096)`,
which on Darwin blocks until it has the full count or the pipe closes — so a
client holding stdio open and sending one small line at a time was answered
by **nothing at all**, on every one of the tools in this file. It survived
because every driver this surface has ever had wrote its whole script and
closed stdin, which is a batch rather than a client.
[`StdioTransportLivenessTests`](../now-host/Tests/NOWMCPTests/StdioTransportLivenessTests.swift)
spawns the real executable, writes one small line and holds stdin open — the
one condition every previous driver removed.

Both are the same lesson in different places: **a table of what a surface
declares is not evidence that the surface answers.** Neither gate changes a
row below; they are what makes the rows mean something.

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
| `now_projects` | — | — | none; bounded host-owned project storage and recoverable history, independent of guest consent |
| `now_development_environment` | `development` | `development` | command; path-free PPC guest qualification facts |
| `now_development` | `development-project`, `development-stage`, `development-build`, `development-run`, `development-test` | `development-project`, `development-stage`, `development-build`, `development-run`, `development-test` | command; one closed semantic family for verified guest snapshots, inactive candidates, declarative ToolServer jobs, exact-product test receipts and exact-product launch; optional CodeKitten handoff remains a human-only app action |
| `now_list_machines` | — | — | none; host listener state |
| `now_session_capabilities` | — | — | none; `help` plus bounded probes, described in agent-integration.md |
| `now_hardware_census` | `census.request` | `census.request` | message family |
| `now_machine_facts` | `gestalt` | `gestalt` | command |
| `now_list_processes` | `process.list` | `process.list` | message family |
| `now_observe_elements` | `elements` | `elements` | command |
| `now_semantic_ui_start` | — | — | none; starts the host's semantic UI state engine and may show its human Mirror sibling, asking the Mac nothing |
| `now_semantic_ui_status` | — | — | none; reads the native Mirror state engine without another guest request |
| `now_semantic_ui_snapshot` | — | — | none; reads the native Mirror state engine without another guest request |
| `now_semantic_ui_find` | — | — | none; queries the native Mirror state engine without another guest request |
| `now_semantic_ui_wait` | — | — | none; waits for the native Mirror state engine without another guest request |
| `now_semantic_ui_metrics` | — | — | none; reads the host's own act and scene-cycle clocks, and asks the Mac nothing |
| `now_semantic_ui_lifecycle` | — | — | none; reports the resident facts the host already read, and asks the Mac nothing |
| `now_semantic_ui_journal` | — | — | none; reads the host's own operation journal, and asks the Mac nothing |
| `now_semantic_ui_wait_for_settlement` | — | — | none; waits on the native Mirror operation journal by attempt identity, including terminal late success or refusal, without another guest request |
| `now_semantic_ui_act` | — | — | command; the verb depends on the gesture the plan resolves to (`winact`, `menuact`, `key`, or a Finder script), so the row declares no requirement: demanding all four would make a keystroke unavailable on a guest that serves `key` and not `script`. The executor's own refusal names the missing half. |
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

That direct-row gap is not the retained semantic action surface.
`now_semantic_ui_act` already reaches the same `ditemact` command through the
shared executor with `gesture: dialogItem`, the containing window's retained
`entityID`, and the item's 1-based `itemIndex`. The 2026-08-09 F-009 follow-up
made this route discoverable instead of implicit: the MCP schema now publishes
the exact 16-gesture enum and one required-argument branch per gesture, while
the projection rejects cross-gesture argument mixtures before they reach the
host. The enum, schema branches, and decoder derive from one Swift contract;
focused tests pin all 16 branches and were watched failing against the old
unconstrained string schema. A private Luna repeat then recovered from direct
control refusals to the retained `dialogItem` route and dispatched the
snapshot's numbered Open item. The dialog's file list remained an opaque
`userItem`, so selecting the intended row is recorded separately as F-010 in
the audit report rather than attributed to the action grammar.

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
| `host.shown` | message | ppc | deliberate | The host's answer to a guest-initiated `host.show` — the PPC guest's dispatch RECEIVES it as the asker, which is what the Served column's derivation sees; no guest serves one. The host-surface family runs guest-to-host by definition — its subject is a WINDOW on the modern machine, which no classic Mac has — so no guest will ever serve one and there is nothing here for a projection to ask a guest for ([command-parity.md](command-parity.md), and the `guestAsksHostSurface` / `hostServesHostSurface` operations in the contract). The agent-facing reading of the same act is `now_semantic_ui_start`, which is a projection over the HOST rather than over a guest. |
| `mirror.invalidate` | message | none | deliberate | An unsolicited generation hint emitted by the PowerPC guest and consumed by the host's Mirror scheduler, not a request either guest serves or a state answer a caller asks it to produce. The caller-facing surface reads the resulting authoritative state engine through `now_semantic_ui_status`, `snapshot`, `wait`, and `metrics`; exposing the raw hint would create a second, weaker route whose sampled or gap quality is explicitly not evidence that state changed. The ownership and fallback rule are [mirror-drive-loop.md](mirror-drive-loop.md) rule 2o and [plan 029](plans/2026-08-09-029-fix-mirror-interaction-latency-and-coherent-state-plan.md) U4. |
| `chat.catalog` | message | ppc | deliberate | The host's answer to a guest-initiated `chat.models` — the PPC guest's dispatch RECEIVES it as the asker, which is what the Served column's derivation sees; no guest serves one. The chat family runs guest-to-host by definition — its subject is the host's own model harness, which no classic Mac has — so no guest will ever serve one and there is nothing here for a projection to ask a guest for; the MCP is a client of guests, not of the host's own services ([command-parity.md](command-parity.md), and the `guestAsksChat` / `hostServesChat` operations in the contract). The agent-facing reading of the same harness is the chat face itself, not a projection. |
| `chat.delta` | message | ppc | deliberate | The streamed half of the host's answer to `chat.send` — same definitional direction as `chat.catalog`, same citation ([command-parity.md](command-parity.md)). |
| `chat.result` | message | ppc | deliberate | The terminal half of the same turn, same reason ([command-parity.md](command-parity.md)). |
| `chat.status` | message | ppc | deliberate | The transient liveness line of the same family, same reason ([command-parity.md](command-parity.md)). |
| `cloud.card` | message | ppc | deliberate | The host's answer to a guest-initiated `cloud.detail` — the PPC guest's dispatch RECEIVES it as the asker, which is what the Served column's derivation sees; no guest serves one. The cloud family runs guest-to-host by definition — its subject is the host's own iCloud, which no classic Mac has — so no guest will ever serve one and there is nothing here for a projection to ask a guest for; the MCP is a client of guests, not of the host's own services ([command-parity.md](command-parity.md), and the `guestAsksCloud` / `hostServesCloud` operations in the contract). |
| `cloud.listing` | message | ppc | deliberate | The host's answer to a guest-initiated `cloud.list` — same definitional direction as `cloud.card`, same citation ([command-parity.md](command-parity.md)). |
| `cloud.refuse` | message | ppc | deliberate | The refusal half of the same family, same reason ([command-parity.md](command-parity.md)). |
| `cloud.report` | message | ppc | deliberate | The host's answer to a guest-initiated `cloud.services` — same definitional direction as `cloud.card`, same citation ([command-parity.md](command-parity.md)). |
| `continuity.report` | message | none | deliberate | The bounded status and negotiation answer to the host Mirror module's internal `continuity.arm` request. The host consumes it to settle one optional human pointer-control epoch; exposing the raw report would make that transport handshake a second public control surface even though Continuity explicitly excludes MCP and agent integration. The ownership and surface boundary are stated in [continuity-mode.md](continuity-mode.md). Both guests emit a report, but neither dispatches one as an incoming request, which is why the mechanically derived Served column says `none`. |
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
| `cursoract` | command | ppc | deliberate | An internal cursor-follow adjunct for host-owned Finder semantics, not a separately useful agent capability. Finder selection/open/rename travel as exact Apple events and therefore bypass the resident act route that normally places P8; the host follows a successful semantic action with this observation-bound, no-click placement so the guest sprite shows where the action occurred. A caller cannot usefully mint its opaque window argument outside the same projection, and exposing it would create a second public route for pointer positioning without an operation to accompany it. The ownership and failure rule are in [cursor-follow.md](cursor-follow.md): cursor failure is logged and cannot rewrite a successful Finder mutation. |
| `actselftest` | command | ppc | unnoticed | Proves the act plane's trap calling convention from inside one process, and it is the only instrument that reads the CALLER's side of the call — every other one reads ours. It matters more than its size, because a patch whose result lands in the wrong slot **does not crash, it lies**: every counter the plane owns reports success while the application reads a value we never wrote. Nobody has decided either way. What a row would have to settle first: whether an agent about to drive the act plane should be able to ask "is this machine's ABI the one you were built against" before it acts — the case for is that a silent wrong answer is the failure mode this plane actually has; the case against is that a host could simply call it once per session itself and never expose it. |
| `ditemact` | command | ppc | planned | U5/KTD11 of the [NOW Mirror UX completion plan](plans/2026-08-03-001-now-mirror-ux-completion-plan.md): prove the keyboard-and-mouse Mirror path first, then add MCP parity as a thin adapter over the same typed operation. The command selects one observation-minted, revalidated 1-based DITL item through the application's Dialog Manager path; projecting it before the direct UI is watched would invert that acceptance order. |
| `dragpress` | command | ppc | unnoticed | Presses the mouse button on an element and LEAVES IT DOWN, handing the gesture to the resident's Time Manager drag vehicle. Landed 2026-08-07 with the vehicle itself; nobody has decided whether an agent should be able to ask for it. **What a row would have to settle first, and it is not the usual question:** every other capability on this surface either reads a machine or asks an application to do something it already knows how to do. This one moves a PHYSICAL POINTER on somebody's Macintosh and holds its button down — so the question is not whether it is useful but whether a caller who is not looking at the screen should be able to start a gesture a person at that machine will be fighting. The resident's dead-man bounds the damage in TIME (it releases whether or not anyone asks, and clamps its own deadlines so a caller cannot switch it off), which is exactly the property that would make a row defensible; it does not bound it in SPACE. Deciding this means deciding all three drag verbs together, not one. |
| `dragmove` | command | ppc | unnoticed | Publishes a new pointer position for a held drag. Same landing, same undecided status, and it cannot be decided separately from `dragpress` — a press with no move is not a gesture. Its own distinguishing question is a smaller one: this verb is also what relays caller liveness, so a projection would be taking on the obligation to keep talking, and a tool that stopped mid-gesture would produce a dead-man release rather than an error. That is the honest failure and it is still a failure a caller has to be told about in advance. |
| `dragrelease` | command | ppc | unnoticed | Asks the resident to release a held drag. Same landing and same coupling to the other two. The one thing it adds to the decision: it reports that it ASKED and never that it released, because the resident's own deadline may have got there first — so a projection would have to carry a four-valued outcome (released-as-asked, dead-man-idle, dead-man-cap, session-lost) rather than a boolean, and a tool that flattened it would be asserting an outcome nobody observed. |
| `aesend` | command | ppc | unnoticed | One of four core Apple Events — quit, oapp, odoc, pdoc — to a process named by its serial. A closed vocabulary, not a class/id pipe, which is what makes it a candidate at all. Nobody has decided. What a row would have to settle first: `quit` overlaps `now_request_quit` outright, so a row would either drop that op or be a second route to a capability already projected; and the two document ops are the only way this product can open or print a file on the guest, which is a capability no tool has and nobody has asked for. Deciding it means deciding those two questions separately, not deciding one verb. |
| `key` | command | ppc | planned | **W3** of the parity slice. **The pane face landed 2026-08-01; this row tracks the MCP face, which has not.** One keystroke, posted through the Event Manager — the ground `now_text_set` cannot cover: a dialog that answers only keystrokes, and keys that carry no text (Return, Escape, the arrows). **The row that landed is the human-facing one, and it is `mods`-gated rather than blanket.** `ActionModel.availability(.key)` is now a function of `mods`: `mods == 0` answers `.available(command: "key")` and routes through `AgentIntegrationHostAdapter.key` → `AgentIntegrationActControl.key` (reads the input plane's own lower-case `posted` row, not the act plane's `Dispatch`); `mods != 0` still answers `.unavailable`, refused before a request is built. `MirrorModuleView`'s drawing captures a `keyDown` (`MirrorKeyCaptureView`, an AppKit view because `.onKeyPress` needs macOS 14 and this app supports 13) and `ActionModel.paneKeystroke` translates it, folding Shift into the character rather than into `mods` — the guest's own key table is case-sensitive on the char, not on a bit. **Not landed:** the *agent*-facing row — no `KeyProjection.swift`, no `AgentIntegrationClient.key` on the protocol, no MCP/`appIntents` face — so an MCP caller still gets no `key` tool. **Not verified:** the capture view's AppKit/SwiftUI integration has not been run in the built app (no display attached to this work); `docs/pane-keys-audit.md` names the specific risk and the check that would retire it. What a row must still decide for the modified half is the honest limit stated here since: an event's modifiers live on the Event Manager's queue element, and the only call that returns it is `PPostEvent`, which is `CALL_NOT_IN_CARBON` — so this verb refuses `mods != 0` outright rather than posting a bare key and reporting success ([input-plane-decisions.md](input-plane-decisions.md)). |
| `cycle` | command | ppc | unnoticed | Brings each faced application forward in turn with the anchor plane held armed, so each executes its own event loop once and the resident captures its anchor, then restores the previously frontmost application. Landed 2026-08-07 (plan 018 slice 15) as the guest half only. **The gap is honest rather than argued: nobody has decided whether an agent should be able to ask for it.** **What a row would have to settle first:** this verb DISTURBS THE MACHINE on purpose — windows come forward and flash past — so exposing it to an agent is a question about consent and surprise rather than about plumbing. It is the one verb on this surface whose whole point is a visible side effect, and the argument against a tool is that an agent could invoke it while a person is working; the argument for is that an agent facing a freshly booted Mac currently sees one window and has no way to fix it, which is exactly the hole that drove agents to macOS accessibility scripting. The capability itself is not in doubt. |
| `development-open` | command | ppc | deliberate | The optional transition from headless work to a human editor. It locates and launches CodeKitten, opens only the active `Project.ckp`, and brings the IDE forward, but it is intentionally an explicit app action rather than agent authority: project sync, build, promote and run do not depend on an IDE. A distinct test operation is still open and is not being implied by build or run ([development.md](development.md)). This is the initial projection boundary in the [Projects and Development plan](plans/2026-08-09-029-feat-projects-and-development-plan.md) (projection-family table and U9). |
| `mirror` | command | ppc | unnoticed | What this Mac can say about MIRROR - whether each of its three resident extensions is loaded, whether its agent is running, and which port the file beside the agent names. Landed 2026-08-02 as the guest half only, and the gap is honest rather than argued: nobody has decided whether an agent should be able to ask it. **What a row would have to settle first:** Mirror is a SEPARATE application that happens to run on the same Macintosh, so a tool here would be NOW reporting on a neighbour - which is defensible (the host's own Mirror page does exactly that, one step less truthfully, off a folder listing) but is a boundary question rather than a plumbing one. The capability itself is not in doubt: residency is a Gestalt answer and the guest is the only side that can give it, which is why the verb exists at all ([contract-coverage.md](contract-coverage.md)). The pane face is owed the same upgrade and has not had it either - the host page still lists the Extensions folder, so today NEITHER face reads this verb. |
| `mouseloc` | command | ppc | deliberate | Where the pointer IS — an instrument, not a capability. It exists because an emulator's relative mouse is acceleration-distorted, so the host's own drag plane positions by reading this and correcting; every hop calibration closes its loop against it. A caller that is not driving a pointer has nothing to do with the answer, and a caller that IS driving one is the host, which calls it directly rather than through a tool. Projecting it would put a calibration read on a surface whose other rows are capabilities. The closed loop it is the far end of is described in [emu-readiness.md](emu-readiness.md), which is also where the probes that depend on it are listed. |
| `net` | command | ppc | unnoticed | What a Mac says about its own networking: the link it holds to this host, its TCP/IP configuration, its network ports, and — last — why a list of that machine's connections is not among them. **Landed 2026-08-01 as a spike, guest page and host pane, with no projection deliberately.** Nobody has decided whether an agent should get it. What a row would have to settle first: nearly all of it is *read-only and harmless*, which argues for a plain row — but the fourth group is a statement about an API rather than about a machine, and a capability report that says "this Mac cannot list its connections" would be the wrong shape of true. A tool would have to carry that distinction into typed unavailability, or drop the group and answer three. There is also a real question of whether `now_hardware_census` already covers the hardware half, which would make a `net` row a second route to a capability already projected — the thing this column exists to refuse. PowerPC only: it is built on Open Transport, and the 68K guest speaks MacTCP ([ot-networking-surface.md](ot-networking-surface.md)). |
| `wirestat` | command | ppc | deliberate | How long the guest takes to NOTICE a request — the interval between its own wire service passes, and the delay from Open Transport announcing data to its event loop reading it — and the two knobs that change them. **An instrument, not a capability, and the same disposition as `mouseloc` for the same reason.** It answers a question about the wire this host is holding, so the only caller that can use the answer is the one already on the other end of it; a tool would put a measurement of the instrument on a surface whose other rows are things a Mac can DO. The half that decides it is the setting half: `sleep N` changes the guest's event-loop sleep and `wake off` its Open Transport wake, which makes a row a **configuration** surface rather than a capability one — and the setting it would expose is the one that starves every other application on a cooperatively scheduled Macintosh if a caller sets it wrong. Landed 2026-08-06 with the wire-latency arc; the numbers it produced are in [open-issues.md](open-issues.md). Revisit if an agent ever needs to defend its own latency budget to a caller, which is the one case that would argue for the reading half alone. |
| `update` | command | ppc | deliberate | Withheld from agent projection because today's artifacts are explicitly unsigned. The guest's Connections page requires a local modal confirmation before it may pass `allow_unsigned`; the shared console/wire command cannot spend that confirmation, and an MCP row would be a second remote route around the same boundary. Status remains visible to the person on the classic Mac. Revisit only after the release-signing design has a pinned trust root, rotation, revocation and recovery policy ([command-parity.md](command-parity.md), “`update` is the mutating example”; [host-owned updates](developer-guide/architecture/updating.md#trust-boundary)). |
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
| `vers` | command | ppc | deliberate | Build identity. `hello` already carries name, version and OS, and `now_list_machines` reports all three ([agent-integration.md](agent-integration.md)). |

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
careless. It happened a THIRD time at the 019 integration, where the
drag lane's rewrite of this paragraph named the three `drag*` verbs and
dropped `cycle` and `desktop`; the list below is derived from the
Disposition column above rather than retyped:*
`awk -F'|' '/^\| `[a-z]/ && $5 ~ /unnoticed/ {gsub(/[ `]/,"",$2); print $2}' docs/mcp-coverage.md | sort -u`*.)*

The three `drag*` verbs joined on 2026-08-07, the day the vehicle landed,
and they are the first rows here whose undecidedness is about **physical
effect on somebody else's desk** rather than about risk, shape or whose
machine. Every other capability on this surface reads a Macintosh or asks
an application to do something it already knows how to do; these move a
pointer and hold its button down, and a person sitting at that machine
would be fighting them. They must also be decided **together** — a press
with no move is not a gesture — which is why there are three rows and one
question.

`desktop` joined on 2026-08-07, and it is the only one here whose
undecidedness is about **what kind of thing this surface is for**: every
other row is a capability with an effect or an inventory of hardware, and
"what does this Mac look like" is neither. It also arrived already
consumed — the host reads it to draw the mirror — so unlike the rest, the
question is not whether the capability is safe to expose but whether a
caller wants it for anything the render does not already do.

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

## Declared versus exercised

Everything above this line is **declared**: what the registry says a
projection reaches, derived from source and gated by a test. That column
was correct on every row while seven tools were dead and all forty-one
were unreachable to any real client, and it is worth saying plainly why
it could not have been otherwise — *a declaration is a claim about the
catalog, and a dead lane is a fact about the machine.*

**Exercised** is the second column, and it is filled by running the
surface rather than reading it:

```
# The gate. No host is reached: the companion is pointed at an endpoint
# nothing binds, which is CI's shape.
swift test --filter MCPClientConformanceTests

# The measurement. Needs a host and a guest, and asserts WHICH guest
# before believing a row.
NOW_AGENT_SOCKET_SUFFIX=<yours> NOW_MCP_CONFORMANCE_LIVE=1 \
  NOW_MCP_CONFORMANCE_BUILD=<build prefix> \
  swift test --filter MCPClientConformanceTests
```

Both print the table. Four verdicts, and the fourth is the one a
three-verdict table would have hidden:

| Verdict | Means |
| --- | --- |
| `served` | the tool answered with its own success |
| `refused` | this host, the guest or the machine said no, **and said why** |
| `failed` | no answer, an unreadable one, or an answer a healthy host contradicts |
| `uncovered` | advertised, and this surface can construct no legal argument for it |

A second column says whether the argument was `real` — built from this
run's own earlier answers — or `synthetic`, a syntactically valid
reference deliberately never minted. It decides what a refusal proves: a
synthetic row exercises the lane and the guest's revalidation, and says
nothing about the capability. Several rows are synthetic **on purpose**
and not for want of trying — `now_text_set` replaces a field with no undo,
`now_control_act` presses whatever control it was handed, `now_request_quit`
would end a process the rest of the run reads.

### Exercised, 2026-08-07

Two runs of the same driver, on `claude/019-conformance`.

| Condition | served | refused | failed | uncovered |
| --- | --- | --- | --- | --- |
| No host (the gate) | 0 | 40 | 0 | 1 |
| Live, Mac OS 9 under QEMU, guest build `20ba2e29bff1` | 19 | 21 | 0 | 1 |

**`now_transfer_approved_artifact` is the uncovered row, and the only
one.** An approval receipt is minted by a person approving a transfer in
the host's own UI; no MCP tool produces one, so a headless caller cannot
reach that capability at all. Sending it a receipt nobody issued would
have exercised a regular expression and scored a refusal, which is why
the fourth verdict exists.

Three answers the live run surfaced that no derivation over declarations
could have, recorded here and in `open-issues.md`:

- `now_semantic_ui_lifecycle` refused with *"No Mac is connected, so no
  resident has answered"* **while a Mac was connected** — a false
  sentence from a healthy host, which is the class of defect this plan is
  named for.
- `now_guest_files_upload_begin` refused a **four-byte** upload with
  *"Private staging cannot reserve the declared upload"*.
- `now_reveal_item` refused *"nothing named System Folder to reveal"* on
  a Mac OS 9 volume that has one.

None was chased here.

### Exercised again, 2026-08-09

After the discovery cleanup and F-003 capacity fix, the same derived driver
called all 42 advertised tools through the real client-launched stdio mode against
an identity-checked Mac OS 9.1 VM (`Power Mac G4`, build
`0aa097ba0c1b`). It reported 29 served, 12 explained refusals, one explicitly
human-gated row, zero failed, and zero uncovered. The upload recipe itself had
carried the wrong digest for its four bytes; after deriving length, digest and
chunk from one payload, `now_guest_files_upload_begin`,
`now_guest_files_upload_append`, and `now_guest_files_upload_commit` all
served in that run. This is transport-and-reply coverage on an emulator, not a
claim that every served mutation was observed semantically or on metal.

### HTTP/stdio parity and varied Development loops, 2026-08-10

The derived driver now sees 46 advertised tools. Its no-host recipe ran against
both real transports: 45 typed host-unavailable results, the one
person-approved transfer explicitly human-gated, zero failed and zero
uncovered on each. A separate cross-transport parity fixture compared initialize,
initialized-notification gating, ping, resource and prompt lists/reads, all tool
names/descriptions/input schemas, one real tool result, and invalid
method/tool/cursor/resource/prompt errors byte-for-structure across HTTP and
stdio. Removing the HTTP tool catalog alone made that exact parity test fail.

Against an identity-checked Mac OS 9.1 VM (`Power Mac G4`, guest build
`27e37aeeaa0a`), authenticated HTTP MCP served 31 rows, returned 14 typed
refusals, left one human-gated row, and had zero failed or uncovered rows. Four
Development loops then used HTTP exclusively for project, guest-file,
toolchain, build, test, semantic-action and cleanup operations: simple; source
resource-fork preservation; six-file failure/repair/cancel/restage; and
guest-only import/edit/build/test/promote/diverge/recover. This is emulator
transport-and-operation evidence, not metal verification of all 31 served
capabilities.

The varied-loop receipts above were collected before HTTP ownership was moved
out of the separately shipped companion. The corrected normal NOW app retains
the same dispatcher and protocol implementation; its focused parity,
conformance, security and liveness gates pass, and its in-process HTTP adapter
completed an authenticated request against a private VM. That smoke reached
the exact guest session and Development report, but did not repeat the four
loops: the qualified-dev-disk cold-boot topology did not auto-launch its worker.

## Status

**Tested, not metal-verified.** The tables are a derivation over source and a
contract, and the guest-side `Served` column claims only what a guest's
dispatch answers — never that any of it has run. `contract-coverage.md`'s
"how far each served thing is proven" is the axis for that and is not
duplicated here.

**Seven rows retain direct effect evidence from the 2026-08-07 run.** Against
Mac OS 9 under QEMU, each of `now_guest_log_tail`,
`now_observe_elements`, `now_semantic_ui_act`, `now_window_act`,
`now_control_act`, `now_text_get` and `now_text_set` was called through the
MCP transport — the New Old World executable's stdio mode over JSON-RPC, not a test seam —
and four of them were watched taking effect on the machine: the walk minted
`now-element-…` references for a Finder window's scrollbars, `now_window_act`
moved that window to exactly the coordinates it was given, `now_control_act`
was dispatched against one of those scrollbars, and `now_semantic_ui_act`
zoomed the window. `now_text_get` and `now_text_set` reached the guest and
were refused **by the guest, in its own words** — *"that reference names a
control, not a text element"* — which proves the reference vocabulary is
shared but is not a completed reading; a window carrying a discoverable
`TEHandle` was not open on that machine. Nothing here has run on real
hardware. The broader 2026-08-09 run above proves every advertised row
answered and the three-stage upload completed; it does not retroactively add
direct-effect evidence to the other rows.

**The completed text reading was taken later the same day**, on
`claude/019-conformance`, through New Old World's stdio mode over JSON-RPC. A
window with a discoverable `TEHandle` is a *dialog's*, not a document's —
the contract says so — so SimpleText's Find dialog was opened, and
`now_observe_elements` minted the text reference the walk carries under
`windows[].text.ref`. `now_text_get` answered `completed` with
`text: "New Old World"` and `truncated: false`; `now_text_set` wrote
`"read through MCP"`; a second walk and a second `now_text_get` read that
back. So the pair is now emulator-verified as a round trip rather than as
reachability, and the earlier refusal is exactly what it said it was — a
control reference, not a text one.

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

Last derived: 2026-08-07, on `claude/019-integration-4`, by running
`swift test --filter MCPCoverage` against the five-lane merge
(`018-render-defects`, `018-cdef-classify`, `019-charcoal`,
`019-cursor-follow`, `019-depth-and-face`) as part of a green
`scripts/test-all`. **No row moved and no list rotted** — the unnoticed
paragraph's thirteen names still match the `awk` over the Disposition
column exactly, which is the first round since that list was written
where the check found nothing to fix. Two of the merged lanes widened
verbs the surface already exposes rather than adding rows: `ctlact`
gained a click point and `mouseloc` gained prose. **A projection that
does not pass `h`/`v` through cannot aim a click at a tab or a list
row**, and nothing in these tables can see that, because they count rows
and this is an argument — the same blind spot `contract-coverage.md`
recorded at round 4 for the same pair of lanes.

Before that, **2026-08-07**, on `claude/019-integration-3`, by running
`swift test --filter MCPClientConformance` and `--filter MCPCoverage`
against the merged tree of seven lanes. **No row moved**, and the run's
own line is `served 0, refused 41, failed 0, uncovered 1` — 42 advertised
tools, every one of which answered a real client, with no host running
so a named refusal is the right answer for all of them. The one
`uncovered` is `now_transfer_approved_artifact`, unchanged and for the
reason its recipe states.

Two things had to be fixed before that line could be produced, and both
were merge artefacts rather than defects in either lane: `now_semantic_ui_start`
had no conformance recipe (`018-open-mirror` landed the row before
`019-conformance` forked), and its reply is a **fourth** spelling of
availability — `showing` beside `available`, `hostAvailable` and `ok`.
Consolidating those four is the open item; see
[open-issues.md](open-issues.md).

Before that, 2026-08-07, on `claude/018-mcp-revival`, by running
`swift test --filter MCPCoverage` — which reads the registry in process, so
the tables below are what the running catalog says today. **No row moved**,
and that is the finding rather than the absence of one: the seven tools this
branch brought back to life were declared correctly the whole time, so a
derivation over declarations could not tell they were dead. The two gates
named in "Derived, and gated by a test" are the answer, and the drive that
proved the fix is recorded in Status above.

Before that, 2026-07-30, on `claude/tbt-parity-slice` with the phase
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

## The machine half: this file declares itself derived

`MCPCoverageTests` is the deep check and stays the deliverable. This
section is the shallow one a **hook** can run in a second, and it exists
because the failures it catches all happened at a merge, where nobody
runs a four-minute Swift suite before typing `git commit`.

The `derived-doc` block below carries runnable derivations, the sha256 of
each answer, and a digest of the sources they read.
`tools/derived-doc-gate` refuses a merge commit touching this file, or
any of those sources, unless they were re-run.

**The prose list is gated as part of the table.** "The unnoticed rows,
named together" restates the table's own `unnoticed` column in a
sentence, and on 2026-08-05 that sentence rotted three times in one
night — once becoming *two* lists, one naming `desktop` and one naming
`cycle`, neither naming both. So there are two derivations here and they
are asserted `equal`: one reads the column, the other reads every bold
name-run in that section. Two lists make the second one longer than the
first, and the gate names the difference.

<!-- derived-doc v1
sources: contract/asyncapi.yaml now-guest-ppc/src/core/wire.c now-guest-68k/src/core/wire68.c now-guest-ppc/src/commands/commands.c now-guest-68k/src/commands/commands68.c now-host/Sources/NOWAgentIntegration/Projection/HostProjectionCatalog.swift
sources-sha1: e937f84137eda84ec46d4d6fed58f6517b412f2a
derive ppc-inbound-types sha256=1aad1e912a333898e94ca678d768a85c901845b3e7826945f94ed0033553d7b7 lines=53 published
    grep -oE 'json_type_is\([a-z_]+, *"[a-z.]+"\)' now-guest-ppc/src/core/wire.c \
      | grep -oE '"[a-z.]+"' | tr -d '"' | sort -u
derive 68k-inbound-types sha256=53d664d7837eb250945e6c2d46f0aaeedd8a8c65aca5154477236991be70825b lines=25 published
    grep -o 'strcmp(type, "[a-z.]*")' now-guest-68k/src/core/wire68.c \
      | sed 's/.*"\(.*\)".*/\1/' | sort -u
derive disposition-census sha256=72111076c8035b5bd9cceacc45e74c81bbcb8059cc93b1468147c1141a29dabe lines=3
    awk -F'|' '/^\| *`[a-z0-9._]+` *\|/ {s=$5; gsub(/ /,"",s); \
        if (s ~ /^(deliberate|planned|unnoticed)$/) print s}' \
        docs/mcp-coverage.md | sort | uniq -c | awk '{print $1, $2}'
derive unnoticed-from-table sha256=f02459c7b08ea7eb3926b9c5867761042bb300ba3cb38b9ecb18caab24a99814 lines=14
    echo "name-lists: 1"
    awk -F'|' '/^\| *`[a-z0-9._]+` *\|/ {t=$2; gsub(/[ `]/,"",t); \
        s=$5; gsub(/ /,"",s); if (s=="unnoticed") print t}' \
        docs/mcp-coverage.md | sort -u
derive unnoticed-from-prose sha256=f02459c7b08ea7eb3926b9c5867761042bb300ba3cb38b9ecb18caab24a99814 lines=14
    runs() { awk '/^### The unnoticed rows, named together/{s=1;next} \
        s&&/^#/{s=0} s' docs/mcp-coverage.md \
      | tr '\n' ' ' | grep -oE '\*\*[^*]+\*\*' \
      | grep -E '^\*\*(`[a-z0-9._]+`,? ?(and )?)+\*\*$'; }
    echo "name-lists: $(runs | wc -l | tr -d ' ')"
    runs | tr -d '*`' | tr ',' '\n' | sed 's/ and /\n/g' \
      | sed 's/^ *//;s/ *$//' | grep -v '^$' | sort -u
equal: unnoticed-from-table unnoticed-from-prose
rederived: 2026-08-07T03:50:12-0400 8c1e3d94 sources, ppc-inbound-types 0->48, 68k-inbound-types 0->23, disposition-census 0->3, unnoticed-from-table 0->8, unnoticed-from-prose 0->8 (first declaration)
rederived: 2026-08-07T03:52:39-0400 d17ca9eb unchanged (count the lists, not just their union)
rederived: 2026-08-07T03:52:58-0400 d17ca9eb unnoticed-from-table 8->9, unnoticed-from-prose 8->9 (the prose derivation now counts the LISTS, because two lists whose union matches the table is the 2026-08-05 rot)
rederived: 2026-08-07T04:05:51-0400 dd520b71 unchanged
rederived: 2026-08-07T12:06:16-0400 c76fea99 sources, ppc-inbound-types 48->49, disposition-census 3->3, unnoticed-from-table 9->14, unnoticed-from-prose 9->14
rederived: 2026-08-07T13:30:46-0400 40ab79b6 sources
rederived: 2026-08-07T14:11:03-0400 4b54a5d2 sources
rederived: 2026-08-07T13:51:56-0400 a309422b sources
rederived: 2026-08-07T14:20:10-0400 ae89768d unchanged
rederived: 2026-08-07T15:21:01-0400 07b89775 sources
rederived: 2026-08-07T16:24:02-0400 1a35e96f sources
rederived: 2026-08-07T17:09:34-0400 0f3a3a43 sources
rederived: 2026-08-07T18:08:07-0400 4adb35b6 unchanged
rederived: 2026-08-07T20:20:55-0400 69c3c7e0 unchanged
rederived: 2026-08-07T23:45:38-0400 c8a61884 unchanged
rederived: 2026-08-08T01:33:41-0400 6610538c unchanged
rederived: 2026-08-08T12:59:17-0400 449efbee unchanged
rederived: 2026-08-08T21:56:10-0400 0ca7eb51 sources, disposition-census 3->3
rederived: 2026-08-09T04:12:08-0400 3159abaf sources
rederived: 2026-08-09T04:56:02-0400 ecdf1284 unchanged
rederived: 2026-08-09T04:56:23-0400 04313f08 unchanged
rederived: 2026-08-09T16:10:25-0400 e74b3ab1 sources
rederived: 2026-08-09T16:29:42-0400 9034e3eb unchanged
rederived: 2026-08-09T17:05:28-0400 446cf620 unchanged
rederived: 2026-08-09T17:08:04-0400 446cf620 unchanged
rederived: 2026-08-09T17:53:28-0400 ed9436c0 unchanged
rederived: 2026-08-09T18:53:51-0400 181db7a5 unchanged
rederived: 2026-08-09T18:56:23-0400 181db7a5 unchanged
rederived: 2026-08-09T19:21:55-0400 dc5bfcd2 unchanged
rederived: 2026-08-09T19:33:55-0400 c854246d unchanged
rederived: 2026-08-09T16:17:39-0400 451d757c sources
rederived: 2026-08-09T17:11:01-0400 5c773d12 disposition-census 3->3
rederived: 2026-08-09T17:11:40-0400 5c773d12 unchanged
rederived: 2026-08-09T17:29:58-0400 b5f126e7 unchanged
rederived: 2026-08-09T19:12:11-0400 a1df31e3 sources
rederived: 2026-08-09T20:56:35-0400 9864da82 sources
rederived: 2026-08-09T21:05:28-0400 9864da82 unchanged
rederived: 2026-08-09T21:43:47-0400 2b3c2c0e unchanged
rederived: 2026-08-09T22:09:30-0400 d54812c2 unchanged
rederived: 2026-08-09T22:18:49-0400 e637efd3 unchanged
rederived: 2026-08-10T02:53:59-0400 62603174 sources
rederived: 2026-08-10T04:27:16-0400 886ee556 sources
rederived: 2026-08-10T04:38:54-0400 886ee556 unchanged
rederived: 2026-08-10T05:38:07-0400 a0ede9ec unchanged
rederived: 2026-08-10T13:10:56-0400 47bf54fb sources
rederived: 2026-08-10T13:36:45-0400 b15b4827 unchanged
rederived: 2026-08-10T14:49:44-0400 4ea2d97d unchanged
rederived: 2026-08-10T14:45:43-0400 26b75393 unchanged
rederived: 2026-08-10T14:48:15-0400 26b75393 unchanged
rederived: 2026-08-10T15:30:54-0400 32bdd096 unchanged
rederived: 2026-08-10T15:34:28-0400 72868e9e sources, ppc-inbound-types 49->50
rederived: 2026-08-10T15:46:03-0400 72868e9e disposition-census 3->3
rederived: 2026-08-10T15:52:47-0400 77329146 unchanged
rederived: 2026-08-10T16:52:02-0400 d77cc444 unchanged
rederived: 2026-08-10T20:03:22-0400 d3e26c39 sources
rederived: 2026-08-10T20:22:53-0400 818c1577 unchanged
rederived: 2026-08-10T21:35:35-0400 a79833e9 unchanged
rederived: 2026-08-10T22:32:24-0400 e9bf9632 sources
rederived: 2026-08-10T22:33:05-0400 e9bf9632 unchanged
rederived: 2026-08-10T22:47:49-0400 431e7308 unchanged
rederived: 2026-08-11T00:25:05-0400 bbab04b9 unchanged
rederived: 2026-08-11T00:33:22-0400 4b24cc1f unchanged
rederived: 2026-08-11T19:45:15-0400 065da692 unchanged
rederived: 2026-08-11T20:08:53-0400 852b41ae unchanged
rederived: 2026-08-11T20:43:59-0400 5c07bcd6 unchanged
rederived: 2026-08-11T20:54:11-0400 f9ceab81 unchanged
rederived: 2026-08-11T21:13:10-0400 098805ff unchanged
rederived: 2026-08-11T21:20:51-0400 15514cc9 unchanged
rederived: 2026-08-11T21:26:23-0400 7bfb617b unchanged
rederived: 2026-08-11T21:32:38-0400 57a081ab unchanged
rederived: 2026-08-11T21:39:37-0400 5a82bf82 unchanged
rederived: 2026-08-11T21:49:35-0400 7dc5b09d unchanged
rederived: 2026-08-11T21:54:55-0400 8c482312 unchanged
rederived: 2026-08-11T21:59:53-0400 562b4b50 unchanged
rederived: 2026-08-11T22:06:35-0400 65f52bf3 unchanged
rederived: 2026-08-11T22:10:48-0400 3df65dde unchanged
rederived: 2026-08-11T22:15:20-0400 68853632 unchanged
rederived: 2026-08-11T22:31:03-0400 a16b6a61 unchanged
rederived: 2026-08-11T22:41:39-0400 e1fc84c4 unchanged
rederived: 2026-08-11T22:47:34-0400 9776cf7a unchanged
rederived: 2026-08-11T23:12:01-0400 ddf740ce unchanged
rederived: 2026-08-11T23:31:22-0400 ad4d680 sources
rederived: 2026-08-11T23:37:11-0400 ad4d680 disposition-census 3->3
rederived: 2026-08-12T13:02:41-0400 7cea759e sources, ppc-inbound-types 50->52, 68k-inbound-types 23->25
rederived: 2026-08-12T13:11:34-0400 7cea759e disposition-census 3->3
rederived: 2026-08-12T13:12:13-0400 7cea759e unchanged
rederived: 2026-08-12T15:54:08-0400 939e43b7 sources
rederived: 2026-08-12T17:19:20-0400 338eca21 sources
rederived: 2026-08-12T18:34:29-0400 3688b9f6 unchanged
rederived: 2026-08-12T18:58:27-0400 3771e144 sources
rederived: 2026-08-12T19:15:24-0400 3771e144 unchanged
rederived: 2026-08-12T19:31:58-0400 3771e144 unchanged
rederived: 2026-08-12T20:08:32-0400 5a601a18 sources
rederived: 2026-08-12T20:15:22-0400 9e828cdc unchanged
rederived: 2026-08-12T20:34:42-0400 4d9ba67d sources
rederived: 2026-08-12T20:37:07-0400 633da491 sources, ppc-inbound-types 52->53
rederived: 2026-08-12T20:45:45-0400 a0878023 sources
rederived: 2026-08-12T22:18:37-0400 18d0d3c4 sources
rederived: 2026-08-12T23:59:07-0400 e5b16a71 sources
rederived: 2026-08-13T00:21:46-0400 e5b16a71 sources
rederived: 2026-08-13T00:58:12-0400 9f5139cf sources
rederived: 2026-08-13T01:23:45-0400 9f5139cf unchanged
-->
