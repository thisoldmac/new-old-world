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
