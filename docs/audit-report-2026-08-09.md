# Audit Report — NOW MCP — 2026-08-09

## Scope

Correctness, structure/maintainability, and agent-surface security were audited
for NOW's MCP companion and host projections at base commit `ab3625e8`. The
review also mapped TimBotTu classic/0.6.4, TimBotTu 0.7/next, and CodeKitten at
the snapshots recorded in [now-mcp-audit-barrage.md](now-mcp-audit-barrage.md).
Evidence includes source and registry derivation, 228 focused baseline tests,
post-change focused tests, real spawned-client conformance, and a private PPC
VM barrage using fresh GPT-5.6 Luna workers. The comparative repositories were
read-only and sampled at their public MCP/command boundaries rather than
audited internally. The final `scripts/test-all` status is added at closeout.

## Summary

NOW has a broad, strongly typed, locally private agent surface with good
machine/session identity and unusually deep behavioral tests. Its dominant
agent problem is not capability absence but first-contact routing: most bare
classic-Mac tasks never selected NOW, while one routing sentence made every
repeat select it first. The pre-barrage pass resolved the ambiguous discovery
name, server-owned guide, Mirror vocabulary leak, and conformance
classification. The barrage also reproduced a small high-impact upload
capacity bug and exposed an authority distinction that documentation must make
more explicit. A deeper tool hierarchy should wait for a separate design pass.

## Findings

### [F-001] NOW was not an obvious first-contact plane (severity: high, effort: S) — resolved

- **Dimension:** structure-maintainability
- **Evidence:** `now-host/Sources/NOWAgentCompanion/NOWMCPServer.swift` exposed
  only tools in the baseline; H0 had to infer `now_session_health`, and five of
  seven bare barrage tasks never called NOW.
- **Why it matters:** a capable server is irrelevant when the agent confidently
  operates on the modern host or an empty workspace instead.
- **Proposed change:** one discovery entry point plus a server-owned workflow
  guide; evaluate a thin client routing skill separately.
- **Blast radius:** companion discovery protocol and tool name; verified by
  companion tests, conformance, and controlled H0/H1.

The server now publishes initialize instructions, `now://agent/first-contact`,
`start-with-now`, and `now_list_machines`. Controlled first contact improved,
but the bare-task result leaves the client-routing half open under F-005.

### [F-002] Human Mirror terminology leaked into the agent model (severity: medium, effort: S) — resolved

- **Dimension:** structure-maintainability
- **Evidence:** nine baseline tools in
  `now-host/Sources/NOWAgentIntegration/Projection/` used `now_mirror_*` even
  though the human Mirror and agent projections are siblings over one state
  engine.
- **Why it matters:** an unfamiliar agent had to learn a product name before it
  could reason about semantic desktop/application state.
- **Proposed change:** use `now_semantic_ui_*`, explicitly experimental, with no
  compatibility aliases while the surface has no compatibility obligation.
- **Blast radius:** nine MCP names and derived documentation; host engine,
  executor, and human UI unchanged.

### [F-003] Positive-size upload staging always refuses on this Mac (severity: high, effort: S)

- **Dimension:** correctness
- **Evidence:**
  `now-host/Sources/Host/Automation/GuestUploadStagingStore.swift:111-125`
  trusts `volumeAvailableCapacityForImportantUsage`; live Foundation returned
  `0` for that key and about 714 GB for ordinary available capacity. X1 and N1
  refused 52- and 2,466-byte reservations, while a zero-byte upload succeeded.
  `docs/mcp-coverage.md` records the same refusal for four bytes on 2026-08-07.
- **Why it matters:** the advertised create-only upload lane cannot transfer
  any non-empty file on the current host.
- **Proposed change:** centralize capacity reading and fall back to ordinary
  volume capacity when the important-usage value is zero/unavailable, without
  weakening the five-percent reserve.
- **Blast radius:** guest-upload and guest-download staging capacity readers;
  verify with injected-capacity unit tests, a live positive-size upload, and
  `scripts/test-all`.

### [F-004] Transfer approval and caller-supplied upload are easy to conflate (severity: medium, effort: S)

