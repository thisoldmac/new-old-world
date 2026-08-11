# Where each rule lives, and why that is the question

Every hook, gate and convention in this repository is enforced from
*somewhere*. This page says where each one belongs, because putting one in
the wrong place has already taken every gate in the repository offline
once, and the mechanism was not subtle.

Michelle, 2026-08-07:

> the hooks and other rules we've built out here should be persisted, yes.
> but make them at least now-specific, if not lab-scoped rather than
> mirror specific. if we have mirror specific hooks, rules and skills that
> should be landed with a mirror domain rather than treated as global

## Read this first: `now/` is a separate repository, and nothing crosses in

This is the structural fact the rest of the page rests on. **A reader who
misses it will design something impossible**, which is exactly how the
outage below happened.

`now/` is excluded from the parent TimBotTu checkout —
the parent repository's `.git/info/exclude` — so it is not a
subdirectory, not a submodule, and not part of that repository in any way
git or Claude Code can see. It is an independent repo that happens to sit
inside another one's working directory.

Three consequences, and together they are the whole shape of the problem:

- A NOW session's `$CLAUDE_PROJECT_DIR` is **this tree**. The parent's
  `.claude/settings.json` and `.claude/hooks/` are never loaded here. The
  parent's main guardrail has never once run for a NOW session.
- `core.hooksPath` is **per clone**, and resolves inside one worktree's
  checked-out tree. There is no cross-repository form of it, and an
  absolute value is wrong by construction (`tools/hooks-doctor` carries
  why).
- `~/.claude/settings.json` is the only true machine scope, and it carries
  no `hooks` block at all.

**So there is no working lab scope for enforcement today.** "Lab-scoped"
here can only mean one of exactly two things, and every entry below says
which: **(a)** it lives in `~/.claude` or `~/.codex` and is genuinely
shared — this is how all nine skills already work, correctly — or **(b)**
it is deliberately duplicated into each repository from one named source,
with the source named in both copies. **There is no third option.**
Assuming there was one is what left `AGENTS.md` claiming a PreToolUse
guard this repository did not have.

## The three scopes

- **LAB-SCOPED** — true of any project on this machine, or of any
  retro-Mac work. Wants to be inherited by every repository — and, per the
  section above, can only get there by (a) or (b).
- **NOW-SCOPED** — true of this repository: both guests, the host, the
  contract, the resident. Belongs on `main`, so every branch and worktree
  cut from `main` inherits it.
- **MIRROR-SCOPED** — specific to the Mirror subsystem. Lands under
  `mirror/`, and must not sit anywhere a non-Mirror worktree depends on.

## The concrete failure this page exists to prevent

`.githooks` was added in `543b06af` (2026-08-06) and **has never been an
ancestor of `main`**. 123 of 424 branches carry it; `main` is not one of
them. The shared checkout is parked on `claude/mirror-subproject` — a
Mirror-specific branch, from before `.githooks` existed — and 48 worktrees
carry a per-worktree `core.hooksPath` naming an absolute path into that
checkout's non-existent `.githooks`.

**A repository-wide outage caused by parking on a subsystem's branch.**
Not one gate has refused a commit in any NOW worktree since. The full
diagnosis, with the mutation evidence, is
[docs/open-issues.md](open-issues.md) > "`main` never received the gates".

## Deriving this table

Rows and coverage counts are derived, not remembered
(AGENTS.md > "Derive it, do not remember it"). Re-run after any merge:

```sh
# Which arc branches can actually reach each rule?
for f in .githooks/pre-commit tools/setup-hooks tools/hooks-doctor \
         tools/ext-bake-gate tools/receipts-merge-driver tools/derived-doc-gate \
         tools/gate-impact-sweep tools/image-provenance tools/image-discipline-tests \
         tools/volclean.py tools/lane-ports tools/arc-status \
         docs/arc-coordination.md docs/arc-triggers.conf \
         .claude/settings.json scripts/test-all; do
  n=0
  for b in $(git for-each-ref --format='%(refname:short)' 'refs/heads/claude/019-*'); do
    git cat-file -e "$b:$f" 2>/dev/null && n=$((n+1))
  done
  printf '%-34s %s/55  main:%s\n' "$f" "$n" \
    "$(git cat-file -e main:"$f" 2>/dev/null && echo yes || echo NO)"
done
```

