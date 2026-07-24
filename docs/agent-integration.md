# Host agent-integration boundary

The optional NOW agent-integration companion is host-side only. It projects a narrow typed view of capabilities already owned by a running NOW host, but it does not own the host app, guest connection, transport, transfer lane, or any human-facing operation.

## Implemented slices

The implemented surface exposes only four host-owned projections.

| Tool contract | Existing NOW owner | Implemented projection |
| --- | --- | --- |
| `now_session_health` | `GuestListener.State` and `GuestListener.SessionHealth` | `AgentIntegrationHostAdapter.sessionHealth` returns a side-effect-free snapshot of not-listening, listening, connected, or failed host state. Connected snapshots carry only existing guest health fields plus an opaque adapter-owned session ID. |
| `now_list_processes` | `process.list` / `process.listing` and `GuestListener.listProcesses` | Reads a fresh, complete snapshot from the current paired guest. It returns at most 48 bounded entries, a point-in-time observation timestamp, and opaque references only for entries with a live PSN. PSNs and paths never leave the host adapter. A reference may be offered only to cooperative quit, which revalidates it before use. |
| `now_launch_software` | `software.list` / `software.listing`, then the existing declared `launch` command | Reads the current `apps` catalog and launches only one exact full-name match, using the listing path internally. Zero matches return `notFound`; multiple matches return at most eight bounded candidates and launch nothing. An opaque candidate reference is session-bound and revalidated against a fresh catalog before launch. No path or raw guest result text crosses the host adapter. |
| `now_request_quit` | `process.list` / `process.listing`, then `process.quit` / `process.result` | Accepts only a current opaque process reference issued within 30 seconds. The host re-lists, verifies the same PSN still has the same name, kind, type, and creator, then sends cooperative quit. The guest revalidates the live PSN again. Success means only that the quit request was sent, never that the process exited. |

The client-launched `NOWAgentCompanion` executable speaks newline-delimited JSON-RPC over stdio and advertises only these four tools. It opens one bounded local request to the running host for each call. Session health sends no guest message; the other tools ask the host to use the existing paired connection. Launch accepts exactly one bounded name or generated opaque reference; quit accepts exactly one generated process reference. Neither accepts a PSN or guest path. Every tool exposes typed unavailability and no host or listener lifecycle operation. If the host is absent, the result is `now-host-unavailable`; the companion never launches it. If the host is present without a paired guest, guest-dependent tools return `now-guest-unavailable` and never use cached state.

The planned approved-artifact-transfer tool is not implemented.

## Connection posture

NOW keeps its existing guest-dials-host paired connection throughout V0. The companion projects host-owned operations over that already-running session; it does not add a listener to the NOW guest, introduce a second guest protocol implementation, or wait for a replacement transport before the remaining tools proceed.

CodeKitten is the proving ground for the opposite connection posture. Its listener must first establish the design under adversarial stress, including framing, pairing and security, health and latency semantics, lifecycle, stale-state recovery, and classic cooperative-loop behavior. The [sibling CodeKitten roadmap](../../codekitten/docs/plans/2026-07-23-002-feat-codekitten-phase-0-1-roadmap-plan.md) describes that intended proof work; it is a prerequisite, not evidence that the listener or a shared service already exists.

Only after that proof should a separate worktree extract the parts that have demonstrably generalized into a shared network-protocol service. That future service must leave a compatible migration path for NOW, but it is neither current shared infrastructure nor a dependency of the NOW MCP. NOW will not change its functional dial-out path merely to validate CodeKitten hypotheses.

## Local trust boundary

V0 deliberately trusts processes running as the same macOS user. This protects against other local users and accidental clients; it does not protect against malicious code already running as that user.

- The host creates `dev.newoldworld.now-agent-<uid>/host.sock` beneath the user's private temporary directory. The directory is mode `0700`; the socket is mode `0600`.
- The host checks every accepted peer with `getpeereid` and serves it only when the effective UID matches.
- The companion checks that the directory and socket are owned by its effective UID, have no group/other permission bits, and are a directory and socket rather than links or other file types.
- Local schema v2 allows only `session_health`, `list_processes`, `launch_software`, and `request_quit`, permits one request per connection, and caps each request and response at 16 KiB. V2 makes the process-reference authority change explicit rather than letting a v1 companion misread a quit-eligible snapshot. Launch selection is exactly one bounded name or opaque reference; quit selection is exactly one current opaque process reference. MCP stdio input is separately capped at 64 KiB per line.

