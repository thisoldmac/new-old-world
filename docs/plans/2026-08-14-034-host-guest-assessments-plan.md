# 034 — Host & guest assessments: plan

Status: **research complete, plan assembled** (2026-08-14). 14 research
units fanned out over the ~30 items; every unit landed. Full per-unit
evidence (file:line refs, alternatives, inventories) is in
`docs/local/assessments-034/U*.md` (gitignored scratch); everything
load-bearing is restated here. All findings below are **code-read, not
live-verified** — items whose classification depends on watching the app
run say so.

Branch: `claude/host-guest-assessments-7b254f`, forked off
`refactor/mirror-continuity-split` @ 76f4dac6.

Classification: **LOCKED** = decided, ready to implement as written.
**DISCUSSION** = options below, awaiting Michelle. **CORRECTED** = the
item's premise didn't survive contact with the code — see Part 0.

---

## Part 0 — Premise corrections (read first)

Four items came back different from how they were filed:

- **H1 (web proxy 127.0.0.1 → 10.0.2.2): not a bug in shipped code.**
  The guest's 127.0.0.1 is the guest's *own* OT loopback listener
  (`web_proxy_ot.c:13-14,168-212`) that its browser proxies to; page
  content crosses over the existing NOW wire
  (`now_wire_web_request/response_*`), never a second raw IP connection.
  The host's 127.0.0.1 (`WebBridgeModels.swift:173-185`) is only for the
  host's own Python subprocess. `10.0.2.2` matches the *superseded*
  "Direct" design in `docs/plans/2026-08-10-032-feat-web-bridge-plan.md`;
  nothing that compiles references it. Proposed close: fix that plan
  doc's receipt section (it still claims Direct is current), no code
  change. If Direct mode as an opt-in LAN topology is actually wanted,
  that's separate security-relevant feature work. **The autostart toggle
  half (H1b) is real and locked below.**
- **H6 (spring-loaded anim): already built.** Finder-style double accent
  flash ships (`SidebarNativeDragSurface.swift:296-304`,
  `NavigationDragCoordinator.swift:461-464`) with tests;
  `docs/open-issues.md` records it as built but UI-unverified. Plan:
  live-verify before writing any animation code; close if it reads well.
- **G8 (Connect ↔ Disconnect): half already exists.** `conn_idle()`
  already flips the button title and `conn_click()` already disconnects
  when connected. The real gap is only connect-on-edit — locked below.
- **H10 (chevron "moves up a few pixels"):** the only chevron+hover
  pairing in the area is the Files collapsed rail
  (`FilesNativeSplitViews.swift:41-206`), which today does a whole-rail
  1.015 scale + accent tint, not a chevron nudge. Assuming that's the
  control meant; flag if it isn't.

---

## Part 1 — LOCKED work

Grouped into implementation slices. Effort: S ≈ under an hour, M ≈ a
session, L ≈ multi-session.

### Slice A — host mechanical fixes (all S)

- **H5 — shelf click returns to first tab.**
  `SidebarShelfRow.activate()` (`SidebarNavigationContent.swift:444-446`)
  always calls `openShelf`, which restores the last-remembered tab via
  `NavigationShelfSessionState.selection(forOpening:)`. Fix: when the
  row is already selected, select
  `NavigationShelfTab.tabs(for:registry:).first` instead.
- **H16 — dropdown hover highlight sticks.** Root cause: the shelf
  icon's `NSMenu.popUp` (modal tracking loop,
  `SidebarNativeDragSurface.swift:365-380`) swallows the `mouseExited`
  that would clear `isHovering`; there is no post-modal reset. Fix: after
  `popUp` returns, recompute/clear hover via `configuration?.hoverChanged`
  and cancel pending hover-disclosure state.
- **H2 — Files sidebar theming.** Both sidebars
  (`FilesWorkspaceShell.swift:628-717`, `HostFileBrowser.swift:650-705`)
  paint flat opaque `controlBackgroundColor` behind a `.sidebar` List,
  while the sibling collapsed rail (`FilesNativeSplitViews.swift:41-91`)
  already uses a proper `NSVisualEffectView(material: .sidebar)` — the
  expand/collapse swap between real vibrancy and flat color *is* the
  mixed theming. Fix: extract the rail's material view as a reusable
  background, apply to both sidebars, add `.scrollContentBackground(.hidden)`
  to both Lists. Everything else in the module audited native-correct
  (table in U4 notes).
