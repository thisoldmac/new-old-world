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

[`host/Tests/HostTests/CommandParityTests.swift`](../host/Tests/HostTests/CommandParityTests.swift)
enforces all three by reading the guests' own source. Prose goes stale;
that test fails.

## Where the seam is

**NOW-68K (`guest68k/`)** — two mechanisms, because it has two kinds of
capability:

- *Commands* (`launch`, `quit`). `commands68.c` runs one and fills an
  `N68CmdResult` — the facts, no formatting. `n68_cmdresult.c` holds both
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

**The PowerPC guest (`guest/`)** — `commands.c` answers the wire and
`console_model.c` answers the Console page. Two dispatch lists, so two
chances to drift, and the parity test compares them directly. The
implementations live below both.

## Deliberate asymmetries

Kept in the test as data, not prose, so they cannot rot:

| Verb | Face | Why |
|---|---|---|
| `putstat` | wire only | a diagnostic the host reads to size a transfer; nothing for a person at the guest to do with it |
| `help`, `clear`, `?` | console only | act on the console window itself and mean nothing on a wire |
| `put`, `mv`, `trash`, `untrash`, `mkdir` | console only (PPC) | the host reaches the same capability through the `file.*` message families, not through x-commands |
| `put` | **both faces (NOW-68K)** | the same capability, the opposite decision — see below |

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

Sending, like receiving, is also a message FAMILY, so `xfer` reports
both directions from `now68k_wire_send_status()` and
`now68k_wire_put_status()` — one implementation each, two renderers, and
`testTheSixtyEightKConsoleCanSeeAnOutgoingFile` is the guard. It was
written before the gap could cost anything, which is the first time that
has been true in this file.

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
