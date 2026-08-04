# Two faces, one implementation

Every guest has two faces. The **console** is what a person types into
standing at the machine; the **wire** is what the host drives it over.
Both must reach every capability, and each capability must have exactly
one implementation behind them.

That is the whole rule. The rest of this file is why it is worth a file,
where the seam is in each guest, and what is deliberately asymmetric.

## Why

The two faces fail at different times, which is exactly when you need the
other one.

On 2026-07-25 the PowerBook 180c's display failed mid-session — a
marginal joint, probably from a recap. Everything automated kept working,
because the wire does not care about a panel. Two hours earlier the
situation had been the reverse: MacTCP had wedged silently and the
machine was reachable only by someone standing in front of it. A
capability that exists on one face and not the other is unavailable in
whichever half of that pair you happen to be living in.

The drift is also *invisible*, which is the part that bit. `process.list`
shipped on NOW-68K's wire that same day. Its console could not list
processes at all. Nothing failed, no test noticed, no reviewer caught it,
and the gap surfaced only because someone asked out loud what the console
could do. Nobody decided that; it simply never came up.

## The rule

1. **A capability is reachable from both faces**, or the asymmetry is
   written down with its reason.
2. **One implementation, two renderers.** The faces format; they never
   decide. Two code paths that answer the same question will eventually
   answer it differently, and the machine they disagree about is in
   another room.
3. **The contract declares every wire verb.** A guest inventing one is a
   verb the host can only learn about by accident.

[`now-host/Tests/HostTests/CommandParityTests.swift`](../now-host/Tests/HostTests/CommandParityTests.swift)
enforces all three by reading the guests' own source. Prose goes stale;
that test fails.

## Where the seam is

**NOW-68K (`now-guest-68k/`)** — two mechanisms, because it has two kinds of
capability:

- *Commands* (`launch`, `quit`, `front`). `commands68.c` runs one and
  fills an `N68CmdResult` — the facts, no formatting. `n68_cmdresult.c` holds both
  renderers side by side: contract JSON for the wire, text for the
  console. The console **delegates** to `now68k_commands_run()` rather
  than dispatching its own copy, so a verb added to the table reaches the
  console the moment it exists, with nobody having to remember. That
  delegation is what the parity test asserts.
- *Message families* (`process.list`). Not commands, so no table compares
  them — this is the one that drifted, twice, in opposite directions.
  `proc_list_rows()` is the single implementation; `n68_proclist.c`
  renders it as `process.listing` and as the `ps` command's rows, and
  `conwin.c` renders the same rows as text.

  The second drift is the one worth remembering. `ps` was added to
  `conwin.c` alone, reading the family the wire already served — which
  satisfied "reachable from both faces" on paper and was still broken,
  because the **host console is a dumb shell**. It sends the line a
  person typed as a `command.request` and knows no message families, so
  a capability that is a family on the wire and a verb only on the
  guest's own keyboard is a capability the host cannot type. The guest
  listed processes happily at the PowerBook while answering
  `unknown-command` to the same word from the host. A message family
  serves a MODULE; a person needs a verb.

  `file.list` was written to that rule from the start rather than into
  it: `n68_fileenum.c` walks the catalog once, `n68_filelist.c` renders
  that walk as `file.listing` for the Files module and as `ls`'s rows for
  anyone typing, and `n68_cmdresult.c` turns those rows into contract
  JSON or console text. Four faces on the wire and the pane, one
  enumeration.

**The PowerPC guest (`now-guest-ppc/`)** — `commands.c` answers the wire and
`console_model.c` answers the Console page. Two dispatch lists, so two
chances to drift, and the parity test compares them directly. The
implementations live below both.

`mirror` is the one-extension example. Both faces call `now_mirror_probe()`;
the wire serializes its schema-1 facts while the Console and Workshop render
the same lifecycle and P1-P4 rows. All three are read-only. Host plane policy
is deliberately not a third guest face: it changes named claims through the
native Mirror source, and the guest surfaces report what the resident actually
requested and activated rather than echoing that policy.

## Deliberate asymmetries

Kept in the test as data, not prose, so they cannot rot:

| Verb | Face | Why |
|---|---|---|
| `putstat` | wire only | a diagnostic the host reads to size a transfer; nothing for a person at the guest to do with it |
| `help`, `clear`, `?` | console only | act on the console window itself and mean nothing on a wire |
| `put`, `mv`, `trash`, `untrash`, `mkdir` | console only (PPC) | the host reaches the same capability through the `file.*` message families, not through x-commands |
| `put` | **both faces (NOW-68K)** | the same capability, the opposite decision — see below |
| `cancel` | **both faces (NOW-68K)**, no verb on PPC | ending a transfer, split the same way `put` is and for a sharper reason — see below |

