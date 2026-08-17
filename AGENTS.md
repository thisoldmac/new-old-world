<!-- now-doc-provenance: generated reviewed=false -->

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

## THE BLESSED PATH

> **Force the code through the blessed OS path so the OS's behavior,
> not ours, is what ships.**

When Michelle asks for a **native** dialog, drag, progress window, or any
OS-owned surface, that is an *architectural instruction*, not a styling
target. The acceptance test is that **our code draws nothing and the OS's
own component appears** — a real `DragRef` in flight, the Finder raising
its own replace dialog, a genuine copy-progress window. A hand-composed
lookalike passes a screenshot while silently discarding the one property
that was requested: the OS's machinery carrying the behavior and its edge
cases for free. That is agent-created debt, and it has been created twice
in this repository (a styled `now_confirm` replace dialog and a styled
transfer windoid, both delivered against an explicit ask for native).

This binds **both machines equally**. On the guest the blessed path is
the Toolbox's: a real `DragRef`, the Finder's own dialogs, the Drag
Manager's ghost. On the host it is AppKit's: a real `NSDraggingSession`
begun the way AppKit begins one, `NSFilePromiseProvider` delivering the
file so macOS shows its own drag image and copy behavior — not an
asserted seed into a borderless panel, not an eager fetch that writes
the file itself and leaves the promise as decoration.

If you cannot reach the blessed path, **stop and report the wall** with
evidence (the way slice 2 reported `inwin=1`), so the wall itself becomes
the work. Do not ship the imitation.

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

- **`scripts/test-all` is the gate.** It runs the four below in order,
  cheapest first, and stops at the first failure naming it. A broken
  frame codec should cost two seconds to find, not the four minutes
  xcodebuild takes to reach the same conclusion by a longer route.
- MirrorKit: `scripts/test-mirrorkit` — the NOW-owned package at
  `now-host/Packages/MirrorKit/` and its own suite. It became stage 2 on
  2026-08-06 **because it was missing**: the imported package was tracked
  in this tree,
  and no gate ran it, so `test-all` read green for three days with seven
  of those tests red. That is the same hole as "every other gate can be
  green while neither guest compiles" — a gate is only as wide as the
  tools it invokes. Its output is logged rather than shown, but a SKIP is
  pulled back out and echoed, because a gate that quietly declines to run
  is how this one came to be missing in the first place.
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
- **Product code does not merge on automated gates alone.** A pull request
  touching the product paths declared once in
  `.github/repository-policy.json > code_qa.product_code` needs current-head
  `Emulator QA` and `Metal QA` statuses. The emulator status is an agent-driven
  sweep of every affected surface on the applicable emulators, not merely a
  rerun of native tests. The metal status records QA on the applicable physical
  machine with the build and machine guards above. Record them with
  `tools/code-qa`; a later push invalidates both because GitHub requires them on
  the new head. Only the human owner may run `tools/code-qa override-metal`, and
  an override is explicit evidence of missing metal proof, never
  metal-verification. Agents must stop and ask; they may not invoke or answer
  its interactive confirmation. GitHub Team cannot enforce required environment
  reviewers on this private repository, so that final human/agent distinction
  is a working rule backed by an audited PR record rather than a platform claim.
- **Your ports are derived, not asked for.** `tools/lane-ports` hashes
  your worktree path to a block of eight ports nobody else can pick, and
  `scripts/spin-up-ppc` already defaults to them — so no coordinating
  session hands out `--port N` and no lane has to ask. It replaces
  exactly that, and the hand-assigned scheme it replaces lost a lane's
  run on 2026-08-06 to a port held by a VM nobody owned any more. The
  guards now answer *whose* a held port is, and a block whose owner died
  is reclaimable by its owner alone (`tools/lane-ports reclaim` — through
  QMP by socket path, never `kill` on what `lsof` named).
  [docs/lane-ports.md](docs/lane-ports.md).
- **An instrument that READS a live machine must assert that the plane
  armed** — the same shape of rule as the two above, and it has already
  cost this project four durable sentences. A metal gate asks *which
  build answered* because the alternative reads green having reached
  nothing; an observing rig must ask *was there anything to see*,
  because the alternative reports absence and defect in the same words.
  Integration rounds 2 and 3 rendered over a scene envelope, and
  `SceneBuilder.normalizeWindows` sets `display: nil` unconditionally —
  so no interior was ever on disk, every window looked empty, and the
  emptiness was written down as four separate render defects. The check
  is cheap and it is about the ARTIFACT, not the intent: a stored
  capture proves the content plane was reachable only if it wrote a
  drain, whatever the guest was doing. **"I armed it" is not the
  assertion; "the artifact carries it" is.** The dated correction is in
  [docs/open-issues.md](docs/open-issues.md) and the re-derivation in
  [docs/fidelity-sweep-2026-08-07-c.md](docs/fidelity-sweep-2026-08-07-c.md).
  Its companion: **a count you did not derive is not evidence** — the
  honest unit is the store you can check, not sentences agreeing with
  each other across five documents.
