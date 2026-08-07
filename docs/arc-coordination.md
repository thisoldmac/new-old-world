# Running a fanned-out arc without lying about it

## Where this is going

Michelle, 2026-08-07, going to bed:

> what id like to be doing tomorrow is saying how good everything looks
> and feels so we can land this in main and start cleaning up for public
> alpha. but maybe thats optimistic.

**That is the destination: land on `main`, then clean up for a public
alpha.** Her hedge is hers and it stays — this is a direction to steer
by, not a promise anyone made.

**Landing is a joint act. Never do it alone.**

> dont land on main on your own. i want to be there for that.

### It is not a reason to narrow

A first draft of this section read "work that moves the product toward
landing outranks work that is merely interesting". **She pushed back on
that and she is right:**

> you can keep the interesting stuff going. i strongly encourage it,
> especially if its turning out good findings and missing pieces that are
> in service of "good enough to land". pushing back on this gate because
> i dont want you hyperfocused too narrowly on patching when theres still
> a lot of open ends.

So the destination is a **direction**, not a gate that forecloses
breadth. Nearly everything that made this product better was found by
work that looked tangential when it started — the transport bug found by
a lane sent to revive seven tools, the two-pixel window rect found by
making one reader authoritative, a font gap wearing a chrome costume.
**Findings and missing pieces are in service of landing, not competing
with it.** Narrowing to patch what is already known would forfeit exactly
the mechanism that has been producing the wins.

### On people versus instruments — the framing to use

The same draft said "a thing that looks wrong to a person outranks a
thing that measures wrong to an instrument". That is lazy, and Michelle
corrected it:

> ideally something looking wrong to a person should look wrong to the
> machine. the opposite is seldom true

**The asymmetry is the point.** When an instrument goes red, it is almost
always genuinely wrong. When a *person* sees something wrong that every
gate passed, the defect is real **and so is a second defect: the
instrument has a gap.** The response is not "trust the human over the
tests" — it is **go make the gate that would have caught it.**

This arc has produced five of those gaps and every one was found by a
person or by accident, never by the instruments themselves. A human
noticing is a signal that we are one gate short, not a licence to skip
building it.

### The prerequisites, which are not features

`.githooks` does not exist on `main`, so the commit gates cannot be
armed; several corpus findings cite `now/docs/` files that live only on
lane branches; and the arc is a long way ahead of main with the merge
never yet attempted in that direction.


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

**And every line of it is a timestamp.** `idle` means *that worktree had
no dirty files at the moment it was read* — an agent between two edits
reads exactly like an agent that finished. An integration takes an hour;
a lane can wake up inside it. So a plan built on a status is fine, and a
**claim** built on one is only as old as the run: say when you took it,
and re-derive before quoting a number to a person. The second of the two
misreports above was true when the branch was read and false ten minutes
later, and what made it a lie rather than a stale fact was the missing
timestamp.

## The two cadences, and they are different

**The triggers are numbers in [arc-triggers.conf](arc-triggers.conf), and
`tools/arc-status` evaluates them.** It prints a VERDICT naming which
trigger fired. That is deliberate: "when it feels good" is not a
schedule, and a tired coordinator reinterpreting a guideline at 2am is
exactly how fifteen slices end up untested together. Argue with the
numbers and change them — in the file, not in the moment.

**MERGE, TEST, DRIVE** — the frequent one. Land what is finished, run the
gates, boot a guest, and **look at pixels**. Computed triggers, any one:

- **3+ idle unlanded lanes.** Three is where their conflicts begin
  interacting rather than merely existing.
- **40+ unlanded commits**, however few lanes. One lane can be a jam.
- **Any single lane at 5+ conflicts.** Past that the merge is a project
  rather than a chore, and it only grows.
- **`main` has anything we do not.** Always. It is somebody else's work
  and the drift is silent.
- **Anything touched `ext/` or `contract/peek_table.h`** — a bake is
  owed, and a stale resident invalidates every measurement taken after
  it.
- **An unlanded lane touched a foundation path** — the renderer, the
  ladder, the unknown, the content plane, the state engine, the guest's
  scene/act/peek trees, the contract. Everyone else is working against a
  tree about to move.

**FULL SWEEP** — rare, scored, and specified in
[fidelity-sweep-spec.md](fidelity-sweep-spec.md). Its job is to name the
pain points that steer work **still in flight**, so it must not wait for
everything.

**A sweep does not require a person.** An agent runs it alone and the
result stands. A human co-drive is *additional* signal, scheduled when
convenient — treating it as a precondition once turned a preference into
a blocker and nearly cost a night's measurement. Computed trigger:

- **Every branch in `SWEEP_GATE` is landed**, AND
- **at least one merge-test-drive round has run since the last of them
  landed.** A sweep of a tree whose newest work has never been merged
  with the rest measures the lanes, not the product.

