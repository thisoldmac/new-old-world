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
| 2a | Anchor plane + per-process validated window read | ext P1 | **metal-verified** (2026-07-21) |
| 2b | Front & Capture crops to those bounds | 2a | **metal-verified** (2026-07-21) |
| 3 | `process.*` wire family; host sees the guest's processes | contract | **metal-verified** — the host Processes module drew the PB1400c's table over the wire (2026-07-21) |
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

### `quit <name>` — the same action, named the way a person names it

The page acts on a selected row and the wire verb acts on a PSN. Neither
is usable from a loop that only knows *"NetPresenz"*, and that loop — 
deploy, quit the server, probe, relaunch — is the reason `launch` exists
without its opposite number being a gap anyone could live with.

`quit` is therefore a **composition**, not a new capability:
`process.list` → match by name → re-validate → `process.quit` →
**`process.list` again**. It is a console command and an x-command
(`contract/asyncapi.yaml`), it shares `now_proc_ask_quit` with the page
and the wire verb, and its argument grammar lives once in
`proc_quit_args.c` (Toolbox-free, unit-tested on the host) so the console
path and the wire path cannot drift — and so the planned 68K client
mirrors a file rather than re-deriving a grammar.

**The re-list is the feature.** `now_proc_ask_quit` returning `noErr`
means the Apple Event was *delivered*, and nothing more. Every outcome the
composition can produce is reported distinctly, as its own machine-
readable `Outcome` row beside the sentence:

| Outcome | means | `ok` |
|---|---|---|
| `gone` | asked, and a re-list confirms it is not there | true |
| `not-running` | nothing of that name was running to ask | true |
| `sent-unconfirmed` | `--no-wait`: delivered, deliberately unverified | true |
| `still-running` | asked, and STILL THERE at the deadline | **false** (`quit-declined`) |
| `ambiguous` | several processes share the name, no `--all` | false |
| `refused-self` | the only match was our own process | false |
| `undeliverable` | the Apple Event Manager would not send it | false |
| `bad-args` | the argument line did not parse | false |

