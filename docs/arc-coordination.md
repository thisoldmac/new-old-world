# Running a fanned-out arc without lying about it

A coordinating session that has a dozen lanes in flight cannot hold their
state in its head. The failure mode is not forgetting a lane — it is
**confidently misreporting one**, which is worse, because a person acts
on it.

Both of these happened on 2026-08-07, hours apart, and both were one
command away from being right:

- A slice was reported as dispatched when only its **task** had been
  created; the agent was never spawned. Caught by the human asking "is
  everything else truly done and closed?"
- An integration branch was reported as having **merged nothing** — true
  when the branch was read, false ten minutes later, and stated without
  the timestamp that would have made it checkable.

Neither was careless. Both were memory standing in for evidence.

**So: `tools/arc-status` is the answer to "where are we".** It derives
what is landed, what is not, what conflicts each unlanded branch would
hit, whether main is in, what is running on the machine, and whether the
gates are actually armed. Run it before saying any of that out loud.

## The two cadences, and they are different

**MERGE, TEST, DRIVE** — the frequent one. Land what is finished, run
the gates, boot a guest, and **look at pixels**. Its job is to stop
"fifteen slices and nobody tested them together", which is a jam you
cannot back out of once you are in it.

Trigger it when **any** of these is true:

- Three or more lanes have landed since the last one.
- A lane touched something every other lane builds on — the renderer,
  the ladder, the guest walk, the contract, the act plane.
- `main` has moved.
- Anything at all touched `ext/` (a bake is owed, and a stale resident
  invalidates every measurement taken after it).
- A lane reports a defect in **another** lane's landed work.

**FULL SWEEP** — the rare one. The scored instrument across every
target, with a person driving a parallel build. Its job is to **name the
pain points to steer the work still in flight**, which means it must
happen while there is work in flight to steer. A sweep taken after
everything lands has nothing left to inform.

Trigger it when:

- The defects the last sweep named are fixed, **and** the fixes have
  been through a merge-test-drive round. Sweeping over a known-bad
  target scores one cause twice.
- The product's shape changed — a new capability class, not a fix.
- Before a handoff to a new session, so the next one starts from a
  measurement rather than a story.

**Sweep a frozen commit.** Cut it, sweep that, let the other lanes keep
running on their branches. This satisfies "do not measure a tree moving
underneath you" without stalling anything.

## The stop rule

**Never stop with a live finding undispatched.** A blocker, a half-landed
lane or a failed gate that exists only in a chat transcript is lost the
moment the session ends — and this repository's most expensive lesson is
work lost to a session that ended without warning.

Before ending a turn where anything is in flight, in this order:

1. **`tools/arc-status`.** Not recollection.
2. **Bank other people's uncommitted work.** A dirty worktree whose agent
   died gets committed as `[UNVERIFIED CHECKPOINT]`, attributed to the
   session doing the committing rather than the agent that wrote it, so
   nobody mistakes it for reviewed work. It is one careless checkout
   from oblivion and it is not yours to lose.
3. **Fold in and dispatch.** Anything that failed, landed half, or
   surfaced a blocker gets an agent **before** you stop — not a note
   saying it should.
4. **Say what is unlanded**, by name, with the number of commits. "Mostly
   done" is not a state.
5. **Name what is unverified**, separately from what is unfinished. They
   are different debts: one needs work, the other needs somebody to look.

## Things that read as green and are not

Each of these produced a false green here, and each is checked by
`tools/arc-status`:

- **`scripts/build-guests` skips silently without `.env.lab`.** A worktree
  without one reports `ok` having invoked no cross-compiler. The machine
  had none at the common root for most of 2026-08-06, so an unknown
  number of that day's "green" gates never compiled a guest.
- **The commit hooks were never armed.** `core.hooksPath` pointed at a
  directory that does not exist, so `ext-bake-gate` and the main
  guardrail had never fired in any worktree — which is why an honest
  `TBT_DEFER_EXT_BAKE=1` left **no record at all**: the mechanism that
  writes one was the gate that never ran.
- **A test suite that exists and is not in the gate.** `test-mirrorkit`
  became a stage *because it was missing* while everything else read
  green for three days.
- **A conformance driver that closes the pipe.** The MCP surface answered
  every test harness and no real client, because every driver wrote its
  whole script and closed stdin. **A pipeline that closes the pipe is a
  batch, not a client.**

## Derived things are re-derived at the merge, never merged

Coverage tables, counts, and any hand-maintained enumeration. Two lanes
each honestly re-derive a table, the merge keeps both, and the result is
a lie neither author wrote. It has happened here at least three times —
including one where a "named together" prose list became **two** lists,
one naming `desktop`, the other `cycle`, neither naming both.

And check the shape after any conflicted merge: a keep-both once produced
**six duplicate Python function definitions that still parsed**. Brace
depth for Swift, duplicate `def` for Python, and remember only
`scripts/build-guests` catches guest-side truncation.
