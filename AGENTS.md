# Working conventions for New Old World

Read this before writing code or docs here. It applies to **everyone —
human or agent**. [CONTRIBUTING.md](CONTRIBUTING.md) is the shorter door
into the same material for a first-time contributor; this is the full
set.

## What this is

Two applications and one contract between them: a PowerPC Carbon app for
Mac OS 8.6–9.2.2 (the CarbonLib 1.6 range), and a native macOS app. A
third, **NOW-68K** (`now-guest-68k/`), speaks a subset of the same contract
from a 68K Mac under System 7.1 over MacTCP — non-Carbon Toolbox C via
Retro68, for machines Carbon cannot reach. It is a sibling of the Carbon
guest, not a port of it: load `classic-mac-toolbox-ui` and
`classic-mac-toolbox-platform` for that tree, not the Carbon skills.

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

Both guests have **two faces** — the console a person types into at the
machine, and the wire the host drives them over — and every capability
must be reachable from both, with one implementation behind them.
[docs/command-parity.md](docs/command-parity.md) is the rule, the seam in
each guest, and the asymmetries that are deliberate;
`CommandParityTests` fails the build when a verb appears on one face
only. It exists because `process.list` shipped wire-only and nothing
noticed until someone asked out loud what the console could do.

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

- **`scripts/test-all` is the gate.** It runs the three below in order,
  cheapest first, and stops at the first failure naming it. A broken
  frame codec should cost two seconds to find, not the four minutes
  xcodebuild takes to reach the same conclusion by a longer route.
- Guest builds: `scripts/build-guests` cross-compiles both guests.
  Nothing else in this tree does — every other gate can be green while
  neither guest compiles, because none of them invokes a cross-compiler,
  which is exactly the shape of gate this project has been bitten by
  before. It skips (exit 0) without Retro68 installed, because a
  contributor who cannot run a gate is not failing it. A build proves
  only that the code compiles.
- Host: `scripts/test-host` — the suites *and* the Xcode app target, Debug
  and Release. `swift test` alone is not the gate: the two build systems
  have diverged before, and a broken app build passed 459 green tests for
  a day because nothing built the thing a human launches.
- Guests: `scripts/test-native` — both guests' native tests, compiled with
  the host `cc` and run here, in one command (`scripts/test-native frame`
  filters). `json_native_test.c` is the pattern for anything with no
  Toolbox dependency. **A new test must be added to that script's
  manifest**, which fails the run if a test file is not listed: a test
  nobody runs reads as coverage in a directory listing and proves nothing.
- Metal gates (`Metal*Tests`) are opt-in and, once opted in, **fail rather
  than skip**. `NOW_METAL` unset skips; with it set, a held port or a Mac
  that never dialled in is a failure, because a gate that reads green
  having never reached a machine is worse than no gate.
  `tools/fakeguest.py` exercises the harness without hardware — and proves
  nothing about a guest; read its header before quoting a result from it.
- **A metal gate must check WHICH guest answered.** Every QEMU guest on
  this Mac sees the host as `10.0.2.2` under user-mode networking, and
  the human's own app may already hold the default port — so any
  session's VM, running any branch's build, can answer your listener.
  This is not theoretical: `Metal68KSendTests` first reported
  `unknown-command` from another branch's guest, and its refusal case
  PASSED against it, because "unknown command" is also a refusal with a
  reason. Boot with `scripts/q800-68k --port N` on a port nothing else
  is dialling, pass the same `NOW_METAL_PORT`, and assert a capability
  only the build under test has before believing anything it says
  (`requireTheBuildUnderTest()` is the pattern).
- **A metal gate must also check the MACHINE is free.** That rule asks
  who answered; it cannot ask whether somebody else was already using
  the Mac. Two host sessions once shared one PowerBook — one holding a
  port for an hour while the other deployed into the same folder
  mid-transfer — and produced a stall at 606208 bytes that nothing could
  attribute afterwards. `MetalMachineGuard` runs before anything binds
  (`lsof` answers it in a second) and FAILS naming the process; set
  `NOW_METAL_MACHINE` for a run against real hardware, or half of it
  cannot run. The procedure, and how to tell contention from a defect,
  is [docs/68k-metal-runbook.md](docs/68k-metal-runbook.md). A metal
  MEASUREMENT is recorded rather than narrated: `NOWBASE` lines carry
  the build, machine and port beside every number and
  `NOW_METAL_REPEATS` samples the large rungs more than once
  ([docs/68k-metal-baseline.md](docs/68k-metal-baseline.md)).
- `GuestWireConformanceTests` reads `now-guest-ppc/src/**/*.c` and checks every
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

