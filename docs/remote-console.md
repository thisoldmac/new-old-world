# The remote console

**Status:** implemented on both guests and the host, 2026-07-28.
**Emulator-verified** the same day — NOW-68K on the q800, 8/8 in
`MetalExecTests`, which found two real bugs (below). **Metal pending**; see
[the checklist](#the-metal-checklist) at the foot. Emulator-verified is not
metal-verified: a 68040 under 8.1 with 128 MB is not a 68030 under 7.1 with
4 MB, and nothing about timing or memory pressure carries over.

This describes a shape, not just NOW's implementation of it. It is meant to be
the standard for any TimBotTu host console. If you are writing a second one,
the argument is the first section and the rules are the third.

## What a remote console is, and the test for it

> The host console must be able to render output from a program **neither side
> has ever heard of**.

If rendering correctness depends on the host knowing which command ran, it is
not a remote console — it is a GUI with a text field. That is falsifiable, and
it is the thing to check when reviewing one.

The operational form of the same test, which is what `ConsoleShellTests ::
testAVerbThisHostHasNeverHeardOfIsTypeable` actually asserts:

> Add a verb to the guest. Rebuild **the guest only**. It must be typeable
> from an **unchanged host binary** against an **unchanged contract**.

## Why: drift is a velocity tax, not an aesthetic one

The console is most useful exactly when iterating on a new guest command — and
under the old design that was when it cost the most. A verb was not typeable
until the contract declared it (`x-commands`) *and* the host was rebuilt, so
every iteration meant building and deploying both sides in parity with a fresh
session. The two halves drifted in the gap, invisibly, because nothing failed;
`process.list` shipped wire-only for a day and `ps` spent a day reachable from
one keyboard (`command-parity.md` has both stories).

Note what was *already* right before this work: the host console kept no
command list and relayed the line. The closure was one layer down, in the
contract — `x-commands` declared CLOSED, every reply pinned to exactly-two
string rows, and an explicit clause reading *"the wire is never a TTY."* The
host was honest and the contract underneath it was not open. **When auditing a
console, check the contract, not just the client.**

## The two planes

Neither replaces the other. They are opposite bargains and both are worth
having.

| | typed (`command.*`) | console (`exec.*`) |
|---|---|---|
| caller | knows the command | knows nothing |
| sends | `name` + typed `args` | `line`, whole, verb included |
| returns | declared per-command schema | free text |
| declared in the contract | every command, closed | nothing about a line |
| used by | modules, the MCP companion, Tab completion | the console |
| survives a new guest verb | no — needs a contract edit | yes |

The typed plane keeps every property it was built for. A module calling
`process.quit` wants a declared shape and `x-commands` is what makes that
checkable. What it could not do was carry a verb nobody had declared yet, and
that is all exec adds.

## The rules

1. **The host never looks inside the line.** Not to validate it, not to trim
   it, not to find where the verb ends. "A verb ends at the first space" is a
   rule about a command set; a host that has one has a command set.
2. **The envelope is the contract; the command never is.** One versioned
   message shape, command-independent. Adding a verb touches the guest only.
3. **The guest renders.** Not "the guest returns data the host formats" — the
   guest returns *the text its own console would have shown*. This is the rule
   that is easiest to get subtly wrong and it is the one that matters most;
   see the next section.
4. **One implementation, more faces.** exec is a face on the guest's existing
   dispatch, never a second one. A guest that grows a separate exec dispatch
   has broken parity, and the parity test says so.
5. **Command awareness is an enhancement layer only.** Completion, history,
   hints may use the typed plane, may be stale, may be absent — and none of
   that may affect a single pixel of output.
6. **Control channel, never the bulk lane.** The bulk lane is one transfer
   wide across both directions; a console session holding it would block
   capture and file transfer for its lifetime. Control frames also
   queue-and-retry, which console text needs: pixels are re-capturable,
   a command's output is not.
7. **Text is a chunk, not a line.** A guest splits where its buffer ends.
   Reassemble before looking for line breaks.
8. **The unit is a line, never a keystroke.** See [Not a TTY](#not-a-tty).

## The rule that is easy to get wrong

Rule 3 sounds like a formatting preference. It is not.

Before this change the host rebuilt its display from `[label, value]` rows: pad
the first column, group the second, skip anything that was not a pair. Three
things were wrong with that, and only the first was visible:

- It could not show anything that was not two columns, and the guard was
  `where row.count >= 2` — so a one-column row was **silently dropped**. A
  missing line, not an ugly one, which is the worst way for a console to be
  wrong.
- It reconstructed a layout the guest had already decided, so the same listing
  lined up one way on the PowerBook's screen and another way on the host.
- A new output shape needed a host change, which is the drift this exists to
  end.

The fix is not a better renderer on the host. It is **no renderer on the
host**.

## How each guest reaches it

The two guests needed different surgery for the same property, which is worth
recording because a third console will be one or the other.

**NOW-68K** — the dispatch policy lived inside a *window*. `conwin.c`'s
`submit_line()` decided that `vprobe` renders its whole table, that `ps` is
answered directly, what an unknown name says — reachable only by someone
standing at the PowerBook. That moved out to
[`guest68k/src/n68_exec.c`](../guest68k/src/n68_exec.c) verbatim, with
`con_out`/`con_out_block` collapsed into one emit callback. Both consoles call
it. `clear` stayed behind.

**The PowerPC guest** — the split already existed: `console_model_run()` took a
whole line and appended lines to a scrollback. So it needed a **sink**, not
surgery. `console_model_append` gained a redirect
([`guest/src/console_model.c`](../guest/src/console_model.c)), which means all
forty-odd of its call sites — including every one added after today — reach
whichever face is asking without any of them knowing there are two.

**The test for either:** a verb belongs to the side whose pixels it changes.
`clear` empties a scrollback that only exists at the guest; the host has its
own `/clear`. That is the same rule the host's `/`-verbs follow from the other
end.

## Cancel, and what it can actually reach

`exec.cancel` is **always answered** — an unknown id gets `exec.result
ok:false "not-running"`, the rule `stream.stop` was hardened into. It is
*marked*, not acted on: the guests dispatch synchronously, so a cancel stops
further output at once and the one terminal result is sent when the command
returns. Exactly one `exec.result` goes out however the race falls.

**A cancel only arrives mid-command while something pumps.** A command that
runs straight through finishes first, and the cancel then finds nothing
running and is answered `not-running` — which is true. So: *nothing that does
not pump can be interrupted, however long it takes.* Stated rather than hidden,
because it decides what a person can get out of.

## Input, and the wedge it is shaped around

`exec.input` answers a prompt a guest printed. Three things make it safe on a
cooperatively-scheduled machine with no preemption to rescue it:

- **The wait is bounded** — 30 s in both reference implementations. An
  unbounded wait here is a Mac that needs a power cycle: the `serial_tx`
  failure with a different cause.
- **It pumps rather than blocks**, so the guest stays alive and answerable
  throughout — which is also the only way the input could ever arrive.
- **`exec.cancel` breaks it immediately.**

An interpreter gets `0` from `now_exec_read_input` for three ordinary reasons
— nothing running under exec, cancelled, or the wait expired — and **must have
an answer for `0` that does not involve asking again.**

The host does not try to tell a prompt from ordinary output. It cannot, and it
does not need to: while an exec is in flight a typed line can only be meant as
an answer, since a second exec is refused `exec-busy`. If the guest was not in
fact waiting it **drops** the line rather than buffering it, so the cost of
guessing wrong is that nothing happens — never that a stale answer lands in
the next prompt.

**Nothing calls `now_exec_read_input` yet.** Every verb both guests serve
answers without asking. It is the mechanism an interactive interpreter needs,
built and wired so that adding one is not also a wire change.

## Not a TTY

The unit is a **line**, never a keystroke. There is no terminal state on this
wire: no cursor addressing, no escape sequences the contract ascribes meaning
to, no resize, no raw mode.

A guest may put anything in `text`, and a host that wants to interpret VT
sequences inside it may — but that is the host choosing to render bytes it was
handed, not the contract carrying a terminal. The line, not the keystroke, is
what keeps a cooperatively-scheduled Mac answerable.

This is also what leaves the door open. Because the contract declares nothing
about what a line *means*, a guest that one day hands the line to some other
interpreter — a shell, a serial session, something on the far side of A/UX —
is **conforming, not extending**. The contract's silence is load-bearing. Use
A/UX as a paper stress test when changing this: if answering "what would it
plug into" requires changing the contract, the change has leaked.

## What the emulator caught

Both were invisible to every unit test, because both are about the *other*
machine. Recorded because they are the two failure modes a third console
should expect to hit.

**1. The outbound queue ate the reply.** `kWireOutQueueDepth` on NOW-68K is
**four**. Every other producer on that wire enqueues one or two frames and
returns to the event loop; exec is the first that emits an *unbounded* number
inside a single dispatch. `help` renders about ten lines, so the frames past
the fourth were dropped — and the one dropped last was the terminal
`exec.result`, so the host waited out its whole 60 s watchdog for a message
the guest had built correctly and thrown away.

It presented as *`help` never comes back while `frobnicate` answers
instantly*, which reads like exec being broken for real commands and is
actually "enough output to fill the queue". The fix is that exec drains after
each frame — `flush_outbound()` on 68K, `service_ctl_tx()` on PowerPC, both of
which push bytes and **read nothing**, so neither can re-enter the dispatch on
the stack. Anything that emits more than a couple of frames per dispatch needs
this.

**2. Moving a face lost a capability.** `help quit` worked from the host
before, via `command.request` → `run_help`. Once the console plane routed
every typed line through `n68_exec.c` instead, `help quit` reached the
console's `show_help`, which had never taken a topic and printed the whole
list. Nothing failed; the host just quietly stopped being able to ask about
one command.

This is the exact failure `command-parity.md` exists to prevent, arriving
through the door built to close it. The lesson generalises: **moving a face
onto one implementation is only safe if the implementation you move onto
answers everything the one you left behind did.** Check the arms, not just the
wiring.

## The metal checklist

Nothing below has run on hardware. Order matters: it climbs from "cannot wedge
anything" to the one path that could, and the emulator gate comes first.

**Before the machine.** Done for NOW-68K on the q800 (2026-07-28):

    scripts/q800-68k                                   # boot; it dials out
    NOW_METAL=1 swift test --filter MetalExecTests     # in another shell

8/8. **Not yet run against the PowerPC guest** — same command, point it at a
mac99 image; `MetalExecTests` skips the vprobe arm on a guest that does not
serve it, so it is the same suite either way.

Still to do by hand on either: byte-compare `help`/`ls`/`ps` against the same
word typed at the guest's OWN console window. The automated suite proves the
text arrives and is the guest's; only a human at both screens proves the two
faces are identical, which is the whole claim.

1. **`help`, `ls`, `ps`** — the ordinary path. Confirm the host shows what the
   guest's own console shows, including alignment.
2. **The drift test, live.** Add a throwaway verb to the guest, rebuild and
   deploy **the guest only**, type it. The host binary and the contract must
   be untouched. This is the acceptance criterion; if it needs a host change,
   the work failed whatever else passed.
3. **`vprobe`** — the ~12 s command. Watch output stream rather than arriving
   at the end.
4. **Concurrency** — run an exec *during* a file transfer and during a capture
   stream. The bulk lane must be untouched and neither should stall.
5. **`exec-busy`** — two commands at once; the second must be refused
   cleanly rather than corrupting the first.
6. **`/cancel` during `vprobe`.** Expect the terminal result to say
   `cancelled`. Note the pumping caveat above: a command that does not pump
   will finish first and the cancel will answer `not-running`, which is
   correct, not a bug.
7. **`exec.input`, last, and attended.** Nothing calls it yet, so this needs a
   scratch verb that prompts. **This is the one path that can wedge a
   cooperatively-scheduled Mac** — do it on the emulator first, then on metal
   with the power switch in reach, and check the 30 s bound actually fires by
   leaving a prompt unanswered.

**PB180c note:** its display failed mid-session on 2026-07-25. If it does that
again, the wire half of this is unaffected — which is exactly the argument in
`command-parity.md` for why both faces have to reach everything.

## corpus_impact

`none` — this documents a NOW-internal design and its metal checklist; no
durable claim about a machine, device, ROM, or measurement changed. The metal
run this checklist describes is expected to produce a finding; it belongs to
that run, not to this document.
