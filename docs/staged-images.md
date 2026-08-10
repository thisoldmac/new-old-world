# Staged images: whose image is this, and what is in it?

Read this before you bake anything, and before you quote a measurement
taken on an emulator.

There is exactly one shared mutable file at the centre of this:

    ~/Lab/Assets/os91-qemu/now-mirror-stage.qcow2

It is a Mac OS 9.1 disk image with the NOW Extension baked into its System
Folder. **It is shared, it is mutable, and the last bake wins.** Everything
below follows from those three words.

## The one-minute version

| You are… | You want |
|---|---|
| changing `ext/` or `contract/peek_table.h` and need a machine to test on | `scripts/bake-ext-image` — **private, the default**, touches nothing shared |
| running a sweep, a fidelity pass, any ordinary guest work | `scripts/spin-up-ppc` — it clones the **designated base** and stages **your tree's** build into the clone |
| unsure which base you should be cloning at all | `tools/base-image which` — and `tools/base-image fit <image> --purpose …` for whether it is fit |
| landing finished resident work that everyone else must now clone | `scripts/bake-ext-image --shared` — announce it first |
| about to quote a number from an emulator run | copy `$NOW_SPIN_RUN/provenance.md` into the report |
| wondering whether the oracle is trustworthy right now | `tools/ext-bake-gate verify-image` |

## Which image is under test — the mistake that made this page

On 2026-08-06 a coordinating session told the human that an arc's
measurements were suspect because the shared stage image was stale. It was
wrong twice, and a lane had to correct it:

- **`scripts/spin-up-ppc` did not use the stage image.** Its `BASE`
  defaulted to `os91-runner.qcow2`. It clones its base, stages *this
  checkout's* ext and app into the clone, cold-boots so the INIT loads, and
  asks the guest to identify itself — so the resident under test is the
  tree's build either way. (The default is gone; see *Which base, and is it
  fit* below. The staging is unchanged, and is still why a stale base warns
  rather than refusing.)
- **The stage image was not merely stale, it was unaccounted for.** Its
  sha256 matched no receipt at all. Something wrote it at 01:58 while the
  newest receipt was written at 01:19, and its content mtime was three days
  older than both — a rollback, by hand, leaving nothing behind that said
  so.

Neither fact was hidden. Both were quiet: one line defaulting a shell
variable, and a hash nobody had compared. **A careful reader got it wrong,
so the cure is volume, not care.** Every run now prints a provenance block
and writes `provenance.json` and `provenance.md` into its run directory.
Copy the file; do not remember which image you used.

## The gate asked the oracle; the script cloned a different file

The same split had a second, longer-lived consequence, found on
2026-08-07 by a person seeing a dialog rather than by any gate.

`ext-bake-gate` requires `volumeClean` in a receipt, and **a receipt
describes the baked oracle.** `os91-runner.qcow2` is never baked and so
had no receipt to require anything of — and it had been dirty since
**19 July**. Every `spin-up-ppc` clone for nineteen days booted into
"Your computer did not shut down properly", a modal that sits on the
desktop until something dismisses it. Nothing measured it, nothing
reported it, and every gate over staged images was green throughout.

The gate and the script **named different files**. So the check moved to
where the file is: `tools/image-provenance` now asks the *volume* of
whatever image it is describing — every image, including the plain
unbaked bases no receipt covers — and prints the verdict in its block and
its rig table. `spin-up-ppc` and `bake-ext-image` already ran it on their
base; `q800-68k` now does too, which was the third clone site nobody was
inspecting.

**It warns; it does not refuse**, for the reason `verify-image` warns:
whether a shared base is clean is not a property of the run about to
start and is not in that caller's power to fix. It is not even a wrong
result — only a slower boot and a dialog. Refusing would strand a
contributor over something they cannot act on, which in this repository
is the more expensive failure.

`unknown` is kept as its own state. An image that could not be read — a
running VM holds a write lock, the format is unfamiliar — is **not
clean**. Folding the two together is precisely how `qemu-img check` came
to stand in for a question it cannot answer.

## Which base, and is it fit — `tools/base-image`

