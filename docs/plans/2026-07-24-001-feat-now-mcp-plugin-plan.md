---
title: NOW Host Agent-Integration Companion - Plan
type: feat
date: 2026-07-24
---

# NOW Host Agent-Integration Companion - Plan

## Goal Capsule

- **Objective:** Add an optional host-side NOW agent-integration companion: a separate MCP-facing executable that projects a small set of operations already owned by a running NOW host without becoming a paired NOW feature module.
- **Authority:** [`contract/asyncapi.yaml`](../../contract/asyncapi.yaml) owns guest-wire meaning. The NOW host remains the sole owner of the guest session, transport, transfer lane, and human-facing operation. The companion may narrow those capabilities but may not widen or own them.
- **Execution profile:** Start conceptually with a lightweight, client-launched stdio executable. Do not commit client configuration or add a daemon, launch agent, or second desktop app.
- **Stop conditions:** Stop if implementation requires a new guest message, a guest-side module, dashboard, or protocol mode, imports TimBotTu runtime code, lets the companion speak the guest wire directly, controls NOW's lifecycle or configuration, exposes an arbitrary path, command, or process-control escape hatch, or makes a future shared transport a dependency of current V0 work.
- **Tail ownership:** With the companion absent, present, starting, or stopping, NOW must launch, connect, transfer files, and serve every paired human workflow with the same host and guest UI/module inventory.
- **Handoff status:** All five V0 projections, the private same-user host adapter, and the client-launched stdio companion are implemented, tested, and covered by a bounded connected PowerBook acceptance receipt. Launch resolves a fresh exact catalog selection; quit requires and revalidates a current opaque process reference; artifact transfer redeems only a native-host-minted, session-bound, one-use receipt for a sealed staged copy and requires matching `file.done` acknowledgement. No MCP input carries a PSN, source path, guest path, shell command, or general filesystem authority. NOW still uses its existing guest-dials-host paired connection; no guest protocol change, guest listener, or client configuration was added. [`agent-integration.md`](../agent-integration.md) records the exact metal evidence and its limits.

---

## Product Contract

### Summary

V0 is a narrow, optional host-side agent-integration companion for an already-running NOW host app. It is a separate MCP-facing executable/adapter that reports session health, lists the connected classic Mac's processes, launches an application through NOW's existing exact-selection semantics, asks a currently identified process to quit, and transfers a separately approved artifact through NOW's existing file-transfer lane. It is not a standard NOW plugin or paired feature module: it adds no guest-side module, dashboard, protocol mode, or paired dashboard inventory. It is not a second shell, file browser, remote-control product, or owner of NOW.

### Problem Frame

NOW already has useful, tested host APIs behind native UI, but an agent cannot safely use a bounded subset of them. A separate companion can project only that bounded host-owned surface without changing the paired product. Exposing `GuestListener` or `command.request` wholesale would erase the product's current safety boundaries: names could become commands, a stale PSN could target a later process, and "send any file the human picked" could become unattended access to a working tree.

### Requirements

**Product boundary**

- R1. NOW remains a paired, human-facing host/guest product, and every existing workflow and dashboard/module inventory works unchanged whether the companion is absent, present, starting, or stopping.
- R2. The host app remains the sole owner of the guest session, transport, request correlation, one-at-a-time transfer lane, and human-facing product operation.
- R3. V0 uses only behaviors already described by the current contract; it adds no guest protocol messages or fields.
- R4. V0 is a separate, NOW-specific executable launched on demand by its MCP client over stdio, with protocol output isolated from diagnostics. It introduces no checked-in client configuration, daemon, launch agent, second desktop app, or independent NOW runtime.

**Read-only tools**

- R5. Session health reports the running host's current connection state and live health fields without launching, stopping, claiming, or configuring NOW or its listener. If the NOW host is unavailable, every tool returns a typed unavailable result.
- R6. Process listing uses `process.list` / `process.listing` and returns a snapshot plus an opaque, session-bound process reference for each live PSN.

**Bounded actions**