The local socket is not the guest wire. It creates no TCP listener, guest connection, protocol message, guest module, dashboard item, daemon, launch agent, or second app.

## Operational prerequisites

Build the host app normally and build the companion with `swift build --package-path host --product NOWAgentCompanion`. An MCP client may launch that executable over stdio, but this repository intentionally contains no client configuration. NOW must already be running for any tool to reach its host projection, and a guest must already be paired for a process snapshot, launch, or quit. A cold application catalog sweep on the PowerBook has previously taken about four seconds. The host therefore settles an unacknowledged launch as `now-launch-outcome-unknown` after 32 seconds, while keeping the action gate closed until a late result or disconnect; the local action response window is 35 seconds and read-only calls retain two seconds. Quit references expire after 30 seconds and the existing process-drive watchdog settles after 15 seconds. A quit receipt distinguishes snapshot, revalidation, and acknowledgement times and says only `requestSent`; process exit still requires a later listing. The companion does not start, stop, configure, or keep either side alive.

## Current verification

All four projections, the local socket, and the stdio wrapper are **tested** here. Focused tests cover missing host or guest; populated and empty process tables; opaque-reference stability; legacy entries without PSNs; exact launch, zero and multiple matches, paged catalogs, empty paths, redacted guest refusal, reference-cap rollover, an unacknowledged command and blocked retry, stale and reconnect-invalidated software references, and concurrent launch refusal; cooperative quit after a fresh full-identity re-list; vanished, expired, mismatched, and reconnect-invalidated process references; bounded guest refusal; concurrent quit refusal; bounded fields and output; malformed and oversized requests; endpoint permissions; real peer-UID comparison; forced peer rejection; duplicate and concurrent reads; discriminated MCP schemas; and unchanged host module inventory/listener state with the socket absent or present. The launch ambiguity guard and quit pre-action revalidation were both introduced proof-first.

The exact read-only companion path is also **metal-verified** by the bounded 2026-07-24 acceptance pass below. Safe launch and cooperative quit remain **tested**, not metal-verified, until connected companion calls are separately observed. The read-only pass does not qualify either action, the unimplemented transfer tool, sustained load, guest UI interaction, transfers, or a future listener/transport.

| Check | Observed result |
| --- | --- |
| Build identity | Commit `f0b5845`; freshly built companion SHA-256 `6979908604db310473d91bb92a306b726c1802ab382ae975b4d943450eea9840` advertised exactly `now_session_health` and `now_list_processes`. |
| Host absence and recovery | Both tools returned `now-host-unavailable` with no snapshot while the host was normally quit. The PowerBook redialed a freshly built host in about four seconds; each host launch minted a new session ID. |
| Paced health reads | 20 calls at 250 ms spacing plus 4 concurrent calls: 7.6 ms minimum, 10.0 ms median, 14.0 ms p95, 14.4 ms maximum. Guest ping and frame counts advanced. |
| Paced process reads | 8 calls at 1 s spacing plus 2 concurrent calls: 51.8 ms minimum, 61.8 ms median, 116.9 ms p95/maximum. Every snapshot held the same 6 bounded rows with point-in-time freshness and stable opaque references. |
| Reconnect scope | Neither tool returned rows during host absence. After reconnect, a fresh snapshot used the new session ID and newly minted opaque references rather than the prior scope. |
| Host impact | The host stayed at roughly 44 MB, 6 baseline threads with a transient peak of 8, and 0.0-0.7% CPU during the measured window. No timeout, unavailable result, protocol error, guest disconnect, or stopped ping was observed under load. |

The guest remained paired and NOW remained the reported front process throughout the measured reads. No guest UI control was exercised or visually qualified during this pass.

A separate safe-launch acceptance attempt later on 2026-07-24 did not
advance the launch rung. The PowerBook was visibly paired to an
Xcode-derived host, but the freshly built companion received typed
`now-host-unavailable` because that running host did not expose the local
adapter. The host did not exit through normal application controls, so
the pass stopped rather than force-terminate the user's session. No
guest application was launched; safe launch remains **tested**, not
metal-verified.
