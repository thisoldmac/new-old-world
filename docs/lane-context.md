# What every lane needs, in one place

**Passed into every dispatch. Read it fully — it is short on purpose.**

This is a map, not a dump: rules, and where to look for answers. It
exists because a coordinator's briefs are mostly the same text retyped,
and that is where the coordinator's errors live. On 2026-08-07 alone:
`GATE_EXIT` was cited to ~10 lanes and **does not exist**; "the hooks are
dead in every worktree" was wrong for one of two populations;
`tools/arc-status` was cited to ~30 lanes that did not have it; two
branches were called tangled when one was a strict ancestor of the other.

**One file makes those correctable once instead of ten times.** If
something here is wrong, say so in your report — you are the check.

## Before your first edit

- **Cut your own worktree.** `git worktree add <path> -b <branch> <base>`.
  Never work in a shared checkout: it has caused **six** failures here,
  including commits silently reattributed to another lane's branch and a
  seven-file revert that auto-merged with no conflict.
- **Fork off the branch your brief names**, not `main`. `main` is ~1,240
  commits behind and **does not contain `mirror/` at all**.
- **Never `git add -A`.** Stage explicit paths.
- **Commit early and label checkpoints unverified.** A session can end
  without warning; six agents were lost in one night with work
  uncommitted, and the one that had banked a checkpoint needed a single
  gate run to finish.

## Committing and the gate

- **Commit with `git -c core.hooksPath=.githooks commit`.** Correct in
  every case, mutates nothing shared.
- **The hooks are dead in SOME worktrees, not all.** Two broken
  populations: ~60 with an absolute `hooksPath` naming a directory that
  does not exist, and anything cut off `main`, which has no `.githooks`.
  A fresh worktree off a gate-carrying branch is armed. **Do not run
  `hooks-doctor --fix`** — it rewrites config hundreds of worktrees share.
- **There is no `GATE_EXIT` artefact.** `scripts/test-all` writes no exit
  file. Capture the status:

  ```
  scripts/test-all > /tmp/gate.log 2>&1; echo "exit=$?"
  ```

  **Never parse the banner** — it prints two different final lines
  depending on whether the hooks are armed, so a grep for "all gates
  passed" misses a qualified pass and a grep for "passed" reads the
  warning as clean. `TBT_ALLOW_UNARMED_HOOKS=1` is documented and means
  **tests green, gates not running** — say so if you use it.
- **Host gate twice, full logs, never piped through `grep`.** The
  54-then-72 skip pair is *one command running the suite twice*, the
  second with `NOW_MIRROR_ASSETS=none`. It is not variance.

## Driving a guest

- **Your own port block** via `tools/lane-ports`. **Never touch 590–599 /
  16728 / 16729** — reserved for a person's stack.
- **Isolate a host app with BOTH** `NOW_PREFS_SUFFIX` and
  `NOW_AGENT_SOCKET_SUFFIX`. There are **two preference domains with
  different names** (`dev.newoldworld.now.settings.<suffix>` and
  `dev.newoldworld.now.<suffix>`); seeding the wrong one is silent and
  the app comes up healthy on the wrong port.
- **Clone `now-mirror-stage.qcow2` explicitly**; read the line the run
  prints saying which base it cloned.
- **Shut down guest-clean** — `tools/shutdown-guest.py --wire`, and
  **quit the host app FIRST**: `--wire` binds the port the host holds.
- **Never QMP `quit`** (a power cut; leaves the HFS volume marked
  mounted). **Never kill by port** — `lsof` matches QEMU itself. **Never
  `kill` by pattern** — that voided a gate run by killing processes the
  gate's own tests had launched.
- **Assert the build under test.** `--expect-build auto` /
  `requireTheBuildUnderTest()`. Any session's guest can answer your
  listener. A capture another guest could have answered is **void**, not
  annotated.
- Copy evidence out **before** `tools/lane-ports reclaim` — it deletes
  run directories.

## Claims

- **Say which level and never write "works":** Builds / Tested /
  Emulator-verified / Metal-verified. **Nothing in this arc is
  metal-verified.**
- **Watch every guard fail against the mutation it CLAIMS to catch.** A
  test watched against *one* mutation is not watched to fail — two render
  guards passed the exact mutation they were written for. Confirm the
  mutation built and the test ran.
- **A count you did not derive is not evidence.** Re-derive; do not quote.
- **`empty` = we looked and there are none. `unknown` = we could not
  establish it. `notFetched` = we have not asked.** Collapsing any two is
  the defect class this project has paid most for.
- **A refuted mechanism is a result.** Report it plainly; do not treat a
  disproved brief as a failure to deliver.
- **The instrument is the suspect.** Sixteen recorded instances where an
  instrument's normal mode of operation was the one condition under which
  the defect could not appear. If something reads green, ask what it
  would look like broken.

## Where to look

| question | file |
|---|---|
| the project's rules, in full | `AGENTS.md` |
| what is broken vs unverified | `docs/open-issues.md` (append-only) |
| what we knowingly ship wrong, and why | `docs/known-wrong.md` |
| who serves what | `docs/contract-coverage.md` (re-derive, never hand-edit) |
| how a sweep is run and what it means | `docs/fidelity-sweep-spec.md` |
| a cold start after a session dies | `docs/plans/2026-08-07-023-recovery.md` |
| why over-the-wire pixels are gated | `docs/the-drive-and-the-islands.md` |
| guest UI non-negotiables | `docs/guest-ui-start-here.md` + the `classic-mac-carbon-ui` skill |

## Reserved for Michelle — never do these

Landing on `main`. Baking the **shared** stage image (`--shared`). Moving
the shared checkout. `hooks-doctor --fix`. Pruning another session's
worktrees. Arming a gate that ships deliberately unarmed.

## DERIVED — re-run, do not trust

These rot. The commands are the source:

```
tools/arc-status <integration-branch>     # lanes, triggers, corpus backlog
tools/base-image which --purpose ppc-work # which base to clone
tools/lane-ports human                    # the reserved human ports
git branch --list 'claude/0[12][0-9]-*'   # the arc's lanes
```

**Do not quote a number from this file.** If a brief cites a branch
list, a port, a count or a base image, **re-derive it** — a candidate
list is a measurement and goes stale between a brief being written and a
lane running it. That mistake skipped a finished lane twice.