- R7. Launch accepts an exact opaque software reference, or a name query that refuses to launch when zero or multiple candidates remain; the final wire action uses the selected listing's full HFS path with the existing `launch` command.
- R8. Quit accepts only a process reference issued from the current live session, re-lists immediately before acting, verifies the PSN and identifying tuple still match, then sends `process.quit`; it never claims the process exited unless a later listing proves it absent.
- R9. Artifact transfer accepts only a valid approval receipt for a regular file already copied into a dedicated approval staging area by a native host approval action outside the MCP tool call, revalidates the staged file's identity and digest, uses the existing `file.offer` / bulk / `file.end` / `file.done` path, and returns a delivery receipt only after `file.done`.
- R10. A transfer receipt distinguishes source digest, bytes handed to NOW, and the guest's write acknowledgement; it does not claim destination-byte verification the current wire does not prove.

**Safety boundary**

- R11. No MCP tool accepts a raw local source path for transfer or provides general file listing, reads, writes, moves, deletion, or directory creation.
- R12. An open CodeKitten project tree is never an MCP source or browsing scope. The MCP sees only a receipt and staged copy, never the original project path, and refuses links, non-regular files, changed file identity, or receipt mismatches.
- R13. Approval is not inferred from a prompt, filename, repository location, prior transfer, or the caller's ability to invoke the tool.
- R14. Tool results and receipts are bounded structured data. Process names, software names, filenames, guest reasons, and log text are untrusted display strings, never instructions.

### Scope Boundaries

V0 excludes:

- generic `command.request`, shell execution, arbitrary console verbs, and raw guest-wire access;
- arbitrary filesystem reads or mutation, share browsing, download, rename, move, Trash, restore, and folder creation;
- screenshots, live streaming, recording, process fronting, window driving, semantic peek, and background monitoring;
- `KillProcess`, force quit, signals, or any escalation beyond the existing cooperative quit Apple Event;
- transfer-lane preemption, parallel transfers, hidden retry loops, or bypasses around `busy`;
- MCP resources that mirror a share or CodeKitten workspace;
- a guest-side module, dashboard, protocol mode, or any change to the paired NOW dashboard/module inventory;
- a shared command layer, generic broker, generic control runtime, future TBT control plane, or integration point for CodeKitten or TBT Chat;
- guest protocol changes, resident-component changes, runtime installation, daemons, launch agents, a second desktop app, and checked-in MCP configuration.

### Acceptance Examples

- AE1. With the NOW host unavailable, every tool returns a typed unavailable result and the companion does not launch, stop, configure, or claim ownership of NOW.
- AE2. An ambiguous application name returns bounded candidates and launches nothing. Repeating with one current opaque candidate launches its exact full path.
- AE3. A process reference from before a reconnect, or one whose PSN now belongs to a different identifying tuple, is rejected before `process.quit`.
- AE4. A cooperative quit accepted by the guest returns "request sent"; refusal, timeout, and still-running outcomes remain distinct from "exited".
- AE5. An expired, replayed, altered, or out-of-scope artifact receipt transfers no bytes.
- AE6. A harmless staged copy swapped for a symlink, hard link, directory, or different inode after approval is rejected at final open.
- AE7. A transfer that sent all local bytes but never received `file.done ok:true` returns no success receipt.
- AE8. Starting, stopping, or crashing the companion leaves the NOW host app, its native UI, the guest UI, and both halves' dashboard/module inventory unchanged.
- AE9. With the companion absent or uninstalled, the paired NOW host and guest start, connect, browse, launch software, request quits, and transfer through their existing human workflows unchanged.
- AE10. With the companion present, a disconnected guest still yields the host-owned `disconnected` health state, while guest-dependent actions return typed unavailable results without changing listener state.

---

## Planning Contract

### Contract-to-tool mapping

This mapping is the first implementation deliverable. It must be checked against the contract, host API, and tests before any MCP handler is written.