`still-running` answering **`ok:false`** is the load-bearing decision. A
`quit` is a request; an application holding an unsaved document stops to
ask about it and keeps running (watched on the emulator: SimpleText with
one typed character sits on "Save changes to the document 'untitled'
before closing?" and the verb answers `quit-declined`). A caller whose
next step assumes a freed port must not read that as success — a `quit`
that reported success while the process was still up would poison every
measurement built on it, silently, from the first iteration.

The cases the composition creates, and what each does:

- **No match** — `not-running`, and *not* an error: the asked-for state
  already holds, which is exactly what a redeploy loop wants to hear on
  the pass after the last one worked.
- **Several matches** — refused with a count. Quitting an arbitrary copy
  is worse than doing nothing; `--all` quits every match.
- **A race** — the listing is already in the past, so each target is
  re-validated (`GetProcessInformation`) immediately before the send, and
  one that died in the gap is simply not asked. Liveness also compares the
  *name*, because a PSN can be reused: "live but differently named" counts
  as gone. Wrong only in the safe direction — never `gone` for a live one.
- **Ourselves** — refused. Quitting NOW while it is composing the reply
  severs the reply. A second, separate *copy* of NOW is a legitimate
  target, so the walk skips only its own PSN rather than the name.
- **The Finder** — not special-cased. The verb is honest, not paternal.

Names match by `EqualString` (case-insensitive, diacritic-sensitive), and
the name is the whole rest of the line so flags are **leading** — a
trailing token cannot be told apart from the last word of a process name,
and process names have spaces in them.

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
6. `now-guest-ppc/CMakeLists.txt` — `processes_module.c` (+ `proc_snapshot.c`
   if the walk/format code splits out for native testing).

Plus the icon: a 16×16 `ics#` in `now-guest-ppc/resources/app.r`, drawn with
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
  ticks stamp — plus, appended since, the stack base and the process's
  own name — with the cheap changed-anchor early-out (AXPeek's
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

### Rung 2 — the anchor plane (P1), in detail

The first plane that produces data the app cannot get itself, and the
first foreign-memory read. Three parts, split so the risky one is
smallest and isolated.

**What the filter captures, and how it is keyed.** The jGNE filter
already runs in every process's context. When armed, it reads the
low-memory globals of *that* context — `LMGetCurrentA5`,
`LMGetWindowList`, `LMGetMenuList`, `LMGetCurStackBase` (V2) and
`LMGetCurApName` (V3) — and a `LMGetTicks` stamp, into an anchor slot.
Nothing else: no Process Manager call (forbidden the lesson-hard way
from resident code), no allocation, no toolbox that moves memory. The
stamp is written last, as the slot's commit, so every field a reader
pairs with it was written before it. Slots are **keyed by A5**, not
PSN — A5 is a cheap, unique-per-process low-memory read, and getting
the PSN would mean a Process Manager call this context must not make.
That split is AXPeek's: the resident code observes low memory; the PSN
correlation happens later, in the application.

Slot management, all O(32) scans (cheap, and the changed-anchor
early-out keeps the common pass near-free): match the current A5, else
take an empty slot (`a5 == 0`), else recycle the stalest. A quit
process leaves a slot whose stamp stops advancing; the app judges it
stale. A5 reuse by a later process is self-correcting — the next pass
overwrites with that world's fresh `WindowList`. `anchor_format` flips
`None →` whatever format this binary publishes — V3 today; the slot's
`psn_*` fields stay zero (the extension never fills them), which every
format documents.

The format word is the reader's only gate on the newer fields. Each
version **appends**, never inserts: `stamp_ticks` keeps offset 20 so
the seqlock stays where a V1 reader left it, and `stack_base` keeps 24
across V3. So a shorter table's bytes for a field it never had are not
absent, they are whatever the shorter struct left there — gate on
`anchor_format`, never on a value being nonzero.
`contract/peek_table.h` is the authority for the slot layout, the
format enum, and that rule.

**The arm handshake — the plane's first real exercise.** P1 is dormant
until asked. The extension advertises it (`caps |= CapAnchors`) but
captures nothing until the app writes `arm_request |= CapAnchors`; the
filter, seeing the request, begins capturing and sets
`arm_active |= CapAnchors`. Disarm reverses it. One writer per word:
the app owns `arm_request`, the extension owns everything else. A
machine whose user never opens a bounds-consuming feature never runs
the capture loop.

As of the unified-extension prerequisite, that single writer is enforced by a
resident-visible application-session lease. Only the canonical process
identity (`New Old World`, creator `NOWo`) may publish the production `NWex`
request word; differently named development copies are read-only. Named
normal-context owners claim capabilities through one aggregator, which renews
from cooperative lifecycle pumps rather than repaint callbacks. Releasing one
owner therefore cannot disarm another live consumer, and a dead or disconnected
application loses the lease without relying on its teardown code running.

The table also appends two deterministic identities: a manifest hash over the
resident inputs and an embedded build fingerprint carried in both the table and
the INIT's `NWid` resource. The staged MacBinary SHA-256 is a third identity;
none substitutes for another. P1 now publishes diagnostic counters and applies
the six-tick unchanged-anchor cadence from the measured AXPeek loop. An A5 or
`WindowList` change may publish immediately; otherwise a continuously pumping
target gets at most one full publish per six ticks. These are **native-tested
and cross-built, not yet emulator-verified** until a cold boot proves the exact
resident fingerprint and its callback behavior.

**The app-side validated read — where the foreign memory is touched.**
This is application code, never resident code, because a bug here is a
file copy from fixed. To get the front window's bounds:

1. `GetFrontProcess` → PSN → `GetProcessInformation` for its
   `processLocation` and `processSize`: the exact partition bounds.
2. Find the anchor slot whose `a5` falls **inside that partition** and
   whose stamp is fresh. That is the PSN↔A5 correlation, validated by
   containment — an A5 outside the front process's partition is not its
   A5, and the read fails closed. Since V2 the oracle checks the slot's
   `stack_base` against the same partition, bounding the A5 world from
   the other end; since V3 it also lets the captured `cur_ap_name`
   **refute** a slot. Both exist to drop debris a recycled partition
   would otherwise let through — and the name only ever refutes, never
   elects, because two copies of one application share it. The
   verdicts are the oracle's (`peek_oracle.c`); a slot that is present
   but provably wrong is a different diagnosis from no slot at all.
3. Follow `window_list` to the front `WindowRecord`, then its
   `strucRgn`/`portRect` bounding box — every dereference bounds-checked
   against the same partition (and validated SysZone for shared
   structures) before it is read. Any pointer that lands outside fails
   the whole read; the app degrades to full-screen capture and says so.

The reader's pure arithmetic — is an address inside `[loc, loc+size)`,
is a `Rect` sane — is host-testable and gets a native test; only the
dereferences themselves are Toolbox-bound and metal-gated.

**First payoff:** Front & Capture crops to the front window's rect
instead of grabbing the whole screen (partial VRAM reads scale
linearly, so the crop is also the fast path). The Processes page's
"Front & Capture" affordance, ghosted since rung 0, lights up when
`caps & CapAnchors` and the read validates.

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
- `process.front`, `process.quit`, `process.shot` — the drive verbs,
  host→guest. Each names its target by the PSN echoed from a listing
  entry; the guest re-validates that PSN against a live process before
  acting, and refuses a quit of NOW itself (it would sever the wire
  mid-reply). `process.quit` is a 'quit' Apple Event the app may decline.
  `process.shot` fronts the process, lets it repaint, crops the capture to
  its front window (`capture_screen_rect`), and delivers over the capture
  transport — so "Screenshot App" is a genuine window shot, not the whole
  screen. front/quit answer `process.result`; shot answers a capture
  transfer. `process.launch` — opening an app that is not yet running — is
  still design; it needs a way to name an unlaunched app (a path or
  signature), not a PSN.

**Landed (2026-07-22):** the `process.list` / `process.listing` pair and
the two drive verbs. The host asks and DISPLAYS — a Processes module
(`ProcessesModel` / `ProcessesModuleView`) that pages the whole table in
on refresh, groups it into Applications (with the Finder) and Background,
flags the front process, captions each row with kind/4CCs/size, reads as
the snapshot it is ("as of HH:MM:SS"), and now DRIVES the selected row:
Bring to Front, Ask to Quit (both metal-verified, incl. the self-quit
refusal), and Screenshot App — a genuine window shot via `process.shot`
(front, repaint, crop to the front window, deliver), which is tested and
builds but whose cropping is not yet metal-verified.

**The one-way direction is the design, not a gap.** NOW drives old-from-
new: the host is the cockpit, the guest the machine being operated, so
host-sees-guest is the product and guest-sees-host is a non-goal. The
guest issues no verbs at the host and has no ask-for-the-host UI, on
purpose. The wire family stays symmetric in MEANING, but the host serves
nothing back — the dead `HostProcesses` serve was removed rather than
kept as ballast. `process.launch` (above) is the honest next verb on the
same arrow.

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