Adding a row here should feel like a small act of documentation. It is a
decision with a justification, not a to-do — anything not listed fails
the build.

### The two guests answer `put` differently, on purpose

The same capability, opposite decisions, and the reason is the machine
rather than the code.

On the **PowerPC guest**, `put` is a console verb only. A host driving
that guest reaches sending through the `file.*` message families — it
asks for a listing, it asks for a file — so there is nothing for a
command to add, and a verb would be a second route to one capability.

On **NOW-68K** it is in `commands68.c`'s table, reachable from both
faces. Two things make that the opposite answer to the same question.
The host console is a **dumb shell**: it relays the line a person types
as a `command.request` and knows no message families, so a capability
that is only a family is a capability the host cannot type. And this is
the machine whose display failed mid-session on 2026-07-25 — the guest
whose own keyboard is sometimes the only face there is, and sometimes
the one that is gone. A capability that exists on one face is
unavailable in whichever half of that pair you are living in.

So `put` is declared in the contract's `x-commands` (the contract
changes first, always), answered by NOW-68K's wire, and reached by its
console through `now68k_commands_run` like every other table verb.
`CommandRegistryTests` records the resulting asymmetry in
`notOnThePowerPCGuest` — that test used to assume the registry WAS the
PowerPC guest's command set, which stopped being true the moment a
command existed that only the other guest answers.

### `cancel` is the same split, one step further along

Ending a transfer went the same way, and the argument is stronger there
than for `put`. Both guests honour `file.cancel` on the wire, so the
CAPABILITY was never asymmetric; what differed is whether it needed to
be typeable. The PowerPC guest is cancelled from the host's Files UI or
from its own Workshop, so it declares no verb. NOW-68K has neither — no
Files page, no cancel affordance anywhere — so on that machine the verb
IS the face.

And it is the face that matters most. The lane is one transfer wide
across BOTH directions, so a transfer nobody can end is a machine that
will not transfer anything again (open-issues, 2026-07-26). The person
in that situation is standing at a classic Mac whose host has stopped
answering — which is exactly the moment the wire is not available to
them. A cancel reachable only over the wire is a cancel missing
precisely when it is needed.

It takes no argument, unlike the wire's `file.cancel {transfer}`. A
person has no way to know a transfer id and no second transfer to
confuse it with; asking for one would be asking for a number the
machine already holds. A quiet machine answers `nothing-to-cancel`
rather than pretending to have stopped something.

Sending, like receiving, is also a message FAMILY, so `xfer` reports
both directions from `now68k_wire_send_status()` and
`now68k_wire_put_status()` — one implementation each, two renderers, and
`testTheSixtyEightKConsoleCanSeeAnOutgoingFile` is the guard. It was
written before the gap could cost anything, which is the first time that
has been true in this file.

### Two ways to name a target is not two faces

`quit` (the x-command) and `process.quit` (the drive verb) are the same
capability with two identifiers, and that is deliberate, not drift.

A **name** is what a person has. They read `ps`, they type what they see,
and the parser takes the whole rest of the line because process names
have spaces in them. A **PSN** is what a machine has: it names exactly
one live process, where a name is capped at 31 characters, need not be
unique, needs a MacRoman comparison the guest refuses for non-ASCII —
and is not derivable from anything on the wire. That last one is why
this section exists. The handoff used to build the outgoing build's name
as `"NOW-68K " + <the version from its hello>`, a file name guessed from
a compiled constant; on 2026-07-25 a build deployed as 0.18 reported
0.16, the guest was asked to quit a process that did not exist, said so
honestly, and left two NOW-68Ks on a 4 MB machine.

So the rule is not "one identifier" but **one implementation**:
`proc_quit_named` turns a name into a PSN and then does exactly what
`proc_quit_psn` does. Neither face invented a second matcher.

`front` arrived with both routes from the start, and with both faces on
both guests, which is the shape this file argues for rather than the one
it usually has to correct after the fact. It is also the answer to a
question `quit` never had to ask: `process.front` had been on the
PowerPC guest's wire since the Processes module was built, and there was
no way to type it — not at either guest's own keyboard, and not from the
host console, which is a dumb shell that knows no message families. A
capability reachable only by clicking a button in one module is exactly
the `ps` shape.

