---
title: NOW V1 Host Product Roadmap
type: feat
date: 2026-07-24
---

# NOW V1 Host Product Roadmap

## Goal Capsule

- **Objective:** Evolve the current macOS host from a one-connection view into a polished target catalog and switcher, then improve the existing Files, Processes, Software, Capture, and Console experiences around one clearly active classic Mac.
- **Entry gate:** Finish the optional host-side MCP companion V0 before beginning V1 implementation. All five V0 projections are implemented and tested; the bounded combined action acceptance and V0 closeout remain.
- **Transport invariant:** The classic guest continues to dial the modern host on one host-wide listener port. V1 adds no guest listener, parallel protocol, per-target port, mobile transport, shared protocol service, or multi-session runtime.
- **Product boundary:** NOW remains a paired, human-facing host/guest product. The MCP companion projects capabilities owned by the running host and never owns guest transport, pairing, lifecycle, or UI.
- **Verification posture:** This roadmap commits product direction, sequencing, and acceptance criteria. It does not claim that V1 behavior is implemented or verified.

## Product Contract

### Committed V1 experience

#### Targets and pairing

- Persist named machines as targets with an icon or thumbnail, last-seen time, connection and pairing state, and one unmistakable active target.
- Keep disconnected targets in the catalog. A disconnected record is useful history, not a failed current session.
- Treat the existing host-wide listener port as a global transport setting and diagnostic. It is not a target property.
- Onboard through automatic discovery and pairing: a guest dials the host, its identity binds the connection to a pending or known target, and the user approves a new pairing. Current onboarding does not ask for a guest IP address.
- Preserve one live guest session. Switching the active catalog selection does not imply concurrent transport sessions.

#### Files

- Put the active target and current guest volume in the header.
- Add a customizable, drag-and-drop guest sidebar for common locations and favorites.
- Keep navigation, sorting, selection, and file actions in the central Finder-like browser.
- Offer an optional collapsible right-side local-host browser for direct drag-and-drop between host and guest.
- Replace prominent Add Files and Add Folder chrome with contextual toolbar actions, menus, and drag-and-drop.
- Build on the existing transfer and file-browsing contract. This is host product work, not a protocol rewrite.

#### Processes

- Add search, sorting, and a clearer selected-process detail inspector.
- Expose safe actions only where an exact existing guest capability supports them: bring forward, capture the selected application, request cooperative quit, and reveal its file in Files.
- Treat every selected process reference as a snapshot. Before action, revalidate it against the current guest session and return stale or unavailable rather than act on a different process.
- Make Reveal in Files transfer typed module context, including the current guest location, instead of reconstructing intent from display text.

#### Software

- Keep the guest inventory authoritative while using host compute for presentation and analysis.
- Group duplicate and version families without hiding individual copies or locations.
- Identify likely suites, components, installers, control panels, and extensions.
- Summarize storage-heavy, old, duplicate, and changed-since-last-inventory items. Each analysis must state its evidence and limitations.
- Offer reveal in Files, exact safe launch when available, running instances, and a possible screenshot after launch.
- Show inventory completeness, freshness, cache provenance, truncation, and refresh or scan affordances explicitly. Quiet uncertainty is not acceptable.

#### Capture and Console

Capture and Console are broadly in good shape. V1 limits their work to target context, consistent headers and empty states, clearer handoff from Processes or Software, and small accessibility or layout polish discovered during integration. They do not become new feature programs.

#### Menu-bar control center

- Show the active target picker and discovery or pairing status at the top.
- Provide target-scoped quick actions, including full desktop capture and an application submenu for bring to front, capture, and cooperative quit.
- Include Open New Old World and Settings/Diagnostics.
- Put a strong separator before Quit.
- Keep this inside the existing host product; do not introduce a second desktop app.

#### Quit policy

- With no active session and no transfer, quit immediately.
- With an active guest session, require confirmation.
- With an in-progress transfer, require confirmation regardless of other preferences.
- A preference may suppress the connected-session confirmation, but it can never suppress the transfer warning.

#### Settings ownership

Settings owns global policies and defaults, not a duplicate of each module's controls:

- **General**
- **Connections**
- **Files & Transfers**
- **Capture**
- **Privacy & History**
- **Agent Integration**
- **Diagnostics**

