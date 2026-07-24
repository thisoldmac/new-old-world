---
title: Optional NOW MCP Plugin - Plan
type: feat
date: 2026-07-24
---

# Optional NOW MCP Plugin - Plan

## Goal Capsule

- **Objective:** Add an optional MCP projection over a small set of operations the NOW host already performs, without changing NOW from a human-facing product.
- **Authority:** [`contract/asyncapi.yaml`](../../contract/asyncapi.yaml) owns guest-wire meaning. The host app remains the sole owner of the guest session and transfer lane. The MCP may narrow those capabilities but may not widen them.
- **Execution profile:** Start with a local stdio MCP server conceptually. Do not commit client configuration until the server and its safety tests exist.
- **Stop conditions:** Stop if implementation requires a new guest message, imports TimBotTu runtime code, lets the MCP speak the guest wire directly, or exposes an arbitrary path, command, or process-control escape hatch.
- **Tail ownership:** NOW must launch, connect, transfer files, and serve every human workflow exactly as it does when the plugin is absent.
- **Handoff status:** Documentation only. No MCP tool, runtime, protocol, or configuration exists from this plan.

---

## Product Contract

### Summary

V0 is a narrow automation companion for an already-running NOW host app. It reports session health, lists the connected classic Mac's processes, launches an application through NOW's existing exact-selection semantics, asks a currently identified process to quit, and transfers a separately approved artifact through NOW's existing file-transfer lane. The plugin is not a second shell, file browser, or remote-control product.

### Problem Frame

NOW already has useful, tested host APIs behind native UI, but an agent cannot safely use a bounded subset of them. Exposing `GuestListener` or `command.request` wholesale would erase the product's current safety boundaries: names could become commands, a stale PSN could target a later process, and "send any file the human picked" could become unattended access to a working tree.

### Requirements

**Product boundary**

- R1. NOW remains human-facing, and every existing workflow works with no MCP plugin installed or running.
- R2. The host app remains the sole owner of the guest connection, request correlation, and one-at-a-time transfer lane.
- R3. V0 uses only behaviors already described by the current contract; it adds no guest protocol messages or fields.
- R4. The initial MCP transport is stdio, with protocol output isolated from diagnostics, but this plan creates no MCP client configuration.

**Read-only tools**

- R5. Session health reports the host's current connection state and live health fields without starting, stopping, or reconfiguring the listener.
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
- guest protocol changes, resident-component changes, runtime installation, launch agents, and checked-in MCP configuration.

### Acceptance Examples

- AE1. With no guest connected, health returns `disconnected`; process, launch, quit, and transfer actions return a typed unavailable result without changing listener state.
- AE2. An ambiguous application name returns bounded candidates and launches nothing. Repeating with one current opaque candidate launches its exact full path.
- AE3. A process reference from before a reconnect, or one whose PSN now belongs to a different identifying tuple, is rejected before `process.quit`.
- AE4. A cooperative quit accepted by the guest returns "request sent"; refusal, timeout, and still-running outcomes remain distinct from "exited".
- AE5. An expired, replayed, altered, or out-of-scope artifact receipt transfers no bytes.
- AE6. A harmless staged copy swapped for a symlink, hard link, directory, or different inode after approval is rejected at final open.
- AE7. A transfer that sent all local bytes but never received `file.done ok:true` returns no success receipt.
- AE8. Starting or stopping the stdio server leaves the NOW host app and its native UI unchanged.

---

## Planning Contract

### Contract-to-tool mapping

This mapping is the first implementation deliverable. It must be checked against the contract, host API, and tests before any MCP handler is written.

| MCP tool | Existing owner | V0 projection |
| --- | --- | --- |
| `now_session_health` | `GuestListener.State` and `SessionHealth` | Read-only snapshot with a plugin-minted session generation; no listener controls. |
| `now_list_processes` | `process.list` / `process.listing`, `GuestListener.listProcesses` | Page the current table and mint opaque process references bound to session generation, PSN, and identifying fields. |
| `now_launch_software` | `software.list` / `software.listing`, then declared `launch` with `target` | Resolve a query without action; launch only one current reference by the listing's full HFS path. Empty paths are never launchable. |
| `now_request_quit` | `process.quit` / `process.result`, `GuestListener.driveProcess` | Revalidate the current-session reference against a fresh listing, then request cooperative quit. |
| `now_transfer_approved_artifact` | `GuestListener.putFile` and `file.done` | Redeem a scoped approval receipt, open the approved immutable source safely, join the existing transfer lane, and issue a delivery receipt after guest acknowledgement. |