Four times a run has been pointed at a base nobody meant, and the shape of
the recurrence is worth more than any of the four:

| when | what | what came out of it |
|---|---|---|
| 2026-08-06 | the stage image was three days old while six `ext/` commits landed that day; every session cloned it | `tools/ext-bake-gate` |
| 2026-08-06 | three bakes installed images whose HFS volume was still marked mounted; `qemu-img check` called all three clean | `tools/volclean.py` |
| 19 July → 08-07 | `os91-runner.qcow2` sat dirty for nineteen days, opening a modal on every clone | the volume check moved into `image-provenance` |
| 2026-08-07 | `spin-up-ppc`'s `BASE` **defaulted** to `os91-runner.qcow2`, so a whole arc cloned a 19 July image | this section |

**Each fix guarded the layer that had just failed, and the next failure
happened one layer away.** Bake is well gated; the *clone sites* were not
gated at all. And the answer to "which base" was spread across a default in
a shell script, a comment contradicting it, `ext/stage-receipts.json` and
prose in AGENTS.md — the exact shape this project's own rule forbids.

So the answer is stated **once**, keyed by purpose rather than by path:

    tools/base-image which                       # the designated PPC base
    tools/base-image fit <image> --purpose ppc-work --stages-resident

`ppc-work`, `oracle` and `bake` all designate
`~/Lab/Assets/os91-qemu/now-mirror-stage.qcow2`. `68k` designates nothing —
there is one 68K base and `.env.lab` names it — and the tool says so rather
than checking a question it did not ask. `scripts/spin-up-ppc`,
`scripts/bake-ext-image` and `scripts/q800-68k` all consult it before they
clone, and **a test fails if a new clone site does not** — because a
hand-maintained list of layers is what was missing all four times.

### Warn or refuse, argued per check

Picking one severity for all of them is how a gate stops being read. The
rule is `ext-bake-gate`'s: refuse when the fix is in the caller's power and
the failure would otherwise produce a **wrong result that looks right**;
warn when the caller cannot act on it, or when the cost is inconvenience
rather than a false conclusion.

| check | warns | refuses |
|---|---|---|
| the file is not there | — | always |
| not the designated base | ordinary work — a private bake is legitimate | `--purpose oracle`, where the conclusion is about *the* stage image |
| volume dirty | always — a slower boot, and not this run's to fix | never |
| volume `unknown` | always, in its own words — **not** clean | never |
| base's resident older than this checkout's `ext/` | when the run stages a fresh resident (`--stages-resident`) | when it does not: the measurement would be of an old resident and read as current |
| shared oracle whose bytes no receipt claims | when the run stages a fresh resident | when it does not |

`--stages-resident` is the load-bearing flag and it must be told the truth.
`spin-up-ppc` passes it because it stages this checkout's ext and app into
the clone and cold-boots; a site that only boots must not. `spin-up-ppc`
refuses `NOW_SPIN_PURPOSE=oracle` outright for that reason — it can never
be a measurement of the baked resident, so declaring itself one would be a
lie told to the gate.

Which has a consequence worth saying plainly rather than discovering:
**no clone site in this tree can currently trip the refusal path**, because
all three stage a resident. The refusals are for the caller that boots a
base as it is, and for a person running `tools/base-image fit --purpose
oracle` by hand before quoting a result about what is baked into an image.
If you write a site that boots without staging, that is the moment those
rows start doing work.

A refusal can be overridden the way the other floors in this repository
are, and on the same terms: `NOW_BASE_FORCE=1` **with**
`NOW_BASE_FORCE_REASON="…"`. A force with no reason is still refused — the
written decision is the point, not the escape.

### Every finding names an act

Not decoration. On 2026-08-06 four lanes read a true warning and correctly
did nothing, because it named an action none of them could safely take. A
warning nobody can act on is broken however true it is, so each finding
carries what the reader should do and who can do it — re-bake, re-ask when
the VM is down, quote `provenance.md`, say it in the channel.

### Repairing a base image

Only a Macintosh can clear the bit, and the applet route is the only one
this rig has: QMP keyboard events never reach the guest (`Ctrl-F2` menu
access was tried on 2026-08-07 and the modifier is dropped), and the
Finder's own Shut Down needs NOW's act plane, which a plain base does not
carry. So:

1. `cp -c` the base to a work copy. **Never boot the shared file.**
2. Boot the copy in place and wait for the anchor. The Disk First Aid
   pass runs and repairs during that boot; dismiss its modal with the
   worker's `key` verb (`{"key": "return"}`).
3. Push `NowShutDown.bin` to `Macintosh HD:TimBotTu:now-dev:NOW Shut
   Down` and run `tools/shutdown-guest.py`. **Never a QMP `quit`** — that
   is the power cut that sets the bit in the first place.
4. `tools/volclean.py` the copy, then `qemu-img check` it. Both, and in
   that order: the second answers a different question.
5. Back up the original as `.bak-YYYYMMDD` and install by atomic `mv`,
   removing the stale `.sha256` and `.volclean.json` sidecars.

A repaired base keeps the shutdown applet at that path, and that is
deliberate: `tools/stage-ext.py` puts the same file there on every clone
anyway, and its presence makes the base repairable next time without a
68K build.

`docs/fidelity-sweep-2026-08-07-a.md` is the standard the generated table
is trying to reach — it named the base, its sha256, the resident's
`sourceManifest` and `buildFingerprint`, and said in words that the stage
image "was not used and is not the oracle for this sweep." It was written
by hand. The next one should not have to be.

## Baking your own image (the default, and what lane work uses)

    scripts/bake-ext-image                      # ~5 minutes, one VM
    scripts/bake-ext-image --name plane-abi     # if the branch name is not the point

It clones the shared oracle, stages your build, cold-boots, and refuses to
install anything unless the **guest itself** says it is running your
resident (lifecycle, capability word, `buildFingerprint`, `sourceManifest`),
the container checks out, and the HFS volume inside is cleanly unmounted.
Then it installs into:

    ~/Lab/Assets/os91-qemu/agent-stage/now-stage-<branch>.qcow2
    …/now-stage-<branch>.qcow2.provenance.json     ← its account of itself

**`ext/stage-receipts.json` is not written.** A receipt in that file means
*"the shared oracle contains this resident"*, and your image is not the
shared oracle. The commit gate refuses a `throwaway` receipt found there,
rather than trusting nobody will paste one in.

Boot it:

    NOW_SPIN_BASE=~/Lab/Assets/os91-qemu/agent-stage/now-stage-<branch>.qcow2 \
    NOW_SPIN_RUN=/private/tmp/nowvm-$$ NOW_ANCHOR_PORT=<yours> \
    NOW_WIRE_PORT=<yours> scripts/spin-up-ppc

Throw it away when the lane ends: `rm -f …/now-stage-<branch>.qcow2*`.

## Updating the shared oracle (a decision, not a step)

    scripts/bake-ext-image --shared

Do this when resident work is **finished** and every other session must now
be testing against it. It prints a banner, and it refuses while other QEMU
guests are running on this Mac (`NOW_STAGE_SHARED_FORCE=1` overrides) —
because a bake mid-arc silently replaces the base under a sweep in
progress. On 2026-08-06 six lanes were live and one was in `ext/`; the only
reason a bake did not pull the floor out from under the others is that
nobody happened to run one, which is luck rather than a safety property.

**Hand it over out loud.** Say in the channel: what resident, which branch,
the new sha256. Anyone mid-run against the old image needs to know their
base changed, and their run directory's `provenance.md` will still name the
old one — correctly, which is the point.

## What each gate can honestly assert

This distinction decides which of them may refuse a commit, and it is worth
more than the gates themselves.