The gate list is deliberately short — three branches, not everything —
because a sweep after all work lands has nothing left to inform. Two
discretionary sweeps stay human calls and are **not** computed: a new
capability class landing (a kind of thing the product could not do
before, not a fix), and before a handoff, so the next session starts
from a measurement rather than a story.

**Sweep a frozen commit.** Cut it, sweep that, let the other lanes keep
running on their branches. That satisfies "do not measure a tree moving
underneath you" without stalling anything.

## The wake rule — the one the stop rule does not cover

**Every rule below is reactive.** They tell a coordinator what to do
*while it is running*. **None of them make it run.**

A coordinator acts when something arrives: a message, or an agent
finishing. That is *how* a silence can last — but it is not how one
starts. **A silence starts with a decision.**

On 2026-08-07 a lane reported **to the coordinator** at 04:34. It read
the report, wrote part of it into the handoff, **left three live defects
undispatched**, and ended the turn without arming anything. Four choices.
Then seven and a half hours passed with the machine idle and three merge
triggers lit — and *that* part was the mechanism.

Michelle had stayed up specifically to put the guardrails in place. The
guardrails were fine. **Describing your own inaction as a system state is
the first thing to catch yourself doing**, because "the pool went to
zero" sounds like weather and "I stopped" does not.

**So, before ending any turn:**

1. **Is anything running?** If the pool is about to hit zero and the work
   is not finished, either **dispatch** or **schedule a wakeup**. Both is
   better.
2. **A self-scheduled wakeup is not optional overnight.** Re-arm it every
   turn; a loop that lapses is indistinguishable from a decision to stop.
3. **The tool that answers "what now" must survive an idle machine.**
   `tools/arc-status` died under `set -e` when `pgrep` matched nothing —
   so with no VMs and no host apps, the VERDICT section never printed. It
   was written while twelve VMs were up and broke in the one state you
   reach for it. Instruments are written in the state their author is in.

**The test: if every agent finished right now, what would happen next?**
If the answer is "nothing", the turn is not over.

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

## An agent's report is not a durable artifact

**A report lives in a transcript that will be compacted.** Everything in
it — the finding, the caveat, the thing it could not close, the number it
measured — is gone the moment the window rolls, unless somebody moves it.

Michelle:

> if you need to delegate new tasks to manage findings from an agent, you
> can and should do that. just make sure they're durable and updated in
> the plan etc.

**So delegating follow-ups is encouraged, not rationed.** A lane that
surfaces four things worth doing should produce four dispatches, not a
paragraph of regret. The coordinator's job is to keep them moving, and an
agent is cheap next to a lost finding.

**Every item in a report leaves with exactly one of these, and the choice
is made in the same pass as reading it:**

1. **Dispatched** — an agent, now, with the finding quoted into its brief.
2. **Written into the plan or `docs/`** — where the next person will meet
   it without knowing to look.
3. **Graduated to the corpus** — if it outlives this repository.
4. **Explicitly dropped, with the reason**, which is a real option and
   sometimes the right one.

What is not on the list: *"noted"*. A finding acknowledged in a reply and
nowhere else has been lost with extra steps.

**Update the plan in the same pass.** Not "at the end" — the end is
exactly when the context is gone. This arc corrected its own plan a dozen
times as lanes came back, and every one of those corrections is now the
only record that the earlier version was wrong.

The test, and it is cheap: **if this session ended right now, would
anything in that report survive?** If the answer is no for an item, it is
not done being handled.

## A failed mechanism is not a result

This gets handed off as done a lot, and it is worth naming precisely
because the honest version and the finished version look identical in a
report.

A lane sent to "classify controls with `GetControlKind`" came back having
established, correctly and with measurements, that `GetControlKind` is
Mac OS X only and that the substitute the resident already used is
declined by the Control Manager for every window the product needs. That
was excellent work and **it fixed nothing** — the controls that render
and cannot be used were exactly as unusable afterwards.

**The cause is in the brief, not the lane.** A brief that names a
mechanism can be satisfied by *disproving the mechanism*. "Use
`GetControlKind` to classify controls" is complete the moment
`GetControlKind` turns out not to exist. "A scrollbar scrolls, a tab
switches, a list row selects — watched on the guest" is not completable
that way at all.

So:

- **State exit criteria as observable outcomes**, in the product, that a
  person could check. A mechanism in a brief is a *suggestion about
  route*, and should be labelled as one.
- **When a mechanism fails, the lane owes the next route** — or an
  explicit "nothing remains untried, and here is the list I considered".
  A disproof plus a recommendation is a good report; a disproof alone is
  a handoff of the original problem back to whoever asked.
- **Separate the requirements a mechanism was standing in for.** The same
  lane's finding split cleanly once looked at: *rendering* a control
  needs to know what it is; *acting* on one needs a click point. One
  failed mechanism was blocking two unrelated deliverables, and only one
  of them actually depended on it.
- **A renegotiated exit criterion is a decision, recorded** — not a
  quiet substitution of what turned out to be possible for what was
  asked.