Derived 2026-08-07 against `claude/019-integration-6` (55 arc branches,
424 branches total).

**Do not quote these numbers — re-run the loop.** The denominator moves on
its own, because lanes are still being cut: the same `arc-status` row was
honestly reported as **18/48** earlier the same day and is **25/55** here,
and neither figure was wrong when it was written. That is the ordinary
derived-document rot AGENTS.md describes, arriving inside a page *about*
where rules live, and it will happen again to whoever reads this next. The
shape of the answer — a fleet-wide coordination rule that most of the
fleet cannot reach — is what is stable; the fraction is not.

## The inventory

### NOW-SCOPED — must reach `main`

`main:NO` on every row below is the whole problem: a worktree cut from
`main` has no copy of the rule *and* no copy of the tool the rule invokes,
so `tools/hooks-doctor --fix`, which only rewrites git config, cannot cure
it.

| Rule | Governs | Arc | main |
|---|---|---|---|
| `.agents/skills/now-mcp` | routes connected classic-Mac tasks into NOW, then applies its evidence and verification order | new in the MCP audit follow-up | NO |
| `.githooks/pre-commit` | main guardrail + `ext-bake-gate check` (+ unarmed derived-doc gate) | 54/55 | NO |
| `.githooks/pre-merge-commit` | `ext-bake-gate merge-check` on an auto-resolved merge | 54/55 | NO |
| `.githooks/post-merge` | announces what the stage image is after any merge, incl. fast-forward | 54/55 | NO |
| `tools/setup-hooks` | arms `core.hooksPath` + the receipts merge driver, once per clone | 54/55 | NO |
| `tools/hooks-doctor` | asks whether the gates are wired instead of assuming | 51/55 | NO |
| `.gitattributes` | names `merge=nowreceipts` for `ext/stage-receipts.json` | — | NO |
| `tools/receipts-merge-driver` | always-conflict driver: two receipts about one shared file | 51/55 | NO |
| `tools/ext-bake-gate` | no resident commit until the stage image contains it | 54/55 | NO |
| `ext/stage-receipts.json` | the bake ledger the gate reads | — | NO |
| `scripts/bake-ext-image` | the one command that re-bakes the oracle | — | — |
| `tools/image-discipline-tests` | stage 1 of `test-all`; the image gates' own suite | 51/55 | NO |
| `tools/image-provenance` | which image is a run about to test, and can anyone account for it | 51/55 | NO |
| `tools/derived-doc-gate` (+ selftest) | a merge may not keep two honest re-derivations — **built, deliberately unarmed** | 24/55 | NO |
| `tools/gate-impact-sweep` | before tightening a gate: does it strand work in flight | 52/55 | NO |
| `scripts/test-all` and the four it calls | the gate | 55/55 | yes (stale: no `hooks-doctor` call) |
| `AGENTS.md`, `CLAUDE.md` | the conventions | 55/55 | yes (stale) |
| `.claude/settings.json` main guardrail | **missing entirely — see below** | 0/55 | NO |

One line each, on why NOW and not lab:

- **`.agents/skills/now-mcp`** — it names NOW's machine selector, consent
  boundary, semantic projections, and guest-file authority lanes. Codex's
  project skill location makes it discoverable only while working in this
  repository; installing it globally would misroute unrelated classic-Mac
  projects and preserve product-specific vocabulary at lab scope.
- **The hook family, `setup-hooks`, `hooks-doctor`, the merge driver** —
  they enforce *this repository's* branch policy and *this repository's*
  receipts file; a second project would want a main guardrail but not
  `ext-bake-gate`.
- **`ext-bake-gate`, `stage-receipts.json`, `bake-ext-image`,
  `image-discipline-tests`** — the resident, the stage image and the
  receipt format are NOW's; the *lesson* generalises (see the last
  section) but the code does not.
- **`image-provenance`** — reads `ext/stage-receipts.json`. NOW-shaped
  today; the `verdict()` half it calls (`volclean.py`) is not, and is
  filed lab-scoped below.
