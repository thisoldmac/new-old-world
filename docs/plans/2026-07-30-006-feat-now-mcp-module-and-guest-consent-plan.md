<!-- now-doc-provenance: generated reviewed=false -->

# The MCP module, and the machine's own answer

**Date:** 2026-07-30 · **Status:** BUILT and TESTED, not metal-verified (updated 2026-07-31) · **Namespace:** `claude/`

A snapshot of intent, per [README](README.md). Where this and the code
disagree, the code is right; where this and
[open-issues.md](../open-issues.md) disagree, the ledger is right.

Follows [2026-07-30-005](2026-07-30-005-feat-now-parity-projections-and-faces-plan.md),
which wired twelve capabilities into twenty-six projection rows. **Its rule
stack still governs and is not restated here.**

## What this closes

Rule 3 says a person must be able to see what they cannot initiate. The
projection phase satisfied the **auditable** half twelve times over — one
dispatch, one event per invocation, every gate mutation-proven. It never built
the **visible** half.

Today an agent can trash a file beneath `guestRoot`, cancel a transfer a person
started, and change what is on their screen. All three write honest log lines.
None of them puts anything in front of the person while it happens, and the
person at the vintage Mac has no way to refuse any of it.

Two facts make that worse than it sounds:

- **The host app has no notion of a companion at all.** `AgentIntegrationLocalServer`
  tracks no accepted peer, so there is nothing to display even if a pane wanted
  to. "Is an agent attached right now" is not a question the code can answer.
- **The guest has no surface, deliberately** — `agent-integration.md` promises
  the local socket creates "no guest module, dashboard item, protocol message."
  That promise is about to move, and it should move on purpose.

## The shape

Three pieces, and the division of labour is the point:

**Consent is the guest's. Enforcement is the host's. Lifecycle is the host's
and always was.**

The companion already connects to a host-owned socket the host serves, so the
last of those is a description rather than a change. What is new is that the
machine being driven gets a vote, and the host is the one that counts it.

### 1. An MCP module in the host app

Its own pane, not a row on Connection. Connection answers *is a Mac attached*;
this answers a different question with its own vocabulary — is a companion
attached, what has it done, what may it do, where is the endpoint. The audit
stream in particular wants room: those events currently land in Logs mixed with
everything else, which is auditable and not visible.

**Prerequisite:** the local server must track its peers. That is small,
self-contained, and blocks everything else in this plan.

### 2. The guest's answer, carried in `hello`

An optional field. **Absence must not read as consent** — this is the trap that
would otherwise be built in, because an installer that omits the AI features and
a guest that predates them look identical on the wire.

| `hello` says | means |
|---|---|
| `disabled` | this machine refuses — an installer choice, or the switch was flipped |
| a tier | this machine consents, to this much |
| nothing | a guest that predates the feature |

So **a refusing machine says so out loud.** One optional `hello` field is not an
AI feature; it is the machine's answer to a question, and the AI-BAD installer
path ships that line while omitting the panel, the module and the consent UI.

**A guest that says nothing fails OPEN, for now.** That matches default-on and
keeps every existing 1400c working. Revisit when the installer lands, which is
the moment silence stops being the common case — and record the flip rather
than letting it drift.

Contract-wise this is an **additive optional field on `hello`**, so no revision
bump, on the precedent of `build` landed 2026-07-30 under the contract's own
rule. Absence has a defined reading, above, and the 68K guest is not forced to
send it.

### 3. Two tiers, with room for a third

**Read Only** and **Full Access**. Ordered rather than boolean, so a
below-the-line tier can slot above without re-shaping the field or the wire when
there is something behind it.

**Derive the tier from the row, do not add a fourth field.** Twenty-one rows
already declare `readOnlyHint` and twenty-one declare `destructiveHint`; the
buckets fall out of what is there. This phase already collapsed four
hand-maintained capability lists in a barrier — one of them a tool partition in
the companion tests that broke the moment guest-files could mutate — and a fifth
would be the same mistake with a fresh coat. Gate it the way the others are
gated.

