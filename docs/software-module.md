# The Software module

What is installed on the machine, and the ability to start it — the
inventory sibling of the Processes page's "what is running". This spec
is the module's contract before any of its pixels exist.

**The doctrine, stated once: console first.** Every capability lands as
a console verb over a tested data layer, gets watched working (emulator,
then metal), and only then grows UI — the UI renders functions that
already work, it never introduces behaviour. This is the lesson of
`two-halves-never-met-in-a-test` applied one layer down: the page and
its logic must not meet for the first time on the PowerBook. Rung 0
below is already done and verified; it is the pattern the rest follows.

## The ladder

| Rung | What | Status |
|---|---|---|
| 0 | `catsearch` probe; `software.c`; `sw` + `launch` verbs | **Done.** catsearch metal-verified (3.8 s cold, 22k files); sw/launch emulator-verified, metal pending |
| 1 | Console completion: resumable sweep, `vers`, running tags | Next |
| 2 | Wire family: `software.list` / `software.listing`, paths | After 1 |
| 3 | Guest page (the six edits + Data Browser) | UI on top |
| 4 | Host module page | UI on top |

Each rung ends the way every arc here ends: suites green, a watched run,
and an `open-issues.md` entry saying what is still unwatched.

## Ground truth from rung 0

Decisions below lean on measured facts, not hopes:

- A whole-volume APPL sweep costs **3.8 s cold on the 1400c** (22,127
  files), warm barely cheaper — so a live sweep is affordable, a cache
  file is not needed, and nothing should treat re-sweeps as free.
- `PBCatSearch` returns roughly **once per 16 KB opt buffer**, worst
  slice 3 ticks — so the buffer size is the slice-length dial and
  `idle()`-driven slicing works as designed.
- The special folders are dozens of files — enumerating them live,
  every time, is cheap enough to never cache.
- **601 applications** on the real disk — so the expensive read is not
  the sweep but per-item `'vers'` resource opens, which stay lazy,
  one visible/selected item at a time.

## Rung 1 — console completion

Three pieces of logic the page needs, each proven as (or under) a
console verb first.

### The resumable sweep

`software.c`'s `appl_sweep` is a blocking loop today. The page needs the
same sweep one slice at a time from `idle()`. Refactor to a stateful
iterator — the `CatPositionRec` already *is* the resumable state:

```c
typedef struct {
    CatPositionRec pos;
    long spent_ticks;
    Boolean done;       /* eofErr reached, or stopped by rule */
    OSErr err;          /* why, when done and not eofErr */
} SweepState;

void now_software_sweep_begin(SweepState *s);
/* One PBCatSearch slice; calls collect per hit. Returns the number
   collected this slice. */
int now_software_sweep_step(SweepState *s, ConstStr255Param name_or_null,
                            SweepCollect collect, void *ctx);
```

`sw apps` and `launch`'s name search become loops over `step` — the
console verb is how the iterator gets exercised and watched **before**
`idle()` ever calls it. Same rules as today: `catChangedErr` ends the
sweep (a restart double-counts), the opt buffer is allocated at `begin`
and freed when `done`.

### `vers` — the lazy detail read

The one-item version read the page's detail pane will render:

```
vers <name or full path>
```

Resolves exactly like `launch` (bare name = exact-name sweep, refuses
ambiguity), then opens **that one file's** resource fork read-only
(`FSpOpenResFile` … `fsRdPerm`), reads `'vers'` id 1 (and id 2, the
region/product string) and the short version string, closes the fork,
and prints them. Rules:

- Resource-fork opens are the measured expensive path: this verb never
  loops over an inventory. One call, one file.
- A file with no `'vers'` answers "no version resource" — absence is an
  answer, the census rule.
- `ResError` after every call; a damaged fork must not crash the read.
  Close what was opened on every path, and restore `CurResFile`.

Layer: `now_software_vers(const char *arg, rows…)` in `software.c`, so
the page calls the same function per selected row.

A bare name that matches several applications shows **every match,
numbered, full path wrapped** (bounded at five) — the metal run found
multiple SimpleTexts immediately, and which copy answered is the whole
point on a disk with duplicates.