- **H1b — web proxy start-automatically toggle.** Copy the MCP module's
  pattern exactly: UserDefaults-backed `@Published var startsAutomatically`
  on `WebBridgeModel` (mirroring `MCPTransportPreferences.swift:7-39`),
  a Toggle in `WebModuleView.swift` beside the existing controls, and an
  `App.swift` launch hook beside the existing
  `stdioStartsAutomatically` block. Default off (it starts a
  subprocess). No contract change.

### Slice B — update-in-place fix (H4, M) — the one real regression

- **Root cause A (the failure), guest:** `update_install.c:152-160`
  `FSpRename`s the *live running app's own file* before trashing it —
  the exact operation `fileshare.c`'s independently-hardened
  `move_busy_named` (`fileshare.c:2341-2367`, fixed 2026-08-12)
  documents as returning `fBsyErr` on some systems. Fix: extract a
  shared "trash-move a possibly-running APPL" helper from
  `move_busy_named` and use it in both places — this is the second
  independent implementation and the second one regressed the first
  one's fix, which is the argument for sharing it. (Decision made:
  shared helper, not a third copy.)
- **Root cause B (the hang), host:** `ConnectionsModel.installUpdate()`
  has no watchdog on the unbounded `update.result` wait — the only
  request family without one (`GuestListener.swift:814-843` documents
  the need). Fix: bounded watchdog (start at 3 minutes flat; tune when a
  metal install time is measured), a determinate progress bar fed from
  the already-wired `put_report_progress` → `captureProgress` plumbing
  (replacing the static "Downloading and installing…" text), and a
  Cancel mirroring `FilesModel.cancelTransfer()`.

### Slice C — ROM dump UX (H3, S)

- `NSSavePanel` before `dumpROM()` for destination + filename (pattern:
  `ScreenshotsModuleView.swift:299`). The guest produces exactly one
  artifact shape (raw `.bin`, `rom_dump.c`), so **no format picker** —
  that part of the filed item doesn't apply. Progress: subscribe
  `CensusModuleModel` to the listener's `.transferProgressed/.transferEnded`
  events (pattern: `ScreenshotModel.swift:368-378`) and render a
  determinate bar during transfer; the guest-side write phase has no
  wire signal, so it stays an indeterminate spinner.

### Slice D — language pass, host (H15, both S)

- **MachineNaming constants:** in `MachineNaming.swift` change
  properNoun/commonNoun (+plurals) from "Old World Mac"/"old world mac"
  to "Guest"/"guest"; `thisMac` already reads "this Mac". Rewrite the
  file's doc comment, which currently *instructs* keeping "Guest" out of
  user copy. One edit propagates to all 128 call sites.
