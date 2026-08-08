# Stopping the Mirror should disconnect it, not pause it

**Reported by Michelle, 2026-08-08, during the first metal session in
weeks.** Filed, not fixed.

## What actually happened

She switched the host's target between the PowerBook 1400c and the
emulator and back, and the Mirror kept showing the VM's desktop while
connected to the PowerBook.

**Targeting was correct the whole time.** The stale part was the desktop
render — leftover pixels from the previous target sitting underneath.
When she opened the Workshop on the guest using the guest's own mouse, it
rendered from the PowerBook correctly.

> No, im pretty sure it was just the mirror's desktop render being stale.
> When I opened workshop on the guest via its own mouse, it rendered
> guest ws just fine.

## Correction, recorded because the first version of this file was wrong

An earlier draft of this document — committed in `1d5fa25e` — read her
first message as evidence that **acts went to the PowerBook while pixels
came from the VM**, called it the most serious defect of the night, and
built a mechanism for it out of `MirrorProjection` carrying a session
identity that nothing checks at render time.

That was wrong, and it was wrong in the expensive direction: it asserts a
severe defect that does not exist, in a published file, with a plausible
mechanism attached. Someone would have spent real time chasing it.

The error was not misreading a fact. It was **escalating an ambiguous
report into its worst reading and then finding a mechanism that fit** —
the mechanism was real code, which is exactly what made the conclusion
convincing. This project already has a name for the shape: a plausible
number is worse than an obviously broken one.

The identity-checking observation itself still stands as an
*observation*: `MirrorProjection` carries `session { guest, incarnation }`,
the host knows the connected machine through `GuestIdentity.machineID`,
and nothing joins them at render time. That is worth knowing. It is not
evidence that anything mis-targeted, and this file no longer claims it
is.

## The actual defect, and the fix Michelle named

> Mirror should *disconnect and shut down* when stopped, not just paused.
> We can have a pause button if we need to pause. We already pause when
> switching modules with mirror running.

Stop currently pauses. That is why a stale desktop survives a target
switch: nothing tore the session down, so the last render stayed
addressable and got composited under the new machine's windows.

So the fix is not a render-time identity guard bolted onto a session that
should not have still existed. It is that **stop means stop**:

- **Stop disconnects and shuts the Mirror down.** The session ends, its
  scene and content state go with it, and a later start is a fresh
  session rather than a resumed one.
- **Pause becomes its own control**, if it is wanted — explicit, named,
  and visibly distinct from stop. A single button that stops in the label
  and pauses in the implementation is the whole bug.
- **Module switching already pauses**, and that behaviour is correct and
  should stay. It is the case pause exists for.

The vocabulary rule this repo already keeps applies to the resulting
empty state: after a stop there is no scene because none was asked for
(`notFetched`), which is a different thing from asking and finding no
windows (`empty`).

## Status

- **Not fixed.** Filed.
- Severity is ordinary: a stale render across a target switch, with
  correct targeting throughout. It is worth patching, and it is not the
  safety defect the first draft of this file claimed.
- Unrelated, same session: [the Mirror crash on
  metal](mirror-crashes-now-on-metal.md).

## This is probably not a polish item — it may be half the crash ladder

Michelle, 2026-08-08, after the VM-off run:

> yeah the host mirror needs to actually be shut off and cleared when it
> is stopped, not merely paused

Two observations from that same session, hours apart, line up:

1. She **stopped the Mirror** after a guest reboot. The crash ladder did
   **not** reset — she was still on a later rung.
2. She **restarted the host app**. The ladder **reset to rung 1**, the
   clean immediate crash.

**Stop does not clear what a restart clears.** That is this defect stated
as an experiment rather than as a complaint, and it arrives from the other
direction: not "the desktop looked stale" but "the machine's failure mode
depends on host state that Stop was supposed to have discarded."

See [mirror-crashes-now-on-metal.md](mirror-crashes-now-on-metal.md) —
the escalation ladder is partly host-side, because a host restart cannot
clear anything accumulating on the Macintosh.