- `GuestWireConformanceTests` reads `now-guest-ppc/src/**/*.c` and checks every
  message the guest can emit against this side's decoder and the
  contract's required fields. **If you add a message built across
  several `snprintf` calls, it will fail** until you give it a fixture —
  that is deliberate, and the failure text says so.

**A test you have not watched fail proves nothing.** Verify a new guard
by mutation: reintroduce the bug and see it named. And a test that
constructs the message it then parses tests one half twice.

**A test watched to fail against ONE mutation is not watched to fail.**
Watch it fail against the mutation it *claims* to catch, and confirm the
mutation actually built and the test actually ran. Both halves have been
paid for here on the same day: two render guards passed the exact
mutation they were written for — each having been watched failing against
a *different* one — and a stability gate passed its mutation twice, for
two unrelated reasons, before it was right; separately, a mutation
harness watching only for `Test Case … failed` read a **build failure**
as no failures, which is a green that never ran. A guard is green for
whatever reason it likes, and only the mutation it names distinguishes
those reasons.

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

## The stage image is the resident under test

`~/Lab/Assets/os91-qemu/now-mirror-stage.qcow2` is the local oracle for
**resident (`ext/`) work**: it is the image with the NOW Extension baked
in, so the resident it holds is whatever was baked — not whatever this
checkout last compiled, and staging a fresh INIT into a throwaway clone
changes the clone, never the image.

**What an ordinary run clones is not something to remember — ask
`tools/base-image which`.** That is the one place the answer lives, keyed
by purpose, and every clone site consults it (`spin-up-ppc`,
`bake-ext-image`, `q800-68k`); a test fails if a new one does not. It also
answers whether a base is **fit** to clone — designated, volume clean, and
whether its baked resident predates this checkout's `ext/` — refusing or
warning per check, with the argument for each in
[docs/staged-images.md](docs/staged-images.md).

Two things this page got wrong in two days, and both are why the answer
moved into a tool. It once said the stage image is what every sweep clones;
on 2026-08-06 a coordinating session read that, told the human an arc's
measurements were suspect, and had to be corrected by a lane that read the
script. Then `spin-up-ppc` defaulted `BASE` to `os91-runner.qcow2` in one
line of shell — so on 2026-08-07 a whole arc cloned a 19 July image, which
is the same stale-oracle failure one layer below every gate. Note that
`spin-up-ppc` stages *this checkout's* ext and app into the clone and
cold-boots either way, so the resident under test there is the tree's
build; that is why a stale base warns rather than refusing.

[docs/staged-images.md](docs/staged-images.md) is the page: which mode to
bake in, what each gate can honestly assert versus imply, and how to hand
a shared bake over. The rules that must not be restated anywhere else:

- **Bake your own by default.** `scripts/bake-ext-image` installs into
  `~/Lab/Assets/os91-qemu/agent-stage/` under your branch's name and
  touches nothing shared. `--shared` is the deliberate, announced act that
  replaces the oracle everybody clones; it refuses while other guests are
  running on this Mac. Nothing in flight should be baking `--shared`.
- **A commit that changes any declared resident build input must be baked
  first**, enforced by `tools/ext-bake-gate` from `.githooks/pre-commit`.
  This includes `ext/`, the shared sources the extension compiles, and its
  contract headers. `contract/resident_version.h` is the intentional release
  identity used by both the shared table and the resident's own liveness
  connection; development builds may share it, while the gate refuses a
  rollback. The newest receipt in `ext/stage-receipts.json` must also
  record a bake of
  exactly this source, with the five facts that make a bake believable —
  the fingerprint the **guest itself** reported, the image sha256, a
  passing `qemu-img check`, a guest-clean shutdown, and a cleanly
  unmounted **volume**, which is a different question from the other four.
