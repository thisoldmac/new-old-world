# Host agent-integration boundary

The optional NOW agent-integration companion is host-side only. It projects a narrow typed view of capabilities already owned by a running NOW host, but it does not own the host app, guest connection, transport, transfer lane, or any human-facing operation.

The completed five-tool V0 surface remains the current implementation. The
approved follow-on is the
[NOW MCP V0.5 guest-files command roadmap](plans/2026-07-24-003-feat-now-mcp-v0-5-files-command-roadmap-plan.md).
V0.5 widens guest filesystem authority only through typed, logged NOW commands
under a persisted root-relative `guestRoot`; it does not turn this companion
into a direct file transport, grant modern-host filesystem access, or add
CodeKitten project semantics.

The first V0.5 command-layer slice is implemented behind the host boundary:
capability discovery, one bounded listing page, and bounded exact stat. It
persists the approved share-root default explicitly, validates every caller
path before composing it beneath policy, returns typed command receipts, and
logs command start/outcome. Invalid stored policy is rejected and reset
audibly. This is deliberately not an MCP surface yet; the existing companion
still advertises only the five V0 tools below.

## Implemented slices

The implemented V0 surface exposes only five host-owned projections.

| Tool contract | Existing NOW owner | Implemented projection |
| --- | --- | --- |
| `now_session_health` | `GuestListener.State` and `GuestListener.SessionHealth` | `AgentIntegrationHostAdapter.sessionHealth` returns a side-effect-free snapshot of not-listening, listening, connected, or failed host state. Connected snapshots carry only existing guest health fields plus an opaque adapter-owned session ID. |
| `now_list_processes` | `process.list` / `process.listing` and `GuestListener.listProcesses` | Reads a fresh, complete snapshot from the current paired guest. It returns at most 48 bounded entries, a point-in-time observation timestamp, and opaque references only for entries with a live PSN. PSNs and paths never leave the host adapter. A reference may be offered only to cooperative quit, which revalidates it before use. |
| `now_launch_software` | `software.list` / `software.listing`, then the existing declared `launch` command | Reads the current `apps` catalog and launches only one exact full-name match, using the listing path internally. Zero matches return `notFound`; multiple matches return at most eight bounded candidates and launch nothing. An opaque candidate reference is session-bound and revalidated against a fresh catalog before launch. No path or raw guest result text crosses the host adapter. |
| `now_request_quit` | `process.list` / `process.listing`, then `process.quit` / `process.result` | Accepts only a current opaque process reference issued within 30 seconds. The host re-lists, verifies the same PSN still has the same name, kind, type, and creator, then sends cooperative quit. The guest revalidates the live PSN again. Success means only that the quit request was sent, never that the process exited. |
| `now_transfer_approved_artifact` | Native Files approval, then `GuestListener.putFile` and `file.done` | The Files page stages one human-selected regular file in a private read-only copy and copies a one-use receipt. The MCP can redeem only that receipt for the approved current guest folder. Redemption rechecks session, expiry, inode, link count, mode, size, and SHA-256 before entering the existing one-at-a-time transfer lane with overwrite disabled. Success requires the matching `file.done ok:true`. |

The client-launched `NOWAgentCompanion` executable speaks newline-delimited JSON-RPC over stdio and advertises only these five tools. It opens one bounded local request to the running host for each call. Session health sends no guest message; the other tools ask the host to use the existing paired connection. Launch accepts exactly one bounded name or generated opaque reference; quit accepts exactly one generated process reference; transfer accepts exactly one host-minted receipt. No tool accepts a PSN, source path, guest path, shell text, or arbitrary filesystem operation. Every tool exposes typed unavailability and no host or listener lifecycle operation. If the host is absent, the result is `now-host-unavailable`; the companion never launches it. If the host is present without a paired guest, guest-dependent tools return `now-guest-unavailable` and never use cached state.

## Connection posture

NOW keeps its existing guest-dials-host paired connection throughout V0. The companion projects host-owned operations over that already-running session; it does not add a listener to the NOW guest, introduce a second guest protocol implementation, or wait for a replacement transport before the remaining tools proceed.

CodeKitten is the proving ground for the opposite connection posture. Its listener must first establish the design under adversarial stress, including framing, pairing and security, health and latency semantics, lifecycle, stale-state recovery, and classic cooperative-loop behavior. The [sibling CodeKitten roadmap](../../codekitten/docs/plans/2026-07-23-002-feat-codekitten-phase-0-1-roadmap-plan.md) describes that intended proof work; it is a prerequisite, not evidence that the listener or a shared service already exists.

