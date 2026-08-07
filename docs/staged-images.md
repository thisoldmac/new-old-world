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
the clone and cold-boots; a site that only boots must not.

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
| `ext-bake-gate check` | a receipt in this tree records a bake of exactly this resident source | **yes** — a fact about two files in git, entirely in the committer's power |
| `ext-bake-gate verify-image` | the bytes at the oracle's path hash to what the newest receipt claims | **no, on the commit path** — a fact about a shared file any lane can invalidate a second later. It warns, loudly. `--require` refuses for a caller who has asked for it |
| the staged-receipt check | a receipt being *written* is true when written | **yes, in one case** — see below |
| `ext-bake-gate merge-check` | a merge did not silently combine two branches' claims | **yes** — via `pre-merge-commit` |
| `merge-check` on **main** | the resident source being landed is covered by a bake | **yes** — `TBT_DEFER_EXT_BAKE=1` with a reason still overrides |
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
  *commit*, and `.githooks/post-merge` reports on a fast-forward, where
  nothing else runs at all.

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

## Run it

    tools/image-discipline-tests     # every mutation, ~3 seconds
    tools/gate-impact-sweep --all-matching 'claude/018-'

The second is the one to run before tightening any gate here: it stages
each live branch's own last commit and reports only whether the proposed
gate refuses something the old one accepted. This repository's most
expensive lesson is uncommitted work lost, and a gate that refuses a
correct commit converts a crash-shaped risk into a certainty.