| MCP tool | Existing owner | V0 projection |
| --- | --- | --- |
| `now_session_health` | `GuestListener.State` and `SessionHealth` | Read-only snapshot with a companion-minted session generation; no listener controls. |
| `now_list_processes` | `process.list` / `process.listing`, `GuestListener.listProcesses` | Page the current table and mint opaque process references bound to session generation, PSN, and identifying fields. |
| `now_launch_software` | `software.list` / `software.listing`, then declared `launch` with `target` | Resolve a query without action; launch only one current reference by the listing's full HFS path. Empty paths are never launchable. |
| `now_request_quit` | `process.quit` / `process.result`, `GuestListener.driveProcess` | Revalidate the current-session reference against a fresh listing, then request cooperative quit. |
| `now_transfer_approved_artifact` | `GuestListener.putFile` and `file.done` | Redeem a scoped approval receipt, open the approved immutable source safely, join the existing transfer lane, and issue a delivery receipt after guest acknowledgement. |

### Key Technical Decisions

- KTD1. **Separate projection, not alternate runtime or paired module.** The client-launched stdio executable talks to a narrow host-owned local control adapter; it does not create another `GuestListener`, bind the NOW port, decode guest frames, or add a guest-side or dashboard module.
- KTD2. **Capability references are session-scoped.** Process and software references are opaque, expire on disconnect/reconnect, and contain enough signed or server-held state to prevent caller fabrication.
- KTD3. **Actions revalidate at act time.** A successful earlier list is evidence for selection, not authority to act later. Quit and launch re-resolve against the current session before sending.
- KTD4. **Approval and delivery are separate receipts.** A native NOW host action copies one human-selected regular file into dedicated staging and authorizes that immutable copy plus a destination scope. The companion cannot invoke this action. A delivery receipt records the resulting NOW request and `file.done` outcome; neither substitutes for the other.
- KTD5. **Workspace isolation is structural.** The companion cannot browse, receive, or resolve original workspace paths and cannot mint approvals. It can redeem only one-use staged-artifact receipts, so CodeKitten project discovery is neither required nor exposed.
- KTD6. **No stdout diagnostics.** Stdio frames are the only stdout bytes. Logs use stderr or the host's existing logging path and redact local source paths from ordinary tool results.
- KTD7. **Lifecycle stays outside NOW V0.** The lightweight companion is launched on demand by the MCP client and exits with that client relationship. A future host-side Integrations UI may own enablement, logs, and removal, but V0 does not build that UI or introduce a daemon, launch agent, second desktop app, or NOW lifecycle controls.
- KTD8. **Transport migration follows proof, not speculation.** NOW keeps its functional dial-out transport while V0 tools project over the existing paired host session. CodeKitten owns the guest-listener experiment and must first prove its framing, pairing/security profile, health and latency semantics, lifecycle, recovery, and stress behavior. Only then may a separate worktree extract demonstrably general pieces into a shared network-protocol service compatible with a later NOW migration. That service is not current infrastructure, a NOW MCP dependency, or a reason to add a parallel NOW guest listener.

### Current verification rung

All five host-owned projections, the private host-local socket, and the
stdio MCP companion are **tested** and have the bounded connected
PowerBook acceptance receipt in
[`agent-integration.md`](../agent-integration.md). The receipt covers
typed host absence, automatic redial with new session/reference scope,
paced and modest concurrent reads, exact ambiguity-safe launch,
separately observed exit after cooperative quit, and one native-approved
artifact with matching `file.done`. None is a replacement transport.
The pass does not qualify sustained load, arbitrary applications or
artifacts, guest UI automation, or destination-byte identity.

- The persistent connection and ordinary bidirectional file workflows are metal-verified, subject to the broken resume path and intermittent large-transfer slowdown recorded in [`open-issues.md`](../open-issues.md).
- Guest process listing and cooperative quit are metal-verified. Host stale-list clearing across reconnect is tested but still listed as not metal-verified in [`open-issues.md`](../open-issues.md).
- `launch -v` has metal evidence. The host's `software.list` exact-path UI flow remains tested/builds but not live end-to-end, so the MCP launch projection begins no higher than **tested** until its own connected run.
- `file.done` is the existing write acknowledgement. Approval staging and delivery receipts are tested host/companion behavior; the integrated PowerBook path remains unverified.

### Grounding

