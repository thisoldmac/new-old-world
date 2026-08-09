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
audited internally. Final `scripts/test-all` passed: 28 image-discipline tests,
149 native tests, MirrorKit, all guest/extension cross-builds, the host suites
in both asset modes, and Debug/Release app builds. The optional live-guest
stage skipped; a separate identity-checked live conformance run reached all 42
advertised tools with zero failed or uncovered rows. This remains tested plus
separately VM-verified, not metal-verified. The full gate was rerun after the
F-009 schema, decoder, guidance, tests, and live-barrage documentation landed.

## Summary

NOW has a broad, strongly typed, locally private agent surface with good
machine/session identity and unusually deep behavioral tests. The server-owned
guide was not sufficient to route arbitrary classic-Mac prompts, but the
repo-scoped `.agents/skills/now-mcp` router closed that first-contact gap: all
seven bare Luna tasks selected NOW and called `now_list_machines` first. The
barrage also reproduced and fixed a small high-impact upload capacity bug,
corrected a conformance recipe that had hidden the next failure, exposed an
authority distinction that documentation must make more explicit, made the
semantic action grammar explicit, and isolated Standard File list navigation
as the remaining modal-UI gap.

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
`start-with-now`, and `now_list_machines`. Controlled first contact improved;
the later repo-scoped routing skill closes the client-selection half under
F-005. A later Qwen3.6 client replay found one protocol interoperability defect
in that fix: Codex includes `_meta.progressToken` in `resources/read`, while
NOW accepted only the `uri` member and returned `-32602 Unknown NOW resource`
for the resource it had just advertised. A spawned-client regression was
watched fail on those exact parameters. NOW now accepts dictionary-valued MCP
`_meta` while continuing to reject unknown routing members and malformed
metadata. The identical Qwen3.6 prompt then read the guide on its first call
and correctly stated that `now_list_machines` is the first workflow step.

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

### [F-003] Positive-size upload staging always refuses on this Mac (severity: high, effort: S) — resolved

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

`PrivateStagingCapacity` now gives both transfer directions one capacity
answer: a positive important-usage value wins, while zero or unavailable falls
back to a nonnegative ordinary volume value. The five-percent reserve is
unchanged. The new resolver guard was watched fail in the two reproduced
zero/missing cases before the fix, then passed with the upload- and
download-store suites. Through the real stdio companion and private host
socket, a four-byte VM upload reserved host space, appended, committed with
guest-confirmed integrity, and statted as a four-byte `TEXT` file on Mac OS
9.1. The full repository gate then passed.

### [F-004] Transfer approval and caller-supplied upload are easy to conflate (severity: medium, effort: S)

- **Dimension:** security
- **Evidence:**
  `TransferApprovedArtifactProjection.swift` requires a one-use human receipt
  for a host-selected private file; `GuestFilesUploadBeginProjection.swift`
  accepts caller-supplied bytes with no receipt. The original N1 proved the
  route with a zero-byte Desktop file; the skill follow-up used a synthetic
  25-byte fixture, committed it, and reverified its guest metadata and digest.
- **Why it matters:** “host-to-guest transfer requires approval” is too broad a
  description. Product review cannot evaluate the intended authority boundary
  until the two source-ownership cases are stated together.
- **Proposed change:** document the distinction explicitly, then have the owner
  decide whether full agent access is sufficient authority for bytes the agent
  can already read.
- **Blast radius:** documentation only unless the authority decision changes;
  any policy change would touch tool contracts, consent, and tests and needs a
  separate approval.

### [F-005] Server discovery does not route arbitrary tasks to NOW (severity: high, effort: M) — resolved

- **Dimension:** structure-maintainability
- **Evidence:** R2/A1/M1/X1/N1 made zero NOW calls from bare prompts. The same
  five prompts, prefixed only with “Use the NOW integration on the connected
  classic Macintosh,” all called `now_list_machines` first.
- **Why it matters:** prompts/resources are opt-in and initialize instructions
  are not a reliable client-side intent router.