| Gate | Asserts | May it refuse? |
|---|---|---|
| `ext-bake-gate check` | the resident release tuple did not roll back and a receipt in this tree records a bake of the exact declared resident build inputs | **yes** — both are facts in git, entirely in the committer's power |
| `ext-bake-gate verify-image` | the bytes at the oracle's path hash to what the newest receipt claims | **no, on the commit path** — a fact about a shared file any lane can invalidate a second later. It warns, loudly. `--require` refuses for a caller who has asked for it |
| the staged-receipt check | a receipt being *written* is true when written | **yes, in one case** — see below |
| `ext-bake-gate merge-check` | a merge did not silently combine two branches' claims | **yes** — via `pre-merge-commit` |
| `ext-bake-gate main-ref-check` | the exact resident build proposed for `main` does not roll its release tuple back and is covered by a verified shared bake and promotion | **yes** — via `reference-transaction`; sees merge commits, fast-forwards and direct ref updates, with no branch-deferral override |
| `tools/image-provenance` | these bytes are (or are not) claimed by a receipt, **and whether the volume inside them is cleanly unmounted** | nothing; it only speaks |
| `tools/base-image fit` | this base is (or is not) the designated one for a stated purpose, its volume's state, and whether its baked resident predates this checkout's `ext/` | **per check** — see *Warn or refuse, argued per check*. It is the only gate here that runs **before a clone**, which is why it may refuse at all |

The staged-receipt case is the subtle one, and it was found by its own
test. A receipt whose `imageSha256` does not match the file it names has
**two possible causes**, and the file's ctime separates them:

- the file was written **after** the receipt's timestamp — another lane
  baked over yours between your bake and your commit. Your receipt is an
  honest record of a bake that happened. **Warn.** Refusing here would
  strand correct work for a reason its author cannot act on, and re-baking
  to satisfy the gate would stomp the other lane straight back.
- the file was written **before** it — the file at that path has not
  changed since before this bake claims to have installed it, so this bake
  did not install it. That was never true. **Refuse.**

### A deferral is a promise, and it comes due at `main`

`TBT_DEFER_EXT_BAKE=1` with a written reason lets a resident change be
**committed** without a bake. That is right, and it is used honestly: on
2026-08-06 the at-arm census lane deferred twice with reasons that said
plainly the bake was sequenced rather than skipped.

It does not let the change **land**. On a branch, a deferral is a
sequencing decision with a name on it; merged to `main` it is an unbaked
resident that the oracle every session clones disagrees with, excused by a
note nobody will read again. So `merge-check` refuses on `main` — and only
on `main`, because lane-to-lane merges are how thirteen concurrent branches
share work and gating those would cost more than the drift it prevents.
The same written override applies: `TBT_DEFER_EXT_BAKE=1` with a reason.

### A note is not a bake

An image can arrive at the oracle's path without a bake — that is what
happened at 01:58 on 2026-08-06, when the last known volume-clean file was
cloned back over it by hand after three bakes installed dirty volumes. A
good decision, written up in `docs/open-issues.md`, and invisible to every
gate: the file then matched no receipt and read as a mystery.

`tools/ext-bake-gate note-image --reason "…"` records who put those bytes
there and why. The verdict it produces says in words what it is: *placed by
hand and recorded — no bake, nobody asked a guest what resident is inside.*
A note never satisfies the commit gate, and there is a test asserting that,
because the 01:19 receipt is this project's standing reminder that **a
check adjacent to the question reads exactly like an answer to it**.

And what none of them can assert: that a receipt is *true*. A receipt is a
record another session wrote about a bake it ran. The gates check that the
record and the file agree about which file — not that the bake did what it
says.

## Merges

`ext/stage-receipts.json` **conflicts by design**. Two lanes each appending
a receipt merges cleanly and produces a file whose last bake entry — which
every gate reads as "the newest bake" — is whichever line sorted last, not
whichever bake happened last. AGENTS.md already says this about derived
tables: *treat a clean textual merge of a derived table as no evidence at
all.* Here the underlying thing can change without any branch touching a
file, which makes it worse.

- `.gitattributes` routes the file to `tools/receipts-merge-driver`, which
  always conflicts and writes a time-ordered proposal to
  `.git/nowreceipts-proposal.json`.
- The driver body lives in per-clone git config (`tools/setup-hooks` writes
  it), so a clone that skipped setup gets git's ordinary merge —
  `.githooks/pre-merge-commit` re-checks the result and aborts the merge
  *commit*. `.githooks/reference-transaction` separately gates the proposed
  `main` object before any merge commit, fast-forward, fetch refspec, or forced
  ref update lands. It also compares `contract/resident_version.h` in the old
  and proposed trees, so a freshly promoted binary cannot keep presenting the
  prior resident's version; `.githooks/post-merge` then reports what image
  exists.

