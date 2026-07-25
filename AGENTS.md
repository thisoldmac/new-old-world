# Working conventions for New Old World

Read this before writing code or docs here. It applies to **everyone —
human or agent**. The parent repository's `AGENTS.md` still governs the
machines, the corpus and the lab; this covers what is different about
this one.

## What this is

Two applications and one contract between them: a PowerPC Carbon app for
Mac OS 8.6–9.2.2 (the CarbonLib 1.6 range), and a native macOS app. A
third, **NOW-68K** (`guest68k/`), speaks a subset of the same contract
from a 68K Mac under System 7.1 over MacTCP — non-Carbon Toolbox C via
Retro68, for machines Carbon cannot reach. It is a sibling of the Carbon
guest, not a port of it: load `classic-mac-toolbox-ui` and
`classic-mac-toolbox-platform` for that tree, not the Carbon skills. No
TimBotTu runtime code is imported on either side. `now/` is a **nested
repository with its own history**, gitignored by the parent exactly like
`qemu/`.

NOW may also ship **optional resident components** on the guest (the NOW
Extension), each behind a versioned in-memory contract stated once in a
shared header; foreign-context execution lives only in resident
components, foreign-memory reads live only in the application, and a
resident component is always optional — the product degrades honestly
without it. The family charter is
[docs/resident-components.md](docs/resident-components.md).

The product is human-facing. Both halves are meant to feel native to
their own machine — not to each other, and not to the web.

## The contract is the source of truth

`contract/asyncapi.yaml` defines every message. Two rules follow:

- **A behaviour change starts there.** If a verb needs a field, the
  contract gains it first, then both halves. A field one side sends and
  the other has never heard of is the defect class that has cost this
  project the most (finding `two-halves-never-met-in-a-test`).
- **The file family is symmetric.** Every message means the same thing
  whichever side sends it, and whoever RECEIVES a request serves its own
  share. When you implement one direction, say plainly whether the other
  now differs — a drift there is a contract violation, not a to-do.

State a limit **once**, where both sides read it. The control-frame cap
lived in prose, in the sender, and as a different number in the
receiver's buffer; nothing was wrong until a message grew past the
smallest of the three.

The same discipline covers the **in-memory contracts**: a resident
component's shared table is one header (`contract/peek_table.h`),
compiled by every side that reads it — 68K extension, PPC application,
and the host `cc` for its native test — with static asserts pinning the
layout, because two compilers sharing a struct is where silent packing
drift bites.

## Two dialects

**Guest — Retro68 retrocarbon, C.** Carbon on CarbonLib 1.6, classic
`WaitNextEvent` loop, cooperative scheduling. Before touching its UI,
read [docs/guest-ui-start-here.md](docs/guest-ui-start-here.md) and load
the `classic-mac-carbon-ui` skill. Non-negotiables live there; the two
that bite hardest are that a UPP is never a cast on this runtime, and
that every nested Toolbox loop must pump the wire (`pump.h`).

The guest is **one window** — the Workshop — and every human-facing
feature is a page inside it behind `WorkshopModuleOps`. There are no
other windows, and a new feature does not get one: it gets a module.
[docs/adding-a-workshop-module.md](docs/adding-a-workshop-module.md) is
the contract, the six edits a page needs, and the rules a page breaks
first.

**Host — Swift, SwiftUI with AppKit where SwiftUI cannot reach.** The
browser is an `NSTableView` because SwiftUI's `Table` cannot be a file
drag source. Prefer the native control over a reimplementation.

Both: comments say **why**, not what. Match the surrounding density.

## Testing

- Host: `scripts/test-host` — the suites *and* the Xcode app target, Debug
  and Release. `swift test` alone is not the gate: the two build systems
  have diverged before, and a broken app build passed 459 green tests for
  a day because nothing built the thing a human launches.
- Guest: the native tests under `guest/tests` compile with the host `cc`
  and run here — `json_native_test.c` is the pattern for anything with
  no Toolbox dependency.
- `GuestWireConformanceTests` reads `guest/src/*.c` and checks every
  message the guest can emit against this side's decoder and the
  contract's required fields. **If you add a message built across
  several `snprintf` calls, it will fail** until you give it a fixture —
  that is deliberate, and the failure text says so.

**A test you have not watched fail proves nothing.** Verify a new guard
by mutation: reintroduce the bug and see it named. And a test that
constructs the message it then parses tests one half twice.

## Verification is a status, not an adjective

Three levels, and say which one you mean:

- **Builds** — proves nothing about behaviour.
- **Tested** — the suites pass here.
- **Metal-verified** — someone watched it work on the PowerBook 1400c.