- **Deferring is a written decision, never silence — and it comes due at
  `main`.** `TBT_DEFER_EXT_BAKE=1` with `TBT_DEFER_EXT_BAKE_REASON="…"`
  allows the *commit* and writes the reason into `ext/stage-receipts.json`,
  so it lands in the same commit as the work it excuses. It does not allow
  the *landing*: `.githooks/reference-transaction` checks the exact old and
  proposed `main` trees and refuses any resident build-input change whose
  version rolled back or which is not covered by a verified **shared** bake
  receipt. It sees merge commits, fast-forwards,
  `git fetch . branch:main`, and forced ref updates—the paths commit and merge
  hooks cannot see—and a branch deferral cannot override it. Lane-to-lane
  updates are untouched. The enforcement is the floor and not the rule.
- **A note is not a bake.** An image can reach the oracle's path by hand —
  that is how the current one got there. `tools/ext-bake-gate note-image
  --reason "…"` records who put it there and why, and says in its own
  verdict that it certifies provenance only: nobody asked a guest what
  resident is inside. It never satisfies the commit gate.
- **The image is shared and the last bake wins**, so a receipt cannot say
  the file still holds what it describes. That check is no longer yours to
  remember: `tools/ext-bake-gate verify-image` runs the `shasum`, the
  commit gate warns when they differ, and `tools/image-provenance` prints
  the verdict at the top of every guest run. It **warns rather than
  refuses**, deliberately — whether another lane has baked over your image
  is not a property of your commit and not something you can act on.
- **Every guest run writes its own rig table.** `$NOW_SPIN_RUN/provenance.md`
  names the base, its sha256, whether a receipt accounts for it, what was
  staged on top, and what the guest said it was running. Quote a
  measurement by copying that file, not by remembering.
- **Receipts conflict on purpose at a merge.** A clean textual merge of
  `ext/stage-receipts.json` is no evidence at all — the same class as the
  derived tables below, made worse by the fact that the thing described can
  change without any branch touching a file. `.gitattributes` +
  `tools/receipts-merge-driver` force a decision;
  `.githooks/pre-merge-commit` and `post-merge` catch the clones whose git
  config lacks the driver. Resolve by asking the file, never by picking a
  side to clear the conflict.

Why it is enforced rather than remembered — twice over. On 2026-08-06 the
newest stage image was from 3 August while **six** extension commits had
landed that day; every session cloned the stale image, staged a build into
a clone and discarded the clone. The rule was written down in
[docs/open-issues.md](docs/open-issues.md) and nothing checked it. Then the
same evening the image was rolled back **by hand** to that 3 August file
after three bakes installed dirty volumes — leaving an oracle whose sha256
matched no receipt at all, with nothing anywhere saying so. A shared
mutable file with quiet provenance goes stale in silence in both
directions: forward, because nobody baked, and backward, because somebody
did something reasonable and left no trace.

## Git

This checkout is **shared**. Other sessions have worktrees off it, and
agents branch in their own worktrees — so the shared checkout stays on
`main`, at the head of the work.

- **Work on a branch, never on `main`.** Before your first edit, cut one
  — `git checkout -b <type>/<kebab-slug>`, forked off the parent branch you are
  continuing, not off main. GitHub `main` receives finished work only through
  its protected pull-request path; local `main` is a mirror, not another
  landing boundary. This is
  enforced (`.githooks/pre-commit`, plus a PreToolUse hook on
  `Write`/`Edit`/`Bash` — `.claude/hooks/guard-main.sh`) — **run
  `tools/setup-hooks` once per clone** to point git at it, which every
  worktree off that checkout then inherits. `.githooks/pre-push` refuses every
  direct remote-main update, and `.githooks/reference-transaction` permits a
  local-main update only when it is the fetched `origin/main` and a
  fast-forward. There is no environment override for those two boundaries.
  The history of the old scope outage, and where every rule belongs, is
  [docs/rule-scopes.md](docs/rule-scopes.md). Branches describe the change, not
  the person or automation making it: use `feat/`, `fix/`, `docs/`,
  `refactor/`, `test/`, `build/`, `ci/`, `chore/`, `perf/`, or `revert/`.
  Do not prepend `claude/`, `codex/`, `thread/`, `fork/`, or another
  creator namespace. `release/vX.Y.Z` is reserved for qualification.
  `tools/git-policy` enforces the grammar and grandfathers only work whose
  merge base predates the policy.
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

The public guide is built by MkDocs from `mkdocs.yml` at the `/docs/` base
path. `docs/user-guide/` and `docs/developer-guide/` use the Diátaxis page
types in front matter; every curated page also declares authority, source
dependencies, lifecycle, media IDs, and a verification date. Run
`scripts/test-docs` before landing documentation or a source change named by
those pages. `tools/docs-gate-selftest` is the mutation evidence for that
gate.

