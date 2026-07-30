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
| `now_list_processes` | `process.list` | `process.list` | message family |
| `now_capture_screen` | `capture.request` | `capture.request` | message family |
| `now_launch_software` | `software.list`, `launch` | `launch` | message family plus command |
| `now_bring_to_front` | `process.list`, `process.front` | `process.front` | message family |
| `now_request_quit` | `process.list`, `process.quit` | `process.quit` | message family |
| `now_transfer_approved_artifact` | `file.put` | `file.put` | message family |
| `now_guest_files_capabilities` | `file.list` | — | message family |
| `now_guest_files_list` | `file.list` | `file.list` | message family |
| `now_guest_files_stat` | `file.list` | `file.list` | message family |
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
| `now_launch_software` | `software.list` | a launch of one exactly-named application; not one catalog entry |
| `now_bring_to_front` | `process.list` | a front switch, and whether a listing CONFIRMS it; the two listings are consumed to revalidate the reference and then to check the switch landed. No listing crosses back — which is why this row does not re-expose the `front` flag `now_list_processes` already returns |
| `now_request_quit` | `process.list` | a quit request; the listing is consumed to revalidate the opaque reference |
| `now_guest_files_capabilities` | `file.list` | the **host's** guestRoot policy and bounds; no directory entry crosses back |

`process.list` and `file.list` are still covered, because
`now_list_processes` and `now_guest_files_list` genuinely expose them.
`software.list` is not exposed anywhere, and that is the gap the next section
used to have to describe in prose.

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
  joins the `sw` verb that is the same capability's console spelling.
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
| `census.request` | message | both | planned | W1 #2. Opens into 14 probes; see the probe note below. |
| `exec.cancel` | message | both | deliberate | Ends an exec, and is excluded with the rest of the console plane — [agent-integration.md](agent-integration.md). |
| `exec.input` | message | both | deliberate | Part of the console plane excluded under rule 3 — [agent-integration.md](agent-integration.md) and the parity slice plan. |
| `exec.request` | message | both | deliberate | The console plane. A shell is not user-initiable in any meaningful sense and is the one thing [agent-integration.md](agent-integration.md) is right to keep out. |
| `file.cancel` | message | both | planned | W1 #8. |
| `file.get` | message | ppc | planned | W1 #4. Not withheld on authority grounds — confirmed 2026-07-29, simply unbuilt. The 68K guest reaches the same capability through its `put` verb. |
| `file.mkdir` | message | ppc | planned | W1 #7. |
| `file.move` | message | ppc | planned | W1 #7. |
| `file.restore` | message | ppc | planned | W1 #7. |
| `file.trash` | message | ppc | planned | W1 #7. |
| `process.shot` | message | ppc | deliberate | Excluded by name in the [parity slice plan](plans/2026-07-29-004-feat-now-tbt-classic-parity-slice-plan.md): PPC-only, and no consumer asked for a single-window capture. |
| `software.list` | message | both | planned | W1 #3. The gap that `exposes` made visible: `now_launch_software` **requires** this and consumes it to match one name, so a `requires`-derived check called it covered while no tool returns a listing. Its console spelling is the `sw` row below. |
| `stream.refresh` | message | ppc | unnoticed | Part of the live-stream bracket; see `stream.start`. |
| `stream.start` | message | ppc | unnoticed | A stream is a continuous host-owned bracket rather than one bounded call, so it may well not belong on a tool surface at all — but **that is a hypothesis, not a decision**: nothing argues it, and the host app's live view owning it today is a fact about what exists rather than a reason. |
| `stream.stop` | message | ppc | unnoticed | The other end of the same bracket; see `stream.start`. |
| `cancel` | command | 68k | planned | W1 #8. The 68K guest's verb spelling of transfer cancel. |
| `catsearch` | command | ppc | unnoticed | Catalog search across a volume. Served on the PowerPC guest, reachable by nothing. |
| `census` | command | both | planned | W1 #2 — the verb spelling of `census.request`. |
| `front` | command | both | deliberate | `now_bring_to_front` needs the `process.front` **family**, not this command, for the reason `quit` gives below: the command takes a NAME, and the opaque-reference and PSN-revalidation model the tool stands on has nothing to stand on without the message. The name form is the console's, by contract — one capability, one route per face ([command-parity.md](command-parity.md)). |
| `gestalt` | command | ppc | unnoticed | **The largest single unnoticed gap.** One verb answers CPU, memory, OS, network and hardware for the whole machine; the PowerPC guest has served it throughout and no host face can ask. |
| `help` | command | both | deliberate | Already sent, once per connection, to build the capability report — its answer *is* `now_session_capabilities` ([agent-integration.md](agent-integration.md)). A second route would be the same answer twice. |
| `ls` | command | both | deliberate | The console spelling of `file.list`, which is projected. One capability, one route — [command-parity.md](command-parity.md) ("two ways to name a target is not two faces"). |
| `ps` | command | both | deliberate | The console spelling of `process.list`, which is projected — same rule as `ls`, [command-parity.md](command-parity.md). |
| `put` | command | 68k | planned | W1 #4. On 68K this verb *is* the guest→host transfer; the PowerPC guest answers the same capability as `file.get`. |
| `putstat` | command | ppc | unnoticed | Transfer diagnostics. The host reads them internally to size a transfer; whether an agent should be able to is undecided. |
| `quit` | command | both | deliberate | `now_request_quit` needs the `process.quit` **family**, not this command: the opaque-reference and PSN-revalidation model has nothing to stand on without it, and is not relaxed to make a tool work ([agent-integration.md](agent-integration.md)). |
| `reveal` | command | ppc | unnoticed | Show an item in the Finder. Served on PPC; nothing asks. |
| `screenshot` | command | both | deliberate | The console spelling of `capture.request`, which is projected as `now_capture_screen`. One capability, one route — [command-parity.md](command-parity.md) ("two ways to name a target is not two faces"), the same rule that keeps `ls` and `ps` off this surface. |
| `shotdiag` | command | 68k | unnoticed | Where a staged capture read from. It found the 24-bit addressing defect on the 180c and is reachable from no host face. |
| `sw` | command | both | planned | W1 #3 — the installed-software listing, and now the `software.list` message row above it. The two used to disagree, one reading COVERED and the other unreachable; `exposes` is what reconciled them. |
| `tail` | command | ppc | planned | W1 #9. |
| `vers` | command | ppc | deliberate | Build identity. `hello` already carries name, version and OS, and `now_session_health` reports all three ([agent-integration.md](agent-integration.md)). |
| `vprobe` | command | both | unnoticed | Framebuffer read cost. A ~12 s measurement on the guest, which is a reason to gate it, not a reason it is absent — nothing has decided either way. |

