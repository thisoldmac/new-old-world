---
title: A Mirror that survives being driven - Plan
type: feat
date: 2026-08-05
---

# A Mirror that survives being driven - Plan

Continues [010, Closing the headless Mirror](2026-08-05-010-feat-closing-the-headless-mirror-plan.md),
which continues [009](2026-08-04-009-feat-now-headless-mirror-mcp-plan.md).
Both keep their history; this one owns what is left. Where they disagree
about status this one is newer, and
[open-issues.md](../open-issues.md) beats all three.

## Why this plan exists rather than more of 010

010 was organised around **what the Mirror can see**: projections, the
element gap, the split of the 190. That was the right question when it was
written and it is not the binding one now.

On 2026-08-05 the Mirror was driven by hand for the first time since those
fixes landed, and it **died**. Not degraded — died: one ordinary Macintosh
event (a document with no creator application) put the Finder in a modal,
and forty seconds later the guest was deaf, acts were queued 87 seconds
deep, six operations settled `sessionChanged`, and the session had to be
abandoned with a socket left `CLOSED` while the host still believed it had
a guest.

Everything 010 cares about is measured THROUGH that. A rendering gap found
on a machine that wedges is a gap you cannot re-measure, and a fidelity
score taken between wedges is not a score. So the ordering inverts:
**reliability first, and the seeing work resumes on top of it.**

Three facts from that drive shape everything below, and all three are
measured rather than argued:

- **One blocked callee deafens the whole guest, 15 s at a time.** The
  guest is serial; `OSADoScript` blocks it entirely; the default deadline
  is `kNowScriptDefaultMs = 15000` and **the host never passes
  `timeoutMs`** — zero occurrences.
- **The single mutation lane converts one stuck act into a dead session.**
  Measured waits: 48 737, 53 146, 53 821, 63 246, 65 653, 70 923, 87 508 ms.
- **Acting on a foreign process's control fails even when the walk can
  name it.** Date & Time's window publishes 41 of 41 items with refs, and
  every `dialogItem` against them refuses `element-not-found: the anchor
  plane is absent or not armed`.

And one premise that is no longer true and must stop being repeated: **the
interaction plane has published.** `interaction=active-current/gen14`,
beside those very acts. The planes were never the reason.

## Goal Capsule

- **Objective:** make the Mirror survivable under a real person driving
  it — no single act able to deafen the guest, kill the session, or block
  behind a stuck predecessor — and then make a modal dialog an ordinary
  thing to see and answer.
- **Authority:** unchanged. `MirrorStateEngine` is the single published
  state, `MirrorActionExecutor` and the broker the single mutation path,
  `contract/asyncapi.yaml` the guest-wire meaning.
- **Stop conditions:** the six from 009/010 stand. One more, earned twice
  today: **stop if a fix cannot be told apart from its neighbours by a
  test.** Three fixes on 2026-08-05 were verified one level below where
  they live, and a mutation reinstating one of them left nine tests green.
- **Tail ownership:** with MCP present or absent the window behaves
  identically.

## Ordering, and the argument for it

**A before everything, because A is what makes the rest measurable.** The
lane is the amplifier: it does not cause failures, it converts any one of
them into a dead session. Until an act cannot block its successors, every
measurement taken after a bad act is a measurement of the lane.

**B and C are the same defect from two ends** — B is a foreign process we
cannot act on, C is a foreign process that can deafen us — and both are
about NOW's relationship with an application it does not own. They are
separable and should be done in either order, but not skipped for D.

**D before any fix to what modals render.** The wrong-controls report is
one observation of one alert. Slice 6's own rule is that a gap without a
three-way capture is a complaint rather than a finding, and a widget
guessed from a bad read is precisely the plausible lie the honesty bar
forbids. Capture first.

**E resumes 010.** Nothing there changed except that it now has a machine
it can be measured on.

## The work

### A — the lane must not be able to kill the session · **FIRST**

Three separable pieces, and the first is most of the value:

1. **An act must be cancellable.** There is no cancel today. A person
   watching a 70-second wait has no way to abandon it, and neither does an
   agent. This is the difference between a bad act and a lost session.
2. **The queue must be bounded by more than a timeout.** A 15 s timeout
   does not bound a QUEUE; it bounds one act, and seven of them stack to
   87 s. Consider whether the FIFO must be one lane or one lane per
   target — 009 asked that and it has never been answered against
   numbers.
3. **The lane must survive its guest.** Six operations settling
   `sessionChanged` at once, with a socket left `CLOSED` while the host
   believed it was connected, is its own defect: the host should notice a
   guest that has stopped answering rather than learning it from a queue
   that never drains.

010 § G deferred this with "re-measure first. Item 1 removed most of its
fuel, and the question should be answered against new numbers rather than
the 51.8 s ones." **The re-measure has happened and the numbers are
worse** — 87.5 s against 51.8 s, after the fix that was supposed to
remove the fuel. That instruction is discharged and the answer is that
the fuel was never the point.

009 saw the connection and filed it under the wrong item: slice 5c item 4
says a modal "BLOCKS the application while it is up — so it is also a
queue problem." It is *only* a queue problem, in the sense that the queue
is what turns it fatal.