- **Resolution:** `.agents/skills/now-mcp` recognizes connected classic-Mac
  tasks, selects NOW, and keeps the live schemas authoritative. With that
  repo-scoped skill installed in an otherwise isolated Luna home, H0, R1, R2,
  A1, M1, X1, and N1 all called `now_list_machines` first from their original
  bare prompts. No worker detoured to TimBotTu, an emulator harness, or the
  modern host.
- **Blast radius:** client packaging and onboarding, not server behavior;
  verified by rerunning the same bare set with no task-specific tool hints.

The first A1 skill run also showed why the router must remain small: a
prophylactic `now_session_capabilities` call and an invented launch `path`
added cost without evidence. The skill now probes capabilities only after an
actual uncertainty or typed refusal and launches by exact inventory name or
reference. The repeated A1 completed with six clean NOW calls and no refused
arguments. Compared with the prior minimally routed runs, the final skill runs
reduced cumulative input accounting by 94,833 tokens for R1, 89,178 for R2,
54,776 for A1, 110,339 for M1, and 536,661 for N1. These are end-to-end client
numbers, not schema-only savings.

### [F-006] Rich, flat discovery has material context cost (severity: medium, effort: M) — resolved by measurement

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

**Measured follow-up (2026-08-09):** the real 42-tool `tools/list` response is
158,123 bytes. Compacting the repeated guest-selector prose removed 14,364
wire bytes but only 181 cumulative Luna input tokens. Omitting every typed
output schema removed 91,057 wire bytes but only 60 input tokens, so deleting
those schemas is not justified. A valid `notifications/tools/list_changed`
did not make Codex 0.147 refetch the catalog; the model guessed instead of
calling the newly exposed typed tool, ruling out session-dynamic disclosure
for this client.

The supported `mcp_servers.<id>.enabled_tools` boundary was material: an exact
Luna A/B with the same natural first-contact prompt and real companion measured
107,990 input tokens with all 42 tools versus 77,120 with only discovery and
capability tools, a 30,870-token reduction. When the prompt explicitly named
`now_list_machines`, both full and filtered cases were approximately 36K.
The F-005 skill result confirms that a small intent-to-canonical-tool map is a
useful client layer. Keep the typed output schemas and do not redesign the NOW
facade from prose-byte counts alone.

- **Resolution:** retain the typed catalog and schemas. Use the repo-scoped
  routing skill for intent selection; use `enabled_tools` only for deliberately
  narrow client profiles, not as session-dynamic disclosure. No server facade
  change is justified by the measured client behavior.

### [F-013] Inventory paths look actionable to the launch tool (severity: low, effort: XS) — resolved

- **Dimension:** structure-maintainability
- **Evidence:** in the fixed cross-model A1, both GPT-5.6 Luna and
  GPT-5.4-mini selected SimpleText correctly from `now_software_inventory`,
  then passed its returned HFS `path` to `now_launch_software`. Luna first used
  a `path` argument and then combined `name` with a placeholder `reference`;
  GPT-5.4-mini put the path in `reference`. NOW refused every malformed call
  and both actors recovered to the exact inventory name. Gemma and Qwen used
  the name directly.
- **Why it matters:** the producer returns a prominent `path`, while the
  adjacent consumer's description ends with the inaccurate statement “Guest
  paths are never accepted or returned.” The path is returned by inventory;
  it is simply not a launch key. Two capable actors made the same cross-tool
  handoff error in an otherwise trivial four-call workflow.
- **Resolution:** the launch descriptor now says to pass the exact inventory
  `name`, not its `path`, and explains that opaque references come only from
  an ambiguous-name refusal. The registry guard was watched fail on all four
  missing handoff phrases before the descriptor changed, then passed. All
  eight registry tests and the final repository gate pass.
- **Blast radius:** one descriptor and one registry guard; no arguments,
  dispatch, guest behavior, or compatibility changes.

### [F-012] Escalation tools omitted their local evidence rank (severity: low, effort: XS) — resolved

- **Dimension:** correctness and structure-maintainability
- **Evidence:** the server guide and routing skill put retained semantic state
  before direct observation and pixels, but the descriptors for
  `now_observe_elements` and `now_capture_screen` did not. In X1, Luna had a
  retained dialog item yet tried the direct family twice before recovering;
  the pre-cleanup H1 also escalated to pixels without retained state.