- **Bypass cleanup:** ~25 hardcoded "classic Mac"/"Old World Mac"
  literals across 11 files (list with line numbers in U9 notes; includes
  `Session.swift:188`'s `unnamedGuest = "Classic Mac"` fallback) get
  replaced with the matching `MachineNaming.*` call so they can't drift
  again. Two sites deliberately left (they name a file format / an OS).
- The guest-side question (whether the vocabulary applies there) is
  discussion — Part 2, D8.

### Slice E — guest mechanical fixes (all S unless noted)

- **G8 — connect on edit:** in `connection_module.c`, the `g_edit`
  branch (~618-634) ends by staging values and asking for a Save click;
  replace its tail with `do_save(true)` — the same force-connect path
  the Connect button uses. ~4 lines.
- **H13 — overview formatting:** both fixes in
  `census_probes.c`, no contract/host change (the host renders guest
  strings verbatim by design). Storage: add a MiB-input formatter
  (MB/GB/TB) for `gather_overview()`'s Storage block (:370-396). CPU:
  add a static Gestalt code→name table (601/603/603e/604/604e/750="G3"…)
  used by both `gather_overview()` (:296-302, e.g. "PowerPC G3 (750) @
  292 MHz") and `gather_identity()` so overview/identity/console stay
  consistent per command parity.
- **G3 (part 1) — chat boxes white:** `draw_transcript()`/`draw_input()`
  in `chat_module.c` `EraseRect` without setting `RGBBackColor`, so they
  erase to the window's gray theme brush. Wrap the 4 erases with the
  save/set-white/restore pattern already used 3× in
  `workshop_sidebar.c`. (Part 2, the sidebar list, is discussion — D6.)
- **G2(a) — Development button overflow:** one shared
  `kButtonWidth=132` (`development_layout.c:3-9`) vs labels needing
  ~190-210px; body width has room. Per-button width constants.
- **G10a — ⌘O opens Workshop:** the Windows▸Workshop item
  (`main.c:153-155`) has no cmd-key; `MenuKey` routing and the handler
  already exist. Add `/O` to the item string. (⌘N left free for a future
  "new" verb; ⌘W/⌘Q/⌘1-0 taken.)
- **G10b — persist Workshop open/closed (M):** add
  `workshop_open_at_quit` to NowPrefs (V27, accretive per `prefs.c`
  convention, default true); give `workshop_close()` a `quitting`
  parameter so user-close records closed and quit-teardown records open;
  gate the unconditional `workshop_open()` at `main.c:462` on the pref.
- **G11b — guest-originated receive cancel:** `now_wire_get_cancel`
  exists for pulls; the push/receive direction has no equivalent
  (`docs/contract-coverage.md` documents the gap). Add
  `now_wire_put_cancel` mirroring it — send `file.cancel` with
  `g_put.id` per the existing FileCancel schema, then the same
  `put_abort` cleanup. Contract already has the message; coverage doc
  updates in the same commit.

### Slice F — guest observability & citizenship (from the U14 review)

- **I3 — `describe_scene` on every page (M).** Only 1 of 17 modules
  implements it (`screenshots_module.c:593`), so the host's observation
  plane sees chrome and no content on 16 pages. Plan: implement per
  module (emit the strings/rects `draw()` already computes, using
  `workshop_scene.h` kinds); add a **source gate** on the
  `control_kind_source_test.py` pattern that fails the build when a
  module's `draw()` calls DrawString/DrawText with a NULL
  `describe_scene`, registered in `scripts/test-native`'s manifest;
  document the requirement in `docs/adding-a-workshop-module.md`. Watch
  the gate fail by NULLing screenshots' entry before trusting it.
- **I5 — About box (S).** No Apple menu at all today; version+build
  shown only on the Connection page. Add the Apple-menu MENU resource,
  "About New Old World…", movable modal on the `confirm.c` pattern
  (never an ALERT — OS 9 speaks those aloud) showing name, `vers`, and
  `now_build_stamp()`. Cheapest close on the list given how much
  diagnosis turns on "which build is this machine running".
- **I8 — title parity gate + tier in rail (S).** `tools/docs-gate`
  compares id/tier/domains/feature_id but **not title**, so three
  features are named differently across the halves today
  (Screen/Screenshots, Connections/Connection, Web Proxy/Web). Add
  `title` to the compared fields; resolve guest titles (keep any
  deliberate difference only if recorded with a reason in the manifest);
  draw the definition's tier as a right-aligned label in the
  rich-density rail row (the guest currently can't show that six of its
  pages are experimental). Watch the gate fail by reverting one title.

Every guest UI slice: load `classic-mac-carbon-ui` first and run its
`audit_source.py` after, per CLAUDE.md. New verbs respect command
parity. Everything above is **Builds/Tested** territory until someone
watches it on metal — H4's trash fix in particular wants a
metal-verified pass since `fBsyErr` is system-dependent.

---

## Part 2 — DISCUSSION agenda

Each with grounded options and a recommendation. Ordered roughly by how
much they gate other work.

### D1 — Module identity: Networking / Diagnostics (H8, H12, G4, G5)

The two thin modules are thin for the same reason: NOW's two best wire
instruments are hidden — `wirestat` (guest-served, contract-declared,
**zero host readers**; the instrument that settled the 86 ms scene
round-trip question, reachable only by typing into a console) and the
link's own RTT/window timing (buried as card 1 of host Networking).

- **Host Networking (H8):** today a pure renderer of the guest's `net`
  verb, sitting in the network shelf. **Recommend: move it to the
  Machine shelf** beside Hardware/Software (it's a facts page about the
  guest machine), and give the instrument content to Diagnostics instead.
  The big alternative — an active bench (extract the parent's `net.bench`
  probe grammar + sweep method from `wsp_net.c` / `Networking.swift` by
  audited extraction) — is written up in U7's notes as a held plan;
  parent findings already show the one real target machine is
  window-insensitive above 4K, so a tuning UI would mostly prove "flat".
- **Diagnostics (H12/G5): recommend GROW, both apps** — add `wirestat`
  as a fourth instrument (one enum case host-side, one card + probe arm
  guest-side, no contract change), move the link timing rows in with it.
  Read-only: `wirestat`'s wake/sleep setters stay console-only, because
  a diagnostics page that changes the machine's scheduling no longer has
  a statable cost. Fallback is KEEP; KILL/FOLD renumbers the guest page
  enum and breaks persisted selections for two rows of content.
- **Guest Networking (G4): recommend keep four cards but arm card 1** —
  a "Test" button that forces a ping now and refreshes RTT (guest
  already originates pings and times RTT in `wire.c`; no contract
  change), and shrink the "why there is no connection list" essay card
  to its one-line placard form. Splitting the link card out entirely
  would leave the page empty on exactly the machine class the product
  exists for.
- **Open:** does the link belong to Networking or Connection(s)? The
  guests currently answer "both", the host answers "Connections" —
  pick one and both sides follow it.

### D2 — Development → rename (H9) and guest parity (G2 b-d)

- **Rename: recommend "Projects"** (module id `projects`). The module
  is ~70% project catalog and everything around it is already named
  Projects (ProjectStore, `Project.ckp`, `now_projects`). "Development"
  names an activity, reads as "IDE", and the plan of record refuses the
  IDE framing. Rename is cheap and safe: `ModuleRegistry.renamedIDs`
  exists for exactly this, and the guest's persisted page id is the enum
  number, not the string. One commit covers host + guest + manifest +
  docs page + nav + screenshot slots; MCP tool names (`now_development*`)
  stay put in that commit (renaming a tool breaks callers) and get
  decided separately. Alternative on the table: "Build".
- **Guest projects/jobs (G2 b-d): recommend the guest-local package** —
  a `development-projects` list verb (the enumeration already exists
  unexposed: `find_project()` walks every project parsing `Project.ckp`
  just to match one ID), a persisted `active_project_id` NowPrefs field,
  a small in-memory job-history ring (~8 summaries), a flat DataBrowser
  list + detail (proven pattern: `processes_module.c`), and Build/Run
  buttons sharing the existing command implementations per parity. The
  host already has picker + Build/Run — the guest is the side that's
  behind, which is exactly the gap class the parity rule exists for.
- **Open:** does job history need to survive relaunch, or is
  session-scope fine (recommend session-scope first)? Do staged
  candidates appear in the projects list (recommend no — keeps the
  projectID/candidateID spaces clean)?

### D3 — Host Connections reorg (H14, L)

Roster to a collapsible **right** sidebar: the exact pattern already
exists as Files' `FilesRightSidebarSplitView` (NSSplitViewController,
toggle, hover-to-peek rail, spring-loading). **Recommend generalizing
that into a shared component** rather than a second implementation —
with the wrinkle that collapsing the roster removes the primary way to
switch machines (unlike Files, where the right pane is secondary), so
the collapsed rail needs a machine-switching affordance (hover-peek
list, or a compact machine menu in the rail). Also: `ConnectionLinkSection`
and `ConnectionListenerLog` currently live in `SettingsModuleView.swift`
— the cleanup moves them home. **Open:** what must still work while
collapsed (switch? add?), and whether extracting the shared component is
in scope now or Connections gets the first copy.

### D4 — Chat: chats & projects (H11 host, G3 part 2 guest)

There is **no multi-chat or project model anywhere** — host keeps one
in-memory conversation, guest one per connection, no contract verbs.
So the sidebars are gated on a data-model decision:

1. Session-only chat list, no persistence (smallest);
2. **Persisted host-side chats (JSON on disk), projects later, no
   contract change — recommended next slice**;
3. Full chats+projects with contract verbs so the guest can browse
   them (largest; blocked on the questions below).

**Open:** what is a "project" here — a folder of chats, or a chat with
inherited system-prompt/model defaults? Should the guest see host-side
chats at all (that's new contract surface)? And do transcripts persist
to disk given they can contain guest-screen content (privacy call)?
Guest sidebar note: hierarchical Data Browser is recorded as not viable
on metal — whatever lands uses the proven flat-list pattern.

### D5 — Settings restructure (H17)

Inventory finding that reframes the item: the module registry's
"settings" id **is the Connections page**; the real Settings surface
(⌘,) is a standalone NSWindow holding only Appearance, outside the
module system entirely. Files and Screenshots already implement the two
patterns the item proposes (internal pill-tabs; a Settings button
opening a sheet). **Recommend:** build the pill-tab Settings window
(reusing Files' pill pattern) with a deep-link seam
(`showSettings(selecting:)` + a settings-navigation closure in module
context); move the clearly-global preferences there (sidebar
rows/collapse, MCP start-automatically, Web compat/safety, Logs
log-to-disk, and H1b's new toggle); leave Files'/Screenshots' in-module
panes alone (they solve locality well, and Screenshots' split is a
documented design decision); leave Continuity's settings in-module
(they're keyed per-machine — a global tab has no home for them).
**Open:** do Mirror's "Development controls" belong in user-facing
Settings or a debug-tier surface? Does Continuity get a
"defaults for new connections" presence in Settings?

### D6 — Guest Files pass (G7)

The module mixes two unrelated concerns under one disclosure triangle
("Shared from this Mac" gates both sharing *config* and send/receive
*controls*), the remote browser has no heading saying whose files it
shows, "Get files into: X" is a button masquerading as a label, and the
single status placard has four independent writers that clobber each
other. **Opinionated first pass to react to:** split into "Their Files"
(top, always visible, the browser) and "My Shared Folder" (bottom,
disclosure-gated), with sharing-config and send/receive as visually
separate rows. Full label-by-label inventory in U12 notes. **Open:**
how much restructuring vs. relabeling do you want this pass? Is the
four-writers placard a separate correctness fix? Is `catsearch.c` (285
lines, wired to nothing) a future search field or deletable dead code?

### D7 — Guest Mirror module (G6)

The four guest checkboxes are **not** accidental duplication: the
contract (~asyncapi line 7431) states the two-key design — guest gates
are application preferences, host toggles are policy, *both* must
permit. Collapsing the guest to enable/disable/show-on-host would
remove a named safety property. The real problem is the two sides'
names don't map (guest: observe-structure/Finder-details/trace-drawing/
foreground-discovery; host planes: structure/semantics/content/
interaction/transitions), so nobody can tell which gate backs which
toggle. **Recommend: rename the guest checkboxes to map 1:1 + one
explanatory line ("the other Mac must also enable each of these") now**;
hold the tabbed Screen-shelf restructuring (mirror/continuity/
screenshots tabs) as the target once `refactor/mirror-continuity-split`
lands and we can see the host's final shape. Per the decisions log: no
file conflict with that thread, conceptual alignment only.

### D8 — Does "This Mac / Guest" reach the guest app? (G9)

The guest has its own **already-consistent egocentric scheme**: "This
Mac" = itself, "the other Mac" = the counterpart (rationale written in
`network_module.c:71-73`). Applying the host vocabulary literally would
make the classic Mac call *itself* "Guest" on its own screen.
**Recommend: the This-Mac/Guest decision is host-UI vocabulary; the
guest keeps its egocentric scheme.** (This also matches the U14
philosophy below.) If you want it product-wide instead, it's a ~30-site
hand edit across 12 files and a deliberate redesign of the guest's
self-reference, not a find/replace.

### D9 — Guest holistic review (G1) — a position to react to

**"Mirror the host's vocabulary, never its gestures."** The halves must
agree on what capabilities exist, what they're called, and what is true
(contract, manifest, parity gates); they must not agree on how any of
it is reached. A host feature the guest can express in an OS 9 idiom
gets the idiom, not the host's control; one it can't express becomes a
*declared* asymmetry (the `ppc_pages: []` pattern), never a hole; a
guest idiom the host lacks stays. The failure mode isn't "the guest
looks different" — it's "the guest looks like a port". U14 also
catalogued nine existing divergences that are deliberate craft (movable
modals because OS 9 speaks alerts aloud, hand-drawn hover tags because
Carbon help tags don't display, …) and proposes recording them in
`docs/guest-ui-start-here.md` so reviewers stop reading them as gaps.

Concrete items it surfaced (beyond the locked I3/I5/I8):

- **I1 — no Drag Manager anywhere** (and no FREF for Finder icon
  drops, no `kAEOpenDocuments` handler while the guest *sends* it in
  four places). Recommend drop-only first (receive handlers + FREF):
  drop is the gesture that makes the guest stop feeling like a control
  panel; a drag *source* from a Data Browser is the bigger riskier half.
- **I2 — no clipboard at all**: console output, census numbers, the
  connection address — nothing can leave the machine except by
  photograph. Recommend a single Copy item dispatched through a new
  optional `WorkshopModuleOps` "selected text" entry (the module
  answers, sidestepping the no-focus problem), extending page by page.
- **I4 — the default rail shows 11 of 14 rows** at the app's own
  standard size (10 on a 640×480 screen), and the below-the-fold pages
  are exactly the newest four. Recommend defaulting to compact density
  (fits all 14); independently the View menu's cmd-keys run out at ten
  on the same pages.
- **I6 — Continuity has no face at the machine**: while the other Mac
  drives this one, nothing on the guest says so. Recommend a status-line
  placard "Being driven from <peer>" + a Stop that disarms; not a new
  page. Open: should the guest be able to *refuse* Continuity
  persistently, or only end a live epoch?
- **I7 — rail order is build order, not product order** (the layout
  header's own comments prove it). Recommend a `k_default_order[]` the
  sidebar seeds from when prefs carry no saved order — ids untouched, no
  renumbering, and write the adjacency argument in prose like the host
  registry does.

### D10 — Spring-load residuals (H7, and H6 verification)

- **H7 (can't spring-load into connections shelf):** grounded
  hypothesis: `NavigationRowDropTargets.target(at:)` splits rows into
  thirds with no first-contact grace, and `previewDrop` applies zone
  moves **eagerly during hover** — so approaching the pinned network
  shelf from above resolves to the "before" zone and visibly pushes the
  shelf out from under the stationary cursor before spring-loading can
  arm. Plan: live-verify the hypothesis, then widen the center hit-band
  (helps every shelf); the alternatives (dwell before preview-moves;
  special-case pinned shelves) stay on the table if verification
  surprises. Not locked only because the mechanism is unconfirmed.
- **H6:** verify the shipped double-flash live; close or tune, don't
  rebuild (Part 0).

### D11 — Small taste calls (quick yes/no)

- **H10 chevron:** recommend `NSSymbolEffect` `.bounce.up` on the
  chevron icon only, layered over the existing subtle rail
  scale+tint (macOS 14+ `#available` gate, same pattern as the existing
  macOS 26 gates). Needs: confirm deployment floor tolerates it, and
  confirm Part 0's control identification.
- **G11a transfer-progress shape:** recommend **floating windoid** over
  modal dialog — the requirement itself ("shows whether or not the
  Workshop is open", multi-minute transfers measured in
  `docs/68k-file-receive.md`) argues against blocking the app. Reuses
  the progress-bar/cancel controls `files_share_view.c` already builds;
  the receive-progress plumbing already exists in `wire.c` with no UI
  consumer for plain host pushes. G11b's cancel lands in this windoid.
  Effectively locked unless you object to a windoid.

---

## Part 3 — Sequencing

1. **Now, parallel-safe:** Slices A–E (independent, small, no design
   gates). Slice F after A–E (I3 is the big one).
2. **After discussion:** D1/D2 renames + module moves (each is one
   coherent commit spanning registry/manifest/docs per the docs rules);
   D3 connections reorg; D4 chat model; D5 settings window.
3. **Gated on `refactor/mirror-continuity-split` landing:** D7's
   restructuring half (rename-for-clarity half can go earlier).
4. **Metal pass at the end:** H4's trash fix, G10/G11 guest UX, I3's
   scene coverage — code-read fixes on system-dependent behavior stay
   "Tested" until watched on the PowerBook.

Gates for all of it: `scripts/test-all`; guest work adds the
carbon-ui skill audit; docs/manifest changes run `scripts/test-docs`;
contract-coverage and mcp-coverage re-derive in the same commits that
change what they derive from.

## Part 4 — Research provenance

14 units, 15 agents (12 sonnet, 2 opus, 1 haiku path-validator), all
completed; ~1.8M subagent tokens. Per-unit notes:
`docs/local/assessments-034/U1..U14.md`. Path validation: one cited
path was wrong (`NavigationLayoutTests.swift` — actual location
`now-host/Tests/HostTests/`); corrected here. Findings are code-read
only; nothing in this document was live-verified on a running app or
metal, and items whose classification depends on live behavior (H6, H7)
say so inline.

## Decisions log

- 2026-08-14 (Michelle): `refactor/mirror-continuity-split` is
  host-side; U12/G6 is guest-side — no file collision, conceptual
  alignment only; G6's final shape waits on that merge.
- 2026-08-14 (assembly): H4 uses a shared trash-move helper (not a third
  copy); watchdog starts at a flat 3 min. H3 ships without a format
  picker (single artifact shape). G10a uses ⌘O. G11a recommended as
  floating windoid pending veto.
