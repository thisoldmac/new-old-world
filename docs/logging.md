<!-- now-doc-provenance: generated reviewed=false -->

# Logging

Design of record. What a log is here, where it lives, what belongs in
one, and how to read the two of them together.

## Why there is one

Three failures this month were diagnosed slowly, and every one was
information that **existed and had nowhere to live**:

| Failure | What was known | Where it went |
|---|---|---|
| Spike died with a Type 3 | which Toolbox call was next | nowhere — invented a throwaway flight recorder on the spot |
| Opening Browse dropped the wire | `"Ignored a 2380-byte message"` | a one-line status field, overwritten before anyone read it |
| A send looked broken | offering / sent / declined, all narrated | the Screenshots panel, which nobody was looking at |

None of these needed more instrumentation. They needed the words that
already existed to be written somewhere durable, on the machine that
knew them.

The classic Mac makes this sharper than usual: a Type 3 takes the
window, the status line and every in-memory buffer with it. **What
survives is what already reached the disk.**

## Shape

One file per launch, named for the moment it started, in a `now-logs`
folder. Plus the last lines kept in memory, so reading them costs no
disk.

| | Guest | Host |
|---|---|---|
| Folder | `now-logs` beside the application | `~/Library/Logs/now-logs` |
| Name | `2026-07-20 225612.log` | `2026-07-20 225612.log` |
| In memory | 2000 lines (the Logs page dumps them) | 2000 lines (the Logs module follows them) |
| Line endings | CR (this machine's) | LF |

Per launch rather than one growing file: the question is almost always
"what happened *that* time", and a launch is the unit that answers it.
The name sorts chronologically, so `ls` is the index.

`~/Library/Logs` on the host because `tail -f` and Console.app already
look there. `now-logs` beside the application on the guest because a log
next to the app is findable by whoever is holding the machine; a log in
some system folder is findable by whoever wrote the code.

## The line

```
HH:MM:SS area   [!?] message
21:04:11 get    Notes.txt, 4096 bytes
21:04:19 wire   ? skipped a 2380-byte control frame: bigger than this buffer holds
21:05:02 files  ! refused 7: io-error (the File Manager refused (-48))
```

- **Time** is the local clock of the machine writing it. The two
  machines do not share one — see *Reading both at once*.
- **Area** is a short tag so a log can be read by subsystem — one of the
  registry below, not an ad-hoc word.
- **Level** shows as a prefix: nothing for info, `?` warn, `!` error.

The area is padded to six columns on both machines, so a `grep area` and
an eye both line up. It is a **small closed vocabulary**; reach for an
existing tag before coining one, and add a new tag here when you do.

**Six columns is a limit, not a suggestion**, and `now_log`'s `%-6.6s`
truncates rather than complains. `network` shipped as a seventh
character that never reached the file: the line said `networ`, so the
one thing the tag exists for — `grep network` over the log — found
nothing, and the code and the log disagreed with nobody to say so. It is
`net` now. `LogAreaRegistryTests` reads both the sources and the table
below and fails on an unregistered tag or an over-long one, because this
table is a hand-maintained enumeration and those rot in exactly this
way (AGENTS.md, *Enumerated lists rot at merges*).

| Area | Covers |
|---|---|
| `app` | process start/stop, and app-wide state (disk logging on/off) |
| `wire` | the connection itself: connecting, disconnected with reason, frames skipped |
| `get` | a file pulled *from* the peer |
| `send` | a file offered *to* the peer |
| `put` | a file received into the share |
| `files` | share-side refusals and file operations |
| `proc` | the process family: drive verbs (front/quit/shot), the list refresh |
| `census` | a hardware-census probe's outcome |
| `act` | the interaction plane's dispatched acts |
| `mach` | the machine family: activate, the act self-test |
| `net` | the Network page's refresh |
| `chat` | the chat transcript's own sequencing faults |
| `web` | the guest-local browser relay and its NOW-wire request lifecycle |
| `update` | update offers rejected by validation, requests refused, and installation results |
| `dev` | project candidate publication and Development build/run settlement |
| `mirror` | the Mirror: the writer verdict, plane arm/disarm requests and outcomes, the Workshop page, and the resident's own counters read back |
| `adb` | guest application only: historical Continuity ADB observations and intake diagnostics; the retired passive observer no longer adds new callback traces |
| `sw` | the software family: the `catsearch` probe, and `launch` outcomes (the `sw` listing itself is a read and stays quiet) |
| `agent` | host only: the optional agent-integration surface — one line per capability a non-user face invoked, and the local endpoint's own failures |

The host writes the same tags for the same events, so the two files read
as one log of the whole system (see *Reading both at once*).

## The `agent` area: who asked

The other areas answer *what happened*. This one answers *who asked for it*,
and it exists because nothing else in either file could. The `sw` line for a
launch and the `proc` line for a quit look identical whether the person at
the machine clicked a row or an agent asked over MCP — so a suite of agentic
controls could drive a Mac all afternoon and leave a log that read like
somebody sitting at it.

**One line per capability a non-user face invokes, whatever it came to:**

```
21:04:11 agent  mcp now_launch_software guest=pb1400c answered
21:04:14 agent  ? mcp now_request_quit guest=pb1400c refused: now_request_quit accepts one current process reference
```

- **Refusals are logged, not just successes.** An attempt that was denied is
  the more interesting event. It is also the only outcome the host would
  otherwise never hear about: an argument refusal is decided inside the
  companion and sends no request at all, so if it were not reported it would
  be recorded nowhere.
- **`answered` means a typed result was produced**, which may itself say the
  guest was unavailable. That distinction lives in the result the caller got,
  not in this line.
- **Never the arguments.** A path, an upload's bytes, an approval receipt or
  a process reference would put user content and one-use credentials in a
  file to answer a question this line is not asking. The Files family
  already logs its own paths under `files`, where the path *is* the event.
- The line is composed by the host from typed fields, not accepted as text
  from whoever reported it — the log belongs to the person at the machine.

The rule and its gate live in
[agent-integration.md](agent-integration.md#every-agent-call-leaves-a-trace).

## The `mirror` area, and the line nothing may cross

The Mirror wrote **no log line at all** until 2026-08-08 — no `mirror`,
`peek`, `plane`, `scene` or `content` tag existed anywhere in
`now-guest-ppc/src`. The bill came in on 2026-08-07: Mirror crashed NOW
reproducibly on the PowerBook 1400c, four guest logs from that session
were recovered, and every one of them said only what NOW happened to be
doing when it stopped. Six plausible mechanisms were read out of the
source afterwards and **not one could be falsified**, which is this
project's recurring shape — an instrument that cannot see the defect.

What the area covers is in the registry above. What matters more is
**where it may be written**, because the Mirror is the one feature in
this tree with code running somewhere a log call would be worse than
silence:

- **The application side runs at task time.** The event loop, a wire
  command being served, a click being handled. Everything the `mirror`
  area writes is here (`now-guest-ppc/src/mirror/mirror_log.c`,
  and its callers in `peek.c`, `mirror_module.c`, `main.c`).
- **The resident side runs inside foreign processes, at draw time.** The
  content plane's QuickDraw bottlenecks, the trap patches and the jGNE
  filter are bounded and allocation-free by construction
  (`ext/src/now_content.c` says so in its own comments). A disk write
  there would change the timing of the thing being measured and could
  take the Finder down with it.

**So a fact that is only knowable inside a hook is surfaced as a COUNTER
the resident bumps and the application reads.** That pattern already
existed — `NowContentCounters` counts installs, uninstalls, repairs,
`skipped_ports`, the three arm refusals and retires — and it was already
being reported to the wire by `qdtrace status`. What was missing was
anybody reading it *without being asked*: `now_mirror_log_idle` polls it
from the main loop every two seconds and writes only the deltas. The
numbers are surfaced, never recounted.

`LoggingSpecTests.testTheResidentNeverLogs` is the gate. It reads
`ext/src/*.c` and fails on a `now_log(` anywhere in it.

**Every `mirror` line is edge-triggered**, and rotation is why that is
load-bearing rather than tidy — see below. The writer verdict is compared
against the last one before anything is written, an arm request that asks
for what is already asked for is not an event, and identical consecutive
settle failures collapse into a count.

**The area's diagnostics are a DEBUG TIER, off by default.** Being
edge-triggered was not enough: a 2026-08-15 session cycling 18
Continuity epochs in three minutes left the 2000-line ring ~97% mirror
counters — each disarm legitimately wrote its ~25-line epoch dump — and
the lines a person diagnosing a *feature* needs (arm/disarm, selection,
grants, errors) were buried past what a 40-line `tail` can serve. The
tier boundary is drawn by one question: does this line serve someone
diagnosing a FEATURE, or someone diagnosing the MIRROR PLANE? Lifecycle
facts and every warn/error stay unconditional; per-epoch counter dumps
and per-event traces sit behind `now_mirror_debug_on()`
(`now-guest-ppc/src/mirror/mirror_debug.h`), flipped by the `mirrorlog`
command from either face. The switch is session-scoped and never saved
— a diagnostic that survives a relaunch is a configuration nobody chose
— and the toggle logs its own transitions so the ring names who opened
the firehose. `now-guest-ppc/tests/mirror_debug_gate_source_test.py`
holds the boundary in both directions.

Advanced Continuity controls are surfaced from the Logs module rather than
from Mirror's primary controls. Fast Pump changes cooperative scheduling for a
bounded comparison. The default-off deep-click probe is deliberately dense,
but still bounded and memory-first: it records the jGNE event stream and click-
relevant low-memory state for a short comparison run. The rolling button timing
ring and front-process-at-down evidence remain available. The former V10 per-
epoch Cursor Device interval dump is retired from the ordinary teardown path
because its volume dominated the event-shaped log it was meant to help. None
of these exceptions permits logging from resident or interrupt context; the
resident records bounded state for the application to drain at task time.

The verdict line exists for one failure in particular. `AGENTS.md`
records that a binary not named exactly `New Old World` (creator `NOWo`)
arms **no plane at all**, while the resident goes on reporting `active`
with full capabilities and nothing anywhere names the cause; it took
renaming a build to discover, and the rename took `requested` from 0 to
15 with nothing else changed. It is now one line:

```
21:04:11 mirror ? writer: REFUSED - binary is not 'New Old World'/NOWo, no plane can arm
```

## Levels, and what they cost

| Level | Means | Disk |
|---|---|---|
| info | it happened | buffered |
| warn | it went wrong and continued | buffered |
| error | it went wrong and stopped | **flushed** |

A write reaches the file system but sits in the disk cache, and a crash
loses it. Forcing it out costs real time on a 603e, so only the lines
that might be the **last** ones pay: if something is about to take the
machine down, the line saying so has to be on the platter before it
does.

**Known consequence:** the info and warn lines immediately before a hard
crash may be missing — and those are often the interesting ones. If that
bites in practice, flush on warn as well and accept the cost. Not yet
needed.

## What to log

**Log the shape of an event**, not its heartbeat:

- Connection: connected, disconnected with the reason, reconnecting.
- Transfers: begun with a size, ended with a count, cancelled.
- Refusals: always, with the code and the reason text.
- Anything **skipped, ignored, or defaulted** — a silent fallback is
  the hardest bug to see from the outside.
- Start and stop of the process itself.

**Never in a per-chunk path.** A transfer moves thousands of chunks. An
instrument that costs a disk write per chunk eats the thing it is
measuring — the File Sharing panel proved this the expensive way, by
starving the very transfer it was drawing a progress bar for.

**A diagnostic string goes where someone will look.** If a string
explains a failure, it belongs in the log, not only in a status line
that the next event overwrites.

## Reading both at once

Each side currently tells a story about itself, and joining them is
guesswork. That is what made the large-transfer collapse expensive: the
host knew what it sent, the guest knew what it received, and nothing
lined the two up.

**Rule: anything that crosses the wire carries its id as the first
token of the message.**

```
guest  21:04:11 get    #12 Notes.txt, 4096 bytes
host   21:04:10 files  #12 serving Notes.txt, 4096 bytes
```

Then `grep '#12'` across both files is the whole transfer, both ends.
The ids already exist in the protocol; this only asks that they be
written down. The file, process and census families do
(`#<id>` as the first token); the capture and stream transports still do
not — that gap is the one place a request cannot yet be traced end to end.

Clocks are not synchronised and will not be: the guest's clock is
whatever that machine believes. Use the ids to correlate, and treat the
timestamps as within-machine ordering only.

## Reading a log

- **A file with no `stopped` line is a process that died.** `started`
  and `stopped` bracket a healthy launch; an unterminated file is itself
  the finding.
- The last line before a gap is the last thing that reached the disk,
  not necessarily the last thing that happened. See *Levels*.

## `tail`

`tail [lines] [area] [before N]` — default 20, most 40 per answer (a
control frame caps at 4 KB). `area` narrows to one subsystem's tag as the
log wrote it, filtered on the guest before the wire; `before N` continues
an answer at the sequence cursor its `log` group offered as `next`, back
through the whole 2000-line ring. Sequences count from 1 at launch and
never renumber, which is what makes a cursor over a live ring honest.
The selection is one implementation for both faces
(`now-guest-ppc/src/core/logquery.c`); `now_guest_log_tail` follows the
cursors itself, so an agent asks for 200 lines and the paging is the
host's problem, not the caller's.

It is one command in the **shared table** that serves both consoles, so
the same words work on the guest's own console and from the host's. That
second path is the one that matters: the classic Mac is the machine that
is hardest to look at, and it is the one that crashes.

Being a wire command, `tail` obeys the command rule: **the contract
declares it, the guest answers it, the host offers it, and
`CommandRegistryTests` reads all three and fails if they disagree.**
`tail` itself was added to only one of the three and was therefore
unreachable — undeclared and unreachable is the quietest kind of broken,
because the feature works and no path to it exists.

## Rotation

A file per launch is bounded on both classic guests. Each launch keeps the
newest 10 recognized NOW session logs by default, including the current file,
and deletes older recognized files by catalog creation date. Unrelated files
and the current log are never candidates. A catalog or delete error stops
pruning but never prevents the current log from opening.

The PPC Logs page changes the bound one launch at a time with **Fewer** and
**More** (1 through 100) and stores it in preferences format 25. NOW-68K uses
the same range and default; a lab that needs another bound adds
`log-retention = N` to `NOW-68K Dev Settings` beside the application. The
selector is native-tested and mutation-proven, and both File Manager adapters
cross-build. Constrained-HFS and physical-machine deletion remain unverified.

**Verbosity is still a disk and latency budget, not only a taste question.**
That is the second reason every `mirror` line is
edge-triggered: an area that wrote a line per event-loop pass would
break rule 1 and churn even a bounded set of files.

## Status

| | State |
|---|---|
| Guest: file, ring buffer, `tail` on its own console | **Metal-verified** 2026-07-20 (PB1400c) |
| Guest: events — connect, transfers both directions, refusals, skips | Built, **not yet read back in anger** |
| Guest: events — process drive verbs (front/quit/shot), census outcomes, process-list refresh | Compiled 2026-07-22; **not yet exercised on metal**. Each carries the wire id; drive-verb refusal reasons now reach the log, not only the wire. `process.list` logs once per refresh (cursor 1), never per page |
| Host: file per launch, in the line format above | Built, **unverified on a real run** |
| Host: `tail` of the guest's log | Built; needs `fork/logging` landed and a rebuild |
| Guest log readable by a non-user host face | Built + tested 2026-07-30 as the `now_guest_log_tail` projection: a line count and never a path, the guest's `shown` row carried through as the bound, and one `app` line per read so the person at the machine can see their log was read. **Unverified on metal.** Scope and encoding: [mcp-coverage.md](mcp-coverage.md) |
| `tail` output as one row per line | Built — byte-bounded, oldest deferred to the next page first, and it says so |
| Guest log retrieved in BULK over the wire | Built + tested 2026-08-15: `tail` pages the ring by sequence cursor with a guest-side `area` filter, and `now_guest_log_tail` walks the cursors to serve up to the whole 2000-line ring in one call, answers in the host log's shape. Emulator-verified this thread; **unverified on metal** |
| Correlation ids in both logs | Built for the file family; **capture and stream still have none** |
| Per-chunk rule enforced by a test | Built (`LoggingSpecTests`), mutation-checked |
| Guest launch-log retention | Built + native-tested + mutation-proven: default 10, configurable 1–100, current/unrelated files protected. Both guest adapters cross-build; constrained-HFS and metal deletion are unverified |
| Guest log surfaced in the UI | The Logs page, pinned in the footer just above Connection: a Monaco dump of the 2000-line ring that follows the tail live, with Invert and Log-to-disk switches | **Metal-verified** 2026-07-22 (PB1400c) |
| Guest disk + invert are toggles | On/off for the file (off keeps the ring), and an inverted dark canvas like Console. Saved in prefs — disk at format 12, invert at 13 | Metal-verified 2026-07-22 |
| Guest retention control | PPC Logs page Fewer/More controls save prefs format 25; NOW-68K reads `log-retention` from its dev settings file | Built and native-tested; target UI/File Manager behavior unverified |
| Host log surfaced in the UI | The host's own Logs module, footer above Connection, same Invert + Log-to-disk switches over HostLog's ring | Built + tested 2026-07-22; **unverified on a real run** |

## Rules for anything added later

These are the standard. A change that logs is reviewed against them.

1. **Log the shape, not the heartbeat.** A new verb logs begun, ended
   with a count, refused with the reason — as part of being done, not as
   a follow-up. Not the thousand steps in between.
2. **Nothing logs in a per-chunk path.** A disk write per chunk eats the
   transfer it is measuring. `LoggingSpecTests` enforces this on the hot
   functions and is mutation-checked.
3. **Anything crossing the wire writes its id first.** `#<id>` is the
   first token, so `grep '#<id>'` joins the two machines' files.
4. **A string that explains a failure goes to the log**, not only to a
   status line the next event overwrites. Refusal reasons especially:
   they exist for exactly the moment someone is reading the log.
5. **Pick the level by what happened**, because only `error` pays to
   flush: `info` it happened, `warn` it went wrong and continued,
   `error` it went wrong and stopped.
6. **Tag with an area from the registry** in *The line*. Reuse a tag
   before coining one; a genuinely new subsystem adds its tag to that
   table in the same change.
7. **One line, short and self-contained.** The ring is the Logs page's
   scrollback and each line is one row there, so no multi-line entries
   and nothing that only makes sense with the line before it.
8. **Write unconditionally; the sink decides.** The in-memory ring is
   always live and the file is a switch (default on) — never gate a
   `now_log` / `HostLog.write` call on whether disk is on.
9. **Both machines log the same event the same way** — same area, same
   shape — so the two files read as one (*Reading both at once*).
10. **A new wire command is declared, answered and offered**, or
    `CommandRegistryTests` fails. Undeclared and unreachable is the
    quietest kind of broken.
11. **Nothing in a resident component logs.** `ext/` runs inside foreign
    processes at draw time and at interrupt level, bounded and
    allocation-free by construction. A fact only knowable there becomes a
    counter the application reads at task time — never a line the
    resident writes. `LoggingSpecTests.testTheResidentNeverLogs` reads
    `ext/src/*.c` and fails on `now_log(` anywhere in it.

## Note on the content-plane crash fix (939fb887)

The guard added to the blit-source row builder is **provably
behaviour-preserving**, which is worth stating because it is the strongest
thing that can be said about a fix that cannot be tested natively.

`now_content_blit_source` in `ext/src/now_content_logic.c` — the pure
logic, already compiled by the host `cc` — starts its loop with:

```c
if (!rows[i].offscreen || rows[i].a5 != armed_a5 || rows[i].pixmap == 0) {
    continue;
}
```

So a row whose `a5` is not the armed context **was always skipped by the
consumer**. The caller nevertheless dereferenced that row's PixMap handle,
its port and its PixMap to fill in `port_version`, `rect_*`, `base`,
`row_bytes` and `pm_*` — fields the join then discarded.

Those reads were **waste as well as danger**. Removing them cannot change
any output; it only removes a read of memory belonging to a process that
may be gone.

### Why there is no native test for it

The bug lives in the row-building loop, which needs `CGrafPtr`, `Handle`
and `PixMap` — Toolbox types the native harness does not have. The pure
seam below it is already correct, so a test written there would pass
before and after the fix: it would be a test of the half that was never
broken.

Stating that plainly rather than adding a green test that proves nothing.
What would make it testable is extracting the row-building decision
("may this row be dereferenced?") the way `now_content_logic.c` already
extracts the join — worth doing, not done here, and not something to
attempt in the same change as a crash fix on an unbaked resident.

The evidence that it is the right fix is not a test; it is the guest's own
log, which armed observe, act and scene without incident and died on the
first content arm — the arm that turns this loop on.