- **`derived-doc-gate`** — it gates `docs/contract-coverage.md` and
  `docs/mcp-coverage.md` by name. NOW-scoped, and it must land unarmed:
  arming a gate across a live fleet is a change to every branch at once,
  made by somebody on none of them.
- **`gate-impact-sweep`** — a general idea with a NOW-specific driver
  (`NOW_GATE_UNDER_TEST`, `claude/` branch namespace). Keep NOW-scoped;
  promote the *idea* to the corpus, not the script.
- **`test-all` and friends** — they invoke this tree's cross-compilers,
  Xcode target and vendored package.

#### The main guardrail that was never here

`AGENTS.md:316` says main is enforced by "`.githooks/pre-commit`, plus a
PreToolUse hook on `Write`/`Edit`/`Bash`". **That PreToolUse hook does not
exist in this repository.** It exists in the parent TimBotTu checkout
(`../.claude/hooks/guard-main.sh`, wired from `../.claude/settings.json`),
and `now/` is excluded from that repository, so no NOW session has ever
loaded it. `now/.claude/settings.json` carries only the Mirror drive loop
and the Toolbox research arc.

This is the same shape as the comment already at the top of
`.githooks/pre-commit` — *"the guard lived only in the PARENT TimBotTu
checkout, so a `now` worktree had documentation for enforcement it did not
have"* — except that fix moved only the git-hook half. The Claude Code half
was left behind, and the sentence claiming it stayed.

Closed on this branch: `.claude/hooks/guard-main.sh` is ported to NOW scope
and wired. It exits 0 on every branch that is not `main`/`master`, so it
refuses nothing that any lane is doing.

### LAB-SCOPED

| Rule | Governs | Where it should live | Why not NOW |
|---|---|---|---|
| `classic-mac-*` skills (7) | Carbon/Toolbox/INIT platform + UI, render preview, routing | already `~/.codex/skills`, symlinked into `~/.claude/skills` | they are about a machine architecture, not a product; the parent and any future retro project want them identically |
| `swarm`, `swarm-hybrid` skills | agent fan-out strategy | already `~/.codex/skills` | nothing in them mentions NOW |
| `worktree-reconciliation` skill | classifying and pruning agent worktrees | already `~/.claude/skills` (Claude-only, not shared with Codex) | it reasons about git worktrees, not about this tree |
| `tools/volclean.py` | is the HFS/HFS+ volume inside this image cleanly unmounted | parent `tools/`, imported here | a fact about Macintosh volumes; the parent bakes images too (`bake-stack`, `bake-harness-overlay`) and has the same blind spot `qemu-img check` left here |
| `tools/lane-ports` | per-lane port blocks derived from worktree path | parent `tools/`, beside `launch`/`stop`/`vms` | it keys on a git worktree root and knows nothing about NOW; the collisions it prevents are between *any* two agent sessions on this Mac, and the parent is where VM management already lives ([memory: VM workshop is the bench](../AGENTS.md)) |
| `tools/arc-status` | derived state of a fanned-out arc | parent `tools/` | it reads branch names and merge-bases; nothing in it is NOW |
| `docs/arc-coordination.md` | how to run a fanned-out arc without lying about it | **split** — the method to the parent, the destination here | most of it is general; the "prerequisites" and landing sections are about NOW |
| `docs/arc-triggers.conf` | when to merge, when to sweep | **stays NOW** | its `FOUNDATION=` paths are NOW/Mirror source files; only the tool that reads it is general |

**`arc-status` and `arc-coordination.md` are the exhibit for why lab scope
matters.** They exist on 25/55 and 27/55 arc branches and on **zero**
percent of `main`. A coordinating rule that thirty lanes cannot read is not
a rule; it is a note one session left for itself. Moving the tool to the
parent (which every session already has on disk, unversioned relative to
these branches) is the only placement where all 55 lanes can run it.

Note the honest cost of moving anything to the parent: NOW's `test-all`
cannot gate a tool that lives outside the repository. A lab-scoped tool is
a tool with a weaker gate, and that is the trade.