**`reveal` is Read Only.** Decided 2026-07-30, and it should be written into the
row rather than left to be re-litigated: it touches no disk and changes what is
on the person's screen, which makes it the case a future author will want to
argue about. `RevealItemProjection` already carries a comment about being the
only capability whose whole effect is on the person's side; the tier belongs
beside it.

**"Mordor" stays internal.** It is this project's word for the below-the-line
toolkit — `peek`/`poke`/`cis`, its own server, emu-only, safe because the blast
radius is a throwaway clone. NOW has no below-the-line surface, and putting an
established word on a different thing is how the plan before this one ended up
renaming its own tiers. The user-facing name for that tier gets decided when it
exists.

## Enforcement, in one place

`HostProjectionDispatch` is already the only thing that calls a projection's
`invoke`, enforced two ways: the audit sink has no default, and a source scan
fails naming any other caller. **One check there covers all twenty-six tools.**

That also means the guest's refusal and the tier ceiling land on the same line
as the audit event — the thing that records what happened is the thing that
decides whether it may. No second mechanism, and no per-row opt-in to forget.

The app's own operations are untouched, because a person clicking Capture never
passes through the companion boundary. That is what makes a guest-side switch
cheap: **the guest never has to distinguish agent traffic from app traffic**,
because the host refuses before anything reaches the wire. No per-request origin
field, no contract-wide change.

## Flipping the switch mid-call

A companion holding a transfer when the switch is flipped gets a prompt on the
guest, with three unambiguous choices:

**"Stop it now" · "Let it finish" · "Never mind"**

The third backs out of the toggle rather than the operation, which is why the
obvious trio — Stop / Wait / Cancel — was rejected: two of those read as *cancel
the operation* and one of them is not. On a vintage Mac dialog that is a coin
flip.

Per the house rule, alerts are for errors; this is a decision, so it wants a
movable modal, or at minimum an alert whose buttons cannot be misread.

## The installer, later

Not this slice, but the design has to accommodate it now. The choice is offered
in the installer's own voice — a retro enthusiast who wants nothing to do with
this deserves a first-class **no**, not a buried preference.

Two things the runtime owes it:

- **AI-BAD omits the components**, and still sends `disabled` (see above).
- **Installer-absent and runtime-disabled converge on one refusal path**, so
  there is a single code path to get right and a single sentence for the caller.
  Two mechanisms for one fact is what this project keeps refusing.

## Out of scope, named

**Permission prompts** — per-operation approval is a later slice, and the tier
model is deliberately shaped to grow into it. **The below-the-line tier** — no
surface exists to put behind it. **AppIntents interaction** — a Shortcuts
automation can fire an intent unattended, so the tier applies there too, but W3
is not built and this plan does not wait for it.

## Open questions

- **What the module shows on a machine no companion has ever touched.** That is
  its resting state on most machines, and an empty pane teaches nothing. It is
  the one thing I would want designed rather than defaulted.
- **What "Read Only" and "Full Access" mean to someone standing at a 1400c**
  reading a menu. The names are fine in a plan and unproven in a dialog.
- Whether the tier is per-connection or persisted per machine across
  reconnections.

## Stop conditions

- **The tier becomes a hand-maintained list.** It derives from the row or it is
  the fifth list this arc has had to collapse.
- **Enforcement lands anywhere but the dispatch.** Two places to refuse is one
  place to forget.
- **Silence starts meaning consent.** The whole point of the three-state table
  is that a machine which never answered is not a machine that agreed.
- **A second mechanism appears for the installer choice.** It writes the same
  state the switch does, or it is a second source of truth about one fact.

## Corpus impact

`corpus_impact: none` — intent only, and it rests on facts already recorded:
the projection registry and its dispatch chokepoint, `readOnlyHint`/
`destructiveHint` on the rows, and `build` as the precedent for an additive
optional `hello` field.
