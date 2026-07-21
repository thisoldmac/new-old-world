# The Processes page, and the extension behind it

This is the spec for the Workshop's Processes module and for the ladder
it starts: the NOW Extension (resident, optional), the `process.*` and
`peek.*` wire families, and — at the top — a host-side mirror that
recreates the guest desktop from Toolbox data rather than pixels, and
can eventually drive it. Rung 0 needs none of that and ships alone.

Read [adding-a-workshop-module.md](adding-a-workshop-module.md) and
[guest-ui-start-here.md](guest-ui-start-here.md) first; this spec
assumes both. Prior art and evidence live in the parent corpus:
`observe-process-local-ui` (the per-process wall, and what still works
across it), the AXPeek/axtree rungs (semantic trees are real and cheap
on metal), and the mirror spike (a live semantic mirror of mac99 worked
end-to-end). We rebuild fresh; the findings are what carry.

## The ladder

| rung | what ships | needs | status |
|---|---|---|---|
| 0 | Processes page: list, front, ask-to-quit | nothing new | **metal-verified** (2026-07-21) |
| 1 | NOW Extension M0: residence, discovery, versioning | the extension | **metal-verified** (2026-07-21) |
| 2 | Anchor plane: per-process window bounds; cropped Front & Capture | ext P1 | |
| 3 | `process.*` wire family; host sees the guest's processes | contract | |
| 4 | Semantic tree; `peek.*` family; host tree view | ext P2 | |
| 5 | Host mock desktop (scene IR, native renderer) | 3 + 4 | |
| 6 | Interiors: bounds-cropped pixel fill inside the mock desktop | 2 + 5 | |
| 7 | Drive: actions routed back at stable refs | much later | |

Each rung is independently useful and independently verifiable. Nothing
below rung 1 installs resident code. Rung 1's code lives in
[`ext/`](../ext/); its metal test plan is in
[open-issues.md](open-issues.md).

## Rung 0 — the Processes page

### Target contract

Same as the application: CarbonLib 1.6 on Mac OS 8.6–9.2.2, PowerPC,
`WaitNextEvent` loop, 620×430 minimum body. Everything this page calls
at rung 0 — Process Manager walks, `SetFrontProcess`, Apple Event
sends, Data Browser — is CarbonLib 1.6 baseline. Data Browser is
metal-verified at 9.1 (`carbon-databrowser-usable-carbonlib-16`) and
**provisional at 8.6** until the 8.6 boot gate exists; it is already a
hard dependency of the Files page, so this page adds no new fallback
obligation.

### Data model

One snapshot struct, refreshed by walking the Process Manager:

- key: `ProcessSerialNumber` (both longs — the identity actions bind to)
- name (`Str31`, drawn as MacRoman)
- type and signature (two 4CCs; "Kind" renders type, e.g. `APPL`/`appe`)
- partition: `processSize`, and used = `processSize - processFreeMem`
- launch date (`processLaunchDate`, drawn with `LongDateString` only —
  `classic-datestring-clamps-past-1972`)

Header facts, from the same refresh: process count, `TempFreeMem`,
`MaxBlock`. **Never `FreeMem`** — it sees only our own heap, which
Retro68's malloc drains at startup (comment carried from tbt's
`mod_state.c`, where this bit).

### Refresh policy

`idle()` runs every pass and must be nearly free, so the walk is
throttled: at most once per 60 ticks, compare the new snapshot against
the cached one (count, PSNs, sizes), and touch the Data Browser only
for rows that changed. The `g_shown_*` cache idiom every module uses.
A walk over a dozen processes is cheap; doing it every pass during a
transfer is not.

### UI

A split view (`compute_rects` fills both panes' rects from the body
rect; click and draw read the same numbers). The split is fixed — a
draggable splitter is a custom control this rung does not buy.
Mockup: [mockups/processes-mockup.html](mockups/processes-mockup.html).

