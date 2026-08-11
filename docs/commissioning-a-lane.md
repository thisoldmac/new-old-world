<!-- now-doc-provenance: generated reviewed=false -->

# Commissioning a lane

[arc-coordination.md](arc-coordination.md) is the coordinator's side —
where the arc stands, when to merge, when to sweep, when to stop. This is
the other side: **what goes in the message that starts a lane**, before
any of that applies.

It exists because of an observation from the night of 2026-08-06/07 that
was, at first, hard to explain. Twenty-odd lanes ran. **The ones that
came back saying the coordinator was wrong were the most valuable ones**
— a lane sent to revive seven dead MCP tools found the transport broken
and all 41 dead; a lane sent to classify controls established the API did
not exist on our floor; a lane sent to confirm the app switcher as an
independent discriminator measured it and killed the claim; a sweep told
the plan its slice ordering was not supported by the evidence.

That is not luck, and it is not a property of those agents. It is a
property of how they were asked. A lane returns a correction only when
the brief has left it somewhere to put one.

## The seven things a brief owes a lane

### 1. An exit stated as an outcome, with the mechanism labelled as a route

The failure and its cause are in
[arc-coordination.md](arc-coordination.md) > "A failed mechanism is not a
result", and are not restated here. The brief-side rule is one line:
**name the observable, then name the mechanism separately and say it is a
suggestion.** "A scrollbar scrolls, a tab switches, a list row selects —
watched on the guest" survives its route dying. "Use `GetControlKind`"
does not.

### 2. A negative that is pre-authorised, in writing

The `GetControlKind` lane produced excellent work that fixed nothing. The
gworld probe, briefed the other way, produced a real answer *and* closed
a road:

> **Any of the three is a successful probe.** Outcome 3 is worth as much
> as outcome 1 — it retires a road that would otherwise be re-proposed
> every few weeks. What is NOT acceptable is a report that cannot tell 2
> from 3 because the instrument could not see.
> — [gworld-probe-brief.md](gworld-probe-brief.md)

**A brief with one acceptable answer will get it.** Enumerate the answers
you would accept, including the ones you would rather not have, and say
which failure is the only real failure — almost always *"the instrument
could not tell these two apart"*, never *"the answer was no"*.

### 3. The verdict vocabulary, handed over rather than invented

Sweep A graded Michelle's six complaints as **CONFIRMED / REFUTED / NOT
REPRODUCED / SPLIT**, and that vocabulary is why four of seven plan rows
could be corrected instead of argued about. A binary pass/fail forces a
lane to round, and it rounds toward the brief.

Two words carry most of the weight:

- **NOT REPRODUCED is not REFUTED.** "I could not force an
  unknown-creator modal" is a fact about the rig. Given only pass/fail it
  becomes "no defect", and a real defect goes quiet.
- **SPLIT** is the common case for anything a person described from
  memory. One complaint was *"broken and not dismissible"*: broken was
  confirmed with a named mechanism, not-dismissible was refuted on the
  first try.

And require the sample size in the sentence. Sweep A's own restraint is
the model: *"One attempt, one success — I did not try to reproduce the
old failure, so the honest statement is 'this build dismissed it once',
not 'the defect is gone'."*

### 4. A positive control, and the rule that its failure voids the report

> **The positive control's result.** If SimpleText's text was not
> visible, everything else in the report is void. … If the probe cannot
> see SimpleText's text, the probe is broken, not the application.
> — [gworld-probe-brief.md](gworld-probe-brief.md)

Every instrument this arc built was eventually found blind, and **not one
of them was found blind by itself.** A named positive control is the
cheapest thing that changes that, because it converts "I observed
nothing" from a result into an alarm. Name it in the brief; a lane
choosing its own control after the fact will choose one that passed.

### 5. Evidence asked for, not a verdict

> **Which outcome each application landed in**, and **the evidence for
> that verdict rather than the verdict alone.**

A verdict cannot be re-read when the premises change, and on this arc the
premises changed hourly. Ask for the rectangle, the count, the two
numbers before and after — the thing a later reader can re-interpret
without re-running anything.

### 6. A fence, with the reason the deferral is not disinterest

Plan 018 held cross-machine file drag out of a slice and said why in two
sentences — it sits on geometry being repaired right now, and it is an
arc rather than a slice. That is worth the sentences. An unexplained
"out of scope" reads as an oversight and gets re-proposed, or worse, gets
quietly done.

### 7. The decisions that are not the lane's

**A coordinator's message is not the user's consent, and a lane is right
to refuse on that basis.** Several did. But that refusal is a round trip
paid for by a brief that should not have asked, so the coordinator's job
is to not commission work whose *last step* is a decision only Michelle
can take.

The right shape is the embedded-Mirror lane: told the layout was rejected,
it rendered two or three candidate layouts as PNGs, **stopped, and
waited**. It spent the night producing the material for the decision
rather than blocking on the decision or taking it.

So: name in the brief which decisions are reserved, and what artefact the
lane should leave for whoever takes them.

## Two clauses that belong in nearly every brief

**A survey does not fix.** Sweep A's header — *"Nothing here is a fix,
and nothing was fixed while it was taken. No source file in this
repository was edited between the first capture and the last"* — is the
whole reason its numbers can be compared to sweep B's. A single "while I
was there" repair voids a measurement pass, and the temptation is
strongest exactly when the defect is small.

**A limitation goes in the artefact, not in the reply.** Sweep A named,
in the document, that its three views are three phases of one boot rather
than one instant, and that it could not see flicker. Both were true of
sweep A's predecessors too, and nobody knew, because those limits had
been mentioned in conversation. **A limitation named in chat and not in
the file is one that will be forgotten** — usually by the person who
quotes the number six weeks later.

## Amend by appending

When a lane corrects a brief, **the brief is not edited.** Plan 018's
sweep-A corrections sit under a heading that says so — *"appended not
edited"* — and the seven-row table above them still reads as it did when
it was drawn.

This costs nothing and buys two things. The record of what was believed
survives, which is the only way to see that a class of mistake is
recurring; and a reader who has already acted on the original can find
what changed under them. The same convention closes a brief:
gworld-probe-brief.md carries **ANSWERED, and outcome 1 shipped** at the
top and is otherwise untouched, so it cannot be mistaken for open work
and cannot be mistaken for a document that always said that.

## What a lane owes back

Short, and each of these was learned by not getting it:

- **A disproof plus the next route**, or an explicit "nothing remains
  untried, and here is what I considered". A disproof alone hands the
  original problem back to whoever asked.
- **Anything derived, re-derived** — by running the commands, not from
  memory, and again at the merge. See AGENTS.md > "Enumerated lists rot
  at merges".
- **The doc.** `tools/arc-status` flags a lane that shipped code and
  touched no `docs/`. That is not a refusal — some lanes legitimately
  only move code — but it must be seen and said.
- **The corpus finding**, where the lesson outlives this repository.
  `docs/` does not leave this project; `data/findings/` does.
- **Its own blind spot, stated before its scores.** Sweep A's most useful
  single paragraph was the one declaring what its method could not
  observe, and it was written before any number in the report.
