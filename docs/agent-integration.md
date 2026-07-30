# Host agent-integration boundary

The optional NOW agent-integration companion is host-side only. It projects a narrow typed view of capabilities already owned by a running NOW host, but it does not own the host app, guest connection, transport, transfer lane, or any human-facing operation.

It is also **not a third face**. It is a client of the wire, reaching a guest through the same commands and message families a human does; the rule and the reason it needs writing down are in [command-parity.md](command-parity.md#the-mcp-is-a-client-not-a-face). A tool projects a capability, it never implements one.

## Availability is decided by capability, never by identity

NOW has two guests of very different completeness. The PowerPC Carbon guest implements most of the contract; NOW-68K implements a small part of it and answers `unknown-command` or a `not-implemented` error to the rest — which is the contract's own additive answer, not a failure. Every tool here must therefore work against whichever guest is connected, and its availability must follow from what that guest can actually do.

Nothing in the companion reads the guest's identity to decide anything. A `guest` selector says WHICH machine a call is about and is resolved by the host before any operation runs; it never becomes an input to what that operation may do. The hello carries a name, a version and an OS string, and the session-health projection reports all three to its caller — but no file that decides what a tool may do is allowed to read them. `AgentIntegrationCapabilityTests.testNoCompanionCodeBranchesOnGuestIdentity` fails the build otherwise. That guard is not hypothetical caution: `MetalQuitTests` derived a guest's abilities from its hello name and went stale the same afternoon that guest grew `process.list`, quietly understating its own evidence. Nothing failed, because a test that expects less always passes.

Two sources, matching the two kinds of capability a guest has.

**Commands** come from `help`, a wire command on both guests that returns that machine's own table. It is fetched once per connection and is the same live source the host console's Tab completion uses, which means a guest that grows a verb becomes usable here with no companion release.

**Message families** (`process.list`, `file.list`, `process.quit`, `software.list`, `file.put`) are not in any command table. `help` cannot see them, and that gap is exactly how `ps` shipped wire-only on NOW-68K and went unnoticed for a day. A family's availability is therefore established by asking, under a stated probing policy:

| Family | How it is established | Why |
| --- | --- | --- |
| `process.list` | probed by the report, and by ordinary use | read-only, and the same request the tool sends; 50-90 ms on the 1400c |
| `file.list` | probed by the report, and by ordinary use | read-only; `now_guest_files_capabilities` already spends one |
| `software.list` | probed only when the caller passes `probeCostly` | its first page is a whole-volume sweep, ~4 s on the PowerBook. A guest that does not implement it refuses instantly, so the cost falls only on the guest that does — but that is still four seconds of someone's machine, so a caller asks for it on purpose |
| `process.quit` | ordinary use only | the smallest request in this family quits a process. "I would have to quit something to find out whether I can quit things" is not an acceptable way to answer a question |
| `file.put` | ordinary use only | same: the smallest request writes a file to the guest |

A family therefore has three states, not two. `unproven` means nobody has asked this guest yet, and is a different fact from `unavailable`. Collapsing them would make the report understate a machine it never questioned — the same failure the hello-name table produced. Only the contract's typed refusals (`not-implemented`, `unknown-command` and their siblings) move a family to `unavailable`; a timeout or a Toolbox error leaves it `unproven`, because silence proves nothing about what a guest implements and one wedged MacTCP stack must not be recorded as a permanently missing feature.

Because ordinary use feeds the same ledger, tools switch on as capabilities appear: a family another session lands on a guest becomes visible here the first time anything asks for it, with no release on this side.

**A tool that cannot be safe against a guest is unavailable against it, in typed form, and that is a complete answer.** It is never a weaker version of the tool with the unsafe part skipped. Two consequences worth stating because they look like gaps:

- `now_request_quit` needs the `process.quit` **family**, not the `quit` **command**. NOW-68K has the command; it does not have the family, so the opaque-reference and PSN-revalidation model this tool is built on has nothing to stand on. The model is not relaxed to make the tool "work".
- `now_launch_software` needs `software.list` as well as the `launch` command, because "launch exactly one exact match from the current catalog" is the entire safety story and there is no catalog without the listing.
- `now_bring_to_front` needs the `process.front` **family** for the same reason as quit, and needs `process.list` twice over: once to revalidate the reference, once to tell a confirmed switch from an accepted one. Both guests serve the family, so this one is available where quit is not.

And a refusal must arrive as a refusal. `GuestListener.recordGuestError` routes a guest `error` to every waiter kind — command, file listing, process listing, software listing, process result, file change and census — because the ids come from one sequence. It previously routed three of those six, so exactly the requests a partial guest refuses reached their caller as a 15- or 30-second timeout carrying no reason. Against a guest that implements part of the contract, refusal is ordinary traffic rather than an edge case, and routing it is what makes the companion usable at all.

The completed five-tool V0 surface remains intact; the surface is now fourteen tools. The approved follow-on is the
[NOW MCP V0.5 guest-files command roadmap](plans/2026-07-24-003-feat-now-mcp-v0-5-files-command-roadmap-plan.md).
V0.5 widens guest filesystem authority only through typed, logged NOW commands
under a persisted root-relative `guestRoot`; it does not turn this companion
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
source. Download and every broader mutation/deployment command remain deferred.

## Where a projection lives

The projections are a module, not a shape the MCP server happens to have:
`now-host/Sources/NOWAgentIntegration/Projection/`. It sits in the package
product both build systems already share, so every host face can read one
registry — the companion renders it as MCP tools, the capability ledger
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
| the outcome: `answered`, or `refused` with the projection's own sentence | which flavour of unavailable an answered result reported; that lives in the result |

**A refused invocation emits.** An attempt that was denied is the more
interesting event of the two, and it is the one class of outcome the host
would otherwise never see: an argument refusal is decided inside the companion
and sends no local request, so an unemitted refusal is recorded nowhere.
`answered` is deliberately coarse — reading a typed result back apart would
mean this seam learning the shape of a dozen result types and going stale
behind the thirteenth.

The MCP face reports over the same per-uid private socket everything else
uses (local schema v8's `audit` operation), and the host writes the line under
the `agent` area of [logging.md](logging.md#the-agent-area-who-asked). The
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

## Implemented slices

The implemented V0 surface exposes only five host-owned projections.

| Tool contract | Existing NOW owner | Implemented projection |
| --- | --- | --- |
| `now_session_capabilities` | `help` over `GuestListener.runCommand`, plus `GuestListener.familyObservations` | Reports the connected guest's own command table, each depended-on message family's state and the evidence for it, and a per-tool availability derived from those. Sends `help` once per connection and bounded read-only probes for `process.list` and `file.list`; `software.list` only on request; never a mutating family. Reads no guest identity. |
| `now_session_health` | `GuestListener.State` and `GuestListener.SessionHealth` | `AgentIntegrationHostAdapter.sessionHealth` returns a side-effect-free snapshot of not-listening, listening, connected, or failed host state. Connected snapshots carry only existing guest health fields plus an opaque adapter-owned session ID. |
| `now_list_processes` | `process.list` / `process.listing` and `GuestListener.listProcesses` | Reads a fresh, complete snapshot from the current paired guest. It returns at most 48 bounded entries, a point-in-time observation timestamp, and opaque references only for entries with a live PSN. PSNs and paths never leave the host adapter. A reference may be offered only to cooperative quit, which revalidates it before use. |
| `now_launch_software` | `software.list` / `software.listing`, then the existing declared `launch` command | Reads the current `apps` catalog and launches only one exact full-name match, using the listing path internally. Zero matches return `notFound`; multiple matches return at most eight bounded candidates and launch nothing. An opaque candidate reference is session-bound and revalidated against a fresh catalog before launch. No path or raw guest result text crosses the host adapter. |
| `now_request_quit` | `process.list` / `process.listing`, then `process.quit` / `process.result` | Accepts only a current opaque process reference issued within 30 seconds. The host re-lists, verifies the same PSN still has the same name, kind, type, and creator, then sends cooperative quit. The guest revalidates the live PSN again. Success means only that the quit request was sent, never that the process exited. |
| `now_transfer_approved_artifact` | Native Files approval, then `GuestListener.putFile` and `file.done` | The Files page stages one human-selected regular file in a private read-only copy and copies a one-use receipt. The MCP can redeem only that receipt for the approved current guest folder. Redemption rechecks session, expiry, inode, link count, mode, size, and SHA-256 before entering the existing one-at-a-time transfer lane with overwrite disabled. Success requires the matching `file.done ok:true`. |

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

The V0.5 upload additions are:

| Tool contract | NOW command owner | Implemented projection |
| --- | --- | --- |
| `now_guest_files_upload_begin` | `guestFiles.put` staging policy | Validates one canonical create-only destination beneath `guestRoot`, declared wire size/container/classic metadata, and SHA-256; requires an existing parent and reserves private disk capacity while preserving five percent of currently available important-usage capacity. |
| `now_guest_files_upload_append` | Private NOW upload stage | Accepts one ordered base64 chunk of at most 8 KiB at the exact receipt offset. It never accepts or resolves a modern-host path and sends no guest message. |
| `now_guest_files_upload_commit` | `guestFiles.put` over existing `file.offer` / bulk / `file.done` | Seals and revalidates the stage, validates MacBinary structure when selected, streams one frame at a time from its immutable file, never creates parents or overwrites, and returns guest reservation, progress, integrity, finalization, and cleanup evidence. Success requires matching guest length, CRC, same-folder rename, and temp cleanup. The stage is one-attempt and replay conflicts. |

The client-launched `NOWAgentCompanion` executable speaks newline-delimited JSON-RPC over stdio and advertises these fourteen tools. It opens one bounded local request to the running host for each call. Session health and upload staging send no guest message; the capability report sends only `help` and the bounded read-only probes named above; commit and the other guest-dependent tools ask the host to use the existing paired connection. Launch accepts exactly one bounded name or generated opaque reference; quit accepts exactly one generated process reference; approved-artifact transfer accepts exactly one host-minted receipt. The V0.5 Files tools accept only canonical paths relative to host-owned `guestRoot`, never an absolute guest path or a modern-host path. No tool accepts a PSN, shell text, arbitrary host filesystem operation, or unimplemented guest Files mutation. Every tool exposes typed unavailability and no host or listener lifecycle operation. If the host is absent, the result is `now-host-unavailable`; the companion never launches it. If the host is present without a paired guest, guest-dependent tools return `now-guest-unavailable` and never use cached state.

## Connection posture

NOW keeps its existing guest-dials-host paired connection throughout V0. The companion projects host-owned operations over that already-running session; it does not add a listener to the NOW guest, introduce a second guest protocol implementation, or wait for a replacement transport before the remaining tools proceed.

CodeKitten is the proving ground for the opposite connection posture. Its listener must first establish the design under adversarial stress, including framing, pairing and security, health and latency semantics, lifecycle, stale-state recovery, and classic cooperative-loop behavior. The CodeKitten roadmap (a sibling project, not public) describes that intended proof work; it is a prerequisite, not evidence that the listener or a shared service already exists.

Only after that proof should a separate worktree extract the parts that have demonstrably generalized into a shared network-protocol service. That future service must leave a compatible migration path for NOW, but it is neither current shared infrastructure nor a dependency of the NOW MCP. NOW will not change its functional dial-out path merely to validate CodeKitten hypotheses.

## Local trust boundary

V0 deliberately trusts processes running as the same macOS user. This protects against other local users and accidental clients; it does not protect against malicious code already running as that user.

- The host creates `dev.newoldworld.now-agent-<uid>/host.sock` beneath the user's private temporary directory. The directory is mode `0700`; the socket is mode `0600`.
- The host checks every accepted peer with `getpeereid` and serves it only when the effective UID matches.
- The companion checks that the directory and socket are owned by its effective UID, have no group/other permission bits, and are a directory and socket rather than links or other file types.
- Local schema v8 makes an agent call VISIBLE. It adds one operation that asks the host for nothing: a face reports a capability it has just invoked — capability name, face, the guest selector as given, and `answered` or `refused` with a bounded sentence — and the host writes that line into its own log under the `agent` area. It carries no selection of any kind and reaches no guest, so it is exempt from the addressing check and shares the read-only response window. The version moved because the shape of the surface changed: a v7 host answers `invalid-request` to it, which is honest — that host has no audit line to write — and a v7 companion never sends one, which is the opacity rule 3 exists to stop being acceptable. See *Every agent call leaves a trace* above.
- Local schema v7 makes the surface guest-ADDRESSABLE. Every tool takes an optional `guest`: a machine id (`pb1400c` — "whatever is connected to that Mac now", which follows a reconnection) or a session id (`pb1400c-<uuid>` — one connection, refused `now-guest-session-ended` once it is over rather than answered by its successor, the same staleness contract the process and quit references keep). Omitting it means the machine the host is currently driving, which is what every v6 caller meant. Naming a machine that is connected but not being driven is refused `now-guest-not-addressed`, naming the driven machine and the whole roster — never answered by the other machine. `now_session_health` reports the driven machine's reference and every connected machine, so a caller can discover the ids it needs. **The guest's ADDRESS is not on this surface.** The host observes it and anchors the machine id on it; the companion is told the id, the session id and the display name, and nothing about where anything lives — the same reticence the endpoint keeps about its own path. The version moved because a v6 companion cannot say which machine it means and would read whichever one happened to be active as the answer to a question it asked about another. Addressability does not touch availability: what a guest can do is still asked of the guest and never inferred from which guest it is.
- Local schema v6 adds the read-only session capability report to v5's staged-upload and browse operations, permits one request per connection, and caps each request and response at 16 KiB. The version changes when authority or action shape changes so an older companion cannot silently misread it. Browse selection is one bounded root-relative path and optional positive cursor; upload selection is one bounded root-relative destination plus declared metadata, followed only by an opaque upload ID, exact offset, and bounded bytes. The NOW command layer performs canonical MacRoman/HFS validation and policy composition. Launch selection is exactly one bounded name or opaque reference; quit selection is exactly one current opaque process reference; artifact selection is exactly one syntactically valid receipt; the capability report's only input is a required boolean `probeCostly`, required rather than defaulted because it decides whether the call spends a guest's whole-volume sweep. The version moved because the shape of the surface changed: a v5 companion cannot ask what the connected guest implements and would present every tool as unconditionally available. MCP stdio input is separately capped at 64 KiB per line.
- V0.5 upload staging lives in a private mode-`0700` per-process directory; each stage is preallocated mode `0600`, becomes mode `0400` only after size and SHA-256 match, expires after ten minutes, and is consumed after one transfer attempt. Capacity is derived from current host disk availability and outstanding reservations, not an arbitrary whole-file cap. On startup NOW removes only well-formed private stages owned by a demonstrably dead process and emits an audit event. Live-process or structurally unfamiliar directories are retained.
- Approval staging lives in a per-host-launch mode-`0700` directory. A selected source must be one directly opened, single-link regular file no larger than 4 MiB. The sealed copy is mode `0400`, expires after ten minutes, is bound to the current guest session and approved Files destination, and is consumed on its first redemption attempt. Final open follows no links and rechecks owner, inode, device, link count, size, timestamps, mode, and digest.
- The MCP cannot mint an approval, list staging, choose a destination, or recover the original path. A user may deliberately select a file from anywhere the native picker can reach, but that grants only the staged copy; it does not expose or make the MCP a side door into a CodeKitten project tree. Same-user malicious code remains outside V0's stated protection.

The local socket is not the guest wire. It creates no TCP listener, guest connection, protocol message, guest module, dashboard item, daemon, launch agent, or second app.

## Operational prerequisites

Two build systems compile this code, and `NOWAgentIntegration` means the same thing to both: a package product. SwiftPM declares it as a library beside the two executables, and the Xcode project consumes that same local package — an `XCLocalSwiftPackageReference` at `.`, linked into the app target — so `import NOWAgentIntegration` is a plain import everywhere.

It was not always so, and the failure is worth keeping. The Xcode target used to pull `Sources/NOWAgentIntegration` in as a second synchronized file group, which put the types in scope but left the module *name* unresolvable, so every import needed a `#if canImport(NOWAgentIntegration)` guard. Two files added in `cbe83e9` omitted it and broke `xcodebuild` for a day while `swift build` and `swift test` stayed green — every gate this project ran was blind to the app not compiling. **`scripts/test-host` now builds the app target as well as running the suites.** Run it, not `swift test` alone, before landing host work.

Build the host app normally and build the companion with `swift build --package-path now-host --product NOWAgentCompanion`. An MCP client may launch that executable over stdio, but this repository intentionally contains no client configuration. NOW must already be running for any tool to reach its host projection, and a guest must already be paired for every tool except host/session health. A cold application catalog sweep on the PowerBook has previously taken about four seconds. The host therefore settles an unacknowledged launch as `now-launch-outcome-unknown` after 32 seconds, while keeping the action gate closed until a late result or disconnect; the local action response window is 35 seconds and read-only calls retain two seconds. Quit references expire after 30 seconds and the existing process-drive watchdog settles after 15 seconds. A quit receipt distinguishes snapshot, revalidation, and acknowledgement times and says only `requestSent`; process exit still requires a later listing.

Artifact transfer is deliberately two-step. In NOW's Files page, navigate to the intended guest folder, choose **Add File… > Approve One-Time Agent Transfer…**, select one file, and hand the copied receipt to `now_transfer_approved_artifact` within ten minutes. Approval does not start a transfer. Redemption is one attempt, never overwrites, cannot be retried with the same receipt, and may wait up to one hour locally for the existing size-scaled guest transfer watchdog. A delivery receipt carries the source and handed-to-NOW digests separately and says `guestAcknowledgedWrite: true`, but always says `destinationBytesVerified: false`: current `file.done` proves the guest reported a successful write and stamp, not a read-back hash. The companion does not start, stop, configure, or keep either side alive.

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

The separately proven reverse-streaming prerequisite is now integrated into
NOW: guest-originated files use bounded fork reads and the host receives into a
private disk sink with progress, CRC, interruption cleanup, and atomic
finalization. This changes no MCP authority. Arbitrary download remains absent
until a typed NOW command, root/size policy, receipts, audit, and explicit tool
projection are designed and verified; reverse resume remains deferred.

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
rather than on its watchdog; and no deciding file in the companion surface
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

All fourteen projections, the local socket, and the stdio wrapper are **tested** here. V0 coverage remains as previously recorded: missing host or guest; bounded process snapshots and references; exact launch/refusal/revalidation; cooperative quit; receipt-backed artifact approval, staging, replay and delivery; malformed and oversized requests; endpoint permissions and peer UID; concurrency; discriminated schemas; and unchanged host module inventory/listener state. V0.5 browse coverage adds explicit/default/invalid `guestRoot` policy, canonical path and root-escape rejection, empty/populated/paged list behavior, fork/type/creator/date projection, exact stat/not-found/scan-limit, stale sessions, bounded guest refusal and malformed listing rejection, concurrent reads, prior local schema v4 rejection, maximum-page response size, host absence without launch, strict MCP arguments, and private-socket round-trip. Upload coverage adds disk-reservation refusal, ordered bounded chunks, digest mismatch cleanup, orphan-stage recovery, create-only collision policy, stale/unavailable handling, one-attempt replay and concurrent-commit refusal, file-backed framing, strict guest completion evidence, late-collision preservation, malformed MacBinary refusal, stale-accept invalidation, cleanup-failure recovery, host/guest observation identities, modified-date omission, strict local/MCP decoding, host build, and a clean Retro68 guest build.

As of the 2026-07-25 reconciliation, the combined V0.5 tree containing these
eleven projections plus the independently verified reverse-streaming
prerequisite is integrated into local `main`. This is an integration status,
not a new verification rung: the read-only Files tools and reverse transport
have the bounded PowerBook receipts below, while staged upload remains tested
but not metal-verified. The reconciled combined tree passed 419 host tests with
13 opt-in metal tests skipped, produced the host app, and completed the Retro68
guest build. No generic download tool was introduced.

Staged upload remains **not metal-verified**. The current automated fixtures
exercise the existing transfer state machine and the classic build proves the
guest changes compile, but no disposable file from this slice has yet been
observed landing on the PowerBook. Its reservation metrics, final Finder
identity, classic metadata/fork fidelity, interruption cleanup, and performance
therefore remain open metal gates. Before that pass, the command also needs a
count quota for active stages—including zero-byte stages—and a stale result
when the human changes the active guest share between begin and commit.

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
