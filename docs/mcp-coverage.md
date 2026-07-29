# What an agent can ask for

[contract-coverage.md](contract-coverage.md) answers **what each guest
serves**. This file answers the other half: **what any host face can ask a
guest to do**, and — where those two differ — whether the difference is a
decision or an accident.

It exists because of drift nobody was watching for. The guests handle 37
(PowerPC) and 23 (68K) inbound message types, 19 command verbs and 14
hardware census probes between them. Of the 24 host-askable capabilities and
19 verbs the contract declares, twelve host projections reach **six**; the
other **37 are gaps**, eleven argued, sixteen planned and **ten decided by
nobody**. Most of the difference is capability the guest already has and no
host face can name. Some of that is deliberate and argued; some of it was
simply never noticed. **Those are different facts, and this file's whole job
is to keep them apart** — a gap with a reason and a gap by accident look
identical in a table that has one column for both, and the accidental ones
survive by hiding among the reasoned ones.

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
| host reach | `HostProjectionCatalog` → each row's `capability` and `requires` | the registry itself, in process — no parsing |
| host-initiated messages | `contract/asyncapi.yaml` → `operations` with `action: receive`, resolved to each message's wire `name` | `receive` means the guest receives it, so it is an ask |
| command verbs | `contract/asyncapi.yaml` → `x-commands` | the closed registry |
| census probes | `contract/asyncapi.yaml` → `x-census`/`x-probes` | the closed registry |
| which guest serves what | `now-guest-ppc/src/core/wire.c`, `now-guest-68k/src/core/wire68.c`, `now-guest-ppc/src/commands/commands.c`, `now-guest-68k/src/commands/commands68.c` | the same greps `contract-coverage.md` publishes, reused rather than reinvented |

The guest-side greps are `contract-coverage.md`'s, unchanged:

```
grep -oE 'json_type_is\([a-z_]+, *"[a-z.]+"\)' now-guest-ppc/src/core/wire.c \
  | grep -oE '"[a-z.]+"' | tr -d '"' | sort -u
grep -o 'strcmp(type, "[a-z.]*")' now-guest-68k/src/core/wire68.c \
  | sed 's/.*"\(.*\)".*/\1/' | sort -u
```

## What the twelve reach

One row per registered projection, in catalog order. `Requires` is the row's
own `requires` array — the guest capabilities it cannot work without — and
the test compares it against the code literally.

| MCP tool | Requires | Guest plane |
|---|---|---|
| `now_session_health` | — | none; host listener state |
| `now_session_capabilities` | — | none; `help` plus bounded probes, described in agent-integration.md |
| `now_list_processes` | `process.list` | message family |
| `now_launch_software` | `software.list`, `launch` | message family plus command |
| `now_request_quit` | `process.list`, `process.quit` | message family |
| `now_transfer_approved_artifact` | `file.put` | message family |
| `now_guest_files_capabilities` | `file.list` | message family |
| `now_guest_files_list` | `file.list` | message family |
| `now_guest_files_stat` | `file.list` | message family |
| `now_guest_files_upload_begin` | — | none; host staging only |
| `now_guest_files_upload_append` | — | none; host staging only |
| `now_guest_files_upload_commit` | `file.put` | message family |

Twelve tools, and the distinct guest capabilities behind them are **six**:
`process.list`, `process.quit`, `software.list`, `file.list`, `file.put` and
`launch`. Eight of the twelve rows are the guest-files family and the
sessions pair; the surface is narrower than its tool count suggests, which
is the same mistake `contract-coverage.md` made when it counted message
types.

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

### Covered is not the same as exposed — a stated limit of the check

The check can see that a capability is **required by some projection**. It
cannot see whether a caller can ask for that capability's own answer.

`software.list` is the live instance. `now_launch_software` requires it and
uses it internally to match one name, so the machine check reads it as
covered — and there is no tool that returns a software listing. An agent can
launch an application it can already name exactly; it cannot ask what is
installed. Plan item W1 #3 is that listing, and the `sw` row below carries
it.

This limit is stated rather than fixed because fixing it means the registry
declaring `exposes` beside `requires`, which is a change to W0.1's seam and
not this document's to make. Until then, treat a `COVERED` reading as "some
projection needs it", never "an agent can ask for it".

## Every gap, with its disposition

The complete list of host-askable guest capability that no projection
requires. `Served` is derived from each guest's own dispatch: **both** ·
**ppc** · **68k** · **none**.

Three dispositions, and the difference between them is this file's reason
to exist:

- **deliberate** — argued somewhere, with the argument cited. The test
  requires the citation, so a row cannot be promoted to "decided" by
  someone typing the word.
- **planned** — a named item in a plan, with its number. Noticed, costed,
  not built.
- **unnoticed** — nobody has decided this either way. **These are the
  rows this document was written to surface**, and there are ten of them.