- **Left: the list** — a Data Browser in list view,
  `files_browser_view.c` pattern, one sortable Name column (icon via
  `GetIconRef` on type/creator + text). Header sorting works;
  type-select does not (documented limitation, not a migration
  invitation). One row selected at a time. Dispose callback UPPs after
  the window is gone, never before.
- **Right: the detail pane** — the selected process, drawn by the
  module itself: name, kind, `type / creator`, memory as text **and**
  the About-This-Computer bar (plain QuickDraw in our own pane — the
  split view is what makes the bar free; as a Data Browser custom
  column it was provisional), launch date. Below the facts,
  `Bring to Front` and `Ask to Quit` push buttons (tracking pumps via
  `now_pump_action`). At the bottom, a "NOW Extension" group box that
  always states the peek status honestly and is where each later
  rung's affordance lands — front-window bounds and Front & Capture at
  rung 2, windows and controls at rung 4 — so the ladder grows the
  pane instead of redesigning the page.

The detail pane repaints only when the selection or a shown value
changes; the throttled walk diffs into both panes.

`status_text`: `"7 processes - 12.4 MB free"`. ASCII only.

### Actions

**Bring to Front** — `SetFrontProcess` on the row's PSN. Proven
cross-process (`observe-process-local-ui`).

**Ask to Quit** — the honest name, because that is all it is: a
`kAEQuitApplication` Apple Event, `kAENoReply`, to the row's PSN. The
flow, carried from the runner's reap ladder:

1. Confirm with a movable modal (`confirm.c` — pumps the wire; Mac OS
   reads alerts aloud, movable modals it does not).
2. Send. On `noErr` the row shows `(quitting...)`.
3. **Keep the PSN until the walk proves the process gone.** A sent quit
   is not a completed one; a slow cooperative app is still exiting, and
   a wedged one will ignore the event forever. That is the ladder's
   honest limit — there is no safe force-quit here and we do not offer
   `KillProcess`.
4. If the row survives ~10 seconds, the annotation becomes
   `(not responding to quit)` and stays until it exits or the user
   moves on.

Guard: the row for our own PSN (`GetCurrentProcess`) disables Ask to
Quit. Everything else is the user's machine and the user's call.

### The six edits, instantiated

1. `workshop_module.h` — `kWorkshopProcesses` inserted before
   `kWorkshopConnection`; `kWorkshopModuleCount` 4 → 5. Connection's
   value moves 4 → 5, which is why edit 6 below exists.
2. `workshop_layout.h/.c` — `nav_rows[3]` → `nav_rows[4]`; the loop in
   `workshop_layout_compute` follows. Four rows at 32 px still fit the
   430-minimum rail with the pinned Connection row.
3. `workshop_sidebar.c` — `k_rows` entry: title "Processes", subtitle
   "Running applications", new `ics#` icon ID. `row_rect()` maps
   non-pinned rows by `module - 1`, so insertion is free.
4. `workshop_window.c` — `k_module_info` entry (title, blurb,
   placeholder line) and `processes_module_ops()` registered in
   `workshop_open()`.
5. `main.c` — View menu gains "Processes" as item 4 with Cmd-4, and
   Connection moves to item 5 / Cmd-5: the menu item number IS the
   module ID, so the keys follow the numbering rather than muscle
   memory. The existing dispatch holds unchanged.
6. `guest/CMakeLists.txt` — `processes_module.c` (+ `proc_snapshot.c`
   if the walk/format code splits out for native testing).

Plus the icon: a 16×16 `ics#` in `guest/resources/app.r`, drawn with
`plot_small_icon()` — never `PlotIconID`
(`ploticon-suite-loses-to-system-family`).

**Prefs remap** — `prefs.workshop_module` persists the enum value, and
Connection moves 4 → 5. On load, when the record's format predates the
bump and the stored value is 4, read it as Connection. Three lines in
the prefs path; the alternative is every existing prefs file reopening
on the wrong page once.