**Launch disambiguation (revised after metal, 2026-07-22).** The first
cut *refused* an ambiguous `launch` and made the person pick. On a real
disk that was too much ceremony for "just open it," so `launch <name>`
now **launches the highest-versioned copy and names it** in the reply
— a visible answer, not a hidden guess. Control is additive:
`launch <name> <version>` forces a copy by its short version string
(the whole arg is tried as a literal name *first*, so "Sherlock 2" and
"Illustrator® 8.0" stay whole; only a name that matches nothing peels a
trailing `1.2.3`), a full path is exact, and `#n` still picks from the
last search. Choosing the newest reads each candidate's `'vers'` — the
expensive path — but bounded: a handful of fork opens, only on an
ambiguous launch. Marked for later, not this ladder: a **duplicate
finder** — group the sweep by name, lazily `vers` each group, and
present same-version/different-version pairs for user-driven
consolidation.

### Running tags — the Processes join

`sw apps` (and the wire listing) tag an item that is currently running.
The join is mechanical: one Process Manager walk per gather
(`GetNextProcess` / `GetProcessInformation`), compare the process's
`FSSpec` (vRefNum, parID, name — not the display name) against each
row's. Cost: the walk is what `ps` already does; the compare is memcmp.
Console proof: `(running)` appears in the detail column, and quitting
the app makes a re-run drop it.

## Rung 2 — the wire family

The host page cannot page through a 4 KB `command.result`, so the
inventory becomes a first-class message pair, shaped like
`process.list`:

```
software.list     { type, id, domain, cursor }        cursor 1-based
software.listing  { type, id, domain, entries[], cursor, more }
```

Entry fields — all present unless marked optional:

| field | | |
|---|---|---|
| `name` | string | catalog/display name |
| `path` | string | full path, the launch key (below) |
| `type`, `creator` | string | 4CCs, MacRoman-escaped like all wire text |
| `sizeK` | int | data + resource forks |
| `off` | bool | disabled-folder sibling |
| `running` | bool | the rung-1 join |
| `version` | string, optional | present only when already known; **never** gathered during a listing |

**Paths are the launch key.** The host launches a listed item by sending
the existing `launch` command with `entry.path` — one mutation verb in
the whole family, and by full path, so the ambiguity refusal never fires
from the UI. Building the path: a folder domain knows its own path once
per listing; an apps-sweep hit walks `parID` upward with a small
per-listing cache. Guest-side logic, exercised by the listing itself.