| Guest capability | Kind | Served | Disposition | Why |
|---|---|:--:|---|---|
| `capture.accept` | message | ppc | deliberate | Answering a guest-initiated capture offer is the paired host's own handshake obligation, not a capability an agent asks for — [command-parity.md](command-parity.md) ("the MCP is a client, not a face"). |
| `capture.cancel` | message | ppc | unnoticed | Abandoning a capture in flight. W1 #8 covers file-transfer cancel and does not mention this one. |
| `capture.refuse` | message | ppc | deliberate | The refusal half of the same handshake, and the same reason — [command-parity.md](command-parity.md). |
| `capture.request` | message | both | planned | W1 #1, the template capability for the whole parity slice. |
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
| `process.front` | message | both | planned | W1 #5. |
| `process.shot` | message | ppc | deliberate | Excluded by name in the [parity slice plan](plans/2026-07-29-004-feat-now-tbt-classic-parity-slice-plan.md): PPC-only, and no consumer asked for a single-window capture. |
| `stream.refresh` | message | ppc | unnoticed | Part of the live-stream bracket; see `stream.start`. |
| `stream.start` | message | ppc | unnoticed | A stream is a continuous host-owned bracket rather than one bounded call, so it may well not belong on a tool surface at all — but **that is a hypothesis, not a decision**: nothing argues it, and the host app's live view owning it today is a fact about what exists rather than a reason. |
| `stream.stop` | message | ppc | unnoticed | The other end of the same bracket; see `stream.start`. |
| `cancel` | command | 68k | planned | W1 #8. The 68K guest's verb spelling of transfer cancel. |
| `catsearch` | command | ppc | unnoticed | Catalog search across a volume. Served on the PowerPC guest, reachable by nothing. |
| `census` | command | both | planned | W1 #2 — the verb spelling of `census.request`. |
| `front` | command | both | planned | W1 #5 — the verb spelling of `process.front`. |
| `gestalt` | command | ppc | unnoticed | **The largest single unnoticed gap.** One verb answers CPU, memory, OS, network and hardware for the whole machine; the PowerPC guest has served it throughout and no host face can ask. |
| `help` | command | both | deliberate | Already sent, once per connection, to build the capability report — its answer *is* `now_session_capabilities` ([agent-integration.md](agent-integration.md)). A second route would be the same answer twice. |
| `ls` | command | both | deliberate | The console spelling of `file.list`, which is projected. One capability, one route — [command-parity.md](command-parity.md) ("two ways to name a target is not two faces"). |
| `ps` | command | both | deliberate | The console spelling of `process.list`, which is projected — same rule as `ls`, [command-parity.md](command-parity.md). |
| `put` | command | 68k | planned | W1 #4. On 68K this verb *is* the guest→host transfer; the PowerPC guest answers the same capability as `file.get`. |
| `putstat` | command | ppc | unnoticed | Transfer diagnostics. The host reads them internally to size a transfer; whether an agent should be able to is undecided. |
| `quit` | command | both | deliberate | `now_request_quit` needs the `process.quit` **family**, not this command: the opaque-reference and PSN-revalidation model has nothing to stand on without it, and is not relaxed to make a tool work ([agent-integration.md](agent-integration.md)). |
| `reveal` | command | ppc | unnoticed | Show an item in the Finder. Served on PPC; nothing asks. |
| `screenshot` | command | both | planned | W1 #1 — the verb spelling of `capture.request`. |
| `shotdiag` | command | 68k | unnoticed | Where a staged capture read from. It found the 24-bit addressing defect on the 180c and is reachable from no host face. |
| `sw` | command | both | planned | W1 #3 — the installed-software listing. Note that `software.list` reads COVERED above while this listing is unreachable; see "Covered is not the same as exposed". |
| `tail` | command | ppc | planned | W1 #9. |
| `vers` | command | ppc | deliberate | Build identity. `hello` already carries name, version and OS, and `now_session_health` reports all three ([agent-integration.md](agent-integration.md)). |
| `vprobe` | command | both | unnoticed | Framebuffer read cost. A ~12 s measurement on the guest, which is a reason to gate it, not a reason it is absent — nothing has decided either way. |

### Ten unnoticed rows, named together

Because they are the point: `capture.cancel`, `stream.start`,
`stream.stop`, `stream.refresh`, `catsearch`, `gestalt`, `putstat`,
`reveal`, `shotdiag`, `vprobe`.

Nine of the ten are served by a guest right now. Nothing in this repository
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

The test is proven by mutation: adding a thirteenth registry row without a
table entry, and declaring a gap for a capability a projection requires,
both fail naming the capability. See the commit that added it.

Last derived: 2026-07-29, on `claude/mcp-coverage-doc`, off
`claude/host-projection-registry` at the twelve-projection registry. Re-derive
by running `swift test --filter MCPCoverage` rather than by reading — if the
tables and the code disagree, the code is right and the test says so.
