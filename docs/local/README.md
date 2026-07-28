# docs/local — the scratch half

Everything in this directory **except this file** is gitignored. It never
reaches the public repository.

## Why the split exists

`docs/` is published. Someone who has never seen this project reads it,
and every file there is a deliberate choice to explain something to that
person. That standard is worth holding — and it is impossible to hold if
the same directory is also where a session drops its working notes.

So the two have different homes. The rule is about **audience**, not
about who typed it:

| | `docs/` | `docs/local/` |
|---|---|---|
| Audience | anyone who finds the repository | this desk, this week |
| Lifetime | as long as the claim is true | until the work lands |
| Standard | deliberate, edited, linked | whatever is useful |
| Published | yes | never |

## What belongs here

- Session handoffs and working notes — what a thread was mid-way through,
  what it tried, where it stopped.
- Investigation logs: the twelve things checked before the one that was
  wrong. Valuable while hunting, noise afterwards.
- Raw run output, timing dumps, screendumps kept for comparison.
- Scratch plans that have not become a commitment yet.
- Anything naming this desk: addresses, machine inventories, which VM was
  on which port. (Configuration itself goes in `.env.lab` — see
  [lab-setup.md](../lab-setup.md).)

## What does NOT belong here

**Anything a future reader needs.** The failure mode this directory
creates is a real finding written into a scratch file and lost. If work
here produces a durable claim, it graduates:

- A behaviour change → the contract, then both halves.
- Something broken or unverified → [open-issues.md](../open-issues.md),
  which is the ledger and is published.
- A change to what a guest serves →
  [contract-coverage.md](../contract-coverage.md), same commit.
- A platform lesson that outlives this repository → a finding in the
  corpus, not a note here.

A note that has graduated can be deleted. A note nobody graduated is how
a lesson gets paid for twice.

## For agents

Write freely here; do not write session narrative into `docs/`. If you
are unsure which a document is, ask what a stranger would do with it — if
the answer is "nothing", it is local.

Published docs are populated deliberately, one edit at a time, by
someone deciding a reader needs that page.