FTP the build to the machine, into its `Lab/` folder. Rumpus decodes a
MacBinary `.bin` on arrival; verify by comparing fork sizes, not by
re-downloading.

The address, account and toolchain path are **not in this repository** —
they describe one desk. They come from `.env.lab`, which is gitignored;
copy `.env.lab.example` and see [docs/lab-setup.md](docs/lab-setup.md).
`scripts/deploy-68k` reads it and stops naming the missing key rather
than guessing, because the failure it exists to prevent is a deploy that
quietly went to whatever machine a stale default named.

- **The canonical binary is `New Old World`.** The build emits it as
  `New Old World.bin` beside `now-guest-ppc.bin` (the CMake target name can't
  hold a space, so `now-guest-ppc/tools/name_macbinary.py` stamps the product
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
- **The name gates the MIRROR too, and that half is silent.** Preferences
  are the mild consequence. `peek.c :: current_app_identity` also requires
  the exact name (plus creator `NOWo`) before the app may write
  `arm_request`, so a differently-named build arms **no plane at all** and
  every act refuses — while the resident reports `active` with full
  capabilities and nothing names the cause. Renaming one build
  `now-guest-ppc` → `New Old World` took `requested` from 0 to 15 with
  nothing else changed (2026-08-05). So a side experiment can carry its own
  name right up until you need a plane, and plane work is the one case
  where the canonical name is part of the test rig, not the product name.
  See [docs/resident-components.md](docs/resident-components.md) >
  "no writer".
- **Check the build stamp before believing a test result.** It can read
  a few minutes early, because CMake touches `build_stamp.c` at the end
  of a build; `touch now-guest-ppc/src/core/build_stamp.c` first to force it current.

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
- **Commit early and often — a session can end without warning.** Commit
  a checkpoint as soon as you have something coherent, and again as you
  go. Do not save it all for the end, and above all do not wait for the
  gate: an unverified checkpoint labelled as one is worth far more than
  a clean tree nobody can recover, and you can always commit again once
  it is green.

  This is not tidiness, it is the most-paid-for lesson in this
  repository. On 2026-07-30 a twelve-capability arc lost six agents to
  host crashes and upstream API errors. **Every one died with work
  uncommitted**, and the difference was stark: the agents that had
  banked nothing needed a full salvage by hand, or were lost outright,
  while the last one died at the same point having already committed
  implementation, module, docs and tests — so finishing it meant running
  one gate. Same failure, minutes apart in cost.

  Two corollaries. A checkpoint's message should say plainly that it is
  unverified, so whoever finds it knows what they have. And if you are
  resuming someone else's interrupted work, **commit their tree before
  you touch it** — it is one careless checkout from oblivion, and it is
  not yours to lose.
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

**`docs/` is published; `docs/local/` is scratch and gitignored.** The
split is by audience, not by who typed the file. `docs/` is read by
people who have never seen this project, and every file there is a
deliberate decision to explain something to that person — a standard that
cannot survive the same directory also being where a session drops its
working notes. Session handoffs, investigation logs, raw run output and
not-yet-committed plans go in `docs/local/`; its
[README](docs/local/README.md) carries the rule and, more importantly,
how a note **graduates** out of it. A finding written into a scratch file
and never graduated is how a lesson gets paid for twice.

`README.md` carries **what works and what does not**, together. A
feature list without its companion is a sales pitch, and the things this
project got wrong were never in the parts anyone demonstrated.

[docs/open-issues.md](docs/open-issues.md) is the ledger, organised
around **broken** versus **unverified**. Every arc ends by updating it —
including the arcs that went well, because "we shipped it and here is
what we still do not know" is the useful half.

[docs/mirror-knowledge.md](docs/mirror-knowledge.md) is the page the
standing rule **check Mirror before deriving anything** points at — what
the sibling project already measured, and where. NOW re-derived Mirror's
answers twice in one day before this line existed; the rule was there and
nothing made it cheap to follow.

[docs/contract-coverage.md](docs/contract-coverage.md) is the inventory
of **who serves what** — every message type, all 16 `x-commands` verbs
and the census probes, per guest, with served and PROVEN kept as
separate columns. **A change to what a guest serves updates it in the
same commit**, the way a behaviour change updates the contract first.

Two rules it has already had to learn the hard way, both worth keeping
in mind when you edit it:

- **Derive it, do not remember it.** The file carries the `grep`
  commands that produce it from the guests' own dispatch tables. Run
  them; do not hand-edit a row from memory.
- **Do not count message types.** `command.request` and `census.request`
  are one row each and open into 16 verbs and 14 hardware probes. The
  first version of that file counted rows, showed two ticks, and so said
  nothing about the fact that NOW-68K cannot report its own CPU or RAM.
  Any row that is a subsystem gets expanded.

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
