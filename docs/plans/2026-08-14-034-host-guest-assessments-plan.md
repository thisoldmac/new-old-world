<!-- now-doc-provenance: generated reviewed=false -->

# 034 — Host & guest assessments: plan

Status: **v2 — round-1 decisions folded in** (2026-08-14). Research by 14
swarm units; full per-unit evidence in `docs/local/assessments-034/U*.md`
(gitignored scratch). Michelle resolved the discussion agenda same day;
the remaining open questions are the short list in Part 2. Findings are
**code-read** unless marked otherwise; two of them were contradicted by
live observation and became investigations (Part 0).

Branch: `claude/host-guest-assessments-7b254f`, forked off
`refactor/mirror-continuity-split` @ 76f4dac6.

Implementation note: load the relevant skills per slice —
`classic-mac-carbon-ui` (+ its `audit_source.py`) and
`classic-mac-carbon-platform` for guest work, `classic-mac-emulator-harness`
for VM verification, and the Xcode/Swift tooling for host work. Gates:
`scripts/test-all`; docs/manifest changes add `scripts/test-docs`;
derived docs re-derive in the same commit.

---

## Part 0 — Code says built, machine says no (live-debug items)

Two research conclusions were contradicted by observation of the running
apps. In both cases implementation + passing tests exist, so these are
"why doesn't the built thing fire" investigations — the most valuable
kind, since something structural is eating the behavior:

- **H6 — spring-load flash never shows in the current build.** The
  double accent flash exists (`SidebarNativeDragSurface.swift:296-304`,
  spec in `NavigationDragCoordinator.swift:461-464`) and its tests pass.
  Investigate on a live build why `springLoadingActivated` never
  produces visible output — candidate causes: the event never reaching
  the NSView (coordinator not arming, H7's eager zone-move displacing
  the target first — these two may be one bug), or the flash drawing
  under another layer. Fix at the root, don't re-animate.
- **G8 — button reads "Connect" while a connection is active and
  healthy.** `conn_idle()` (`connection_module.c:754-762`) polls
  `conn_is_connected()` and flips the title every tick — so either
  `conn_idle` isn't running in the healthy state, or
  `conn_is_connected()` disagrees with the wire's actual state (module
  state vs `wire.c` truth divergence). Debug on the emulator; fix the
  state source, then the already-written title/action logic works.

The corrected premises from research stand:

- **H1 — web proxy addressing is not a bug.** The guest's 127.0.0.1 is
  its *own* OT loopback listener; content crosses the NOW wire, never a
  second IP connection. `10.0.2.2` describes the superseded "Direct"
  design in plan 032. Close by fixing that plan's stale receipt section.
  (H1b autostart toggle is real — Slice A.)
- **H10 — the hover control is the Files collapsed rail** (whole-rail
  scale+tint today, no literal chevron nudge found).

---

## Part 1 — Locked slices

Effort: S ≈ under an hour, M ≈ a session, L ≈ multi-session.

### Slice A — host mechanical fixes (S each)

- **H5 — shelf click returns to first tab.** `SidebarShelfRow.activate()`
  (`SidebarNavigationContent.swift:444-446`) always restores the
  last-remembered tab; when already selected, select
  `NavigationShelfTab.tabs(for:registry:).first` instead.
- **H16 — dropdown hover highlight sticks.** `NSMenu.popUp`'s modal
  tracking swallows `mouseExited` (`SidebarNativeDragSurface.swift:365-380`);
  reset hover state after `popUp` returns.
- **H2 — Files sidebar theming, icons included.** Both sidebars paint
  flat `controlBackgroundColor` behind a `.sidebar` List while the
  collapsed rail already uses real `NSVisualEffectView(material: .sidebar)`
  (`FilesNativeSplitViews.swift:41-91`). Extract that as a shared
  background, apply to both (`FilesWorkspaceShell.swift:628-717`,
  `HostFileBrowser.swift:650-705`), add `.scrollContentBackground(.hidden)`.
  **Per Michelle: audit the sidebar icons in the same pass** — semantic
  template rendering/vibrancy, not baked colors — so icons match the
  material treatment.