- [`README.md`](../../README.md) is the current human-facing behavior and verification summary.
- [`agent-integration.md`](../agent-integration.md) records the host-only projection and the local adapter threat-model gate.
- [`files.md`](../files.md) owns the one-lane transfer and share-boundary semantics.
- [`processes-and-peek.md`](../processes-and-peek.md) owns PSN identity, live revalidation, and cooperative quit.
- [`software-module.md`](../software-module.md) owns exact-path launch and ambiguity behavior.
- [`open-issues.md`](../open-issues.md) remains the authority for broken and unverified behavior.
- The CodeKitten roadmap (a sibling project, not public) defines the intended listener proof campaign. Its presence is planning evidence only, not proof that the listener or a shared service exists.

### Sequencing

1. Freeze the contract-to-tool map and failure vocabulary.
2. Resolve and threat-model the narrow local host adapter, then expose session health through the client-launched stdio companion. This slice is complete.
3. Add process listing over the same host-owned session. This slice is complete.
4. Add safe launch and cooperative quit with at-act-time revalidation. This slice is complete.
5. Add the approval provider boundary and receipt-backed transfer. This slice is complete.
6. Keep the current dial-out connection unchanged throughout V0. After CodeKitten's listener is proven and stress-tested, evaluate a shared-service extraction in a separate worktree; do not mix that migration track into the MCP tool sequence.
7. Run the bounded combined connected acceptance pass and record only the action lanes safely observed. This is complete; the receipt and limits are in [`agent-integration.md`](../agent-integration.md).

---

## Implementation Units

### U1. Contract and safety map

- **Goal:** Turn the table above into executable tool schemas, typed outcomes, and traceability to existing contract messages.
- **Requirements:** R1-R14
- **Dependencies:** None
- **Files:** `contract/asyncapi.yaml` (read only), `host/Sources/Host/ContractMessages.swift` (read only), `docs/plans/2026-07-24-001-feat-now-mcp-plugin-plan.md`
- **Approach:** Confirm that every proposed input is narrower than its wire owner. Record any missing host-only adapter behavior separately; a missing guest field stops the tool rather than expanding the wire in V0.
- **Test scenarios:** Table review catches any tool that would require a new guest message, accepts a raw path/PSN, or maps success to a weaker event than its current receipt.
- **Verification:** The implementation change begins with a reviewed mapping diff before adding handlers.

### U2. Host-owned control facade

- **Goal:** Give an optional local client a typed, narrow interface while the native app retains the live `GuestListener`.
- **Requirements:** R1-R3, R5-R10
- **Dependencies:** U1
- **Files:** `host/Sources/Host/GuestListener.swift`, new focused files under `host/Sources/Host/Automation/`, tests under `host/Tests/HostTests/`
- **Approach:** Extract domain operations, not the listener. Define session generation, opaque references, bounded result types, and a user-local adapter whose lifecycle cannot start or stop NOW. Choose its concrete IPC and caller-authentication mechanism in the contract-map review before executable work.
- **Test scenarios:** Companion absent; adapter client disconnect; guest reconnect invalidates all references; concurrent calls preserve the one-lane invariant; app UI and adapter observe the same host-owned session.
- **Verification:** Host tests prove no adapter call changes listener configuration and existing host suites remain green.

### U3. Read-only MCP tools

- **Goal:** Implement session health and process listing over the facade.
- **Requirements:** R4-R6, R14
- **Dependencies:** U2
- **Files:** new stdio server sources and tests under `mcp/`
- **Approach:** Keep handlers stateless apart from opaque-reference storage and bounded pagination. Treat all guest strings as data.
- **Test scenarios:** disconnected/listening/connected/failed health; multi-page process listing; malformed guest data; output bounds; protocol logs never reach stdout.
- **Verification:** Protocol tests parse every stdout frame and snapshot typed failure results.

### U4. Revalidated launch and quit

- **Goal:** Add the two bounded actions without raw names, paths, or PSNs becoming authority.
- **Requirements:** R7-R8, R13-R14
- **Dependencies:** U3
- **Files:** launch/quit facade and MCP handler files under `host/Sources/Host/Automation/` and `mcp/`; corresponding host and MCP tests
- **Approach:** Launch queries may return candidates but never act on ambiguity. Exact references are refreshed before `launch`. Quit requires a current process reference, a fresh matching listing, and the guest's existing final PSN validation.
- **Test scenarios:** zero/one/many launch matches; empty listing path; stale software reference; reconnect; PSN reuse; target exits during revalidation; NOW self-quit; guest refusal; quit sent but process remains.
- **Verification:** Mutation checks remove each revalidation guard and watch its named test fail.