**Stated as a candidate, not a cause.** What would confirm it: once Stop
genuinely disconnects and clears, stopping the Mirror should reset the
rung exactly as restarting the host does today. If it does not, the
host-side residue lives somewhere Stop was never going to touch, and this
fix is still correct but is not the ladder's cause.

That raises this file's priority. It was filed as a stale-render
annoyance. It is now on the path to "runs on metal", which Michelle has
called the bare minimum for landing `main`.

## …and on disconnection

Michelle, immediately after:

> and on disconnection.

This is the one that closes the loop, and it is the most crash-relevant of
the three, because **a crash IS a disconnection.** Every rung of the
ladder passes through one.

The sequence it implies:

1. The guest crashes — the wire drops.
2. The host's Mirror session is **not torn down**, because nothing treats
   a disconnection as an end.
3. NOW relaunches and reconnects.
4. The new connection **inherits the previous session's state**.
5. The next failure is worse than the last.

That is a complete account of the host-side half of the escalation ladder,
and it explains why only a host restart resets the rung: a restart is
currently the sole thing that ends a Mirror session.

So there are **three** events that must end a session, not one:

| event | today | should |
|---|---|---|
| Stop | pauses | end the session, clear its state |
| **Disconnection** | **session persists** | **end the session** |
| Guest change / new connection | inherits | start fresh |

The vocabulary rule applies to all three: after any of them there is no
scene because none was asked for — `notFetched`, which is a different
state from `empty`, and neither of them is "keep showing the last one".

**Still a candidate, not a proven cause.** The confirmation is unchanged:
once these three genuinely clear, the rung should reset without restarting
the host. If it does not, the residue is somewhere else and this fix is
correct anyway.

## CONFIRMED ON METAL: two live sessions from one guest, 2026-08-08 ~07:05

Poking the connected host's agent socket surface by surface, one guest,
one host app (pid 54137), one listener on 5250:

| burst | samples | `connectedAt` | `framesReceived` |
|---|---|---|---|
| sequential ×6, then concurrent ×6 | all agreed | **07:01:00** | 62 → 67 |
| rapid ×16, minutes later | all agreed | **07:01:12** | **53** |

**`framesReceived` went DOWN while `connectedAt` went FORWARD.** A single
connection's frame counter cannot decrease. These are **two live sessions
from the same guest**, and `health.guest` answers with whichever it
picks — stable within a burst, different between bursts. `roster` reads
`1` throughout because it collapses them by guest id.

An independent process sampling every 4s saw the two alternate
continuously, which is what first surfaced it.

**This is the defect Michelle named, measured:** nothing ends a session on
disconnection, so a redial leaves the old session alive beside the new
one. See "…and on disconnection" above.

### Two consequences

- **The guest is polled by both.** At ~780 ms each, a 117 MHz PowerBook
  has been serving two Mirror cadences at once. Nothing in any measurement
  taken tonight accounted for that.
- **Every metric quoted from `mirror_read` tonight came from an arbitrary
  one of the two.** The cycle counts, the ok/failed splits, the ~780 ms
  cadence in
  [mirror-crashes-now-on-metal.md](mirror-crashes-now-on-metal.md) — each
  is one session's view, presented as the machine's. They are not wrong so
  much as **unattributed**, and the ok/failed ratios in particular cannot
  be trusted to describe the whole.

### How it was missed three times

This alternation was seen three times earlier in the same session and
dismissed each time: first called a host defect, then retracted, then
blamed on the observing monitor. What settled it was **rapid sampling
from one process** — a burst is internally consistent, so any single burst
looks stable and any comparison ACROSS bursts looks like an instrument
fault. The decisive evidence was not more samples but the pairing of
`connectedAt` with `framesReceived`: one field moving forward while the
other moved backward cannot be explained by sampling error.

**A monotonic counter is worth more than a timestamp when asking whether
two observations describe the same thing.**
