<!-- now-doc-provenance: generated reviewed=false -->

# Host UI copy: the register, and how to audit it

For whoever writes user-facing text in `now-host/`. The sibling of
[guest-ui-start-here.md](guest-ui-start-here.md), and the same kind of
document: not a style guide in general, but the specific things this
app's copy has got wrong, with the greps that find them again.

**The app is a workshop, and its text is chrome.** The nearest
neighbours are Xcode, Instruments, Console and Activity Monitor — an
inspector names its field and stops. The failure mode here is not
marketing slop, which this codebase has never had; it is *narration*:
prose that tells the story of what a person or a machine does, in a
place where a tool would print a noun.

Every before/after below is real, from the pass on 2026-08-20.

## The tell: narration

Copy narrates when it describes an event with an actor instead of naming
the thing being labelled. It survives ordinary review because each
sentence is true, specific and well written — which is exactly why it
needs a rule rather than taste.

| Narrated | Named |
| --- | --- |
| `Where the host saw this machine. Authoritative for which socket, useless as a name.` | `Source address of this connection. Identifies the socket, not the machine.` |
| `Stable. What you type to reach this machine, and what follows it across a reconnection.` | `Persistent identifier. Stable across reconnections.` |
| `This connection only. A caller holding it after this machine reconnects is told the session ended, rather than being answered by its successor.` | `Scoped to this connection. Invalidated on reconnect.` |
| `What is running on the Macintosh, and quit or raise it` | `Running processes on the Macintosh` |
| `What each Macintosh has agreed to` | `Consent` |

## Ten rules

**Name the field, do not narrate it.** Help text opens with the field's
category — *Persistent identifier*, *Source address*, *Inbound port* —
not with a sentence about what happens to it.

**No second person.** `you`, `your`, `a person` do not appear in UI
strings. `What you type to reach this machine` → `Persistent
identifier`. `Move this one into your Applications folder` → `Move this
copy into the Applications folder`.

**No narrative verbs for machine behaviour.** A machine does not *dial*,
*see*, *ask*, *say*, *live*, *sit*, *belong to*, or *go across*. It
connects, reads, reports, returns. `The Macintosh dials this Mac; its
processes appear here once it does` → `The Macintosh connects to this
Mac. Processes appear once connected.` That one sentence shape was in
five separate empty states.

**Empty states name the condition; the instruction is the sublabel.**
`Select a probe` / `Pick a probe on the left to see its rows.` →
`No probe selected` / `Select a probe for its rows.`

**Cut the rationale, keep the consequence.** The *why* belongs in a
source comment or in `docs/`, not under a control. `useless as a name`,
`That is not a reading of zero — it is no reading at all`, `These moved
here from Networking` all went; what the reader must do or expect
stayed.

**Never reassure.** `Nothing is wrong with the machine` was in three
separate refusals. A tool states the condition and stops. `The PowerPC
build serves it. Nothing is wrong with that machine.` → `Served by the
PowerPC build only.`

**Do not hedge with `yet` or `still`** unless the temporal claim is
load-bearing. `No scene has arrived yet.` → `No scene received.`
`Nothing has happened yet.` → `No events.` Keep it where it carries a
fact: `Not run yet` distinguishes *unrun* from *ran and returned
nothing*, and that distinction is the whole point of the Diagnostics
page.

**Do not explain by antithesis.** `this page does not watch, it asks.
Refresh for a newer answer.` → `Refresh to re-read.` The construction
reads as voice, and it costs a line to say what a verb says.

**Warnings lose padding, never facts.** `Cannot be undone`, the Trash
consequences, the relaunch requirement and the Trusted-LAN plaintext
warning survive every pass intact. Trim the connective tissue and the
sentence count, never the consequence, the quantity, or the scope.

**Imperative for actions, present tense for state.** `Runs diag on the
Macintosh.` → `Run diag on the Macintosh.` Help on a button describes
what pressing it does.

## Length

- **Label**: a noun phrase, usually two to four words. Never a sentence,
  never a question.
- **Sublabel / caption**: one line.
- **Help**: at most two sentences. A third means the rationale crept
  back in.

Median UI string in this app is 47 characters. Anything past ~140 wants
a reason.

## Typography

- `…` not `...` — 37 strings against 4 when this was last counted.
- `—` not a spaced ASCII hyphen.
- Sentence case in body text, Title Case on controls, per Apple HIG.

## What is protected

Do not "fix" these:

- **Facts, quantities, attributions, and honest admissions.** The asset
  pack help still says no pack has been built from real hardware; the
  Development notes still say what remains incomplete. A shorter version
  that drops the admission is worse, not tighter.
- **Domain terms in their own register.** `Machine id`, `Session id`,
  `loopback`, `MacBinary`, `resource fork` are the correct words.
- **Distinctions the product exists to make.** `Cannot be run here` and
  `has not been run yet` are different facts; so are `refused` and
  `answered with nothing`. Collapsing them for brevity is a defect.
- **The log and wire diagnostics** under `ContinuityEdgeController`,
  `ContinuityGrabTransfer`, `GuestListener` and `NOWMirrorSource`. Those
  are read by a developer mid-handoff, not by a person using the app,
  and their density is doing work. Different audience, different rules.

## Auditing

The patterns are greppable. Extract the prose first — most UI strings
are multi-line concatenations, so a naive grep misses the half of a
sentence that carries the tell:

```sh
cd now-host/Sources/Host
grep -rnE '(Text|Label|Button|Toggle|Section|Picker)\("' --include='*.swift' .
```

Then scan the joined text for each rule. In rough order of how much each
one has actually found here:

| Pattern | Regex |
| --- | --- |
| Second person | `\b(you\|your\|a person)\b` |
| Narrative verbs | `\b(dials\|sees\|asks it\|says about\|lives\|sits\|belongs to\|goes across)\b` |
| Reassurance | `Nothing is wrong\|no need to\|don't worry` |
| Hedging | `\byet[.,]\|\bnot .{0,24} yet\b` |
| Antithesis | `does not [^.,;]{2,30}, it \w` |
| Causal chain | `\bso (there\|no\|none\|it\|that)\b` |
| Question-shaped label | `Text\("(What\|How\|Which\|Why)\b` |
| Typography | `\.\.\.` and `[a-z] - [a-z]` |

A match is a candidate, not a defect. Check it against **What is
protected** before editing, and prefer leaving a line alone to making an
uncertain edit.

## Open

**`MachineNaming` is above this document.** The app calls the guest
*the Macintosh* and the host *this Mac* through a naming layer, so
headers read `Running processes on the Macintosh` rather than
`Guest processes`. Whether that is right is a product-identity question,
not a copy question, and no pass here should quietly answer it.