### U5. Approved artifact transfer

- **Goal:** Transfer one pre-approved immutable artifact and return an honest receipt.
- **Requirements:** R9-R14
- **Dependencies:** U2, U3
- **Files:** native approval action and approval/receipt facade files under `host/Sources/Host/Automation/`, the MCP handler under `mcp/`, and corresponding transfer security tests
- **Approach:** The host action stages one selected regular file and mints a one-use, expiring receipt without exposing its original path. Redemption opens the staged copy without following links, compares file identity, link count, size, and digest, then calls the existing put path and awaits `file.done`.
- **Test scenarios:** explicit host approval; MCP cannot mint approval; valid receipt; expiry; replay; changed bytes; symlink swap; hard-link alias; directory or special file; leaked original CodeKitten path; destination traversal; busy lane; disconnect; timeout after all bytes sent; `file.done ok:false`; no destination hash proof.
- **Verification:** Integration tests use the existing fake guest and assert that rejected cases emit no `file.offer`.

### U6. Companion packaging, lifecycle, and regression proof

- **Goal:** Package the lightweight optional companion without changing normal NOW startup, paired host/guest UI, or client configuration.
- **Requirements:** R1-R5
- **Dependencies:** U3-U5
- **Files:** `mcp/` package/build files, packaging documentation, host and MCP regression tests
- **Approach:** The companion starts only when an MCP client launches it and does not manage NOW. In V0, NOW does not discover, install, launch, stop, configure, or depend on the companion. V0 adds no daemon, launch agent, or second desktop app. A future host-side Integrations UI may own enablement, logs, and removal, but is explicitly deferred.
- **Test scenarios:** absent executable leaves normal paired operation unchanged; present companion leaves host and guest UI/module inventory unchanged; stdio EOF; malformed request; cancellation; host app unavailable returns typed unavailable without starting NOW; client crash mid-action; clean restart; no config present.
- **Verification:** Host and guest regression evidence is unchanged with the companion absent and present, the MCP suite passes in isolation, then connected emulator and attended PowerBook runs are recorded by rung.

---

## Verification Contract

| Gate | Evidence required |
| --- | --- |
| Documentation | All relative links resolve; Markdown/frontmatter parse; diff contains no runtime, contract, or config change. |
| Host behavior | `swift test --package-path host --scratch-path <outside the repo>` passes, with new guards mutation-checked. |
| MCP protocol | Tool schemas, stdio framing, bounded output, cancellation, and stdout isolation pass in the future MCP suite. |
| Security | Every adversarial case in U4-U5 proves no wire action occurred on rejection. |
| Emulator | A connected guest exercises health, list, exact launch, stale quit, successful quit request, busy transfer, and receipt failure. |
| Metal | The same attended flow runs on the PowerBook 1400c; results are reported as metal-verified only after someone watches them. |

---

## Definition of Done

- The five V0 tools are the complete exposed set and map to existing NOW behavior.
- NOW's guest protocol remains unchanged for V0.
- No input permits shell execution, raw process control, arbitrary path access, share mirroring, or workspace mutation.
- CodeKitten project trees remain undiscoverable and unreachable; only immutable staged copies with valid one-use receipts can enter the transfer path.
- Launch and quit act only on current, revalidated identities.
- A transfer succeeds only after approval validation and `file.done ok:true`, with receipt claims limited to what was observed.
- NOW's paired host/guest UI, dashboard/module inventory, and normal operation remain unchanged with the companion absent, present, stopped, crashed, or unconfigured.
- The companion remains a client-launched NOW-specific adapter: it does not own NOW lifecycle or configuration and is not a generic broker, shared command layer, TBT control plane, or CodeKitten/TBT Chat integration.
- NOW's current guest-dials-host transport remains authoritative for V0. No NOW guest listener or parallel protocol implementation is added to validate CodeKitten, and no future shared service is assumed before proof and separate-worktree extraction.
- All builds/tests/metal evidence use the repository's named verification rungs, and abandoned implementation attempts are removed from the final diff.