Resolve it by **asking the file**, not the receipts: `tools/ext-bake-gate
verify-image` prints the sha on disk and which receipt claims it. If it
matches neither side, the honest resolution is to re-bake or to land saying
plainly that the oracle is unaccounted for. Picking a side to make the
conflict go away writes a claim nobody checked.

## First: are the gates even wired?

    tools/hooks-doctor

On 2026-08-06 the answer was **no, and never had been**. `core.hooksPath`
was the absolute path `now/.githooks` — the worktree *container*, parked on
a commit from before `.githooks/` existed — so no pre-commit hook had ever
run in any NOW worktree. Eighteen worktrees carried their own copy of the
same broken value, shadowing the shared one.

An absolute `core.hooksPath` is wrong by construction in a multi-worktree
repository: it aims every worktree at one checkout's hooks. Only the
relative `.githooks` resolves to the hooks the worktree has checked out.
`tools/setup-hooks` has always set the relative form; something else did
not. `tools/hooks-doctor --fix` removes the per-worktree overrides and puts
the relative value in the shared config.

The consequence worth remembering is not the config, it is what a dead gate
did to an honest decision. A lane deferred a bake twice with written
reasons — and **nothing was written**, because the mechanism that records a
deferral is the gate that never ran. `tools/ext-bake-gate defer --reason
"…"` now records one directly, and this is why the merge gate keys on the
digest of the resident source rather than on a deferral being present: a
missing record must not read as nothing to do.

`scripts/test-all` runs the doctor first and, when the gates are not armed,
its final line stops saying they passed.

## Why images kept arriving dirty: nobody was careless, they were cornered

Five of the seven preserved images on this Mac have the HFS "volume
unmounted" bit clear, so every clone of them opens in Disk First Aid
(`tools/volclean.py`, run over all of them 2026-08-07):

| image | mtime | volume |
|---|---|---|
| `now-mirror-stage.qcow2` | 08-06 01:58 | clean |
| `now-mirror-stage.qcow2.bak-20260806` | 08-06 00:44 | clean |
| `now-mirror-stage.qcow2.bak-20260806-2` | 08-06 01:10 | **dirty** |
| `now-mirror-stage.qcow2.bak-20260806-3` | 08-06 01:19 | **dirty** |
| `now-mirror-stage.qcow2.bak-20260806-4-dirty` | 08-06 01:58 | **dirty** |
| `now-mirror-stage.qcow2.bak-…-pre-transport` | 08-06 01:12 | **dirty** |
| `os91-runner.qcow2` | 07-19 13:55 | **dirty** |

`volclean.py` and the bake gate were built to DETECT this. Nothing had
established **why it kept happening**, and the question matters: a rule
everybody breaks is not a rule, it is a description of tooling that made
the rule impossible.

**The mechanism, established 2026-08-07.** A lane reported, honestly, that
it had power-cut its VM against the rule, because the graceful route
refused: the lab's `tools/shutdown-guest` asks the Finder through the
anchor's `script` verb, and the anchor refuses it. Its message ends
*"nothing here can shut this guest down gracefully; that is a scope
decision, not a bug in this tool."* The lane was then choosing between a
power cut and leaving a VM running for the next lane to trip over. It took
the power cut and said so.

Two things about that refusal, and both of them are worse than they look:

- **It fires for every lane, every run, always.** The scope is not a
  per-session decision. It is a static `worker.session` file baked into
  the image, and it is byte-identical in both bases — the same 24 verbs,
  the same `policyDigest` 328e2ef0…, stamped `"owner":"canonical"`. So
  "most sessions are fine and this one was unusual" was never available as
  an explanation.
- **The sentence is false about this rig, and the false half is the
  expensive half.** `launch` IS in that baked scope, which is exactly why
  NOW's staged-applet route works; and the Finder route
  (`shutdown-guest.py --wire`) never asks the anchor at all. Two graceful
  routes were open the whole time. Nothing said so, and the tool an agent
  finds first is the one with the obvious name.