The tell, when reading a report: **does the product do something it could
not do before?** If the answer is "we now understand why it doesn't",
that is a finding, and the work is still open.

This is one of seven things a brief owes a lane;
[commissioning-a-lane.md](commissioning-a-lane.md) has the rest, and the
observation that produced it — **the lanes that came back saying the
coordinator was wrong were the most valuable ones**, which is a property
of how they were asked rather than of who they were.

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

## Arming a gate into a moving fleet

The instinct on finding a gate missing is to arm it now, and on
2026-08-07 the case for urgency was as strong as it gets: the commit
hooks had never fired in any worktree. It was still not the lane's to
do, and the lane that built them said so — **arming is the coordinator's
to sequence while twenty lanes are live.**

The risk is not that a new gate is wrong. It is that it is **right and
refuses correct in-flight work**, stranding it, for a reason its author
cannot act on. Against that, one more hour without the gate is cheap.

- **Name the branches it would newly refuse.** Not argue about it — run
  it. Check out each live branch, stage its own last commit, run the
  gate as this tree proposes it *and* as that branch carries it, and
  report only the difference. Eleven branches, one run.
- **Warn where the failure is informational; refuse only where a quiet
  pass lets a real lie through.** That is a much smaller set than the
  set of things the gate can detect.
- **Put the refusal where the harm is, not where detection is
  earliest.** An unbaked resident is ordinary sequencing on a branch and
  a genuine hazard on `main`. Gating lane-to-lane merges would have made
  thirteen branches merge each other's work harder to prevent a drift
  that costs less.

## Between the lanes: the machine

The fan-out's state is half git and half hardware, and `tools/arc-status`
reports both for that reason. The hardware half has its own rules, all
of them paid for:

- **A lane derives its own ports** (`tools/lane-ports`, from the
  worktree path). Nobody assigns them. The alternative held a dozen
  allocations in one session's head and failed three ways in a day.
- **A result from an unidentified machine reads exactly like a passing
  one.** Every guest here sees the host at `10.0.2.2`. Assert the build
  under test before believing a row — including in a scratch driver you
  intend to throw away, which is where two published findings were
  measured and later withdrawn.
- **Copy the evidence out before teardown.** `lane-ports reclaim`
  deletes the run directory, screendumps included.
- **Clean up by reporting, not deleting.** An idle run directory between
  two boots looks exactly like an abandoned one. `gc` names them with
  their size and whether a process still holds the disk, and removes
  none of them; deleting somebody's mid-flight clone to reclaim disk
  would be a previous mistake in a new currency.
- **Leave the target clean, or declare it dirty.** A modal one sweep
  pass left open was front in the next, so that row is **void, not
  unstable** — and it contaminated every check after it.
- **Taking a held resource is not yours to do.** A guard that refuses
  because another session holds the machine has worked correctly. Wait;
  do not set the override.

## Derived things are re-derived at the merge, never merged

Coverage tables, counts, and any hand-maintained enumeration. Two lanes
each honestly re-derive a table, the merge keeps both, and the result is
a lie neither author wrote. It has happened here at least three times —
including one where a "named together" prose list became **two** lists,
one naming `desktop`, the other `cycle`, neither naming both.

**There is now a machine half, and it is not armed.**
`tools/derived-doc-gate` reads a `derived-doc` block that each derived
document carries next to its own commands, re-runs them, and refuses a
merge commit whose derivations were not re-run —
`tools/derived-doc-gate rederive` is the cure and writes what moved (or
`unchanged`, with the sha) into the file. It sits behind
`NOW_DERIVED_DOC_GATE=1` in both merge hooks; arming it is a change to
every branch at once and waits for a quiet fleet and `.githooks` on
`main`. Until then an integrator runs `rederive` by hand, which is the
same command the gate would run.

And check the shape after any conflicted merge: a keep-both once produced
**six duplicate Python function definitions that still parsed**. Brace
depth for Swift, duplicate `def` for Python, and remember only
`scripts/build-guests` catches guest-side truncation.

## A chip is not work

**Dispatch a real agent. Never a suggestion chip.**

Michelle has corrected this at least four times, most recently by
screenshotting a chip with the words *"tasks not chips"*. The reason is
not stylistic:

- **A dispatched agent does the thing.**
- **A chip is a button she has to press**, sitting in her queue, looking
  handled while nothing has happened.

Handing a person a button is the opposite of taking something off their
plate, and a queue of chips reads as progress in exactly the way an
enumerated list read as coverage — which is the failure this file
already documents twice.

So when a lane finds something adjacent and real: **dispatch it**, with a
prompt self-contained enough to act on without the finding lane's
context. Use a tracked task only when the item genuinely must wait — on a
person's decision, or on another lane landing — and say which.

This kept recurring because a memory said to spawn chips. **When the same
correction arrives a third time, the cause is usually a written
instruction, not the agent** — go and find it. Fixing the symptom four
times is how a rule ends up costing more than the work it governs.