### MIRROR-SCOPED — lands under `mirror/`, not globally

`mirror/` is already a real domain: it has its own `AGENTS.md`,
`CLAUDE.md`, `README.md`, `docs/`, `tools/` and `tests/`. These are outside
it and should not be.

| Rule | Governs | Currently | Should be |
|---|---|---|---|
| `tools/mirror-gate` (+ `tools/mirror-gate-tests/`) | the Mirror drive-loop Stop gate and its bash ban | NOW root, wired into repo-wide `.claude/settings.json` | `archive/mirror-standalone-2026-08-09/tools/`, armed per-run |
| `docs/mirror-drive-loop.md` | the rules `mirror-gate` re-grounds you with | `docs/` (published, read by newcomers) | `archive/mirror-standalone-2026-08-09/docs/` |
| 19 further `docs/mirror-*.md` | act plane, content plane, parity ledger, measurement method, … | `docs/` | `archive/mirror-standalone-2026-08-09/docs/`, except `mirror-knowledge.md` which AGENTS.md points every session at |
| `tools/mirror-acts`, `mirror-corpus`, `mirror-diff` | Mirror instruments | `tools/` | `archive/mirror-standalone-2026-08-09/tools/` |
| `tools/toolbox-re-gate` | the Toolbox/GWorld research arc's Stop gate | NOW root, wired into repo-wide `.claude/settings.json` | arc-scoped, same treatment as `mirror-gate` |
| `mirror/.claude/worktrees/**` | **nothing — 3789 tracked files, 25 MB, five dead agent worktrees** | tracked, landed in `0443ab2b` "vendor Mirror whole as a subproject" | deleted and `.gitignore`d |
| the shared checkout parked on `claude/mirror-subproject` | — | the direct cause of the outage above | `main` |

The argument for each being mirror-scoped is the same one and it is a
strong one: **a non-Mirror worktree pays for them and gets nothing.** Two
Python interpreters start on every `Bash` tool call and every `Stop` in
every worktree, forever, to check state files that a non-Mirror session
never creates. Both gates are genuinely inert without their state — that
was checked, not assumed (`tools/mirror-gate:185`, `load()` returns `None`
and `cmd_guard_bash` exits 0) — so this is a cost and a placement error,
not a hazard.

The placement error is the part that matters. `.claude/settings.json` is
the one file where a NOW-wide agent guard belongs, and it currently
contains two arc-specific loops and no NOW-wide guard at all.

**What cannot be fixed by moving files:** Claude Code resolves hooks from
`$CLAUDE_PROJECT_DIR/.claude/settings.json` and has no per-subdirectory
scope. So a Mirror-scoped agent hook has to be *armed*, not *located*: ship
`mirror/.claude/hooks.json` as a template and have `tools/mirror-gate begin`
merge it into `.claude/settings.local.json` (untracked, per clone), with
`mirror-gate done` removing it. That is a design, not a change made here.

## The landing plan for the NOW-scoped set

The order is forced, and steps 1 and 2 must be close together.

**0. Re-derive the table above.** One command, thirty seconds. A merge
that touched `.githooks`, `tools/` or `main` invalidates it, and a clean
textual merge of a derived table is no evidence at all
(AGENTS.md > "Re-derive at the MERGE").

**1. Prove the gate arc strands nobody.**
`NOW_GATE_UNDER_TEST=tools/ext-bake-gate tools/gate-impact-sweep --all-matching 'claude/019-'`
— for each branch it stages that branch's own last commit and runs the gate
as proposed and as the branch carries it. Only the *difference* matters.
Cost: minutes, one detached worktree per branch. **What breaks: nothing.**
No branch may come back STRANDED; a branch the old gate already refused is
not one this change strands.