### Key Technical Decisions

- KTD1. **Projection, not alternate runtime.** The stdio process talks to a narrow host-owned local control adapter; it does not create another `GuestListener`, bind the NOW port, or decode guest frames.
- KTD2. **Capability references are session-scoped.** Process and software references are opaque, expire on disconnect/reconnect, and contain enough signed or server-held state to prevent caller fabrication.
- KTD3. **Actions revalidate at act time.** A successful earlier list is evidence for selection, not authority to act later. Quit and launch re-resolve against the current session before sending.
- KTD4. **Approval and delivery are separate receipts.** A native NOW host action copies one human-selected regular file into dedicated staging and authorizes that immutable copy plus a destination scope. The MCP cannot invoke this action. A delivery receipt records the resulting NOW request and `file.done` outcome; neither substitutes for the other.
- KTD5. **Workspace isolation is structural.** The MCP cannot browse, receive, or resolve original workspace paths and cannot mint approvals. It can redeem only one-use staged-artifact receipts, so CodeKitten project discovery is neither required nor exposed.
- KTD6. **No stdout diagnostics.** Stdio frames are the only stdout bytes. Logs use stderr or the host's existing logging path and redact local source paths from ordinary tool results.

### Current verification rung

The MCP layer itself does not exist, so it is neither built, tested, nor metal-verified.

- The persistent connection and ordinary bidirectional file workflows are metal-verified, subject to the broken resume path and intermittent large-transfer slowdown recorded in [`open-issues.md`](../open-issues.md).
- Guest process listing and cooperative quit are metal-verified. Host stale-list clearing across reconnect is tested but still listed as not metal-verified in [`open-issues.md`](../open-issues.md).
- `launch -v` has metal evidence. The host's `software.list` exact-path UI flow remains tested/builds but not live end-to-end, so the MCP launch projection begins no higher than **tested** until its own connected run.
- `file.done` is the existing write acknowledgement. The proposed approval and delivery receipts are new host/plugin behavior and begin unverified.

### Grounding

- [`README.md`](../../README.md) is the current human-facing behavior and verification summary.
- [`files.md`](../files.md) owns the one-lane transfer and share-boundary semantics.
- [`processes-and-peek.md`](../processes-and-peek.md) owns PSN identity, live revalidation, and cooperative quit.
- [`software-module.md`](../software-module.md) owns exact-path launch and ambiguity behavior.
- [`open-issues.md`](../open-issues.md) remains the authority for broken and unverified behavior.

### Sequencing

1. Freeze the contract-to-tool map and failure vocabulary.
2. Resolve and threat-model the narrow local host adapter, then add it with session-generation invalidation. Stop if it cannot preserve the host app as sole guest-session owner without an unsafe local control surface.
3. Implement read-only health and process-list tools.
4. Add launch and quit with at-act-time revalidation.
5. Add the approval provider boundary and receipt-backed transfer.
6. Add the stdio server last, so protocol handlers are thin projections over tested domain operations.

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
- **Test scenarios:** Plugin absent; adapter client disconnect; guest reconnect invalidates all references; concurrent calls preserve the one-lane invariant; app UI and adapter observe the same session.
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

### U6. Stdio packaging and regression proof

- **Goal:** Package the optional server without changing normal NOW startup or committing client configuration.
- **Requirements:** R1-R4
- **Dependencies:** U3-U5
- **Files:** `mcp/` package/build files, packaging documentation, host and MCP regression tests
- **Approach:** The MCP executable starts only when an MCP client launches it. NOW does not discover, install, or depend on it.
- **Test scenarios:** absent executable; stdio EOF; malformed request; cancellation; host app unavailable; client crash mid-action; clean restart; no config present.
- **Verification:** Host suite passes with the plugin absent, MCP suite passes in isolation, then connected emulator and attended PowerBook runs are recorded by rung.

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
- NOW works normally with the plugin absent, stopped, crashed, or unconfigured.
- All builds/tests/metal evidence use the repository's named verification rungs, and abandoned implementation attempts are removed from the final diff.