- **Why it matters:** a small client may choose from the one descriptor in
  front of it without consulting an optional resource or repo skill. The two
  escalation tools therefore sounded like primary observation paths.
- **Resolution:** `now_observe_elements` now says to prefer
  `now_semantic_ui_snapshot`, read its result before deciding to escalate, and
  never launch the two reads in parallel. The snapshot descriptor states the
  same ordering from the retained side. Direct observation remains for proven
  incomplete state or fresh direct references. `now_capture_screen` limits
  pixels to genuinely visual facts or exhausted semantic evidence. A registry
  test pins the local instructions and was watched fail before each descriptor
  change.
- **VM validation:** an isolated Luna baseline still launched retained and
  direct observation in parallel under the first wording. With the sequencing
  explicit, the same prompt and VM used process state plus the retained
  snapshot only. A control with the routing skill readable called
  `now_list_machines`, started semantic UI, read the retained snapshot, and
  then cross-checked processes; it used neither a direct probe nor pixels.
- **Blast radius:** two MCP descriptions and one registry test; no dispatch,
  guest, state-engine, transport, or authority behavior changed. The matching
  repo-skill sentence is agent guidance, not a runtime change.

### [F-007] Non-interactive workers cannot complete annotated mutation chains (severity: medium, effort: S) — resolved for the harness

- **Dimension:** correctness
- **Evidence:** M1's three `now_guest_files_mutate` attempts and X1's semantic
  typing/menu actions ended as client-side `user cancelled` before NOW
  execution. Both workers independently verified that the intended state had
  not landed.
- **Why it matters:** the barrage can rate refusal handling but cannot verify
  the mutation capabilities it was designed to test.
- **Resolution:** the isolated evaluation client used its supported automatic
  approval mode; server annotations and consent checks remained intact. M1
  created, verified, trashed, verified absent, restored, and reverified its
  folder. X1's annotated upload and UI calls also reached NOW rather than being
  cancelled, exposing F-009 instead.
- **Blast radius:** evaluation harness only.

### [F-009] Modal direct actions invite ungrounded gesture guessing (severity: medium, effort: S) — resolved

- **Dimension:** correctness and structure-maintainability
- **Evidence:** X1 successfully uploaded and byte-verified its 52-byte text
  file, launched SimpleText, opened its File menu, and entered the guest path.
  When the Open dialog did not settle, the worker crossed retained semantic
  state and direct-observation references, then tried unsupported gesture
  synonyms (`keyPress`, `press`, `submit`, `confirm`, `click`, `invoke`, and
  `select`) until the evaluator interrupted the run at 332 seconds.
- **Why it matters:** the typed surface gives good refusals, but the relation
  between retained entities, direct references, modal controls, and their
  permitted action vocabulary is not self-evident under failure.
- **Resolution:** `now_semantic_ui_act` now publishes the exact 16-gesture enum
  and one required-argument branch per gesture. The decoder enforces that same
  Swift-owned contract before a request reaches the host, rejects arguments
  from another gesture with a specific correction, and tells callers where to
  find dialog item numbers in `snapshot.surfaces[].items`. The Finder gestures
  now state that they do not select rows inside Standard File dialogs.
- **Verification:** the schema and decoder guards were watched fail against the
  old surface. Focused tests pass. In a second isolated Luna run the worker
  recovered from two refused direct-control attempts to the retained snapshot,
  selected `gesture: dialogItem` itself, corrected `item` to `itemIndex` after
  the typed boundary error, and dispatched the exact `Open` item. It did not
  enumerate invented gesture names. The overall task still failed for the
  distinct F-010 selection gap.
- **Blast radius:** experimental semantic-action schema and pre-host argument
  validation only; executor, guest command, and wire behavior are unchanged.

### [F-010] Standard File item lists are not semantically selectable (severity: medium, effort: M)