**And our own callers steered onto the dirty route.** `--wire` is what
selects the Finder route, the only one measured to leave a clean volume;
without it `shutdown-guest.py` falls to the applet, which starts a
shutdown without reliably finishing one. Until 2026-08-07 neither
`tools/lane-ports reclaim` nor the `stop:` recipe `scripts/spin-up-ppc`
prints passed it — while both printed the words *guest-clean*.
`scripts/bake-ext-image` did pass it, and checks `volclean` afterwards;
that is why the current oracle is clean and the older bakes are not.

### What a lane does now

    tools/shutdown-guest.py <qmp.sock> --port <anchor> --wire <wire>

It prints the route list **before** it tries anything, read from the
anchor's own `hello`, so a refusal is a route list rather than a mystery.
If every graceful route fails it names three options and what each costs —
retry with `--wire`, leave the VM up and say so, or `--force`. There is no
ending where the reader is left holding two bad choices and no third; that
is the same failure as the dead-hooks warning four lanes read, believed,
and correctly did nothing about.

`--force` is a QMP `quit` made in the open. It asks
`tools/shared-image-guard.py` first, which **refuses outright** if the
machine is writing to a shared image (`launch --base` does), fails closed
when it cannot tell, and does not object to a read-only backing file. When
a cut does happen the disk is stamped `<image>.power-cut`, because the
damage is otherwise invisible until something boots the image — by which
time it is somebody else's afternoon.

**Still true and still the rule:** a bare QMP `quit` is a power cut. What
changed is that refusing it no longer means abandoning a running VM.

## Which rig tools a lane can actually rely on

Three times on 2026-08-07 a brief cited a tool that was not present on the
branch it was cited to, and each time the lane either worked around it or
broke a rule. Measured across the 48 `claude/019-*` branches:

| tool | present on | absent from |
|---|---|---|
| `tools/shutdown-guest.py` | 47 | 1 |
| `tools/volclean.py` | all | — |
| `tools/lane-ports` | 42 | 6 |
| `tools/arc-status`, `docs/arc-coordination.md` | 18 | **30** |

The first two are safe to cite anywhere. `tools/lane-ports` nearly is.
`tools/arc-status` is on integration branches and nowhere common, so an
instruction that names it is wrong for most worktrees — which is how it
became the third instance of the same mistake in one day.

**And naming a branch to fetch it from has its own failure, which is
worse.** A missing tool announces itself; a stale one does not. The copy
on `claude/019-integration-5` — the one the standing arc-trigger check
still names — globs `claude/01[0-9]-*` and is silently blind to every
`02x` lane. 40 of the 49 branches carrying the file carry that glob
(derived 2026-08-08). The tool now refuses to run when its glob cannot
see the newest arc; see
[arc-coordination.md](arc-coordination.md) > "Where to fetch it".

Two more traps worth knowing before you reach for the parent checkout:

- **`tools/shutdown-guest` (no `.py`) is a different tool.** It lives in
  the lab checkout, not here, and it is the one that refuses; NOW's is
  `tools/shutdown-guest.py`. A lane that finds the parent's by name has
  found the broken route.
- **A worktree outside the repo tree could not run it at all.** The lab
  checkout was located by walking up from the worktree, and an agent
  worktree cut into `/private/tmp` has no such ancestor — so the one tool
  that stops a VM cleanly answered with `ModuleNotFoundError`. It now asks
  git where the real checkout is; `NOW_LAB_ROOT` still wins.

**The landing decision, which is not this lane's to make:** if a rig tool
is meant to be citable in a brief, it belongs on the arc base so every
lane inherits it. `tools/arc-status` and `docs/arc-coordination.md` are
the two that currently are not, and they are the two that keep being
cited.

## Run it

    tools/image-discipline-tests     # every mutation, ~3 seconds
    scripts/test-native              # includes the shutdown-route gate
    tools/gate-impact-sweep --all-matching 'claude/018-'

The second is the one to run before tightening any gate here: it stages
each live branch's own last commit and reports only whether the proposed
gate refuses something the old one accepted. This repository's most
expensive lesson is uncommitted work lost, and a gate that refuses a
correct commit converts a crash-shaped risk into a certainty.
