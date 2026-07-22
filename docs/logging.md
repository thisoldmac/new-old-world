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
| In memory | 200 lines | 100 lines (the Connection window) |
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
- **Area** is a short tag (`wire`, `files`, `get`, `send`, `browse`,
  `app`) so a log can be read by subsystem.
- **Level** shows as a prefix: nothing for info, `?` warn, `!` error.

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
written down. *(Specified here, not yet implemented.)*

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

`tail [lines]` — default 20, most 40 (a control frame caps at 4 KB).

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

A file per launch accumulates forever, on a disk with tens of megabytes
free. Keep the newest ~20 at open, delete the rest. *(Specified here,
not yet implemented — this is a real hazard on the guest, not a
tidiness preference.)*

## Status

| | State |
|---|---|
| Guest: file, ring buffer, `tail` on its own console | **Metal-verified** 2026-07-20 (PB1400c) |
| Guest: events — connect, transfers both directions, refusals, skips | Built, **not yet read back in anger** |
| Guest: events — process drive verbs (front/quit/shot), census outcomes, process-list refresh | Built 2026-07-22; **not compiled on a Retro68 toolchain this session, not metal-verified**. Each carries the wire id; drive-verb refusal reasons now reach the log, not only the wire. `process.list` logs once per refresh (cursor 1), never per page |
| Host: file per launch, in the line format above | Built, **unverified on a real run** |
| Host: `tail` of the guest's log | Built; needs `fork/logging` landed and a rebuild |
| `tail` output as one row per line | Built — byte-bounded, oldest dropped first, and it says so |
| Correlation ids in both logs | Built for the file family; **capture and stream still have none** |
| Per-chunk rule enforced by a test | Built (`LoggingSpecTests`), mutation-checked |
| Rotation | **Not built** |
| Host log surfaced in the UI | **Not built** |

## Rules for anything added later

1. A new verb logs its shape — begun, ended with a count, refused with
   the reason — as part of being done, not as a follow-up.
2. Nothing logs in a per-chunk path.
3. Anything crossing the wire writes its id.
4. A string that explains a failure goes to the log, not only to a
   status line.
5. A new wire command is declared, answered and offered, or the registry
   test fails.