Every tracked Markdown file also carries exactly one
`now-doc-provenance` comment. `generated` is a presence marker and is removed
only by a human rewrite; `reviewed=true` records a separate human review.
Generated projections and `derived-doc` pages must retain `generated`.
`tools/docs-provenance` is the grammar and corpus gate; published pages render
the state, while repository records and `docs/local/` scratch do not.

Module documentation is derived from the live host registry and PowerPC
Workshop enum through `docs/module-manifest.yaml`. A new module updates the
registry, manifest, module page, nav, and screenshot slots in the same
change. The AsyncAPI reading copy is generated with `scripts/docs-contract`;
`contract/asyncapi.yaml` remains the authority.

Screenshot placeholders are deliberate, exact-size artifacts listed in
`docs/assets/screenshots/manifest.yaml`. Replace them in place after a
privacy review; do not change dimensions or delete a slot silently.

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

Three rules it has already had to learn the hard way, all worth keeping
in mind when you edit it:

- **Derive it, do not remember it.** The file carries the `grep`
  commands that produce it from the guests' own dispatch tables. Run
  them; do not hand-edit a row from memory.
- **Do not count message types.** `command.request` and `census.request`
  are one row each and open into 16 verbs and 14 hardware probes. The
  first version of that file counted rows, showed two ticks, and so said
  nothing about the fact that NOW-68K cannot report its own CPU or RAM.
  Any row that is a subsystem gets expanded.
- **Re-derive at the MERGE, not only at the edit.** A derived number is
  true at the moment it is derived and can rot without anyone touching
  it — because a *sibling branch* changed the thing it was derived from.
  Two workstreams on 2026-08-05 each added a verb and each honestly
  re-derived this file; one wrote 40 declared / 37 PPC, the other 38 / 35,
  and both were correct when written and wrong on arrival. **Neither
  author did anything careless and the merge still produced a lie.**
  So: derive again after any merge that touched what the file derives
  from, and treat a clean textual merge of a derived table as no evidence
  at all.

### Enumerated lists rot at merges, and only a gate catches it

The rule above generalises past this one file, and 2026-08-05 paid for it
three times in one day: `contract-coverage.md`'s counts, an
`open-issues.md` heading orphaned from the body that had been retitled
elsewhere, and `mcp-coverage.md` ending with **two** "unnoticed rows,
named together" lists — one naming `mirror`, the other `hide`, neither
naming both.

All three were caught by a gate rather than by a reader, and the sharpest
one says why in its own failure text: *"Closing one is a two-place edit
and this is the second place; a stale list here overstates how much of
the surface nobody has decided about."*

Two things follow, and the second is the one that costs something:

- **A hand-maintained enumeration wants a test that reads it**, checking
  it against whatever it enumerates. `MCPCoverageTests` and
  `CommandParityTests` are the pattern; both exist because the same class
  of drift shipped once already.
- **Prose that restates a table is a second place to be wrong.** Where a
  list appears twice — once as a table and once in a sentence — either
  gate the pair or delete one. A sentence naming seven of eight rows is
  not a smaller error than a wrong number; it is a more convincing one.

**A derived document now declares itself, and the declaration is
machine-readable.** `docs/contract-coverage.md` and `docs/mcp-coverage.md`
each carry a `derived-doc` block beside their published commands: the
runnable derivations, the sha256 of each answer, and a digest of the
source files they read. `tools/derived-doc-gate` re-runs them —
`rederive` rewrites the block and logs what moved, `check` refuses a
**merge** commit whose derivations were not re-run. Three properties are
the point rather than the hashing:

- **The source digest is checked separately from the answers**, because a
  count is blind to a change of shape: two lanes added new *arguments* to
  existing verbs and every count held.
- **The prose list is derived too.** `mcp-coverage.md`'s "unnoticed rows,
  named together" is asserted equal to the table's own column, and both
  sides emit how many lists there are — two lists whose union matches the
  table is exactly the rot that shipped.
- **A confirmation is worth its line.** A re-run that finds nothing
  writes `unchanged` with the sha it ran at, because a derived table
  unmoved by 99 commits looks exactly like a derivation nobody ran.

It is **built and not armed** — `NOW_DERIVED_DOC_GATE=1` switches the
hooks on, and the arming procedure is in `.githooks/pre-commit`. Arming a
gate into a live fleet is a change to every branch at once.
`tools/derived-doc-gate-selftest` is the mutation evidence, in a
throwaway repository with two lanes and a real merge.

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