Current location, selection, filter, sort, and view mode remain in their module and may be remembered there.

### Explicit boundaries

V1 does not add:

- a guest listener, second NOW protocol implementation, parallel connection, per-guest port, mobile transport, or multi-session runtime;
- a shared network-protocol service or a dependency on CodeKitten or TBT;
- a guest dashboard/module or a new guest wire command for host UI convenience;
- enterprise fleet management, remote administration, generic brokering, or a second desktop app;
- new MCP ownership of pairing, guest transport, target persistence, or the human-facing product.

CodeKitten remains the proving ground for a guest-listener design, pairing and security profile, health and latency semantics, cooperative-loop behavior, lifecycle and recovery, and adversarial multi-peer behavior. Only after that proof may a **separate worktree** consider extracting demonstrated common protocol pieces and a later NOW migration. The extracted service must be compatible with NOW, but NOW must not be mutated to validate CodeKitten hypotheses. See the [CodeKitten proof roadmap](../../../codekitten/docs/plans/2026-07-23-002-feat-codekitten-phase-0-1-roadmap-plan.md); the link is a prerequisite plan, not evidence that the listener or shared service exists.

## Key Technical Decisions

- **KTD1 — Catalog and session are different.** A target is durable host product state; a connection is disposable live state associated with at most one active target.
- **KTD2 — Pairing is an approval boundary.** Guest-provided identity proposes a binding. The host records an approved identity relationship and presents conflicts rather than silently retargeting a known machine.
- **KTD3 — Cross-module handoff is typed.** Reveal, capture, and running-instance actions carry target/session identity plus guest location or process identity, never a display label masquerading as authority.
- **KTD4 — Action references are snapshots.** Process and software actions revalidate against the live guest before execution. Stale and unavailable are normal typed outcomes.
- **KTD5 — Inventory analysis preserves guest truth.** Host-derived groupings and heuristics are labeled views over complete or explicitly incomplete guest observations; they never rewrite the underlying copies or locations.
- **KTD6 — Global settings do not absorb module state.** Policies and defaults live in Settings; transient browsing and inspection state stays with the owning module.
- **KTD7 — Transport extraction follows proof.** Capability attestation, opaque identity, bounded receipts, health/latency telemetry, lifecycle/recovery, and compatibility fixtures are extraction candidates only when demonstrated independently. They are not V1 infrastructure assumptions.

## Sequencing

### U0. Finish and close V0

- Complete cooperative quit and approved artifact transfer using the existing NOW commands and current private host adapter.
- Revalidate every action at execution time and keep verification-rung claims honest.
- Close V0 docs and outstanding issues before V1 runtime work begins.

### U1. Target catalog and pairing model

- Define the persistent target record separately from live session state.
- Bind current guest identity to pending or known targets and add explicit approval/conflict outcomes.
- Keep the host-wide listener configuration global.
- Add migration for the current implicit single target without changing transport.

Likely ownership: host target/session domain types, persistence, `GuestListener` connection events, focused host tests, and contract read-only verification.

### U2. Host shell, switcher, menu bar, and Settings

- Replace the one-connection shell with catalog selection and a clear active-target header.
- Integrate discovery/pairing state, disconnected targets, global diagnostics, menu-bar quick actions, and the quit policy.
- Add the seven global Settings sections without moving module-local state into them.

### U3. Files product pass

- Implement the guest favorites sidebar, central browser ownership, optional local browser, contextual actions, and typed incoming Reveal context.
- Preserve the existing transfer lane, path rules, and completion semantics.

### U4. Processes product pass

- Add search, sort, detail, and the four bounded actions.
- Revalidate selected snapshots immediately before bring-forward, capture, cooperative quit, or reveal.
- Keep refused, stale, unavailable, request-sent, and verified outcomes distinct.

### U5. Software product pass

- Add host-side grouping and evidence-labeled analyses over the guest inventory.
- Preserve every copy and location, expose running-instance relationships, and integrate reveal, exact launch, and possible post-launch capture.
- Make completeness and freshness visible in normal and degraded states.

### U6. Integration and qualification

- Apply only light target-context and handoff polish to Capture and Console.
- Exercise target persistence, pairing conflicts, disconnect/reconnect, transfer-aware quit, stale action references, inventory truncation, and module handoffs.
- Update [`README.md`](../../README.md) and [`open-issues.md`](../open-issues.md) with tested versus metal-verified status.