### peek.h ships at rung 0, answering "no"

The page lands with the extension's client seam already in place:

```c
typedef enum {
    kNowPeekNotInstalled,   /* no Gestalt, no file            */
    kNowPeekNeedsRestart,   /* file in Extensions, no Gestalt */
    kNowPeekWrongVersion,   /* Gestalt answered, major differs */
    kNowPeekActive
} NowPeekState;

NowPeekState now_peek_status(unsigned long *caps);
```

At rung 0 it returns `kNowPeekNotInstalled` unconditionally and the
page renders one quiet line — "NOW Extension not installed" — where
extension-backed affordances will appear. The four states and the
capability word are the product's graceful-degradation contract, and
the UI learns to render them before the extension exists.

### Tests and verification

- `compute_rects` and the formatters (4CC → text, KB, partition
  string) compile as pure units with the host `cc`, the
  `workshop_layout_test.c` pattern. Watch each fail first.
- The walk, actions, and Data Browser behavior are Toolbox-bound:
  emulator pass, then the PowerBook. *Builds* proves nothing; the page
  is **tested** when the native suites pass and **metal-verified** when
  someone watches it list, front, and quit real processes on the
  1400c.
- Run the `classic-mac-carbon-ui` skill's `audit_source.py` over the
  new sources before calling it done.
- 8.6 remains an open gate for the whole application; this page adds
  Data Browser-at-8.6 to the list of claims waiting on it.

## The NOW Extension

One file, one installer checkbox, one restart story. Not tbt's
sibling-INITs shape — but it must keep the two things that shape was
buying, by internal discipline instead of separate binaries. The
family charter — tiers, table rules, identity codes, verification
gates — is [resident-components.md](resident-components.md); this
section is the ladder-specific view.

### Domain rules

**Boot-minimal frozen core.** The only code that runs at boot: a
chained jGNE filter, the shared table, one Gestalt selector. The core
reaches done at M0 and then changes rarely; it is the part whose
failure would need a shift-boot, so it stays small enough to audit
exhaustively.

**Planes, dormant until armed.** Every capability beyond the core is a
plane: dormant code that executes only after the application writes an
arm request into the table, and the filter — already running in the
target context — performs any in-context installation. Disarm works
the same way. The failure boundary is *which code has run*, not which
file shipped; a machine that never opens the mirror never executes a
draw hook.

**Planes talk only through the core.** Separate translation units, no
cross-plane calls. The discipline tbt enforced with separate binaries,
enforced here in source.

**The table is a contract, stated once.** One header — `peek_table.h`
— compiled by both the 68K extension and the PPC application, with
static asserts on size and field offsets (the `qdpeek.c` idiom; two
compilers sharing a struct is exactly where silent packing drift
bites). Prelude: magic, extension version, table length, then a
per-plane block of {format, capability bits, heartbeat/freshness}.
Compatibility is accretive and per-plane: exact major, `length >=`
what you read.

**Freshness is per-slot and honest.** Anchors are captured when a
process pumps its event loop, so a faceless or wedged app has an
absent or stale slot — distinct states, both rendered truthfully by
every consumer up to and including the mirror. Slots carry a ticks
stamp; readers decide staleness, the extension never guesses.

**Foreign-memory reads live in the application, never the extension.**
The extension publishes anchors; the app follows them with
partition-validated, bounded reads that fail closed. The risky logic
stays where a file copy can fix it.

**Dev builds are their own INITs.** An unproven plane is developed as
a throwaway extension under an honest name on the QEMU clone, and
folded into NOW Extension only after its evidence ladder passes.
Users see one file; experiments get isolated blast radius.

### Planes, as currently foreseen

- **P0 — core.** Residence, chaining, Gestalt, heartbeat. M0 exists to
  run the INIT evidence ladder end to end: clean boot, shift-disable,
  removal, repeated restarts, on emulator then metal. The Processes
  page's status line is its first consumer.