**Done when:** a deliberately-wedged guest (open a document with no
creator application — it reproduces on demand) costs the acts behind it
nothing, and the session survives.

### B — anchor the process you are about to act on

The walk names foreign controls correctly and cannot act on them. The
ref is minted by observing a process; re-resolving it needs the anchor
armed **for that process's context**, and nothing arms it.

Two independent witnesses, which is why this is a gap and not a symptom:
every `dialogItem` in the 2026-08-05 drive, and the P5 work concluding
separately that *"the sequence for anchoring a foreign process before
arming it isn't established."*

**Done when:** a control in a foreign application's dialog is pressed from
the Mirror and the machine changes. Date & Time's `Set Time Zone…` is the
standing case — it renders, it is addressable, and it does nothing.

### C — a poll must not be able to deafen the guest

Routine scene maintenance — the icon roster, the visibility census —
should carry a SHORT `timeoutMs` and give the wire back. A user-initiated
act may keep the long deadline, because a person is deliberately waiting
for that one. The argument already exists on the verb and nobody passes
it, so this is a change at the call sites rather than a mechanism.

**Watch for the trap:** shortening the deadline makes a blocked Finder
produce many fast failures instead of one slow one. That is only an
improvement if the failures are attributable — a poll that gives up must
say it gave up, or the coverage claim will read as "the Finder has no
icons" rather than "we could not ask".

**Done when:** a blocked Finder costs the guest its Finder reads and
nothing else — the wire stays live, the heartbeat is answered, and other
applications remain drivable.

### D — capture the alert three ways before fixing what it renders

Three cases were reported on 2026-08-05 and only one is understood:

| case | state |
|---|---|
| `harness.log` double-click renders no modal at all | **explained, not evidenced** — most likely C's deafness, since no scene publishes while the script blocks. Needs one observation: does the modal appear after the 15 s deadline expires? That answer decides whether this is C or its own defect |
| Date & Time ▸ Set Time Zone renders with controls that do nothing | **understood** — that is B |
| Mail's "connected to the internet" alert renders the WRONG controls | **not understood, do not patch** |

For the third: `tools/mirror-corpus`, three reads of one moment —
framebuffer, IR, and the guest's own structures. The IR-versus-guest diff
is what assigns it to a layer, and without it any fix is a guess. Note
that every item on the Date & Time window carries `kind: None`, so the
renderer is drawing widgets from something other than a determined kind;
whether that is the same cause here is exactly what the capture settles.

**And the third read is currently untrustworthy, which comes first.**
Gap-ledger row 6: *"The harness reads window titles as binary garbage —
every window in every `guest.json`, where the IR has correct titles. The
independent oracle is wrong here, not the thing it is checking."* 010 § E
already ranked that ahead of anything it measures, and this is the first
piece of work that actually depends on it. A capture whose oracle
silently reports garbage cannot assign a layer, and would let a
producer bug and an instrument bug swap places — which this project has
done once before, from a two-byte width error in a probe's own filter.
**Fix row 6, then capture.**

### E — what 010 still owns, now that it can be measured

Unchanged in substance, listed so nothing is lost: slice 1's
page-versus-reply check (the only item needing a person's eyes); a live
`finderDeselect` and a `dialogItem` that does something (B unblocks the
second); the split-the-190 histogram against a batched build; the
corpus recapture; and slice 6 proper, whose control half is now known to
be a transport question rather than a drawing one.

Two smaller ones from 2026-08-05, both recorded and neither fixed:

- **The host face can hide and cannot show.** Hiding NOW from the Mirror
  leaves nothing on that face able to bring it back. What closes it is a
  show direction on the verb the host already calls.
- **The Finder roster is intermittent** — sometimes published, sometimes
  nil, on the same guest minutes apart. That is a race or an expiry, not
  an absence, and it is a different investigation from the one the
  earlier entry implied.

### F — the test seam, which is why several of these shipped

`NOWMirrorSource.serve` turns a plan into a guest command and nothing can
intercept it in a test, so every fix to it is verified one level below
where it lives. Mutating the Finder `activate` call site to reinstate the
exact defect it fixes left **nine tests green**. Every defect the machine
found on 2026-08-05 — an unparseable refusal, a reply that lost its own
records, a verb that could not arm — lived in that same band.

One injectable "send this command" function, of the kind
`NOWMirrorCycleIO` already gives the scene cycle, closes it. Small
refactor, large effect on what can be claimed.

## Verification

Everything from 010, plus two rules today paid for:

- **Read the premise beside the measurement.** `actmeta` exists for this
  and it settled the modal question in one line: the planes were active
  and publishing while the acts refused, so "the plane was dark" was never
  the explanation. A measurement without its premise is a confident,
  meaningless number.
- **A fix is not verified by a test one level below it.** If the wiring
  cannot be tested, say so in the commit rather than letting a green
  helper suite imply otherwise.

## What would make this wrong

- Fixing what a modal RENDERS before capturing one three ways.
- Treating the lane as a performance problem. It is a survivability
  problem: the 87-second wait is a symptom, and the dead session is the
  defect.
- Shortening a poll's deadline without making its failure attributable,
  which would turn a slow truth into a fast lie.