## Acceptance Criteria

- **AE1:** A first guest connection creates a pending target and requires user approval; current onboarding never asks for a guest IP.
- **AE2:** Approved targets persist with name, visual identity, last seen, and state after disconnect and host relaunch.
- **AE3:** Exactly one active target is visually clear, while disconnected targets remain selectable without implying a live session.
- **AE4:** Listener port changes appear only in global Connections or Diagnostics, never on a target record.
- **AE5:** Adding the catalog does not create a second guest session, guest listener, port, protocol, or guest module.
- **AE6:** Files shows active target and volume, supports guest favorites and contextual drag-and-drop, and uses the existing transfer contract.
- **AE7:** Enabling or collapsing the local-host browser changes only host presentation and does not expose arbitrary access to the MCP companion.
- **AE8:** Every process action revalidates the current session and selected identity; a stale snapshot acts on nothing.
- **AE9:** Reveal in Files opens the intended guest location through typed module context.
- **AE10:** Software grouping preserves each copy and location and visibly labels incomplete, truncated, cached, stale, or heuristic results.
- **AE11:** Menu-bar actions are scoped to the active target and unavailable actions explain why without changing session ownership.
- **AE12:** Quit is immediate only without a session or transfer; an active session confirms unless suppressed, and a transfer always confirms.
- **AE13:** Settings contains only global policies/defaults while module view, filter, sort, selection, and location remain module-owned.
- **AE14:** The MCP companion absent or present leaves target catalog, pairing, guest UI, ordinary NOW operation, and module inventory unchanged.
- **AE15:** V1 builds and tests without any CodeKitten, TBT, shared-service, or future transport dependency.

## Decisions Intentionally Open

- The exact information architecture and visual treatment of the catalog, switcher, pending pairing, and active-target header.
- Which guest identity evidence is durable enough for pairing and how conflicts or guest reinstalls are explained.
- Thumbnail sources, update cadence, retention, and privacy defaults.
- Default guest favorites and whether they are per target, per volume, or both.
- Which local inventory analyses are sufficiently reliable to ship and how long inventory history is retained.
- Default visibility and remembered width of the optional local-host browser.
- The default connected-session quit-confirmation preference.
- Which module view/filter/sort/location choices persist, for how long, and at what scope.

These decisions are design inputs for their owning implementation unit, not permission to widen transport or protocol scope.

## Verification Contract

- V1 begins **unverified**. A build proves only **Builds**; passing host and native guest suites earns **Tested** for the exercised behavior; a witnessed PowerBook run earns **Metal-verified** only for that scenario.
- Contract changes are not expected. If a unit discovers that it needs one, stop and reassess the roadmap rather than quietly widening the guest wire.
- Each unit adds focused tests for its state transitions, stale identity behavior, unavailable states, and noninterference with the existing paired workflow.
- The final acceptance pass covers automatic pairing, target persistence, disconnect/reconnect, module handoffs, safe actions, transfer-aware quit, and the unchanged single-session transport.

## Grounding

- Current behavior and verification: [`README.md`](../../README.md)
- V0 companion boundary: [`2026-07-24-001-feat-now-mcp-plugin-plan.md`](2026-07-24-001-feat-now-mcp-plugin-plan.md) and [`agent-integration.md`](../agent-integration.md)
- Wire authority: [`contract/asyncapi.yaml`](../../contract/asyncapi.yaml)
- Files semantics: [`files.md`](../files.md)
- Process identity and actions: [`processes-and-peek.md`](../processes-and-peek.md)
- Software inventory and exact launch: [`software-module.md`](../software-module.md)
- Broken and unverified ledger: [`open-issues.md`](../open-issues.md)

## Definition of Done

- V0 is complete before V1 runtime implementation starts.
- U1-U6 meet their acceptance criteria without changing the guest-dials-host, one-host-port, single-session transport.
- The target catalog, pairing, Files, Processes, Software, menu bar, quit policy, and Settings ownership behave coherently with the companion absent or present.
- Capture and Console receive integration polish only.
- Documentation records what is tested, what is metal-verified, and which product decisions remain open.
- Any shared protocol extraction remains a separate, post-CodeKitten-proof worktree and is not represented as delivered infrastructure.