- **P1 — anchors.** Per-process `CurrentA5`, `WindowList`, `MenuList`,
  ticks stamp, with the cheap changed-anchor early-out (AXPeek's
  measured envelope: 0–1 tick on a 33 MHz 68040; the 1400c runs the
  filter under 68K emulation, so the early-out is not optional).
  First app payoff: front window bounds → cropped Front & Capture
  (partial VRAM reads scale linearly — the crop is also the fast
  path).
- **P2 — semantic assist.** Whatever the tree walk needs beyond
  anchors. May be empty: tbt's Worker built full trees from anchors
  alone.
- **P3 — content.** QuickDraw bottleneck hooks, the full Timbuktu
  move. The riskiest code class here; it ships dark, arms per-port on
  request, and does not exist until the mirror needs interiors better
  than pixel fill.

Deferred by design: the Tier B background app (`'appe'`) for
launch-NOW-when-closed, and the possibly-single-file `'appe'`+INIT
packaging — recorded as probe-required, decided when the requirement
is real.

### Known INIT-side probes

- Boot the extension on 8.6 (loader behavior, size ceiling — AXPeek
  proved ~51 KB loads at 9.1; 8.6 unproven).
- jGNE coexistence next to era-typical third-party residents.
- Cold-boot cycling on QEMU needs the hard-restart recipe: OS 9
  ignores soft power-down, and INITs load at boot only.

## The wire, when the ladder reaches it

Rung 3 adds the first symmetric family to `contract/asyncapi.yaml`
(the change starts there, both halves follow):

- `process.list` / `process.listing` — whoever receives serves its own
  share: the guest answers with the Process Manager walk, the host
  with its own process list. The listing is the mirror's degraded
  plane (tbt's spike mirrored process list + front app at ~1.2 ms per
  poll with no extension at all), so it is worth having before the
  semantic tree exists.
- `process.front`, `process.launch`, `process.quit` — the page's
  actions, offered to the peer. The host receiving `process.launch`
  opens an application via NSWorkspace; the guest receiving it calls
  `LaunchApplication`. Host-launches-guest-app needs nothing resident
  as long as NOW is running, because the wire terminates in NOW.

Rung 4's `peek.request` / `peek.tree` carries the semantic tree with
stable, pointer-free refs. Design it snapshot-first but
delta-friendly: the mirror will poll or subscribe at a few Hz, and
the `stream.*` family is the in-contract precedent for a subscription
shape. Refs must be stable and serializable from day one — they are
what rung 7's actions bind to, and what makes an interactive mirror
(click the mock desktop, drive the real machine) possible at all.
Every emitted message needs its conformance fixture; multi-`snprintf`
builders fail the suite until they have one, deliberately.

## The mirror, as a north star

The tbt spike proved the idea end to end on mac99: adapter → scene IR
→ renderer, drawing the guest's real windows, z-order, menubar and
controls from semantic state, `bytesScanned=0`, interiors honestly
absent. Two of its rules become requirements here:

- **The renderer never sees the wire.** Adapters are the only
  wire-touching code; the scene IR is the boundary. This is what makes
  the render surface swappable — NOW's host app natively today, and
  someday a lighter desktop-emulation surface (we need Platinum
  chrome, not CPU emulation) with the same IR feeding it and input
  events routing back as rung-7 actions.
- **Degrade by tier, render the gap.** No extension → process plane
  only. Anchors → geometry. Tree → structure. Pixel fill → interiors.
  Each tier is honest about what it does not know.

Asset extraction for the Platinum chrome is its own work item when
rung 5 starts; tbt's `extract-assets` shows it is tractable.

## What lands when

Rung 0 is one branch: the module, the six edits, the icon, the prefs
remap, `peek.h` answering no, native tests for the pure parts. Every
later rung starts with its own contract edit or extension milestone
and ends by updating [open-issues.md](open-issues.md) — including the
rungs that go well.
