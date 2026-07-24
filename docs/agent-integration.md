# Host agent-integration boundary

The optional NOW agent-integration companion is host-side only. It may project a narrow typed view of capabilities already owned by a running NOW host, but it does not own the host app, the guest connection, the transport, the transfer lane, or any human-facing operation.

## First vertical slice

The first slice implements only the in-process host projection behind the planned `now_session_health` tool.

| Tool contract | Existing NOW owner | Implemented projection |
| --- | --- | --- |
| `now_session_health` | `GuestListener.State` and `GuestListener.SessionHealth` | `AgentIntegrationHostAdapter.sessionHealth` returns a side-effect-free snapshot of not-listening, listening, connected, or failed host state. Connected snapshots carry only existing guest health fields plus an opaque adapter-owned session ID. |

The call has no inputs, sends no guest message, opens no connection, and exposes no listener lifecycle operation. `AgentIntegrationSessionHealthResult.hostUnavailable` fixes the companion-side failure vocabulary at `now-host-unavailable`, but no external transport currently emits it.

The other four planned V0 tools are not implemented.

## Local adapter threat-model gate

The repository has no existing host-local IPC or caller-authentication pattern to reuse. Its only listener is the guest-facing TCP `NWListener` in `GuestListener`; it has protocol handshake rules for a classic Mac and is not a local companion boundary. A repository search found no XPC service, Mach service, UNIX-domain socket, peer-credential check, audit-token check, or code-signature validation.

That leaves a product/security decision this slice does not make: which local processes are authorized to reach a future adapter.

- A same-user boundary could use a private UNIX-domain socket plus peer-UID validation, but accepting every process running as the logged-in user is a policy choice.
- A code-identity boundary would need a signed-client/XPC design and packaging analysis. It must still avoid a daemon, launch agent, second desktop app, or host-managed companion lifecycle.

Unauthenticated loopback TCP, a filesystem-published endpoint without peer validation, and reuse of the guest wire are rejected. No stdio MCP executable or host-local transport is added until the caller trust boundary is explicitly chosen.

## Current verification

The host projection is **tested** here, not metal-verified. Focused tests cover idle and connected snapshots, stable identity across duplicate concurrent reads, identity invalidation across reconnect, typed host-unavailable vocabulary, and unchanged host module inventory/listener state when the facade is present. The full host regression suite also passes here; its metal tests remain skipped. An actual absent-host or malformed-local-request test remains blocked on the transport decision.