- **Dimension:** security
- **Evidence:**
  `TransferApprovedArtifactProjection.swift` requires a one-use human receipt
  for a host-selected private file; `GuestFilesUploadBeginProjection.swift`
  accepts caller-supplied bytes with no receipt. N1 read a modern Desktop file
  using the Codex shell and committed its bytes through the latter lane.
- **Why it matters:** “host-to-guest transfer requires approval” is too broad a
  description. Product review cannot evaluate the intended authority boundary
  until the two source-ownership cases are stated together.
- **Proposed change:** document the distinction explicitly, then have the owner
  decide whether full agent access is sufficient authority for bytes the agent
  can already read.
- **Blast radius:** documentation only unless the authority decision changes;
  any policy change would touch tool contracts, consent, and tests and needs a
  separate approval.

### [F-005] Server discovery does not route arbitrary tasks to NOW (severity: high, effort: M)

- **Dimension:** structure-maintainability
- **Evidence:** R2/A1/M1/X1/N1 made zero NOW calls from bare prompts. The same
  five prompts, prefixed only with “Use the NOW integration on the connected
  classic Macintosh,” all called `now_list_machines` first.
- **Why it matters:** prompts/resources are opt-in and initialize instructions
  are not a reliable client-side intent router.
- **Proposed change:** package a thin NOW skill that recognizes connected
  classic-Mac tasks, selects NOW, and then defers to the server-owned guide.
- **Blast radius:** client packaging and onboarding, not server behavior;
  verify by rerunning the same bare set with no task-specific tool hints.

### [F-006] Rich, flat discovery has material context cost (severity: medium, effort: M)

- **Dimension:** structure-maintainability
- **Evidence:** controlled one-call H0 recorded 76,618 input tokens. Routed R2
  and A1 recorded 270,593 and 250,909; X1 recorded 856,750 across eleven calls,
  including a large semantic snapshot.
- **Why it matters:** context amplification makes longer cross-domain work
  slower and costlier and can bury the shortest workflow.
- **Proposed change:** first measure schema bytes, fixed client context, and
  per-result growth separately; only then consider domain grouping, compact
  projections, or response shaping.
- **Blast radius:** potentially the whole public catalog, so this is not a
  cleanup-pass edit.

### [F-007] Non-interactive workers cannot complete annotated mutation chains (severity: medium, effort: S)

- **Dimension:** correctness
- **Evidence:** M1's three `now_guest_files_mutate` attempts and X1's semantic
  typing/menu actions ended as client-side `user cancelled` before NOW
  execution. Both workers independently verified that the intended state had
  not landed.
- **Why it matters:** the barrage can rate refusal handling but cannot verify
  the mutation capabilities it was designed to test.
- **Proposed change:** run one explicitly interactive, observed M1/X1 follow-up
  with confirmations intact; do not remove destructive annotations.
- **Blast radius:** evaluation harness only.

## Not findings

- NOW's stdio companion plus private same-UID Unix socket is not a confused
  dual transport. The Unix socket is local implementation IPC to an already
  running host; NOW exposes no hosted MCP endpoint.
- The human-facing Mirror and agent semantic projections are not two state
  engines. Source tracing showed one native engine and executor with sibling
  presentations; the baseline problem was terminology.
- TimBotTu 0.7's generic `mirror_call` is a deliberate sibling-service boundary,
  not evidence that NOW should replace its typed projections with one generic
  escape hatch.
- N1 did not forge or bypass an approval receipt. It used a different,
  documented byte-supply authority path. Whether that path matches product
  intent remains F-004.
- Client-side mutation cancellation is safe behavior. The missing piece is an
  interactive evaluation mode, not weaker confirmation.

## Suggested order

1. F-003 after explicit approval: the reproduced defect is small and blocks
   X1 plus every non-empty caller-supplied upload.
2. F-004: decide and document the intended authority boundary before changing
   either transfer family.
3. F-007: run the one interactive mutation follow-up.
4. F-005: prototype and retest a thin client-side routing skill.
5. F-006: measure context contributors, then review the deeper semantic/tool
   hierarchy with the barrage traces in hand.

F-001 and F-002 are resolved in this branch.