- **Dimension:** correctness and structure-maintainability
- **Evidence:** the retained SimpleText Open-dialog surface named `Open` as
  dialog item 1 and exposed its other controls, but represented the file-list
  rectangle only as an unnamed `userItem`. It published no file rows, current
  selection, or row action. Direct observation likewise exposed the container
  control but no selectable children. Luna set the filename field to the exact
  uploaded name and dispatched `Open`; SimpleText opened the previously
  selected `Apple DVD Player Read Me` instead.
- **Why it matters:** the MCP can open and dismiss the dialog but cannot
  reliably choose the document inside it. Cross-domain open/save tasks
  therefore degrade into keyboard, pixel, or container guesses even though the
  final button is fully semantic.
- **Review result:** keep literal Open-dialog row navigation as a distinct,
  unresolved semantic-capture problem. The installed Navigation Services
  headers expose selection through an opaque `NavDialogRef`, but the observed
  `WindowRef` is a distinct type and there is no public inverse lookup.
  Capturing it generically would require a new in-context registration or
  interception seam and resident contract. Do not widen `dialogItem`, infer a
  selected row from editable text, or disguise a coordinate as a row identity.
  The bounded high-impact slice is instead the dedicated `now_open_document`
  projection described in [now-mcp-standard-file-review.md](now-mcp-standard-file-review.md),
  using the PPC guest's existing closed `aesend`/`odoc` mechanism. It does not
  claim to fix explicit dialog traversal.
- **Blast radius:** likely guest semantic capture plus the retained projector
  and executor, or one new typed domain action. This is not folded into the
  action-schema cleanup.

### [F-011] A bounded guest document-open capability exists but is absent from MCP (severity: medium, effort: M)

- **Dimension:** correctness and structure-maintainability
- **Evidence:** the PPC guest's contract and implementation already serve a
  closed `aesend` vocabulary. Its `odoc` operation addresses one exact PSN,
  resolves one HFS document, sends `kAEOpenDocuments`, and reports `sent`
  rather than `performed`. `docs/mcp-coverage.md` records it as unprojected.
  TBT classic exposes the same mechanism but gives agents a generic event tool.
- **Why it matters:** an agent that has uploaded or found a known document must
  currently reverse-engineer an application's Open dialog even though the
  operating system already provides a semantic document-open operation.
- **Proposed change:** add `now_open_document(processReference, path)`. Reuse
  opaque process revalidation and the host-owned root-relative Files policy;
  extend the guest command accretively with a share-relative path form rather
  than reconstructing an actionable full HFS path from a display label. Expose
  only `odoc`, not generic `aesend`; keep NOW-68K typed unavailable.
- **Blast radius:** async contract, PPC command argument/resolve seam, one host
  projection and local-protocol lane, derived MCP/coverage docs, and focused
  tests. No resident or Mirror state-engine change.

### [F-008] The live upload conformance recipe contradicted its own payload (severity: medium, effort: XS) — resolved

- **Dimension:** correctness
- **Evidence:** the recipe declared the four bytes `now\n` but supplied a
  different hard-coded SHA-256. Once F-003 allowed staging to proceed, the
  live run appended all four declared bytes and commit correctly refused
  `now-files-integrity-failed`. Because an explained refusal is normally a
  valid conformance verdict, the full-surface gate could still pass.
- **Why it matters:** the upload chain could answer every advertised row while
  never proving a successful commit, masking both recipe drift and a broken
  data path.
- **Resolution:** the recipe now derives byte count, digest, and base64 chunk
  from one `Data` value. The spawned-client no-host gate passed all 42 rows;
  the identity-checked live run then classified upload begin, append, and
  commit as served, with zero failed or uncovered rows.
- **Blast radius:** conformance test data only; production upload behavior did
  not change.

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

1. F-004: decide and document the intended authority boundary before changing
   either transfer family.
2. F-011: with explicit approval, project the PPC guest's bounded document-open
   mechanism as `now_open_document`; keep generic Apple Events off MCP.
F-001, F-002, F-003, F-005, F-006, F-007, F-008, F-009, and F-012 are resolved
in their stated scope. F-004 remains a review input. F-011 awaits approval.
F-010 remains an explicitly deferred resident-contract problem, not a
prerequisite for F-011.