- **H1b — web proxy start-automatically toggle.** Clone the MCP pattern
  (`MCPTransportPreferences.swift:7-39`): UserDefaults-backed
  `@Published` on `WebBridgeModel`, Toggle in `WebModuleView`, launch
  hook in `App.swift` beside the stdio one. Default off.

### Slice B — update-in-place (H4, M)

- **Guest:** `update_install.c:152-160` `FSpRename`s the live running
  app before trashing — the exact `fBsyErr` operation
  `fileshare.c::move_busy_named` (:2341-2367) was hardened against on
  2026-08-12. Extract a shared "trash-move a possibly-running APPL"
  helper; both call it (decided: shared helper, not a third copy).
- **Host:** `ConnectionsModel.installUpdate()` has no watchdog on the
  `update.result` wait — add one (flat 3 min to start), a determinate
  progress bar from the existing `put_report_progress` plumbing, and a
  Cancel mirroring `FilesModel.cancelTransfer()`.
- Wants a metal-verified pass (`fBsyErr` is system-dependent).

### Slice C — ROM dump UX (H3, S)

`NSSavePanel` for destination/filename (pattern
`ScreenshotsModuleView.swift:299`); no format picker — the dump has one
artifact shape (raw `.bin`). Determinate progress from
`.transferProgressed` events (pattern `ScreenshotModel.swift:368-378`);
guest write phase stays indeterminate (no wire signal).

### Slice D — language, host (H15, S)

- `MachineNaming.swift`: properNoun/commonNoun (+plurals) → "Guest"/
  "guest"; rewrite the doc comment that currently forbids exactly this.
  128 call sites follow for free.
- Replace ~25 hardcoded bypasses across 11 files (site list in U9
  notes) with `MachineNaming.*` calls, incl. `Session.swift:188`
  `unnamedGuest`. Two deliberate non-changes (file format / OS names).

### Slice E — guest mechanical fixes

- **H13 — overview formatting (S).** Both in `census_probes.c`:
  MiB→MB/GB/TB formatter for the Storage block (:370-396); static
  Gestalt code→name table (601…750="G3", 7400="G4"…) used by
  `gather_overview()` and `gather_identity()` so overview/identity/
  console agree ("PowerPC G3 (750) @ 292 MHz").
- **G3a — chat boxes white (S).** `draw_transcript()`/`draw_input()`
  erase without `RGBBackColor`; wrap the 4 erases with the
  save/white/restore pattern `workshop_sidebar.c` uses 3×.
- **G2a — Development button overflow (S).** Per-button width constants
  replacing the shared `kButtonWidth=132` (`development_layout.c:3-9`).
- **G10a — ⌘O opens Workshop (S).** Add `/O` to the Windows▸Workshop
  item string (`main.c:153-155`); dispatch already generic.
- **G10b — persist Workshop open/closed (M).** `workshop_open_at_quit`
  in NowPrefs (V27 accretive), `workshop_close(quitting)` to
  distinguish user-close from teardown, gate the launch `workshop_open()`.
- **G11b — guest-originated receive cancel (S).** Add
  `now_wire_put_cancel` mirroring `now_wire_get_cancel` (send
  `file.cancel` with `g_put.id`, then existing `put_abort` cleanup).
  Contract message exists; `contract-coverage.md` updates same commit.
- **G11a — receive-progress floating windoid (M).** Non-modal windoid
  (decided over modal) shown from the idle loop whether or not the
  Workshop is open; reuses `files_share_view.c`'s progress/cancel
  controls; consumes the existing but UI-orphaned receive plumbing in
  `wire.c`; hosts G11b's Cancel. Lives in `workshop/`.

### Slice F — guest observability & citizenship

- **I3 — `describe_scene` on all 17 pages + build gate (M).** One page
  implements it today; 16 describe as empty panes to the observation
  plane. Implement per module from what `draw()` already computes; add a
  source gate (pattern `control_kind_source_test.py`) failing any module
  whose `draw()` draws text with NULL `describe_scene`; register in
  `scripts/test-native`'s manifest; mutation-watch it by NULLing
  screenshots' entry.
- **I5 — About box (S).** Apple menu + "About New Old World…" movable
  modal (`confirm.c` pattern, never an ALERT) with name, `vers`,
  `now_build_stamp()`.