**2. Land the gate arc on `main`.** Joint with Michelle; it is a change to
`main` and to every branch cut from it afterwards. It brings `.githooks/`,
`tools/setup-hooks`, `tools/hooks-doctor`, `tools/ext-bake-gate`,
`tools/receipts-merge-driver`, `.gitattributes`, `ext/stage-receipts.json`,
`tools/image-discipline-tests` and a `test-all` that calls `hooks-doctor`.
**What breaks between 2 and 3:** every worktree that carries a
`core.hooksPath` override now finds a `.githooks` that exists *and* a
`test-all` that **refuses** rather than warns. About 48 worktrees stop
being able to run the gate until step 3. The deliberate override for that
window is `TBT_ALLOW_UNARMED_HOOKS=1`, and it is the right thing to use —
not a workaround.

**3. `tools/hooks-doctor --fix` on the shared checkout.** Strips the 48
per-worktree `core.hooksPath` overrides, sets the relative `.githooks` in
the shared config, configures the receipts merge driver. Cost: one command,
seconds. **It never edits a working tree.** Its hazard is timing: it
rewrites config that all 246 worktrees share, so it wants a moment when no
other session is mid-commit. Do it within minutes of step 2.

**4. Move the shared checkout off `claude/mirror-subproject` to `main`.**
`git -C <now> merge --ff-only main` (or `git fetch . main:main` and then
`git reset --hard main` — moving the ref alone leaves the files behind and
`git status` will report the newly-landed files as staged deletions, which
reads exactly like a session that ripped them out; AGENTS.md carries this).
**What breaks:** any session working directly in the shared checkout,
which is why the checkout is supposed to stay on `main` in the first place.

**5. Confirm.** `tools/hooks-doctor` with no flags in a *fresh* worktree
cut off `main` — not in an existing one, because an existing one may still
carry the override that step 3 was meant to strip. Then verify by mutation:
`git commit` on `main` in that worktree must be refused by name. A test you
have not watched fail proves nothing.

**6. Only then consider arming `derived-doc-gate`,** by deleting the
`NOW_DERIVED_DOC_GATE` test in both hooks, after re-running step 1 with
`NOW_GATE_UNDER_TEST=tools/derived-doc-gate`. Arming it before the fleet is
quiet is a unilateral change to work in flight.

**What none of this fixes:** a lane already in flight keeps whatever
`.githooks` its own branch carries, which is one branch's version of the
gates. That is correct — the relative `core.hooksPath` is the only form
that resolves to the hooks the worktree actually has — but it means the
gates are not uniform across the fleet until the lanes land.

**Until step 2, a lane gates its own commits with
`git -c core.hooksPath=.githooks commit`.** It changes nothing shared and
works on any branch that carries `.githooks`.

## Which of these deserve to outlive this repository

Findings go to the parent's corpus (`data/findings/`, validated with
`tools/data check`). The bar is a mechanism that has been *paid for*, more
than once, with the second firing not a repeat of the first. Four clear,
two candidates — and a note at the end on how the fourth was nearly missed,
which is worth more than the count.

**Rules.**

1. **A gate that cannot be reached is not a gate.** Four independent
   firings here, and they are genuinely different mechanisms: `test-all`
   never invoked `test-mirrorkit` (a gate not called); `.githooks` never
   reached `main` (a gate not inherited); `core.hooksPath` named a
   directory that does not exist (a gate silently skipped — git says
   *nothing*); `arc-status` reached 25 of 55 branches (a rule most of the
   fleet cannot read). Same conclusion, four routes. That is a rule, and
   its sharp corollary is that **a dead hooks path is indistinguishable
   from having no hooks**, so wiring must be *asked about*, never assumed.

2. **A shared mutable oracle needs provenance, and a merge of records
   about it is not a merge of facts.** Three firings: the stage image
   three days stale while six extension commits landed; the image whose
   sha256 matched no receipt because something wrote it 39 minutes after
   the newest one; two lanes' receipts merging cleanly into a file whose
   last entry is whichever line sorted last. The general shape — *two
   honest records about one shared byte range cannot both be true, and no
   textual rule can pick* — is not about qcow2 images.

3. **A hand-maintained enumeration rots at merges, and only a gate catches
   it.** Already in AGENTS.md with three firings on one day. Its second
   half is the expensive one: *prose that restates a table is a second
   place to be wrong*, and a sentence naming seven of eight rows is a more
   convincing error than a wrong number.