**Symmetry, declared honestly.** `software.list` means the same thing
whichever side sends it — but NOW is a cockpit, and the family follows
the `process.list` precedent exactly: the host asks, the guest serves,
and the host *ignores* a `software.list` rather than serving one. That
asymmetry is stated in the contract's operation description, not
drifted into. (An earlier draft had the host serving `/Applications`;
the established sender-only rule for the host's receiving half won.)

**Conformance.** `software.listing` is built across `snprintf` calls, so
`GuestWireConformanceTests` will fail until it gets a hand-written
fixture in `GuestWireFixtureTests` — that failure text is the reminder,
and includes a `®`-bearing name to pin the MacRoman escape path. The
`testMessagesThisCannotCheckAreKnown` set gains `software.listing`.
Logging: `software.list` logs once per refresh (cursor 1) under `sw`,
the `process.list` rule.

## Rung 3 — the guest page

Only after rungs 1–2 are watched working. The page renders functions
that already ran; its jobs are geometry, controls, and pacing.

**Placement.** Module id after Hardware, before the footer pair:
sidebar order Screenshots, Files, Console, Processes, Hardware,
**Software**, then Logs / Connection pinned. View menu gains Cmd-6;
Logs and Connection shift down (check whether the persisted selected
page in prefs stores the module id — if it does, that is a prefs format
bump, the Connection-renumber precedent).

**Layout.** Domain popup at the top (Applications, Extensions, Control
Panels, Startup Items, Apple Menu — popup, not tabs: five domains do
not earn tab chrome). Below it a Data Browser list: Name (icon-less
text first; icons are a later nicety), Kind (type/creator), Size, and
a state column (`off` / `running`). Below the list, the detail line and
buttons. All geometry in `compute_rects` over the body rect, pure, with
a host-`cc` test (`workshop_layout_test.c` pattern).

**Filling, by domain price.** Folder domains: enumerate on every page
show — live and instant, no staleness to manage. Applications: first
visit starts the rung-1 sweep, one `step` per `idle()` pass, rows
appended as slices land, placard reading "Sweeping Macintosh HD — 214
applications…" (the `status_text` op). Sweep state is kept for the run
(modules are never disposed); a Rescan button re-runs it. No cache
file — 3.8 s of honest progress beats stale-and-wrong.

**Idle discipline.** One slice per pass, nothing else; every drawn
value behind a `g_shown_*` cache; no `HiliteControl` unconditionally.
The sweep must also **yield entirely while a transfer is in flight**
(`conn` knows) — the no-sleep loop is the one place a 3-tick slice
would still be felt.

**Actions.** Launch (selected, by FSSpec — the page has it; never by
name), and for a `running` row Front / Ask to Quit, reusing
`proc_actions` exactly as the Processes page does. Launch failures go
to the placard *and* the log (already the rung-0 rule). Selecting a row
triggers the one lazy `vers` read for the detail line; cache the answer
on the row.

**The six edits, instantiated.** `workshop_module.h` (id 6 +
`kWorkshopModuleCount`), `workshop_layout` (`nav_rows` 5 → 6),
`workshop_sidebar` (row + 16×16 `ics#`, plotted with
`plot_small_icon`), `workshop_window` (`k_module_info` + ops
registration), `main.c` (View menu Cmd-6 + renumber), CMakeLists
(`software_module.c`, `software_layout.c`).

## Rung 4 — the host module

`SoftwareModel` (drives `software.list` paging, holds entries) +
`SoftwareModuleView`: SwiftUI `Table` — nothing here needs to be a drag
source, so no `NSTableView` — with the domain picker, the same columns,
and a Launch button sending `launch` with the entry's path. Model tests
mirror `ProcessesModelTests` (paging, entry decode, running/off
rendering); the listing decode is pinned by the rung-2 fixtures. Until
this rung exists, the host console's local `swpage [domain] [cursor]`
drives the family live.

## Failure honesty

- A domain folder that does not exist is an empty listing, not an error.
- A sweep stopped by `catChangedErr` or the tick cap says so (placard /
  listing `more`), never silently truncates.
- `launch` refusals carry the reason to the console, the placard, and
  the log — three surfaces, one string.
- `vers` on a damaged fork reports, closes, and moves on.
- The host serving empty non-apps domains is a **declared** limit in the
  contract, not an accident.

## Tests and verification

- Host `cc` natives: layout geometry; any pure row-formatting logic
  worth pinning (the `fourcc`/size text already ship inside
  `software.c` — if they grow, split them the `conn_fields` way).
- `GuestWireFixtureTests`: `software.listing` fixtures, including a
  MacRoman high byte and an `off`+`running` combination.
- Host suite: SoftwareModel paging + HostSoftware serving.
- Mutation check the new guards at least once each: break the FSSpec
  compare and watch the running tag lie; drop a required listing field
  and watch conformance name it.
- Emulator pass per rung (the rung-0 flow: clone VM, push, drive the
  console, screenshot). Metal pass before any rung is called done:
  `sw`, `vers`, sweep pacing under a live transfer, and the page —
  the PowerBook is where the disk is honest.

## What lands when

1. **Rung 1** — one commit-able arc: iterator refactor + `vers` +
   running tags, console-verified in the emulator, `sw`/`launch`
   metal-run re-checked (they are still unwatched on the 1400c).
2. **Rung 2** — contract + both serving halves + fixtures; host console
   can already page by asking twice, before any page exists.
3. **Rung 3** — the guest page, an afternoon of geometry over working
   verbs if the doctrine held.
4. **Rung 4** — the host page, likewise.

Anything cut lands in `open-issues.md` under broken/unverified — the
ledger, not the spec, tracks what actually happened.