### The unnoticed rows, named together

Because they are the point: `stream.start`, `stream.stop`,
`stream.refresh`, `catsearch`, `gestalt`, `putstat`, `reveal`, `shotdiag`,
`vprobe`.

Gated against the table's own `unnoticed` column, so closing one of these is
a two-place edit and the test names the second place. `capture.cancel` used to
be on the list and left it by being **decided** rather than by being built —
see its row; that is the other way a name leaves.

Every one of them is served by a guest right now. Nothing in this repository
argued for their absence; they are absent because the question never came
up. That is exactly the shape of the `process.list` drift
`command-parity.md` was written for, one layer out.

### The census probes are one row until they are fourteen

`contract-coverage.md`'s hard-learned rule is that a row which is a
subsystem gets expanded, because `census.request` as a single tick hid the
fact that NOW-68K could not report its own CPU. The same rule applies here
and lands differently: **no host face reaches the census at all**, so
fourteen rows would carry no information a single row does not.

The test encodes that as a condition rather than a judgement. The 14 probes
enter the universe it demands rows for **the moment any projection requires
`census.request`** — so whoever lands W1 #2 must declare, probe by probe,
which of the fourteen an agent can reach. `selectors` and `scsi` are
`refused` on NOW-68K and `pci` is `absent` on both, so a census projection
will not reach fourteen everywhere, and a single tick would hide that the
same way it did before.

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

Last derived: 2026-07-30, on `claude/agent-family-gate`, off
`claude/tbt-parity-slice` at the fourteen-projection registry. Re-derive by
running `swift test --filter MCPCoverage` rather than by reading — if the
tables and the code disagree, the code is right and the test says so.
