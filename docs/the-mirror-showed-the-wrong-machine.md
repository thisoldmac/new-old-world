# The Mirror showed one machine and drove another

**Reported by Michelle, 2026-08-08, during the first metal session in
weeks.** Filed from her account plus a read of the code. **Nothing here is
reproduced by a test yet** — the mechanism below is derived from the
source, and the sequence is hers.

## What happened

She switched the host's target between the PowerBook 1400c and the
emulator and back. With a healthy connection to the PowerBook:

> despite having a healthy connection to the powerbook, the mirror is
> still showing the vm
>
> wait, no, its actually targetting the powerbook. it just has a dirty
> desktop and is showing the vm's desktop. I closed the now ws on the
> powerbook, despite showing the vm's desktop. workshop rendered with the
> collapsed sidebar, just like i had it on the powerbook, i clicked close
> on the mirror and it closed. i clicked one more thing and i wedged the
> system

Read that correction carefully, because it inverts the severity. The
first sentence describes a stale view — annoying. What she actually found
is worse:

**Acts went to the PowerBook. Pixels came from the VM.**

The proof is in her own account and needs no instrument: closing the NOW
Workshop *on the PowerBook* worked while the view showed the VM's
desktop, and the Workshop that rendered carried **her collapsed sidebar**
— PowerBook state — inside a desktop that was the VM's.

Then she clicked one more thing and wedged the machine. That is the
predictable end of it, not a separate incident: she was choosing where to
click from machine A's picture, and the click landed on machine B.

## Why this is the most serious defect of the night

Every other bug in this arc is a thing that does not work. This is a
thing that works **while lying about where it is working**. The product's
one job is to let a person drive an old machine through a window on a new
one, and the contract that makes that safe is that the window shows the
machine the clicks reach.

It is the same hazard the act plane already refuses at the point level —
the cursor rig's README states it plainly, that clicking a point nobody
resolved is an inference a real act plane will not make. This is that
inference one level up: **acting on a machine nobody confirmed.** The
mechanism is not a click at an unresolved point; it is a *human*
resolving a point against the wrong machine's screen.

## The mechanism, derived from the source

Identity is present in the data and unchecked at the boundary where it
matters.

- `MirrorProjection` (`mirror/host/MirrorKit/Sources/MirrorKit/MirrorProjection.swift:11`)
  carries `session: MirrorGuestSession`, and `MirrorGuestSession`
  (`MirrorEntityIdentity.swift`) is `{ guest, incarnation }`. So every
  projection already knows which guest and which incarnation it came
  from.
- The host also knows the connected machine independently:
  `GuestIdentity` (`now-host/Sources/Host/GuestIdentity.swift:267`) holds
  `machineID` and builds a stable key `m<machineID>`.
- **Nothing joins them at render time.** A search for a scene reset on
  target change finds only `WireClient.disconnect()` dropping the
  connection — the last projection is not invalidated by a target change,
  and the renderer has no guard that the projection's `session.guest`
  matches the machine now connected.

So on a target switch the act path re-points immediately (it routes to
the live connection) while the view keeps the last projection it was
handed. The two halves disagree and neither notices.

This is the file family's own rule turned inward: a field one side sends
and the other never checks is the same defect class as a field one side
sends and the other has never heard of.

## What the fix has to be, and what it must not be

**Refuse, do not reconcile.** The renderer must compare the projection's
`session.guest` against the connected machine's identity and, when they
differ, show nothing — an honest empty state naming both machines — until
a projection for the connected machine arrives. Showing a stale frame
with a warning badge is not acceptable here: a person mid-drive reads
pixels, not chrome, and the failure mode is that they click.

Three things that would each be a smaller version of the same lie:

- **Do not clear to a blank window silently.** "We have not asked yet" and
  "we asked and this machine has no windows" are different states with
  different vocabulary (`notFetched` vs `empty`), and this is `notFetched`.
- **Do not fall back to the last known good scene for the new machine.**
  That is the same bug with a longer fuse.
- **Do not let a click through while the identity is unresolved.** The act
  lane should refuse for the same reason the view does, so the two halves
  cannot disagree in the other direction either.

## The gate this needs

A test that constructs a projection from guest A, connects to guest B,
and asserts the renderer produces the refusal rather than A's scene. And,
because this repo has shipped guards that passed the mutation they
claimed to catch, it must be **watched failing**: remove the identity
comparison and confirm the test names it.

The deeper gate is that `MirrorProjection` and the connected
`GuestIdentity` should not be joinable by convention. If the render path
took a type that can only be built by proving the two agree, this class
could not return.

## Status

- **Not fixed.** Filed only.
- **Not reproduced in a test.** The sequence is Michelle's; the mechanism
  is read from the source. Those are different confidence levels and this
  document does not merge them.
- Related and NOT the same: the Mirror crashing NOW on the PowerBook, and
  the Finder dying after the second crash. Same session, no established
  connection between them.