4. **One worktree per lane — because a shared worktree silently
   reattributes commits to whichever branch is checked out.** Three
   firings on 2026-08-07, and the third is the one that makes this a rule
   rather than an etiquette note:

   - A lane's `act_client.c` edits were reverted under it by another lane
     in the same worktree, which then committed over its branch. Its own
     reflog is the record: `13:02 checkout -b cdef-memory-radios` →
     `13:14 checkout → ctlact-settlement (not me)` → `13:17 commit ← mine`
     → `13:22 checkout → asset-packs (not me)` → `13:28 commit ← mine`.
   - The consequence: **one lane's emitter change landed on
     `claude/019-ctlact-settlement` and its matching test update on
     `claude/019-asset-packs`** — one coherent change split across two
     unrelated branches by somebody else's checkout between two of its own
     commits. That is the red `scene_json_test` that blocked every lane
     inheriting `361c50ec` and cost a dedicated lane to unblock.
   - A third lane had three edits reverted mid-work
     (`scripts/test-native`, `commands.h`, `commands.c`), **two of which
     surfaced only as a link error.**

   **Nothing looked wrong to anybody at the time.** `git log -1` showed
   the right hash on every commit and the main guardrail was satisfied,
   because from inside the lane every individual operation was correct.
   The damage appeared later, on a different branch, as an unexplained red
   test — so the cost was paid by a lane that had done nothing wrong and
   could not see the cause.

   **The counter-reading, stated because it is defensible.** These are
   three symptoms of one root cause on one day, and by the discriminator
   used for candidate 6 below — "one day, one mechanism" — that would make
   this a candidate, not a rule. Two things decide it the other way.
   First, they are not one mechanism: *edits clobbered* and *commits
   reattributed to a foreign branch* are different failures with different
   cures, and the second is the one no guard here detects. Second, and
   this is the deciding fact, the reattribution produces **damage
   displaced in time and place from its cause, with no local signal at
   all** — which is a categorically worse failure than "two lanes collided
   and both noticed". That is the same test applied to rule 1: not how
   many times, but how many independent routes to the same conclusion.

**Candidates — the mechanism is general, the evidence is one event.**

5. **A repair instruction that cannot work is worse than no instruction.**
   `hooks-doctor` recommended `--fix` under Fault B, where `--fix` rewrites
   config and the fault was a missing branch. Four lanes read the warning,
   believed it, and correctly did nothing. That turns a live problem into
   one somebody believes they already tried. One firing, but the shape is
   sharp and cheap to state.

6. **Per-lane resource reservation derived from the worktree path.** Ports
   assigned by hand failed three ways in one day — an orphaned VM holding a
   block, a guard that could say "something holds this" and nothing more,
   and an agent re-diagnosing a busy machine as a defect in their own
   change. Three symptoms, but one day and one mechanism. Worth writing
   down as a *technique* (a worktree root is unique by construction, stable
   for the lane's life, and knowable with no coordinator) rather than as a
   law.

**The standard, and a correction to how it was applied.**

*A rule that has fired once is not yet a rule; one that has fired zero
times is a preference.* That bar stays. But a first draft of this page put
one-worktree-per-lane under "not yet a rule" on the grounds that *nothing
here records a failure caused by violating it* — and that was wrong on the
evidence, not on the standard. It had fired three times that day. The
reports were in lane handoffs rather than in `docs/`, so a grep of this
repository found nothing and the absence was mistaken for a negative.

**An unfired rule and an unsearched record look identical from here.** So
the bar needs a second half: *say where you looked*. This page's evidence
comes from `docs/open-issues.md`, the tools' own header comments and git
history — none of which contains a lane's report of another lane
overwriting its work, because that is not a defect in any file. Anything
whose failures are only ever narrated between agents is invisible to the
method used here, and that class is exactly where the shared-machine rules
live.

**Also not for the corpus: the scope question itself.** "Lab-scoped or
NOW-scoped" is a judgement about one machine's directory layout, and the
mechanism that made it bite — `core.hooksPath` being per-clone and
`$CLAUDE_PROJECT_DIR` being per-project — is documented above where the
people affected by it will read it. It belongs on this page, not in a
corpus of durable technical claims.