Only after that proof should a separate worktree extract the parts that have demonstrably generalized into a shared network-protocol service. That future service must leave a compatible migration path for NOW, but it is neither current shared infrastructure nor a dependency of the NOW MCP. NOW will not change its functional dial-out path merely to validate CodeKitten hypotheses.

## Local trust boundary

V0 deliberately trusts processes running as the same macOS user. This protects against other local users and accidental clients; it does not protect against malicious code already running as that user.

- The host creates `dev.newoldworld.now-agent-<uid>/host.sock` beneath the user's private temporary directory. The directory is mode `0700`; the socket is mode `0600`.
- The host checks every accepted peer with `getpeereid` and serves it only when the effective UID matches.
- The companion checks that the directory and socket are owned by its effective UID, have no group/other permission bits, and are a directory and socket rather than links or other file types.
- Local schema v3 allows only `session_health`, `list_processes`, `launch_software`, `request_quit`, and `transfer_approved_artifact`, permits one request per connection, and caps each request and response at 16 KiB. The version changes when reference authority or action shape changes so an older companion cannot silently misread it. Launch selection is exactly one bounded name or opaque reference; quit selection is exactly one current opaque process reference; artifact selection is exactly one syntactically valid receipt. MCP stdio input is separately capped at 64 KiB per line.
- Approval staging lives in a per-host-launch mode-`0700` directory. A selected source must be one directly opened, single-link regular file no larger than 4 MiB. The sealed copy is mode `0400`, expires after ten minutes, is bound to the current guest session and approved Files destination, and is consumed on its first redemption attempt. Final open follows no links and rechecks owner, inode, device, link count, size, timestamps, mode, and digest.
- The MCP cannot mint an approval, list staging, choose a destination, or recover the original path. A user may deliberately select a file from anywhere the native picker can reach, but that grants only the staged copy; it does not expose or make the MCP a side door into a CodeKitten project tree. Same-user malicious code remains outside V0's stated protection.

The local socket is not the guest wire. It creates no TCP listener, guest connection, protocol message, guest module, dashboard item, daemon, launch agent, or second app.

## Operational prerequisites

Build the host app normally and build the companion with `swift build --package-path host --product NOWAgentCompanion`. An MCP client may launch that executable over stdio, but this repository intentionally contains no client configuration. NOW must already be running for any tool to reach its host projection, and a guest must already be paired for every tool except host/session health. A cold application catalog sweep on the PowerBook has previously taken about four seconds. The host therefore settles an unacknowledged launch as `now-launch-outcome-unknown` after 32 seconds, while keeping the action gate closed until a late result or disconnect; the local action response window is 35 seconds and read-only calls retain two seconds. Quit references expire after 30 seconds and the existing process-drive watchdog settles after 15 seconds. A quit receipt distinguishes snapshot, revalidation, and acknowledgement times and says only `requestSent`; process exit still requires a later listing.

Artifact transfer is deliberately two-step. In NOW's Files page, navigate to the intended guest folder, choose **Add File… > Approve One-Time Agent Transfer…**, select one file, and hand the copied receipt to `now_transfer_approved_artifact` within ten minutes. Approval does not start a transfer. Redemption is one attempt, never overwrites, cannot be retried with the same receipt, and may wait up to one hour locally for the existing size-scaled guest transfer watchdog. A delivery receipt carries the source and handed-to-NOW digests separately and says `guestAcknowledgedWrite: true`, but always says `destinationBytesVerified: false`: current `file.done` proves the guest reported a successful write and stamp, not a read-back hash. The companion does not start, stop, configure, or keep either side alive.

## Current verification

All five projections, the local socket, and the stdio wrapper are **tested** here. Focused tests cover missing host or guest; populated and empty process tables; opaque-reference stability; legacy entries without PSNs; exact launch, zero and multiple matches, paged catalogs, empty paths, redacted guest refusal, reference-cap rollover, an unacknowledged command and blocked retry, stale and reconnect-invalidated software references, and concurrent launch refusal; cooperative quit after a fresh full-identity re-list; vanished, expired, mismatched, and reconnect-invalidated process references; bounded guest refusal; concurrent quit refusal; explicit artifact approval, private mode-`0400` staging, expiry, replay, reconnect, source links/directories/oversize, symlink and hard-link swaps, changed bytes, concurrent redemption, collision refusal, matching `file.done`, separate digests, no destination hash claim, and omission of a modern date the deployed guest cannot represent; bounded fields and output; malformed and oversized requests; endpoint permissions; real peer-UID comparison; forced peer rejection; duplicate and concurrent reads; discriminated MCP schemas; and unchanged host module inventory/listener state with the socket absent or present. The launch ambiguity guard, quit pre-action revalidation, staging hard-link guard, and signed-date guard were introduced proof-first.

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
