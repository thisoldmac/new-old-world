# Closing the remaining gaps — a fan-out plan

**Date:** 2026-07-31. **Status:** plan, not started.

Eleven gaps are open (see [STATUS.md](STATUS.md) "Not yet done" and
[PORTAL-PLAN.md](PORTAL-PLAN.md) op 4–5). Most are independent. This is how to
run them in parallel without the two failure modes that have already cost us:
agents colliding in a shared file, and an agent reporting a verb's own return
value as evidence.

## The partition is by FILE, not by feature

The first fan-out on this project put two agents in one worktree and both
commits swept up both changes. The fix is not care, it is ownership: **every
lane gets its own git worktree, and no two concurrent lanes may write the same
file.** Feature boundaries do not respect file boundaries — `mirrorverbs.c`
alone is touched by four of the gaps below — so the lanes are drawn where the
files divide.

| File / tree | Owner |
|---|---|
| `guest/extensions/portal/*` | **P** (one lane at a time, ever) |
| `guest/app/src/mirrorverbs.c` | **P** and **G**, by region — see below |
| `guest/app/src/main.c`, build files | **G** |
| `host/MirrorKit/**` | **H** |
| `tests/*.py` | **T**, plus each lane's own new probe file |
| `docs/*` | everyone, own section only |

**`mirrorverbs.c` is the one shared file, and it merges cleanly if two rules
hold** (this is measured, not hoped — the lab's `verbs.c` has multi-branch
merged clean for a year): a lane appends its verb functions rather than
inserting among existing ones, and a lane adds its dispatch-table rows at the
end of the table without reordering. The one trap is two lanes adding the
*same* verb name — grep the table before you write, and the merge is a
conflict rather than a silent duplicate.

## Phase 1 — three lanes, concurrent, no shared files

### Lane T1 · No-hijack (Portal acceptance 3)

**This gates everything else in the Portal.** The guard is written and 40 trials
produced no stray actuation, but nobody has armed a request and then clicked a
*different* control to watch it chain through. Every op after this one adds a
patched trap; if the guard leaks, each new op multiplies the leak. Do it first
and cheap.

- Arm a `CONTROL_INVOKE` against control A, then drive a real click on control
  B. B must do B's thing; A must not move. Then the reverse for `MENU_INVOKE`:
  armed on File/New, user clicks Edit — Edit's menu must track normally.
- Also: arm a request, **never** click, and confirm it times out disarmed
  rather than firing on the user's next unrelated click ten seconds later.
- N=20 each, independent trials, oracle = guest state.
- **Owns:** `tests/nohijack-probe.py`, its two cases in `trials.py`.
- **Done when:** a number exists for "armed requests that fired on the wrong
  target", and it is 0 — or it is not 0 and that is the finding.

### Lane G1 · The three small guest truths

Three unrelated defects, all in guest files, all cheap, none touching the
Portal:

1. **`mirror.app {op:"launch"}` has never worked.** The contract has specified
   it since day one; the guest has no `launch` verb, so it returns
   `unknown_verb`. Add the verb (`LaunchApplication`, or the Finder AE — pick
   by what survives a suspended Finder) and make the contract true.
2. **Apple-menu item titles carry leading NUL bytes**, which breaks title
   matching — so the one menu every app has is the one an agent cannot address
   by name.
3. **A build stamp cannot confirm a deploy.** `kBuildStamp` is `__DATE__
   __TIME__` in `mirrorverbs.c`, so a change to `main.c` alone ships a binary
   reporting an unchanged stamp. This has already bitten once, and it is the
   kind of bug that makes every *other* measurement suspect — a lane that
   deploys and measures the old binary reports a confident, false number. Fix
   it with something that cannot be stale (link-time, or hash the sources).
- **Owns:** `mirrorverbs.c` (append-only), `main.c`, build files.
- **Done when:** launch measured on a real app by its window appearing;
  Apple-menu items addressable by title; a `main.c`-only change moves the stamp.

### Lane H1 · IR v1 freeze and the parity gate

The scene IR is still version 0 and explicitly unstable. `irVersion` now rides
on both `scene` and `attach`, so the gate has somewhere to live — what is
missing is the decision about what v1 *contains*, and a test that fails when
the shape drifts.

- Inventory what the IR carries today against what the fixture corpus expects;
  name the fields that are provisional and either promote or drop each.
