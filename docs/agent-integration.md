# Host agent-integration boundary

The optional NOW agent-integration companion is host-side only. It projects a narrow typed view of capabilities already owned by a running NOW host, but it does not own the host app, guest connection, transport, transfer lane, or any human-facing operation.

## Session-health slice

The implemented slice exposes only the host-owned projection behind `now_session_health`.

| Tool contract | Existing NOW owner | Implemented projection |
| --- | --- | --- |
| `now_session_health` | `GuestListener.State` and `GuestListener.SessionHealth` | `AgentIntegrationHostAdapter.sessionHealth` returns a side-effect-free snapshot of not-listening, listening, connected, or failed host state. Connected snapshots carry only existing guest health fields plus an opaque adapter-owned session ID. |

The client-launched `NOWAgentCompanion` executable speaks newline-delimited JSON-RPC over stdio and advertises only this no-input tool. It opens one bounded local request to the running host for each call. It sends no guest message and exposes no host or listener lifecycle operation. If the host is absent, the result is `now-host-unavailable`; the companion never launches it.

The other four planned V0 tools are not implemented.

## Connection posture

NOW keeps its existing guest-dials-host paired connection throughout V0. The companion projects host-owned operations over that already-running session; it does not add a listener to the NOW guest, introduce a second guest protocol implementation, or wait for a replacement transport before the remaining tools proceed.

CodeKitten is the proving ground for the opposite connection posture. Its listener must first establish the design under adversarial stress, including framing, pairing and security, health and latency semantics, lifecycle, stale-state recovery, and classic cooperative-loop behavior. The sibling CodeKitten roadmap at `../codekitten/docs/plans/2026-07-23-002-feat-codekitten-phase-0-1-roadmap-plan.md` describes that intended proof work; it is a prerequisite, not evidence that the listener or a shared service already exists.

Only after that proof should a separate worktree extract the parts that have demonstrably generalized into a shared network-protocol service. That future service must leave a compatible migration path for NOW, but it is neither current shared infrastructure nor a dependency of the NOW MCP. NOW will not change its functional dial-out path merely to validate CodeKitten hypotheses.

## Local trust boundary

V0 deliberately trusts processes running as the same macOS user. This protects against other local users and accidental clients; it does not protect against malicious code already running as that user.

- The host creates `dev.newoldworld.now-agent-<uid>/host.sock` beneath the user's private temporary directory. The directory is mode `0700`; the socket is mode `0600`.
- The host checks every accepted peer with `getpeereid` and serves it only when the effective UID matches.
- The companion checks that the directory and socket are owned by its effective UID, have no group/other permission bits, and are a directory and socket rather than links or other file types.
- The local schema is versioned, allows only `session_health`, permits one request per connection, and caps each request and response at 16 KiB. MCP stdio input is separately capped at 64 KiB per line.

The local socket is not the guest wire. It creates no TCP listener, guest connection, protocol message, guest module, dashboard item, daemon, launch agent, or second app.

## Operational prerequisites

Build the host app normally and build the companion with `swift build --package-path host --product NOWAgentCompanion`. An MCP client may launch that executable over stdio, but this repository intentionally contains no client configuration. NOW must already be running for an available health result; the companion does not start, stop, configure, or keep it alive.

## Current verification

The projection, local socket, and stdio wrapper are **tested** here. Focused tests cover missing host, malformed and oversized requests, endpoint permissions, real peer-UID comparison, forced peer rejection, duplicate and concurrent reads, socket-to-MCP traversal, and unchanged host module inventory/listener state with the socket absent or present. A built companion returned typed unavailable while the host process was absent, then reported a live `connected` session with the PowerBook 1400c after the host was launched. The tool path has therefore been observed against the real guest; broader paired human workflows were not re-run as part of this read-only check.
