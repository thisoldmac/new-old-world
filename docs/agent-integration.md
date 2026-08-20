<!-- now-doc-provenance: generated reviewed=false -->

# Host agent-integration boundary

The optional MCP surface is owned by NOW. It projects a narrow typed view of
capabilities already owned by the running host; it does not own a second host
app, guest connection, transfer lane, or human-facing operation. The normal
New Old World app owns HTTP in process. For clients that require stdio, the
same New Old World executable runs with `--mcp-stdio` as a narrow bridge to
the already-running app's private same-user socket. There is no separately
installed MCP companion product.

It is also **not a third face**. It is a client of the wire, reaching a guest through the same commands and message families a human does; the rule and the reason it needs writing down are in [command-parity.md](command-parity.md#the-mcp-is-a-client-not-a-face). A tool projects a capability, it never implements one.

## Availability is decided by capability, never by identity

NOW has two guests of very different completeness. The PowerPC Carbon guest implements most of the contract; NOW-68K implements a small part of it and answers `unknown-command` or a `not-implemented` error to the rest — which is the contract's own additive answer, not a failure. Every tool here must therefore work against whichever guest is connected, and its availability must follow from what that guest can actually do.

Nothing in the MCP projection reads the guest's identity to decide anything. A `guest` selector says WHICH machine a call is about and is resolved by the host before any operation runs; it never becomes an input to what that operation may do. The hello carries a name, a version and an OS string, and the session-health projection reports all three to its caller — but no file that decides what a tool may do is allowed to read them. `AgentIntegrationCapabilityTests.testNoCompanionCodeBranchesOnGuestIdentity` retains its historical name and fails the build otherwise. That guard is not hypothetical caution: `MetalQuitTests` derived a guest's abilities from its hello name and went stale the same afternoon that guest grew `process.list`, quietly understating its own evidence. Nothing failed, because a test that expects less always passes.

Two sources, matching the two kinds of capability a guest has.

**Commands** come from `help`, a wire command on both guests that returns that machine's own table. It is fetched once per connection and is the same live source the host console's Tab completion uses, which means a guest that grows a verb becomes usable here with no host MCP release.

**Message families** (`process.list`, `file.list`, `process.quit`, `process.front`, `software.list`, `file.put`, and the four catalog mutations `file.move` / `file.trash` / `file.restore` / `file.mkdir`) are not in any command table. `help` cannot see them, and that gap is exactly how `ps` shipped wire-only on NOW-68K and went unnoticed for a day. A family's availability is therefore established by asking, under a stated probing policy:

| Family | How it is established | Why |
| --- | --- | --- |
| `process.list` | probed by the report, and by ordinary use | read-only, and the same request the tool sends; 50-90 ms on the 1400c |
| `file.list` | probed by the report, and by ordinary use | read-only; `now_guest_files_capabilities` already spends one |
| `software.list` | probed only when the caller passes `probeCostly` | its first page is a whole-volume sweep, ~4 s on the PowerBook. A guest that does not implement it refuses instantly, so the cost falls only on the guest that does — but that is still four seconds of someone's machine, so a caller asks for it on purpose |
| `process.quit` | ordinary use only | the smallest request in this family quits a process. "I would have to quit something to find out whether I can quit things" is not an acceptable way to answer a question |
| `file.put` | ordinary use only | same: the smallest request writes a file to the guest |
| `file.move`, `file.trash`, `file.restore`, `file.mkdir` | ordinary use only | same again, and plainly: the smallest request in each of these families moves, trashes, restores or creates something on somebody's disk. The listener records each answer as it settles, so one real call is what settles the family — and a guest that does not serve it refuses instantly |

A family therefore has three states, not two. `unproven` means nobody has asked this guest yet, and is a different fact from `unavailable`. Collapsing them would make the report understate a machine it never questioned — the same failure the hello-name table produced. Only the contract's typed refusals (`not-implemented`, `unknown-command` and their siblings) move a family to `unavailable`; a timeout or a Toolbox error leaves it `unproven`, because silence proves nothing about what a guest implements and one wedged MacTCP stack must not be recorded as a permanently missing feature.

Because ordinary use feeds the same ledger, tools switch on as capabilities appear: a family another session lands on a guest becomes visible here the first time anything asks for it, with no release on this side.

**A tool that cannot be safe against a guest is unavailable against it, in typed form, and that is a complete answer.** It is never a weaker version of the tool with the unsafe part skipped. Two consequences worth stating because they look like gaps:

- `now_request_quit` needs the `process.quit` **family**, not the `quit` **command**. NOW-68K has the command; it does not have the family, so the opaque-reference and PSN-revalidation model this tool is built on has nothing to stand on. The model is not relaxed to make the tool "work".
- `now_launch_software` needs `software.list` as well as the `launch` command, because "launch exactly one exact match from the current catalog" is the entire safety story and there is no catalog without the listing.
- `now_guest_files_mutate` needs **all four** catalog-mutation families, not the three it happens to be using on a given call. A guest serving `file.trash` without `file.restore` would offer a deletion the tool could not undo, and that pairing is the safety property rather than a convenience, so it is a requirement — the tool is unavailable where the lane is incomplete rather than shipping the half that destroys.
- `now_bring_to_front` needs the `process.front` **family** for the same reason as quit, and needs `process.list` twice over: once to revalidate the reference, once to tell a confirmed switch from an accepted one. Both guests serve the family, so this one is available where quit is not.

And a refusal must arrive as a refusal. `GuestListener.recordGuestError` routes a guest `error` to every waiter kind — command, file listing, process listing, software listing, process result, file change and census — because the ids come from one sequence. It previously routed three of those six, so exactly the requests a partial guest refuses reached their caller as a 15- or 30-second timeout carrying no reason. Against a guest that implements part of the contract, refusal is ordinary traffic rather than an edge case, and routing it is what makes the MCP projection usable at all.

The completed V0 surface remains intact and the parity slice is widening it a row at a time. **The tool count is not stated here on purpose**: it moved four times in two days, every capability that changed it had to edit a sentence it was otherwise unrelated to, and the number is derived in [mcp-coverage.md](mcp-coverage.md)'s projection table from the registry itself. Read it there. The approved follow-on is the
[NOW MCP V0.5 guest-files command roadmap](plans/2026-07-24-003-feat-now-mcp-v0-5-files-command-roadmap-plan.md).
V0.5 widens guest filesystem authority only through typed, logged NOW commands
under a persisted root-relative `guestRoot`; it does not turn this MCP surface
into a direct file transport, grant modern-host filesystem access, or add
CodeKitten project semantics.

The first two V0.5 slices are implemented through the host boundary:
capability discovery, one bounded listing page, and bounded exact stat. It
persists the approved share-root default explicitly, validates every caller
path before composing it beneath policy, returns typed command receipts, and
logs command start/outcome. Invalid stored policy is rejected and reset
audibly. A create-only staged upload now reserves private host disk, accepts
ordered bounded bytes rather than a host path, seals them by declared SHA-256,
and enters the existing one-at-a-time guest put lane through a file-backed
source. **Download landed 2026-07-30 as a bounded command** — one path beneath
`guestRoot`, a size ceiling refused from the guest's own reported fork sizes
before any byte moves, a destination the caller cannot name, one attempt, and
the same receipt envelope as the rest of the family (see the parity-slice Files
addition below). **Catalog mutation landed with it**: `file.move`,
`file.trash`, `file.restore` and `file.mkdir` are projected as one row under
the authority stated in its own file and summarised below. What stays deferred
is everything that authority cannot cover — unlink (`delete`), tree deployment,
prune, and overwrite in any form.

## Where a projection lives

The projections are a module, not a shape the MCP server happens to have:
`now-host/Sources/NOWAgentIntegration/Projection/`. It sits in the package
product both build systems already share, so every host face can read one
registry — the transport-neutral server renders it as MCP tools, the capability ledger
renders it as per-tool availability, and a later face renders it its own
way without a second list to keep in step.

`HostProjection` is the contract and states rule 2 of the parity slice in
its own words: a projection may **address, authorize, bound and render**,
and may not **decide or answer**. `LaunchSoftwareProjection` is the
reference example of how much composition that allows — list, exact-match,
opaque reference, revalidate, `launch`, with every fact supplied by the
guest in the same breath and nothing remembered between calls.

**Adding a capability is one new file plus one row** in
`HostProjectionCatalog`. There is deliberately no shared switch: a row
declares its name, the guest capabilities it cannot work without
(`requires`), the ones a caller can actually ask about through it
(`exposes` — a subset, and a different question), the sentence the
capability report uses when the guest has them, its MCP descriptor, and its
own argument validation. The tool's `name` and the
`guest` selector are injected by the renderer, so a row cannot misspell its
identity or forget addressing. Two rows claiming one capability throws
rather than letting one win silently, which is what makes it safe for
several agents to add rows in parallel — a silent winner would leave one
face reaching a capability the next does not.

Same discipline as [adding-a-workshop-module.md](adding-a-workshop-module.md)
on the guest side, and for the same reason.

**What a row costs beyond the row**, when the capability is new to the host
rather than a second view of something already wired. All four are on shared
files, so they are stated here once rather than rediscovered per capability:

| Obligation | Where | What happens if you forget |
|---|---|---|
| the requirement, as a **named constant** | `AgentIntegrationCapabilityNames` | `HostProjectionRegistryTests` names it |
| a **`familyPolicy` row**, for a requirement that is a message family | `AgentIntegrationCapabilityLedger` | nothing at run time: the ledger falls through to the command table, which cannot hold a family, and the tool reports itself unavailable against **every** guest, forever. `MCPCoverageTests.testEveryFamilyRequirementHasALedgerRow` is the only thing that names it |
| a **default** for a new client method | the extension in `Projection/AgentIntegrationClient.swift` | the test target stops compiling in seven unrelated stub files. No test can gate this — the build fails before any test runs — so the rule lives in that file's own doc comment |
| a row in **[mcp-coverage.md](mcp-coverage.md)** | that file's projection table, and the gap it closes | `MCPCoverageTests` names the heading to add it under |

A requirement that is a **command** needs no ledger row: commands come from
`help`, which the guest itself answers, so the fall-through is the right
answer rather than a trap.

**What the registry currently reaches, and what it does not, is
[mcp-coverage.md](mcp-coverage.md)** — this file is the boundary, that one is
the inventory. It joins the registry against the contract and both guests'
dispatch, separates a gap somebody argued for from a gap nobody noticed, and
is enforced by `MCPCoverageTests` rather than maintained by hand. A new row
here means a row there, in the same commit; the test says so if it does not.

## Every agent call leaves a trace

**User-initiable where possible; strictly-headless surfaced as a log event.**
MCP is an optional feature of NOW, and optional does not mean kneecapped —
but a suite of agentic controls that is completely opaque to the person at the
machine is not what NOW is. Where a capability cannot be user-initiated, the
person must at least be able to see that it happened.

That is mechanical rather than a habit. Every face invokes a capability
through **one** dispatch — `HostProjectionDispatch` — and the dispatch emits
one audit event per invocation. A row does not emit, so a row cannot forget
to; the next capability's author gets the behaviour by adding a row.

| The event says | It never says |
| --- | --- |
| which capability, by the one name the registry keys on | the arguments — no path, receipt, reference, chunk or name |
| which face asked (`mcp` today) | anything about the caller beyond its face |
| which machine it concerned — the selector as given, or the driven machine's id, resolved by the host | the guest's address, which is not on this surface at all |
| the outcome: `answered`, `refused` with the projection's own sentence, or `denied` when the machine's own ceiling turned the call away | which flavour of unavailable an answered result reported; that lives in the result |

**A refused invocation emits.** An attempt that was denied is the more
interesting event of the two, and it is the one class of outcome the host
would otherwise never see: an argument refusal is decided inside the MCP server
and sends no local request, so an unemitted refusal is recorded nowhere.
`answered` is deliberately coarse — reading a typed result back apart would
mean this seam learning the shape of a dozen result types and going stale
behind the thirteenth.

The MCP face reports over the same per-uid private socket everything else
uses (local schema v8's `audit` operation), and the host writes the event to
**both** places a person can read it, from one call and one composition: the
line under the `agent` area of
[logging.md](logging.md#the-agent-area-who-asked), and the **Agent** page's
stream. One seam rather than two, because the visible half of this rule went
missing for twelve capabilities precisely by being a second thing to
remember. The page adds nothing to what the event carries — the same refusal
to record arguments holds there. The
host validates rather than transcribes: an event naming a capability no row
claims is refused, the face is a closed enum, the refusal sentence is bounded
and its control bytes are escaped. A same-uid process can already cause real
agent lines by making real calls; it does not also get to invent lines about
capabilities that do not exist.

**A failure to report is silent and does not fail the call.** The reasons it
can fail — the host is absent, is an older version, has stopped answering —
are all cases where there is no log to write into, and failing a call this
face has already served would be worse. The known gaps, stated rather than
discovered later: a call still waiting on a 32-second launch has not been
logged yet (the event is emitted once, when the outcome is known, rather than
as a begun/ended pair that would double this face's local round-trips), one
that takes the process down is never logged, and a malformed `guest` selector
is refused by the face before any capability is invoked, so it names no
capability and emits nothing.

Two tests hold it, and both were verified by mutation:
`HostProjectionAuditTests.testNothingButTheDispatchInvokesAProjection` reads
`now-host/Sources` and fails naming the file and line when anything but the
dispatch calls a projection's `invoke`, and
`NOWAgentAuditTests.testAToolCallReportsItselfToTheHost` drives the real MCP
entry point and reads what arrived at the host end of the socket.

## The machine's own ceiling

**Consent is the guest's; enforcement is the host's.** A guest states how far
an agent may drive it in one optional `hello.agent` field, and the host
refuses above that line — so the guest never has to tell agent traffic from
app traffic, and a person clicking a button in the app is untouched by any of
this.

The check is in `HostProjectionDispatch`, on the same line as the audit event:
the thing that records what happened is the thing that decides whether it may.
One check covers every registered row, and there is no per-row opt-in to
forget.

| `hello.agent` | What the host does |
| --- | --- |
| `disabled` | refuses everything |
| `read-only` | runs the read-only rows, refuses the rest |
| `full` | runs everything |
| absent | **runs everything** — a recorded decision, not a property |
| anything else | refuses everything |

**Absence fails open** because a guest older than the field and an installer
that omitted the feature look identical on the wire, and today every machine
in the field is the former. That flips when the installer lands, and the line
that flips it is in `HostProjectionDispatch.consentDenial`.

**An unrecognised token refuses.** Unlike silence the machine *did* answer: it
named a limit this build cannot evaluate, and a receiver that cannot name the
ceiling cannot claim to be under it. The alternative would make an older host
the way around a newer machine's narrower tier.

**The tier is derived, never declared.** A row needs Read Only if its
published MCP annotations say `readOnlyHint: true`, and Full Access otherwise
— no fourth per-row field, because this arc has already collapsed four
hand-maintained capability lists and a fifth would be the same mistake.
`destructiveHint` moves nothing (with two tiers it cannot) and is used to
CONTRADICT: a row claiming to be read-only and destructive at once fails the
gate. `HostProjectionConsentTests` holds both halves, over the registry rather
than a list, so row twenty-seven is covered the day it lands.

Two consequences worth knowing before reading the tiers off a row:

- **`now_reveal_item` is Full Access**, not Read Only as
  [plan 006](plans/2026-07-30-006-feat-now-mcp-module-and-guest-consent-plan.md)
  expected. Its own row declares `readOnlyHint: false` and argues why — it
  takes over the screen of whoever is sitting at the machine. Moving it would
  mean either publishing an annotation an agent reads and that is not true, or
  adding the field the plan forbids.
- **The upload trio is Full Access**, because putting a file on somebody's
  machine is not reading it, whatever `destructiveHint` says.

**A refusal by consent is not an unavailability, and does not borrow its
words.** This surface is already fluent in *"this guest cannot"* —
`unavailable`, `unproven`, the family ledger, `not-implemented` — and a
consent refusal routed through any of them reaches an agent as a broken
capability. So it is a typed outcome (`HostProjectionOutcome
.deniedByConsent`) with its own vocabulary, and a caller tells the two apart
by shape rather than by prose:

| | incapacity | consent |
| --- | --- | --- |
| MCP shape | a RESULT, `isError: false`, whose payload says `unavailable` | a JSON-RPC ERROR, code `-32010` |
| how to branch | the row's own output schema | `error.data.kind == "consent"`, plus `reason`, `requiredTier` and `machineAnswer` |
| audit line | `answered` | `denied`, at `warn` |

A denied call still emits — it is the more interesting event to the person at
the machine, and the only outcome class the host would otherwise never see,
because nothing is sent when consent is missing.

## Implemented slices

The implemented V0 surface exposes only five host-owned projections.

| Tool contract | Existing NOW owner | Implemented projection |
| --- | --- | --- |
| `now_session_capabilities` | `help` over `GuestListener.runCommand`, plus `GuestListener.familyObservations` | Reports the connected guest's own command table, each depended-on message family's state and the evidence for it, and a per-tool availability derived from those. Sends `help` once per connection and bounded read-only probes for `process.list` and `file.list`; `software.list` only on request; never a mutating family. Reads no guest identity. |
| `now_list_machines` | `GuestListener.State`, `GuestListener.SessionHealth`, and the Connections page's machine labels | Returns a side-effect-free snapshot of not-listening, listening, connected, or failed host state. Connected snapshots keep the stable host machine id, exact session id, host-owned human display name, and guest-reported name distinct. |
| `now_list_processes` | `process.list` / `process.listing` and `GuestListener.listProcesses` | Reads a fresh, complete snapshot from the current paired guest. It returns at most 48 bounded entries, a point-in-time observation timestamp, and opaque references only for entries with a live PSN. PSNs and paths never leave the host adapter. A reference may be offered only to cooperative quit, which revalidates it before use. |
| `now_launch_software` | `software.list` / `software.listing`, then the existing declared `launch` command | Reads the current `apps` catalog and launches only one exact full-name match, using the listing path internally. Zero matches return `notFound`; multiple matches return at most eight bounded candidates and launch nothing. An opaque candidate reference is session-bound and revalidated against a fresh catalog before launch. No path or raw guest result text crosses the host adapter. |
| `now_request_quit` | `process.list` / `process.listing`, then `process.quit` / `process.result` | Accepts only a current opaque process reference issued within 30 seconds. The host re-lists, verifies the same PSN still has the same name, kind, type, and creator, then sends cooperative quit. The guest revalidates the live PSN again. Success means only that the quit request was sent, never that the process exited. |
| `now_transfer_approved_artifact` | Native Files approval, then `GuestListener.putFile` and `file.done` | The Files page stages one human-selected regular file in a private read-only copy and copies a one-use receipt. The MCP can redeem only that receipt for the approved current guest folder. Redemption rechecks session, expiry, inode, link count, mode, size, and SHA-256 before entering the existing one-at-a-time transfer lane with overwrite disabled. Success requires the matching `file.done ok:true`. |

The Projects/Development addition is three compact rows rather than a generic
filesystem, Git or shell surface:

| Tool contract | Existing NOW owner | Implemented projection |
| --- | --- | --- |
| `now_projects` | Host `ProjectStore` beneath the app-owned Application Support Projects root | Lists/creates named projects, opens persistent workspaces, performs bounded reads and guarded atomic applies, and returns Git-backed history without accepting a host path or Git command. Mutation attempts are caller-addressable and replay their durable terminal response after host restart. |
| `now_development_environment` | PPC guest `development` qualification report | Returns path-free Projects/toolchain/backend/version/capability facts. NOW-68K is unavailable by the command ledger, not by identity inference. |
| `now_development` | PPC `development-project`, `development-stage`, `development-build`, `development-test` and `development-run` over `AgentIntegrationDevelopmentControl` | Catalogues and imports a verified guest snapshot, stages and verifies an inactive candidate, promotes with a base/current digest guard, drives one declarative ToolServer job, cancels it, tests or launches only its unchanged measured product, and inventories retained recovery work. It accepts opaque IDs and caller mutation-attempt IDs only. CodeKitten handoff remains an explicit app action. |

These rows cross two authority domains. Host-home project work is confined by
product contract to NOW's same-user Projects root and needs no guest grant.
Guest import needs Read Only; candidate transfer, build, promotion and run need
Full. Chat receives the same rows only when its transcript has Development
intent, so ordinary machine questions do not pay their schema cost. See
[development.md](development.md) for project-home truth and current limits.

Before these domain rows dispatch, the stdio bridge asks the local host for a
compatibility description: host build, local protocol revision, projection
catalog version/digest and supported schema revisions. An incompatible peer
returns one typed refusal instead of cascading generic decode failures.
Projects and Development describe each operation as its own schema branch, so
project-revision and workspace-commit guards cannot coexist accidentally.

The stdio process can outlive an in-place replacement of the app bundle. It
captures the executable vnode, size and modification time at launch and checks
that identity after each input read, before sending anything to the host. If
the stable app path now names another build, the pending call receives
`now-mcp-companion-stale` with `reach: notSent` and the companion exits so its
supervisor can relaunch the current binary. This is a deployment-lifecycle
split, not a guest refusal and not an `invalid-response` retry loop.

NOW offers two independently controlled transports over one `NOWMCPServer`
registry and dispatcher. An MCP client launches the New Old World executable
with `--mcp-stdio` for newline-delimited JSON-RPC; that narrow mode reaches the
running app over the private same-user local socket described below. The normal
app owns authenticated HTTP directly in process and binds it to IPv4 loopback.
HTTP is preferred for a long-running client: the current app owns dispatch and
lifecycle, so replacing the installed bundle cannot strand that client inside
an older executable generation. Stdio remains the parity and fallback entry
point for clients that require it.
The MCP module starts and stops each transport independently, shows its current
endpoint, copies the stdio command or HTTP URL, and exposes the bearer only by
an explicit Copy action. Transport preferences live in NOW preferences.
Parity tests compare the complete tool descriptors and schemas, resources,
prompts, results, errors and MCP lifecycle; the same 46-tool conformance recipe
runs against both.

The parity-slice addition (W1 #1) is:

| Tool contract | Existing NOW owner | Implemented projection |
| --- | --- | --- |
| `now_capture_screen` | `capture.request` / `capture.begin` / bulk / `capture.end` over `GuestListener.requestCapture` — the same call the Screenshots page's **Capture** button and the menu bar's **Screenshot Guest** make | Asks the paired guest for its screen at a caller-chosen depth from the closed set the guest implements, and returns one whole PNG plus the width, height, depth, transfer time, wire bytes and digest behind it. The **first answer on this surface that is not JSON**: the picture rides the result's image attachment, so it is carried once rather than twice, and the local surface's 16 KiB cap is paged out inside the projection rather than by its caller. A capture is refused while the one transfer lane is busy — an agent must not overwrite the completion the person at the machine is waiting on. `abandon` releases that lane from a capture in flight; what it directs is the host's wait, not the guest's `capture.cancel`, which the 68K guest does not implement and which the host does not need honoured. Nothing is filed into the app's history, save folder or clipboard: those belong to the person at the machine. |

The parity-slice addition (P1 #5) is:

| Tool contract | Existing NOW owner | Implemented projection |
| --- | --- | --- |
| `now_bring_to_front` | `process.front` / `process.result` over `GuestListener.driveProcess`, plus the `process.list` it revalidates and confirms against — the same call the Processes page's **Bring to Front** button makes | Accepts only a current opaque process reference, the same vocabulary as quit and refused the same way when stale; the host re-lists, matches the full observed identity, and the guest revalidates the live PSN before `SetFrontProcess`. The answer keeps **confirmed apart from accepted**: `process.result` has no field that could carry "and it landed", and the switch happens when the guest next yields, so the projection re-lists once more and reports `fronted` only when the target's own `front` flag says so — otherwise `unconfirmed`. Not-running is a refusal here where quit calls it done: quit's asked-for state already holds, and you cannot front what is not there. It exposes the ACTION only; which application is frontmost is `now_list_processes`' `front` flag and was never a gap. |

The V0.5 read-only additions are:

| Tool contract | Existing NOW owner | Implemented projection |
| --- | --- | --- |
| `now_guest_files_capabilities` | Persisted host `guestRoot` policy plus a bounded root `file.list` | Reports the active policy version, root-relative scope, guest share label, page/path/stat limits, transfer-lane state when known, and implemented versus deferred commands. |
| `now_guest_files_list` | `guestFiles.list` over `file.list` / `file.listing` | Accepts only a bounded canonical path relative to `guestRoot` plus an optional positive cursor. Returns at most one 16-entry page, both fork sizes, type/creator, classic modified time when present, freshness, continuation, and a command receipt. |
| `now_guest_files_stat` | `guestFiles.stat` over bounded parent listing pages | Accepts one exact root-relative item path. Returns its bounded metadata or typed not-found, scan-limit, stale-session, unavailable, or refusal evidence. |

The parity-slice Files addition (P1 #4) is:

| Tool contract | Existing NOW owner | Implemented projection |
| --- | --- | --- |
| `now_guest_files_download` | `guestFiles.download` over `file.get` / `file.begin` / bulk / `file.end` through `GuestListener.getFile` and the reverse-streaming sink — the same call the Files page's **Download** row action makes | Pulls one file off the machine under a **bounded** policy, which is the answer this document deferred rather than a general download. The source is one canonical path beneath `guestRoot`; a folder is refused rather than walked. The **size ceiling is applied before the wire**, from the fork sizes the guest's own bounded listing just reported — an item over `AgentDownloadPolicy.maximumBytes` (4 MiB, where the artifact lane's human-source cap and the reverse path's metal ladder both stop) is refused having transferred nothing, and an arrival over it is discarded and lands nothing rather than being reported short. **The caller does not name the destination and cannot**: the host writes into private per-launch storage (mode `0700`, the landed file `0400`) and the receipt names the path, which is the exact mirror of upload accepting bytes and never a host path. Those bytes live only as long as the host launch that authorized them. One attempt — reverse resume does not exist, so a `resumeToken` is reported when a guest offers one and never consumed. The container is the guest's fork rule's answer, not a caller's choice, and `crc32` absent means the guest computed none and the bytes are UNCHECKED. Two mechanisms exist on the wire and this row uses one: see the `put` row in [mcp-coverage.md](mcp-coverage.md) for why the 68K verb is still a gap, which is a limitation of the host registry's conjunctive `requires` rather than a fact about either guest. |

The parity-slice addition (P1 #7) is the first **mutating** guest-Files row:

| Tool contract | Existing NOW owner | Implemented projection |
| --- | --- | --- |
| `now_guest_files_mutate` | `file.move` / `file.trash` / `file.restore` / `file.mkdir` over `GuestListener.moveFile` / `trashFile` / `restoreFile` / `makeFolder` — the same four calls the Files page's confirmation sheet, New Folder and Undo controls make | Four intentions on one row, because the contract's four messages are one lane: one path space beneath `guestRoot`, one `file.result` code vocabulary, one authorization, and `restore` consumes what `trash` answered. The authority is `guestRoot` and nothing else the caller can name: both of a move's paths are composed beneath the host-owned root, the root itself is never the target, and a path the share cannot express is refused before anything is sent. **Nothing is overwritten and nothing is unlinked.** `file.move`'s `overwrite` flag is never set and an argument asking for it is refused, so a collision comes back as the guest's own `exists`, rendered `conflict`; removal means the Trash, and the answer carries the name the item landed under — the only key a restore takes, remembered on neither side. One item, one intention, one attempt, one wire request, no created parents, no recursion. A trash whose answer names nothing is reported as exactly that rather than as a restorable one. Rule 3 costs it nothing: a person has had all four with a worded confirmation and a fifty-deep Undo since the Files page learned to change the share, and each agent call writes the same path-bearing Files log line the browse commands write beside the dispatch's own audit event. |

The four families are required **together** and none of them is ever probed,
so the row reads `unproven` until a real call settles it and `unavailable`
against a guest that refuses any of the four. Only one guest serves them
today; that is a fact the guest supplies by answering, and no file on this
surface reads which guest it is talking to.

The V0.5 upload additions are:

| Tool contract | NOW command owner | Implemented projection |
| --- | --- | --- |
| `now_guest_files_upload_begin` | `guestFiles.put` staging policy | Validates one canonical create-only destination beneath `guestRoot`, declared wire size/container/classic metadata, and SHA-256; requires an existing parent and reserves private disk capacity while preserving five percent of available capacity. This is the caller-supplied-bytes lane under full guest agent access, not redemption of a host-selected file; it therefore takes no one-time approval receipt. |
| `now_guest_files_upload_append` | Private NOW upload stage | Accepts one ordered base64 chunk of at most 8 KiB at the exact receipt offset. It never accepts or resolves a modern-host path and sends no guest message. |
| `now_guest_files_upload_commit` | `guestFiles.put` over existing `file.offer` / bulk / `file.done` | Seals and revalidates the stage, validates MacBinary structure when selected, streams one frame at a time from its immutable file, never creates parents or overwrites, and returns guest reservation, progress, integrity, finalization, and cleanup evidence. Success requires matching guest length, CRC, same-folder rename, and temp cleanup. The stage is one-attempt and replay conflicts. |

The live-stream addition is the **only row on this surface that is not one
bounded call**, so it is described with the rule that makes it safe rather than
only with what it does:

| Tool contract | Existing NOW owner | Implemented projection |
| --- | --- | --- |
| `now_stream_screen` | `stream.start` / `stream.stop` / `stream.refresh` over `GuestListener.startStream` — the same host-owned bracket the Screenshots page's **Start Streaming** button opens, and the same one a guest's `stream.request` is answered with | Opens the bracket, hands back one whole frame at a time, and closes it. Three intentions on one row because they are one bracket: stop and refresh take the id start minted and mean nothing without it. A frame request sends `stream.refresh` and answers with the frame that FOLLOWS, so "after you asked" is true; the picture rides the result's image attachment and is paged out inside the projection exactly as a capture's is. The pace is bounded here and is never absent — the contract reads absent as the guest's own ~15 fps floor, which is right for a person watching and wrong for a caller reading one frame per call. **A bracket an agent opens ends without the agent**: the host records the pid the kernel named on the opening socket and ends the stream when that process is gone, and equally when it has not called for a minute, because a live stdio bridge that stopped reading costs the Macintosh exactly what a dead one does. Stopping is not restricted to the opener — the person at the host can end any stream from the page they watch it on, and the Screenshots and MCP pages both say when one is an agent's. |

The New Old World executable's `--mcp-stdio` mode and the app's in-process HTTP
listener advertise exactly the registry's rows. Stdio opens one bounded local
request to the running host for each call; HTTP dispatches in process. Session
health and upload staging send no guest
message; the capability report sends only `help` and the bounded read-only
probes named above; commit and the other guest-dependent tools ask the host to
use the existing paired connection. Launch accepts exactly one bounded name or
generated opaque reference; quit accepts exactly one generated process
reference; approved-artifact transfer accepts exactly one host-minted receipt.
The V0.5 Files tools accept only canonical paths relative to host-owned
`guestRoot`, never an absolute guest path or a modern-host path. No tool accepts
a PSN, shell text, an arbitrary host filesystem operation, or a guest Files
mutation this host does not implement — and none accepts an overwrite flag, an
unlink, a recursive form, or more than one item per call. Every tool exposes
typed unavailability and no host or guest-listener lifecycle operation. If the
host is absent, stdio returns `now-host-unavailable`; its bridge never launches
the app. HTTP exists only while the host app is running. If the host is present
without a paired guest, guest-dependent
tools return `now-guest-unavailable` and never use cached state.

## Connection posture

NOW keeps its existing guest-dials-host paired connection throughout V0. The
MCP surface projects host-owned operations over that already-running session;
it does not add a listener to the NOW guest, introduce a second guest protocol
implementation, or wait for a replacement transport before the remaining
tools proceed.

CodeKitten is the proving ground for the opposite connection posture. Its listener must first establish the design under adversarial stress, including framing, pairing and security, health and latency semantics, lifecycle, stale-state recovery, and classic cooperative-loop behavior. The CodeKitten roadmap (a sibling project, not public) describes that intended proof work; it is a prerequisite, not evidence that the listener or a shared service already exists.

Only after that proof should a separate worktree extract the parts that have demonstrably generalized into a shared network-protocol service. That future service must leave a compatible migration path for NOW, but it is neither current shared infrastructure nor a dependency of the NOW MCP. NOW will not change its functional dial-out path merely to validate CodeKitten hypotheses.

## Local trust boundary

V0 deliberately trusts processes running as the same macOS user. This protects against other local users and accidental clients; it does not protect against malicious code already running as that user.

HTTP adds a separate local network boundary. It binds only `127.0.0.1`, checks
the request Host is loopback, and rejects non-loopback Origins. What the
Authorization header must carry is a persisted access mode, chosen on the MCP
page while HTTP is stopped and applied at the next start; whichever mode is
chosen, the loopback Host and Origin checks are unconditional:

- **Bearer** (the default, and what every pre-mode install keeps): a 32-512
  byte token supplied from NOW's private Application Support storage. The
  token is generated by NOW on first use, stored mode `0600`, never rendered
  or logged, and copied only on explicit request from the MCP module.
- **OAuth**: NOW is its own authorization server for standard MCP clients.
  It serves RFC 9728 protected-resource and RFC 8414 authorization-server
  metadata (the 401 challenge names the metadata URL), accepts RFC 7591
  registration of public clients whose redirect URIs are loopback HTTP
  (bounded at sixteen, least-recently-used evicted), and runs only the
  authorization-code flow with PKCE `S256`. An authorization request parks
  until a person answers the consent row on the MCP page (five-minute
  timeout, then `access_denied`); codes are single-use with a 60-second
  life, and a replayed code revokes the tokens it minted. Access tokens
  live an hour, refresh tokens thirty days with rotation; both are opaque
  random values, persisted only as SHA-256 digests in a mode-`0600` state
  file beside the bearer token. The MCP page can revoke every client and
  token in one action.
- **Unauthenticated**: no Authorization check. The page carries warning copy
  because this hands the surface to any process on the Mac.

HTTP allows at most
eight initialized sessions by default, expires them after 30 minutes, supports
explicit DELETE, caps headers and MCP bodies, rejects chunked or ambiguous
framing, and closes each TCP connection after one response. The bearer and
OAuth modes are still
same-user protection; another malicious process under that user remains outside
the model.

- The host creates `dev.newoldworld.now-agent-<uid>/host.sock` beneath the user's private temporary directory. The directory is mode `0700`; the socket is mode `0600`. Suffixed development lanes use the same uid-specific mode-`0700` leaf beneath `/tmp`, because the Darwin user-temp root plus a legal suffix can exceed `sockaddr_un`; the unsuffixed product path is unchanged.
- The host checks every accepted peer with `getpeereid` and serves it only when the effective UID matches.
- **The host remembers that local MCP peers exist, in counts and clock times only.** The private socket surface is one request per connection and a stdio bridge is short-lived, so the host tracks the *peer process* rather than the socket: when the first one ever spoke, when the last one did, how many requests are in flight this instant, how many distinct peer processes have spoken, and how many peers the UID gate turned away. A peer is identified by `LOCAL_PEERPID` — the kernel's answer about the socket, asked only *after* the gate has passed it, and never anything a peer said about itself. Pid reuse means two short-lived bridge processes can read as one, which undercounts rather than inventing one. The list is bounded at eight, most recently active first; the totals do not age out. **Nothing about the CONTENT of a request is recorded here** — no operation name, no arguments, no payload — because the audit event above is where "what was invoked" is answered and it refuses arguments deliberately; a presence ledger that recorded more would be the back door that puts them back. "Nothing has ever attached" is a distinct, first-class reading, not a zeroed count, and is the resting state before a stdio client has attached. In-process HTTP requests use the same operation audit without inventing a peer process.
- The stdio bridge checks that the directory and socket are owned by its effective UID, have no group/other permission bits, and are a directory and socket rather than links or other file types. HTTP bypasses this process boundary and dispatches inside the owner app.
- Local schema v8 makes an agent call VISIBLE. It adds one operation that asks the host for nothing: a face reports a capability it has just invoked — capability name, face, the guest selector as given, and `answered` or `refused` with a bounded sentence — and the host writes that line into its own log under the `agent` area. It carries no selection of any kind and reaches no guest, so it is exempt from the addressing check and shares the read-only response window. The version moved because the shape of the surface changed: a v7 host answers `invalid-request` to it, which is honest — that host has no audit line to write — and a v7 stdio bridge never sends one, which is the opacity rule 3 exists to stop being acceptable. See *Every agent call leaves a trace* above.
- Local schema v7 makes the surface guest-ADDRESSABLE. Every tool takes an optional `guest`: a machine id (`pb1400c` — "whatever is connected to that Mac now", which follows a reconnection) or a session id (`pb1400c-<uuid>` — one connection, refused `now-guest-session-ended` once it is over rather than answered by its successor, the same staleness contract the process and quit references keep). Omitting it means the machine the host is currently driving, which is what every v6 caller meant. Naming a machine that is connected but not being driven is refused `now-guest-not-addressed`, naming the driven machine and the whole roster — never answered by the other machine. `now_list_machines` reports the driven machine's reference and every connected machine, so a caller can discover the ids it needs. **The guest's ADDRESS is not on this surface.** The host owns the id, session id and display name internally and returns them without exposing where anything lives — the same reticence the endpoint keeps about its own path. The version moved because a v6 client cannot say which machine it means and would read whichever one happened to be active as the answer to a question it asked about another. Addressability does not touch availability: what a guest can do is still asked of the guest and never inferred from which guest it is.
- Local schema v6 adds the read-only session capability report to v5's staged-upload and browse operations, permits one request per connection, and caps each request and response at 16 KiB. The version changes when authority or action shape changes so an older stdio bridge cannot silently misread it. Browse selection is one bounded root-relative path and optional positive cursor; upload selection is one bounded root-relative destination plus declared metadata, followed only by an opaque upload ID, exact offset, and bounded bytes. The NOW command layer performs canonical MacRoman/HFS validation and policy composition. Launch selection is exactly one bounded name or opaque reference; quit selection is exactly one current opaque process reference; artifact selection is exactly one syntactically valid receipt; the capability report's only input is a required boolean `probeCostly`, required rather than defaulted because it decides whether the call spends a guest's whole-volume sweep. The version moved because the shape of the surface changed: a v5 bridge cannot ask what the connected guest implements and would present every tool as unconditionally available. MCP stdio input is separately capped at 64 KiB per line.
- V0.5 upload staging lives in a private mode-`0700` per-process directory; each stage is preallocated mode `0600`, becomes mode `0400` only after size and SHA-256 match, expires after ten minutes, and is consumed after one transfer attempt. Capacity is derived from current host disk availability and outstanding reservations, not an arbitrary whole-file cap. On startup NOW removes only well-formed private stages owned by a demonstrably dead process and emits an audit event. Live-process or structurally unfamiliar directories are retained.
- Approval staging lives in a per-host-launch mode-`0700` directory. A selected source must be one directly opened, single-link regular file no larger than 4 MiB. The sealed copy is mode `0400`, expires after ten minutes, is bound to the current guest session and approved Files destination, and is consumed on its first redemption attempt. Final open follows no links and rechecks owner, inode, device, link count, size, timestamps, mode, and digest.
- The MCP cannot mint an approval, list approval staging, choose the approved file's destination, or recover its original path. A user may deliberately select a file from anywhere the native picker can reach, but that grants only the staged copy; it does not expose the selected path. This approval boundary applies to that host-selected-file lane. A full-access caller may separately supply bytes it already possesses through `now_guest_files_upload_*`; whether access to modern-host files should require an additional product-level approval is tracked in [audit-report-2026-08-09.md](audit-report-2026-08-09.md) F-004. Same-user malicious code remains outside V0's stated protection.

The stdio local socket is not the guest wire. It creates no TCP listener, guest
connection, protocol message, guest module, daemon, launch agent, or second app.
The NOW-owned HTTP transport creates one loopback-only TCP listener inside the
normal host app; it does not change the guest wire or create another product.

**It creates one page on this side: MCP.** Rule 3 asks that what a person
cannot initiate they can at least see. The page owns both transport controls,
their endpoints and connection details, the audit stream as it happens, and
the machine's own `hello` consent answer read back. It does not override guest
consent; what may happen remains settled in one place, at the dispatch.

## Operational prerequisites

Two build systems compile this code, and `NOWAgentIntegration` means the same thing to both: a package product. SwiftPM declares it as a library beside the Host executable, and the Xcode project consumes that same local package — an `XCLocalSwiftPackageReference` at `.`, linked into the app target — so `import NOWAgentIntegration` is a plain import everywhere.

It was not always so, and the failure is worth keeping. The Xcode target used to pull `Sources/NOWAgentIntegration` in as a second synchronized file group, which put the types in scope but left the module *name* unresolvable, so every import needed a `#if canImport(NOWAgentIntegration)` guard. Two files added in `cbe83e9` omitted it and broke `xcodebuild` for a day while `swift build` and `swift test` stayed green — every gate this project ran was blind to the app not compiling. **`scripts/test-host` now builds the app target as well as running the suites.** Run it, not `swift test` alone, before landing host work.

Build and install the host app normally. A stdio MCP client launches that
app bundle's New Old World executable with `--mcp-stdio`; the command can be
copied from NOW's MCP module. Start HTTP from the same module and copy its URL
and bearer token there; its default port is 5254. There is no companion product
to build, install, version or keep running. NOW must already be running for stdio to reach its
host projection, and a guest must already be paired for every tool except
host/session health. A cold application catalog sweep on the PowerBook has
previously taken about four seconds. The host therefore settles an
unacknowledged launch as `now-launch-outcome-unknown` after 32 seconds, while
keeping the action gate closed until a late result or disconnect; the local
action response window is 35 seconds and read-only calls retain two seconds.
Quit references expire after 30 seconds and the existing process-drive watchdog
settles after 15 seconds. A quit receipt distinguishes snapshot, revalidation,
and acknowledgement times and says only `requestSent`; process exit still
requires a later listing.

Artifact transfer is deliberately two-step. In NOW's Files page, navigate to the intended guest folder, choose **Add File… > Approve One-Time Agent Transfer…**, select one file, and hand the copied receipt to `now_transfer_approved_artifact` within ten minutes. Approval does not start a transfer. Redemption is one attempt, never overwrites, cannot be retried with the same receipt, and may wait up to one hour locally for the existing size-scaled guest transfer watchdog. A delivery receipt carries the source and handed-to-NOW digests separately and says `guestAcknowledgedWrite: true`, but always says `destinationBytesVerified: false`: current `file.done` proves the guest reported a successful write and stamp, not a read-back hash. The MCP transport does not start, stop, configure, or keep the guest alive.
`now_session_health` also reports host-process problems before guest details.
If more than one NOW host application is running, its required `issues` array
contains `now-host-session-collision` at error severity and names the process
IDs. This is not inferred from the listener that happened to answer: the
running host enumerates its peer applications. The message says explicitly
that MCP may be connected to one host while another visible window reports
Address already in use, so an agent does not diagnose the guest through an
arbitrary surviving socket. Older local-health payloads without `issues`
decode as an empty array for compatibility.

Generic V0.5 upload is a separate three-call command lifecycle. Begin declares
one root-relative destination, byte count, SHA-256, container, and optional
classic metadata; append supplies ordered bounded bytes; commit consumes the
stage and attempts one create through the current guest session. There is no
host-path form, overwrite mode, automatic retry, or resume API for callers.
An unrepresentable optional classic modified date is omitted rather than
saturated or fabricated. A commit receipt distinguishes receiver-confirmed
bytes from local sends and reports unknown cleanup or stalled state honestly.
Host staging and outbound reads use bounded off-UI-actor disk I/O. A failed
local cleanup remains recoverable and is reported as `cleanup-needed`.

The separately proven reverse-streaming prerequisite is integrated into NOW:
guest-originated files use bounded fork reads and the host receives into a
private disk sink with progress, CRC, interruption cleanup, and atomic
finalization. `now_guest_files_download` is the agent-facing projection over
**that** path and adds no second one — the typed command, root and size policy,
receipt, audit line and explicit tool projection this document said arbitrary
download would have to wait for. What it deliberately is **not** is arbitrary:
there is no caller-named destination, no unbounded size, no folder, no
overwrite and no retry. **Reverse resume remains deferred**, and the download is
one attempt because of it: the deployed sequence has no guest-issued source
identity before the host asks for an offset, so a retained partial could stitch
two different sources together.

## Current verification

The capability projection is **tested** and **not metal-verified**. Its
coverage: a partial guest serving only `process.list` gets per-tool
availability derived from what it answers; the same code against a guest
serving `file.list` and `software.list` gets the opposite answer, which is
what makes it a derivation rather than a table; an unprobed costly family
reports `unproven` rather than `unavailable`; mutating families are never
probed, asserted by counting `process.quit` requests during a report; a
refusal observed in ordinary use settles a family the report will not probe;
a non-refusal failure leaves the family `unproven` while still carrying the
guest's own code; every family waiter receives a guest `error` promptly
rather than on its watchdog; and no deciding file in the MCP projection
mentions a guest name or hello field.

Two of those guards were proven by mutation. Removing three of the six
waiter routings reproduced the original defect exactly — 15 s, 30 s and 15 s
waits, each arriving as `timeout` instead of `not-implemented`. It also
found a hazard in the first version of the fix, which cleared the watchdog
before routing: a waiter kind the function forgot would then have hung
forever rather than merely slowly, so the watchdog is now cleared only when
a waiter was actually answered. Reading a hello name in the ledger failed
the identity guard by name and file.

The fake partial guest answers `not-implemented` the way
`now-guest-68k/src/core/wire68.c` does, which means the host's half is tested twice
and the guest's half not at all. Nothing here has been run against the
PowerBook 180c; `open-issues.md` lists exactly what that leaves open.

Every registered projection, the local socket, stdio wrapper, and HTTP wrapper
are **tested** here. The client-launched stdio mode and the app-owned HTTP
listener have exact surface/result/error parity and both run the complete
advertised-tool conformance recipe. HTTP adds
tests for loopback Host, bearer and Origin checks; initialization and session
deletion/cap/expiry; bounded incremental bodies and ambiguous framing; and an
actual incremental-listener liveness path. V0 coverage otherwise remains as
previously recorded: missing host or guest; bounded process snapshots and
references; exact launch/refusal/revalidation; cooperative quit; receipt-backed
artifact approval, staging, replay and delivery; malformed and oversized
requests; endpoint permissions and peer UID; concurrency; discriminated
schemas; and unchanged host module inventory/listener state. V0.5 browse
coverage adds explicit/default/invalid `guestRoot` policy, canonical path and
root-escape rejection, empty/populated/paged list behavior, fork/type/creator/date
projection, exact stat/not-found/scan-limit, stale sessions, bounded guest
refusal and malformed listing rejection, concurrent reads, prior local schema
v4 rejection, maximum-page response size, host absence without launch, strict
MCP arguments, and private-socket round-trip. Upload coverage adds disk-reservation
refusal, ordered bounded chunks, digest mismatch cleanup, orphan-stage recovery,
create-only collision policy, stale/unavailable handling, one-attempt replay and
concurrent-commit refusal, file-backed framing, strict guest completion
evidence, late-collision preservation, malformed MacBinary refusal,
stale-accept invalidation, cleanup-failure recovery, host/guest observation
identities, modified-date omission, strict local/MCP decoding, host build, and a
clean Retro68 guest build.

As of the 2026-07-25 reconciliation, the combined V0.5 tree containing these
eleven projections plus the independently verified reverse-streaming
prerequisite is integrated into local `main`. This is an integration status,
not a new verification rung: the read-only Files tools and reverse transport
have the bounded PowerBook receipts below, while staged upload remains tested
but not metal-verified. The reconciled combined tree passed 419 host tests with
13 opt-in metal tests skipped, produced the host app, and completed the Retro68
guest build. No generic download tool was introduced.

`now_guest_files_download` is **tested** and **not metal-verified**. Its
coverage is aimed at the policy rather than the transfer, because the transfer
is the reverse path that already has the bounded PowerBook receipt above: a
whole file landing inside host-owned storage with a receipt naming it, the
landed file read-only, a guest checksum reported as checked and its absence
reported as unchecked, an offered resume token reported and unused, caller
paths rebased beneath `guestRoot`, and — the assertions the policy rests on —
an over-ceiling item, a folder, an item whose size the guest did not report, a
host without room, and every escaping or unrepresentable path each refused
having sent **no** `file.get` at all. Plus: a second download of one name
landing beside the first rather than over it, an arrival over the ceiling
discarded leaving nothing behind, a guest name turned into a filename rather
than a path, and the projection refusing any argument but `path` — which is how
"the caller cannot name the destination" is enforced rather than asserted. What
that leaves open is what no automated fixture can settle: no agent download has
pulled a real file off a Macintosh, so the 4 MiB ceiling's behaviour against a
1400c's actual catalog sizes, and whether the guest's reported fork sizes agree
with what MacBinary then puts on the wire, are unmeasured.

Staged upload remains **not metal-verified**. The current automated fixtures
exercise the existing transfer state machine and the classic build proves the
guest changes compile, but no disposable file from this slice has yet been
observed landing on the PowerBook. Its reservation metrics, final Finder
identity, classic metadata/fork fidelity, interruption cleanup, and performance
therefore remain open metal gates. Before that pass, the command also needs a
count quota for active stages—including zero-byte stages—and a stale result
when the human changes the active guest share between begin and commit.

`now_guest_files_mutate` is **tested and not metal-verified**, and the
distinction matters more here than for a read: nothing in this slice has moved
or trashed a file on the PowerBook. Its coverage is the refusal list (an
overwrite argument, a crossed key set, the root as a target, a move into its
own subtree, a trashed name that is a path, a path the share cannot express —
the last proven to send nothing at all), root composition on both of a move's
paths, the absent `overwrite` flag on the wire, `exists` arriving as
`conflict` with the File Manager's own number intact, the trashed name
returned verbatim rather than the name that was asked for, a trash with no
reported name staying an honest success with no undo key, the Files log line
carrying the path and the outcome, a refused family taking the whole row
`unavailable` in the capability report, and a report — including its costly
form — sending none of the four. Each was watched failing by mutation. What
remains open on metal is what always does: the `PBCatMove` rename-first path
on a real volume, a Trash that must be created, and the guest's own timings
([files.md](files.md#verified-on-a-real-volume) has the emulator receipt for
the human lane).

The three V0.5 read-only tools also have a bounded **metal-verified** receipt
from 2026-07-24 against the paired PowerBook 1400c. The current host build
reported policy version 1, `guestRoot` at the share root, `Macintosh HD:` as a
display-only label, and only capability/list/stat as available. Two 16-entry
root pages returned deterministic cursors 17 and 33 with type, creator, both
fork sizes, and classic dates. Exact stat succeeded for `Lab` and for a legal
HFS name beginning with control bytes. That latter entry exposed and then
verified a narrow compatibility correction: canonical paths accept
MacRoman-representable HFS control bytes, except NUL because the guest
C-string boundary cannot carry it, while audit text escapes them. The host
remained connected and its normal Files view remained usable. This receipt
does not qualify download, mutation, tree deployment, transfer performance,
or arbitrary guest directories.

The complete V0 companion path also has a bounded **metal-verified**
acceptance receipt from 2026-07-24. This qualifies only the calls and
receipts below against the paired PowerBook 1400c. It does not qualify
sustained load, destination-byte identity, arbitrary applications or
artifacts, guest UI automation, or a future listener/transport.

| Check | Observed result |
| --- | --- |
| Build identity | Commit `1a6057b`; current host debug dylib SHA-256 `3a2bcaf8ca356070075d83038975180f5285e6bd52754941a87cde2a07712f75`; current companion SHA-256 `5bc3a13dc4d0c02764c9c56c717519bbfe5b9417d9a3d57e81de77cd71915cb2`. |
| Prior read-only load | 20 health calls at 250 ms spacing plus 4 concurrent calls measured 7.6-14.4 ms. Eight process calls at 1 s spacing plus 2 concurrent calls measured 51.8-116.9 ms. All snapshots stayed bounded and stable; host use stayed about 44 MB, 6 baseline threads, and 0.0-0.7% CPU. |
| Health and reconnect | The current companion reported connected PowerBook health, then `now-host-unavailable` in 10 ms while the stopped host was absent and did not launch it. After relaunch, the PowerBook redialed automatically and health returned connected under a new session ID, `4BE83248-72B3-4A73-AB6E-EA9E3A0B476B`. |
| Process observation | Fresh snapshots took 50-90 ms, contained six bounded rows before and after the action, and exposed no PSN or path. A reference from the prior session returned `now-process-reference-stale` after reconnect and acted on nothing. |
| Exact safe launch | `SimpleText` returned seven exact candidates and launched nothing in 17.89 s. Selecting the current opaque SimpleText 1.4 candidate returned `launched` in 17.66 s; a fresh process snapshot separately showed SimpleText as the front application. |
| Cooperative quit | The fresh SimpleText process reference was revalidated and returned `requestSent` in 230 ms. A later point-in-time process snapshot showed SimpleText absent and NOW front; the quit receipt itself did not claim exit. |
| Approved artifact | The native Files action approved one private staged 69-byte text file for guest `Lab`; the MCP received only the one-use receipt. Redemption returned `delivered` in 180 ms after matching `file.done` (transfer `CD3F6B4E-ADDE-4823-A2F8-F3107FF33372`), with source SHA-256 `d98dac6e6cb591a19084d2400b7d2031abdb5fbb711e6d0aab33c01daddf41c4` and handed-to-NOW SHA-256 `b49e50f1c82f1caea7e34090d3da83de64128bc629be38cacd1bcbfce77e0a65`; it correctly reported `destinationBytesVerified: false`. |
| Compatibility finding | The first 61-byte artifact exposed an existing host→guest date overflow: the deployed guest's signed parser saturated a modern optional date to January 1972. Commit `1a6057b` now omits unrepresentable dates across every host→guest file lane. The mutation test failed when that guard was removed, and a second live artifact appeared with the guest's honest creation time rather than 1972. See [Files compatibility](files.md#classic-date-compatibility-boundary). |
| Final host state | The freshly built host was left listening and paired to `Powerbook 1400c`; its final sampled process state was 113,360 KB RSS and 1.1% CPU. The companion exited after each stdio call and no extra guest process, listener, module, port, or protocol message was introduced. |

The acceptance used SimpleText as a harmless user-visible application and
two disposable text files in `Lab`. The first remains as the evidence that
found the timestamp defect; the second is the corrected 69-byte receipt.
No deletion, overwrite, shell, raw path, guest configuration, or
CodeKitten project-tree access was attempted. The agent observed the live
host UI, paired guest responses, process transitions, and Files listings;
it did not independently inspect the physical guest display or read back
the destination bytes.