- Write the parity gate: a consumer must refuse an unknown major, and the test
  suite must fail if a field is added or removed without the version moving.
- **Owns:** `host/MirrorKit/**` exclusively. No guest files, no VM needed.
- **Done when:** `irVersion` is 1, the corpus is pinned to it, and a deliberate
  field change turns the suite red.

## Phase 2 — after T1 is green

### Lane P1 · `WINDOW_ACT`

The largest remaining win: **it removes QMP from the act plane**, and QMP is
the last emulator-only mechanism the plan forbids as load-bearing. Same guarded
shape that now works twice — `DragWindow` and its relatives answered by
identity, so the app moves its own window with no motion at all.

Take `CONTROL_INVOKE`'s lesson literally: its bug was a **phantom constant** in
a doc comment, part codes invented rather than cited. Every part code, message
number and `WindowPtr` field offset in this op cites Inside Macintosh or is
marked a guess awaiting evidence.

- Ops: move, resize, zoom, close. `close` is the one with teeth — it can
  destroy user data, so it is measured on a document with nothing in it.
- **Done when:** a window's own rect, re-read from the guest, changes the way
  the request named it — 20/20 — and no QMP appears anywhere in the path.
- **Owns:** `guest/extensions/portal/*`, appends to `mirrorverbs.c`.
- Serialize against P2: one lane in the Portal extension at a time.

### Lane H2 · Finder folder windows as icons

Needs the `script` verb to resolve a window title to an HFS path; `ScenePoller`
gates it behind `includeWindowItems` because item positions are not
guest-accurate yet. Two halves — resolve the path, then get positions the
Finder agrees with. Split only if the first half lands early.

## Phase 3 — after Phase 2

### Lane P2 · `TEXT_GET` / `TEXT_SET`

The difference between driving an app and filling in a form. Same in-process
shape, on TextEdit's per-process roots.

### Lane R1 · The 0.1 posture

Not code so much as a decision, executed:

- **Flip the Portal to default-off** — one constant plus wiring the enable into
  `tools/spin-up.sh`. An extension that is inert until asked is what makes
  installing this on a real machine a decision rather than a side effect.
- **The metal-safety review, per op.** Everything is mac99 today by the
  standing rule. This lane writes the review — for each op, what it calls, what
  it can wedge, and whether the tiered do-not-touch list in the lab's
  `docs/22-metal-safety-line.md` needs a new row. It does **not** touch metal;
  Michelle's machine is attended and hers to schedule.

### Not a lane: platinum fidelity

All four planes run live, but whether the mirror *looks* right is a human call
and the one thing here no measurement replaces. It needs Michelle in front of
it, not an agent.

## The standing brief every lane gets

Assembled from what has actually gone wrong here:

1. **Commit early and often.** Six agents died mid-task on 2026-07-30; only the
   ones with banked commits were cheap to finish.
2. **Your own worktree, your own branch, your own VM clone.** `tools/spin-up.sh`
   clones a session-private mac99 image. Other VMs running are another
   session's — leave them and launch your own. Stop with QMP `quit`, never
   `pkill`.
3. **The oracle is guest state, never the verb's own report.** `answered:true`
   over an unmoved scrollbar is the exact shape of every false positive this
   project has had. Re-read the thing you claimed to change.
4. **Reset state between trials.** The famous "~9 actuations per boot" was an
   accumulating oracle. Trials that are not independent measure a different
   machine each time.
5. **Prove a fix by mutation.** Put the bug back and show the number collapses.
   `CONTROL_INVOKE`'s root cause was only certain because forcing the wrong
   part code reproduced 100% reply / 0% actuation exactly.
6. **No phantom constants.** Every magic number cites a document, a
   measurement, or an artifact — or is marked a guess. A named `TODO` beats a
   plausible fill. This is the lab's provenance rule and it is also, literally,
   the bug we just spent a day on.
7. **Emulator only.** No metal without a per-op safety review and Michelle
   present.
8. **Report what you did not test** as clearly as what you did. The half-truth
   is more expensive than the gap.

## Merge protocol

Lanes merge to `mirror` main by `--no-ff`, one at a time, each with `swift test`
green and its own probe re-run against a fresh clone. A lane that finishes while
another holds `mirrorverbs.c` waits — appending is safe, merging concurrently is
where the duplicate-verb trap lives.