Its outcomes are NOT `quit`'s with the words changed, and the difference
is worth stating because it is easy to copy wrongly: `quit`'s
`not-running` is ok:true, since "not running" is the state it was asked
to produce and it already holds. `front`'s is ok:FALSE — nothing can
bring forward a process that is not there. And `quit` refuses its own
process while `front` accepts it, because one would sever the reply
mid-send and the other severs nothing.

The listing carries `isSelf` for the same reason — a caller that needs to
name the process it is *talking to* now reads the answer instead of
constructing it. `ps` says `self` on that row on both guests, so a person
at either keyboard can see it too: a fact the wire carries and the
console cannot show is the drift this file is about.

## The exec plane is a FACE, and the console's dispatch moved

Added 2026-07-28, and it changes where this file's rules are enforced rather
than what they say.

The host console no longer sends a command NAME. It sends the whole line
(`exec.request`), the guest interprets it, and what comes back is the text
that guest's own console would have shown — see
[remote-console.md](remote-console.md). So the sentence this file repeats
five times, "the host console is a dumb shell that knows no message
families", is now true one layer deeper: it knows no COMMANDS either, and
there is no host-side list left to drift from.

That did not add a face. It added a reader to the one that existed, and it
removed a renderer:

- **NOW-68K.** `conwin.c`'s `submit_line()` held the console's dispatch
  POLICY — which verbs render whole tables, that `ps` answers directly, what
  an unknown name says. That was reachable only by someone standing at the
  PowerBook, so the host console rebuilt an approximation of it from
  `[label, value]` rows. Both are now `n68_exec.c`, called by `conwin.c` and
  by `wire68.c`. Same bytes on both screens, by construction rather than by
  care.
- **The PowerPC guest** already had the split (`console_model_run` takes a
  line and appends lines), so it needed a sink and not a move.

**The parity tests read `n68_exec.c` now, not `conwin.c`** — that is where the
console's dispatch lives. `conwin.c` keeps only what acts on its own window:
`clear`, scrolling, history, the echo.

**The rule for a new verb is unchanged and the payoff is larger.** Implement
it once below both faces; the wire renderer and the console renderer follow.
What is new is that the console renderer now reaches the HOST too, so "add a
verb, it appears in both places in the same commit" has become "…and it is
typeable from a host binary nobody rebuilt".

## The MCP is a client, not a face

The agent-integration companion (`agent-integration.md`) is **not** a third
face. It is a client of the wire: it reaches a guest through the same
commands and message families a human does, and owns none of them. The two
faces stay two.

That is only worth writing down because there is an obvious way to lose it.
When a tool needs something a guest does not implement — and NOW-68K does
not implement most of the contract — the tempting fix is to do the work *in
the companion*: compose it from smaller calls, cache what the guest cannot
list, or special-case a guest that answers `unknown-command`. Each of those
makes it a face, with its own implementation of a capability, drifting from
the two that exist and answering for a machine it cannot see.

So: a companion tool **projects** a capability, it never implements one — if
a guest cannot do the thing, the tool is unavailable against that guest and
says so in typed form, and that is a complete answer. Availability is decided
by **capability, never by guest identity**. And a refusal must arrive as a
refusal: the host used to drop guest `error` frames, so an unimplemented
request reached its caller as a 15-second timeout carrying no reason —
routing those is what makes a companion usable against an incomplete guest
at all.

## Adding a capability

1. Contract first, if it goes on the wire (`AGENTS.md`).
2. Implement it **once**, below both faces.
3. Wire renderer, console renderer.
4. Run `swift test --filter CommandParity`. If it fails, you have either
   a gap to close or an asymmetry to justify — and writing the
   justification is usually what reveals it was a gap.

If the capability is a message family rather than a command, step 4 will
**not** catch a missing console verb on its own: comparing command tables
cannot see something that is not in a table. Add a case to the parity
test the way `testTheSixtyEightKConsoleCanListProcesses` does. That test
exists because this exact footnote was learned the expensive way.

And if you close such a gap with a console verb, **the verb belongs in
the command table too**, not only in the console's dispatch. The host
console reaches a guest through commands and nothing else;
`testEveryVerbTheSixtyEightKConsoleAnswersIsAlsoOnItsWire` is the guard,
and it was written after `ps` spent a day reachable from one keyboard.
Three verbs answer inside `now68k_commands_dispatch` rather than through
`now68k_commands_run` — `help`, `ps` and `vprobe` — because each returns a
row per item and an `N68CmdResult` holds one row.