- **I8 — title parity gate + tier in rail (S).** Add `title` to
  `tools/docs-gate`'s compared fields (Screen/Screenshots,
  Connections/Connection, Web Proxy/Web currently drift uncaught);
  resolve guest titles; draw tier as right-aligned label in the rich
  rail row. Mutation-watch by reverting one title.
- **I7 — default rail order (S).** Add `k_default_order[]` seeding the
  sidebar when prefs carry no saved order — ids untouched, no
  renumbering — with the adjacency argument written in prose like the
  host registry. (Decided yes.)
- **I4a — remove ⌘1-0 page shortcuts (S).** Decided: the View-menu
  cmd-numbers go away (they ran out at ten pages anyway).
- **I4b — compact-only rail + tooltip (M).** Decided (round 2): retire
  the rich two-line density; the rail is compact-only (all 14 rows fit
  everywhere, incl. 640×480), and the module description moves to a
  hand-drawn hover tooltip tag (`workshop_sidebar.h:56-59` pattern —
  Carbon help tags don't render on OS 9). Density prefs simplify
  accordingly.

### Slice G — decision-driven restructuring (from round 1)

- **G-1 Module moves (H8/H12/G4/G5, M+M+S).** Host Networking → Machine
  shelf as a facts page. Diagnostics **grows** on both apps: `wirestat`
  as a fourth instrument (read-only; wake/sleep stay console-only) plus
  the link timing rows. **Test-ping goes to Connection(s), both sides**
  (decided): the guest's card-1 "Test" button lands on the Connection
  page, not Networking; host link section already lives with
  Connections. Guest Networking keeps the TCP/IP + Ports fact cards and
  shrinks the no-connection-list essay card to its placard line.
- **G-2 Development → Projects (M).** Rename host+guest+manifest+docs
  in one commit via `ModuleRegistry.renamedIDs`; MCP tool names decided
  separately. Guest gets the projects package: `development-projects`
  list verb (expose `find_project()`'s existing walk), persisted
  `active_project_id` (NowPrefs accretive), **session-scoped job-history
  ring** (decided — no on-disk log), flat DataBrowser list+detail
  (pattern `processes_module.c`), Build/Run buttons sharing the
  existing command implementations per parity. Candidates stay out of
  the projects list (clean ID spaces).
- **G-3 Connections reorg (H14, L).** Roster → collapsible right
  sidebar by generalizing `FilesRightSidebarSplitView` into a shared
  component. **No machine-switching affordance needed while collapsed**
  (decided): the app-level guest picker owns switching; the roster is
  for managing **disconnected** (not merely remembered) machines. Move
  `ConnectionLinkSection`/`ConnectionListenerLog` out of
  `SettingsModuleView.swift` into the Connections files.
- **G-4 Chat (H11 + G3b, M then M).** Host: persisted multi-chat with
  **lazy-loaded transcripts** (decided — sympathetic to RAM); sidebar
  List. Projects (round 2): a project is a **folder on disk**, optionally
  associated with a build target/code — i.e. it can reference a
  Projects-module project; chats-first, projects after. Guest: collapsible
  flat list (hierarchical DataBrowser is recorded not-viable on metal)
  once the host model exists; contract verbs for guest browsing decided
  then.
- **G-5 Settings window (H17, M).** Pill-tab Settings window (reuse
  Files' pill pattern) with deep-link seam (`showSettings(selecting:)` +
  module-context navigation closure). Move the global preferences
  (sidebar rows/collapse, MCP autostart, Web compat/safety, Logs
  log-to-disk, H1b's toggle). Files/Screenshots in-module panes stay.
  **Mirror's dev-focused controls stay in-module and messy for now
  (decided — the feature itself isn't settled); Mirror and Continuity
  both get a "defaults for new connections" presence in Settings.**
- **G-6 Guest Files rebuild (G7, L).** Free rein granted ("blender →
  cocktail"). Direction from the audit: separate "their files" (browser,
  always visible, labeled) from "my shared folder" (config + send/
  receive as distinct rows, not one triangle over both); fix the
  four-writers status placard as part of the rebuild; decide
  `catsearch.c` (dead 285 lines) — wire it as search or delete it.
  Design first as a page mock (render-preview skill), then implement.
- **G-7 Mirror consent contract change (G6, M).** Decided: **guest owns
  enable/disable; host owns the granular plane controls.** Contract
  first: revise the two-key consent wording (~asyncapi line 7431) so the
  guest gate is a single master consent and the four per-plane guest
  checkboxes retire; guest Mirror page becomes enable/disable +
  show-on-host + facts; host keeps plane toggles. Both halves + coverage
  docs in the contract-first order. Sequence after
  `refactor/mirror-continuity-split` lands (host mirror surface is
  moving there).
- **G-8 Guest naming (D8, M).** Guest refers to itself as **"This Mac"**
  and to the host as **the host's actual hostname** when known, falling
  back to **"Other Mac"** when disconnected/unknown. Implementation:
  the hostname needs to ride the wire (check what `hello`/census already
  carry; add a field contract-first if absent), plus a small guest-side
  naming helper (the guest's ~30 sites have no central abstraction —
  this creates one, the same move MachineNaming made host-side).
- **G-9 Guest drag (I1, M→L).** Near-term: the sidebar's Option-drag
  rearrange becomes **plain drag** (decided). Then the real Drag
  Manager, drop-direction first (receive handlers on the Workshop window
  + Files page, FREF for 'APPL'+docs so Finder icon drops work,
  `kAEOpenDocuments` handler); drag-source from DataBrowser later.
- **G-10 Guest clipboard (I2, M).** One Edit▸Copy dispatched through a
  new optional `WorkshopModuleOps` "selected text as text" entry — the
  module answers, no focus machinery needed; extend page by page.
  Designed with the future **cross-device copy** idea in mind: the ops
  entry's output shape should be reusable as a wire payload later.
- **I6 — Continuity face at the machine: deferred** (decided — maybe a
  toolbar icon later; `ppc_pages: []` declaration stands).

### Standing philosophy (D9, accepted)

The guest mirrors the host's **vocabulary**, never its **gestures**: a
native Platinum/Carbon application designed by someone who's used to
2026 quality-of-life. Host features get OS 9 idioms or declared
asymmetries, never ported controls. The nine deliberate divergences
catalogued in U14 get recorded in `docs/guest-ui-start-here.md` as a
"deliberate divergences" section so reviewers stop reading them as gaps.

---

## Part 2 — Still open

Nothing. Round 2 (2026-08-14, Michelle) closed the last five:

1. **I4b locked:** no mock — the rail becomes **compact-only**, with the
   module description shown as a hover tooltip (hand-drawn tag, since
   Carbon help tags don't render on OS 9). Joins Slice F alongside I4a.
2. **Chat project defined:** a project gets its **own folder on disk**
   and can **optionally be associated with a build target/code** (i.e.
   it can reference a Projects-module project). G-4 loses its deferral.
3. **"Other Mac" fallback confirmed** for G-8.
4. **H10 locked:** use cutting-edge Swift (`NSSymbolEffect` bounce on
   the chevron icon, layered over the existing scale+tint) behind
   `#available`, degrading gracefully to the deployment floor.
5. **H6/H7/G8 investigations: best effort** — land the best-supported
   root-cause fixes; Michelle live-tests once they land.

## Part 3 — Sequencing

1. **Wave 1 (parallel-safe now):** Slices A, C, D, E + the H6/G8/H7
   live investigations (one debugging session, shared code area for
   H6/H7).
2. **Wave 2:** B (update fix), F (guest citizenship), G-1/G-2 renames
   and moves (each one coherent commit spanning registry/manifest/docs),
   G-9a plain-drag, G-10 clipboard, I7/I4a.
3. **Wave 3:** G-3 connections reorg, G-4 chat, G-5 settings, G-6 files
   rebuild (mock first), G-8 naming (contract check first), G-9b drag
   manager.
4. **Gated:** G-7 mirror contract change waits for
   `refactor/mirror-continuity-split` to land.
5. **Metal pass:** H4, G10/G11, I3 — code-read fixes on
   system-dependent behavior stay "Tested" until watched on hardware.

## Part 4 — Research provenance

14 units, 15 agents (12 sonnet, 2 opus, 1 haiku path validation), all
completed, ~1.8M subagent tokens. Notes: `docs/local/assessments-034/`.
One cited path corrected (`NavigationLayoutTests.swift` lives in
`now-host/Tests/HostTests/`). Code-read only; H6/G8 subsequently
contradicted live and reclassified (Part 0).

## Decisions log

- 2026-08-14 (Michelle): split thread is host-side; G6/G-7 sequences
  after its merge, no file conflict.
- 2026-08-14 (assembly): H4 shared trash helper, 3-min watchdog; H3 no
  format picker; G10a ⌘O; G11a floating windoid.
- 2026-08-14 (Michelle, round 1): H6 and G8 do NOT work in the current
  build despite code+tests → live investigations. H2 includes icons.
  D1 accepted; test-ping lives in Connection(s), facts stay in
  Networking. D2 accepted; job history session-scoped. D3: no collapsed
  switching affordance needed (app-level guest picker exists; roster
  manages disconnected machines). D4: chats persisted, lazy-loaded.
  D5: Mirror controls stay in-module/messy for now; Mirror + Continuity
  get defaults in Settings. D6: free rein on Files rebuild. D7:
  contract changes — guest owns enable/disable, host owns granular
  controls. D8: This Mac / {host's hostname}, "Other Mac" fallback.
  D9 philosophy accepted. I1: rail rearrange becomes plain drag; Drag
  Manager approved in principle. I2: clipboard in, with cross-device
  copy in mind. I4: ⌘-numbers removed; density question open. I6
  deferred. I7 default order yes. Leverage the xcode/c/carbon skills
  during implementation.
- 2026-08-14 (Michelle, round 2): I4b compact-only + tooltip, no mock.
  Chat project = own folder on disk, optional build-target association.
  "Other Mac" confirmed. H10: cutting-edge Swift, degrade gracefully to
  the floor. Investigations best-effort; Michelle tests once landed.
  → Plan fully locked; wave 1 implementation begins.
- 2026-08-14 (wave 1 merged): all 8 lanes landed on
  `claude/host-guest-assessments-7b254f`; `scripts/test-all` green on the
  merged tree, all stages run (native 203, MirrorKit, both guest
  cross-builds, host Debug+Release; live-guest SKIP by design — nothing
  metal-verified yet). Slices A/C/D/E complete; F and G remain (waves
  2-3). G8's mechanism was lazy page creation seeding the title cache —
  ledger entry in open-issues. H6/H7 shared a root (band-scoped arming +
  eager insert preview). Pre-existing defects found at the fork point and
  fixed here: plan-doc provenance marker, half-resolved conflict markers
  baked into 8 derived docs. Outstanding for Michelle: hooks unarmed
  across the shared clone (`tools/hooks-doctor --fix` is hers to run);
  `claude/*` branch names need renaming before landing (git-policy);
  live checklist — spring-load flash + connections-shelf spring-load,
  Disconnect title on a page first opened after auto-connect, receive
  windoid incl. keystroke routing with no transfer running.
- 2026-08-14 (wave 2 merged): seven lanes + one report-less lane (g1b,
  verified post hoc) merged at c8b1d827; scripts/test-all green centrally,
  all stages run. Slices B and F complete; G-1/G-2 complete
  (Tested, nothing live). Notable deviations, all argued in the ledger:
  no new projects verb (catalog regularized instead), title drifts kept
  as gate-validated overrides, About box's DA items inert under Carbon.
  Wave 3 = guest citizenship (I3+I2 as one lane), connections reorg,
  chat persistence, settings window. Wave 4 = guest files rebuild,
  guest naming, drag manager (guest-module file ownership forces the
  split). Live checklist grows: About box, compact rail + plain drag,
  Test ping, Projects page, update-in-place on metal.
- 2026-08-15 (wave 3 merged): four lanes at 0bfdee71, test-all green
  centrally. I3+I2, G-3, G-4 (host half), G-5 complete — Tested, nothing
  live. H1 closed on paper: plan 032's Direct receipt now records its own
  supersession. Wave 4 = guest Files rebuild (owns files/* + its naming
  + copy/describe), guest naming helper (rest of the sites), Drag
  Manager drop-first (owns workshop_window/main/app.r), CloudViewOps
  describe + cheap copy_text adds, H10 chevron. Remaining after wave 4:
  G-7 (gated on the split-thread merge), guest chat sidebar (gated on
  the guest-browsing contract decision), and the live/emulator pass.