Most of the surprises in this project came from code that looked
obviously correct and had never run on the real machine. Never write
"works" for something in the first two categories.

## Deploying to the PowerBook

FTP to `10.91.5.47` (`claude`/`claude`), into `Lab/`. Rumpus decodes a
MacBinary `.bin` on arrival; verify by comparing fork sizes, not by
re-downloading.

- **The canonical binary is `New Old World`.** The build emits it as
  `New Old World.bin` beside `now-guest.bin` (the CMake target name can't
  hold a space, so `guest/tools/name_macbinary.py` stamps the product
  name into the MacBinary; Rumpus decodes by that internal name). That is
  the one a human tests on metal and the one that lands on main.
  `now-guest` and other names are dev / side builds — a side experiment
  goes up as `now-chip` or its own name.
- **Do not overwrite someone else's binary.** `New Old World` is the
  shared canonical one; don't clobber it with an experiment.
- **Deploy under an honest name.** A build named for what it was meant
  to be rather than what it is cost an evening of diagnosis aimed at the
  wrong half of the system.
- **Preferences key off the binary's name.** Any name but `New Old World`
  starts with no preferences and dials `10.0.2.2` — the QEMU gateway,
  which never answers on real hardware and looks exactly like a hang.
  (The canonical name lives once, in `prefs.c :: prefs_spec`; the base
  prefs file is `New Old World Prefs`, so the existing saved host carries
  over from the old `now-guest` canonical.)
- **Check the build stamp before believing a test result.** It can read
  a few minutes early, because CMake touches `build_stamp.c` at the end
  of a build; `touch guest/src/build_stamp.c` first to force it current.

## Git

This checkout is **shared**. Other sessions have worktrees off it, and
agents branch in their own worktrees — so the shared checkout stays on
`main`, at the head of the work.

- **Work on a branch, never on `main`.** Before your first edit, cut one
  — `git checkout -b <ns>/<slug>`, forked off the parent branch you are
  continuing, not off main. `main` receives finished work by
  fast-forward or merge; it is never where work is typed. This is
  enforced (`.githooks/pre-commit`, plus a PreToolUse hook on
  `Write`/`Edit`/`Bash`), and the enforcement is the floor, not the
  rule: don't reach for `TBT_ALLOW_MAIN=1` to get past a block you
  should have avoided by branching. The namespaces in use are
  `claude/`, `codex/`, `thread/` and `fork/` — pick the one that says
  who is working.
- **`main` is the head — keep the shared checkout on it.** Land a
  finished thread by fast-forward or merge (`git -C <path> merge
  --ff-only <branch>`), or move the ref without disturbing a working
  tree with `git fetch . <branch>:main`. Don't leave the shared checkout
  parked on a side branch; that is how it drifted onto a stale one and
  looked like the app had regressed.
- **Moving the ref leaves the files behind — re-sync after.** `git fetch
  . <branch>:main` advances the *ref* only; the shared checkout's index
  and working tree stay at the old commit. `git status` then reports the
  newly-landed files as **staged deletions**, which reads exactly like a
  session that ripped them out, and committing it would revert the work
  that just landed. When a clean checkout shows a large staged `D` diff,
  diff the index against main's ancestors before believing it — if the
  index matches an ancestor of `main`, nothing was deleted and the cure
  is `git reset --hard main`, not a commit.
- Use `git -C <absolute path>` rather than `cd`. A bare `cd` into the
  wrong repository root has put commits on another session's branch.
- Stage explicit paths. Never `git add -A` — it is the difference
  between a stray commit and a destroyed afternoon.

## Docs

`README.md` carries **what works and what does not**, together. A
feature list without its companion is a sales pitch, and the things this
project got wrong were never in the parts anyone demonstrated.

[docs/open-issues.md](docs/open-issues.md) is the ledger, organised
around **broken** versus **unverified**. Every arc ends by updating it —
including the arcs that went well, because "we shipped it and here is
what we still do not know" is the useful half.

Durable technical claims that outlive this repository go to the parent's
corpus as findings (`data/findings/`), validated with `tools/data check`.
The platform lessons from here already live there:
`carbon-upp-is-not-a-cast-on-cfm`,
`carbon-databrowser-usable-carbonlib-16`,
`two-halves-never-met-in-a-test`.

## Working with the human

Small, reviewable pieces beat a finished thing presented at the end.
Report what is unverified as unverified, name what you skipped and why,
and when something fails, say so with the output rather than around it.
If two hours produce nothing runnable, that is worth saying at the
twenty-minute mark instead.