The third one arrived the same day this paragraph warned against it, so
here is the argument rather than the pattern. Each exemption buys its
place by asserting the thing that keeps it honest: `help` renders the
published doc table, `ps` renders `proc_list_rows()`, and `vprobe`
**borrows** the single measurement table rather than measuring twice — a
second run would cost ~12 s and could not agree with the first anyway,
the screen having moved in between. The parity test checks each of those
borrowings by name.

**A fourth should not be another arm.** Three row-array commands is no
longer a special case, it is a shape: the fix is a result type that holds
rows, so the console and the wire render it the way they already render
one-row results, and the exemption list goes back to being empty.

`screenshot` is the first capability added since that paragraph was
written, and it did not become a fourth. Its reply is a sentence and a
handful of numbers — geometry, bytes, ratio, where it went, what it cost
— which is two rows, which is what an `N68CmdResult` holds. So it went in
`commands68.c`'s table like `launch` and `quit`, the console reached it
by delegation the moment it existed, and nobody had to touch `conwin.c`.
The one thing it did cost was **twenty-four bytes of `kN68CmdStateCap`** (24 to 48): row
two is the only field a caller cannot spill into row one, and the cost
line did not fit 24. Widening a field is the cheap answer; a fourth
dispatch arm was the expensive one.

### The fourth arrived, and it is not an arm

`ls` landed with `file.list` (2026-07-26) and took the ruling above rather
than the pattern. `N68CmdRows` (`n68_cmdresult.h`) is the result type that
holds rows; `now68k_commands_run_rows()` is the seam beside
`now68k_commands_run()`; `n68_cmdresult.c` holds both renderers side by
side exactly as it does for the one-row shape. `conwin.c` has **no**
`strcmp(name, "ls")` — it asks the seam whether the word is claimed and
renders whatever comes back, which is the same delegation that makes
`launch` reach the console for free.

`sw` (2026-07-28) is the fifth and the first to cost nothing at all: it
was written straight into `now68k_commands_run_rows()`, and both faces
had it without a line changing in `conwin.c` or `n68_exec.c`. That is
the payoff the ruling was arguing for, so it is worth recording that it
arrived — a shape is only proven by the second thing that fits it. What
`sw` did have to write down is an asymmetry of a different kind: the two
guests serve the same `software.list` and NOW-68K fills six of its eight
entry fields, omitting `version` and `running` rather than fabricating
them. That is not a parity gap — both of NOW-68K's own faces show
exactly the same six — so it lives in
[contract-coverage.md](contract-coverage.md), where what a guest can
answer is the subject.

`census` is the fourth verb through that seam (after `ls`, `sw` and
`shotdiag`), and it is the one that shows what the seam bought. A
hardware census is a table by nature - fourteen probes, a page of
[name, raw, meaning] triples each - and it arrived on both faces in one
commit with **no edit to `n68_exec.c` or `conwin.c` at all**. The wire
gets `census.report` through `censusExchange` and the console gets the
contract's declared collapse of the same page to [name, meaning]; both
render one gather from `census68.c`, which is the property
"one implementation, two renderers" is worth a document for.

It also inherits the seam's one sharp edge, which is worth writing down
because the next table verb will meet it too: a verb's USAGE line is a
single `N68CmdResult` row and is capped at `kN68CmdStateCap` (48 bytes).
`census`'s fourteen probe names do not fit, and are not put there
truncated - a grammar cut off mid-list is worse than a short one,
because a person types what they can see. `help census` says
`census [probe]; no probe runs overview` and the registry lives in the
contract, where it is the source of truth anyway.

`testTheSixtyEightKConsoleCanListFiles` asserts all three halves of that:
that `ls` is in `commands68.c` so the host console can type it, that
`conwin.c` reaches the rows seam, and that `conwin.c` does **not**
dispatch `ls` itself. The last one is the interesting assertion — it is a
test that fails when someone re-adds the exemption this paragraph argued
out of existence.

The three that predate it — `help`, `ps`, `vprobe` — were **not** moved in
that pass, and that is a deliberate deferral rather than an oversight:
migrating three working commands in the same change as a new message
family would make both harder to review. The shape now exists for them to
move into, which is the part that was missing. Until they do, the
exemption list is three, not zero, and this paragraph is the honest
statement of that.
