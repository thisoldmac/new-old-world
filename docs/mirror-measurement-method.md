# How this project learned to measure things

**Date:** 2026-07-31, extended 2026-08-06 · **Status:** recorded
knowledge. Rules 1–12 are **inherited** from the parked upstream project
`timbottu/mirror`, mostly dug out of its 55 KB `STATUS.md`. Rules 13–22
are **NOW's own**, paid for in a single night, and they are the reason
this file no longer carries Mirror's name in its title.

Upstream retracted at least six findings during its life. Every
retraction traced to one of the rules below, and every rule was written
down *after* the mistake that cost it. This page is the part of the
inheritance that costs nothing to adopt and is worth the most.

## The rules

### 1. A rate measured without its premise enforced is a confident, meaningless number

Taught twice, in a week, in the same project.

- A keystroke verb aimed at the wrong application produced a confident
  **0%**.
- A legitimate-menu run came back **0/20 with `answered: true`** — the
  exact shape of a real mechanism failure — because a preceding probe had
  opened a window nineteen times, and with that window frontmost the
  action under test was inapplicable. Closing the leftover windows gave
  **20/20 on the same binary.**

The fix is mechanical: the harness refuses to publish a number when its
own premise is unverified.

### 2. Trials must be independent, or you are measuring drift

The most-cited number in upstream's early history was *"input injection
dies after about nine uses per boot."* The pattern looked like a
resource exhausting: `A-AAAAAAAA----------`.

**It was the oracle.** The test created a folder each trial and checked
it appeared. Nine `untitled folder` entries piled up on the desktop and
the Finder stopped producing ones the oracle could see. Trial 12 was
measured against a different machine state than trial 1.

With state reset between trials — deleting what each one created — the
same verb and the same binary give **20/20.**

That retracted number had already motivated an entire research detour
into an alternative input mechanism. The detour was worth doing for other
reasons, but it was launched on a measurement artifact.

### 3. Never verify a write with the code that performed it

A reply that carries a read-back travels the same code, the same call
and the same moment as the write. It proves the function is
self-consistent, which is not the question.

Upstream's standard was **an independent oracle**: every text-write trial
was also checked against a value read from *outside* the process by
unrelated code over a different seam — no shared code, call, or moment.

And symmetrically, **a read test must not seed its data with the thing it
is testing.** The read half was seeded through the guest's own keyboard
plane. *A read test that writes with the thing it is testing proves
nothing.*

### 4. Object-level agreement is not application agreement

Even an independent read of the object cannot detect an application
keeping its own copy of a field.

So the final oracle was **a file on disk**: write a name into a Save As
dialog, press Return, read the resulting file back. 8/8. That is what
proves the application read the field rather than its own shadow copy.

### 5. Prove a fix by mutation, in the honest direction

Take the fix back out, or deliberately wrongen the constant, and require
the probe to **reproduce the exact reported symptom.**

Upstream used this on every fix worth the name: the window-act arming
fix, the control part code, the quit event constant, the handle range
check, the build stamp, and the scene freeze. Two examples of what it
buys:

- Forcing a control part code to a wrong value gives **reply 100%,
  actuation 0%** — precisely the symptom that had been reported as "the
  mechanism doesn't work," which is how that accusation got retracted.
- Removing a window-act fix leaves `move` at **5/5** while `resize`,
  `zoom` and `close` all fall to **0/5**. `move` uses no patch, so it is
  the control, and its being unmoved is what makes the other three
  meaningful.

The scene-freeze gate was proven the same way — six separate mutations,
each producing a specific count of red tests, each reverted.

### 6. A guarded function cannot report on itself without an unguarded counter

If a patch is not visibly doing anything, you must distinguish **"never
entered"** from **"entered and declined."** Those are opposite repairs.

The technique: a hit counter bumped at the **top** of the function,
before any guard. It read zero, which is how the double-`FindWindow`
behaviour was found.

### 7. An acceptance criterion written down and never run is how a defect lives for weeks

Upstream wrote *"nothing stays armed across a user's own interaction"*
into a plan as a safety property. It was false. Measuring it is how they
found out — 18/20 hijacks — weeks later.

### 8. The instrument is the first suspect

A two-byte width error in a probe's own filter produced two opposite
wrong conclusions from one bug. See
[mirror-journaling.md](mirror-journaling.md).

### 9. Reading a result field without checking the status turns a reply into a failure

An honest `ok: false, not_actionable` reply, read by a client that
indexed straight into the result, became a client-side exception and
then a "wedge" theory. **`ok: false` is a reply, not a failure.**

### 10. Dispatched is not performed

`performed: true` means the event was dispatched. It is not a claim that
anything happened. Upstream names this *"the distinction that cost four
retracted findings."* Every act in its records is verified in guest
filesystem or window state, never by the service's own report.

The same applies to launch: `launched: true` means a Process Manager call
returned without error and handed back a serial number. **It is not a
claim that a window exists.**

### 11. Occlusion is a skip, never a pass

A gesture aimed at a desktop item with a window over it resolves to the
window. The test proves nothing, so it must record a skip.

### 12. Content-address the build stamp

A build stamp derived from a compile clock did not move when a source
file changed — verified: an edit to one file left the stamp at exactly
its previous value. Hashing the sources moves it every time.

**And the corollary upstream recorded as a gap:** only the application
carried a stamp; the resident extensions did not, so a changed extension
shipped alongside an application reporting an unchanged build. **You
could not ask the guest which extension was resident**; liveness had to
be proven by behaviour.

## Two traps in the environment, not the method

Recorded because they cost hours and look like defects in the thing
under test.

- **The single-connection wire.** A second client resets the first, with
  a bare connection reset and no explanation on either side. It has
  manufactured two separate wrong narratives. See
  [mirror-perceive-plane.md](mirror-perceive-plane.md).
- **A missing capability in the session's scope reads as a refusal**, not
  as an absent feature — which looks nothing like the thing it breaks. A
  test battery once reported an actuation bug that was pure
  configuration.

## Two facts about shared headers

Upstream shipped two copies of a shared-memory struct, byte-identical,
in different trees. It is now one include.

> Two copies of a shared-memory ABI do not fail to build when they
> drift. They fail to **agree** — and a struct-offset disagreement across
> a shared block is silent corruption.

It surfaced only because a new field broke one side's build first, which
was luck.

The second fact is the version rule that came out of it: **an older
reader must refuse a newer request rather than reinterpret it.** Writing
a field into a block that has no room for it is silent corruption, not
an error. Upstream's version counter moved four times, and one of those
moves existed only because two parallel branches both numbered their new
operation `5`.

## The rules NOW paid for itself

Rules 1–12 came in from outside. **13–22 were bought here**, all of them
on 2026-08-05/06, and all of them the same shape: the
instrument was wrong, and the wrong answer it gave was plausible enough
to act on. Between them they cost this project six wrong conclusions,
three of which were written down and had to be retracted — the third
being plan 012 § 5's modal row, retracted by rule 21.

They are collected here rather than left in the ledger entries they
came from, because the Macintosh detail in each one is the least
transferable part. Every entry names its evidence in
[open-issues.md](open-issues.md).

### 13. A differential that moves two variables measures neither

The scene walk cost ~1.1 s with NOW frontmost and almost nothing with a
foreign app in front, so the menu bar — the obvious thing that changes
when NOW comes forward — was named as the cost. It is **0.1%** of it.

The two conditions differed by window **activation** as well, and that
was the variable that mattered: `FindControl` costs **~2.7 µs per point
on an inactive window and ~240 µs on an active one** — two orders of
magnitude, and the ledger states that pair three times — because an
inactive window declines the hit test before doing any work. The real
cost was a `FindControl` grid sweep of NOW's own window, ~95% of the
total.

A differential is only an experiment if you can name every difference
between its two arms. If you cannot, it is an anecdote with numbers.

### 14. A clock cannot measure anything shorter than its own tick

`latencyMs` was derived from `TickCount()` — 60 Hz, **~16.6 ms of
quantisation** — and was read for years as though it were a measurement.
Anything faster than a tick reads as 0 or as 16, and *two separate wrong
answers* were argued from those numbers before anyone asked what the
clock's resolution was.

The repair was not a better estimate, it was a better instrument:
`meta.phases`, in **microseconds**, permanently in the message rather
than bolted on for one investigation. A measurement you have to re-add
each time you become suspicious is a measurement you will not take when
it matters.

State a clock's resolution beside its first number, always.

### 15. A bracket is named for what it was for, and contains what it contains

`decode_ms` does not measure decoding. It brackets publish-minus-deliver,
and inside that bracket the host waits on `joinContent` and **two paged
AppleScript round trips into the guest's Finder, run every cycle**. Our
own CPU work in there is **4 ms**.

The number is therefore a measurement of the Finder's mood, not of this
side's code: **12 windows cost 714 ms; 3 windows cost 12,559 ms.** The
count of windows is not the variable — the Finder's responsiveness is.

The name was accurate when the bracket was written. Nothing renamed it
when the waits moved inside. Check what a timer *encloses* before
quoting it, not what it is called.

**Split, and answered live the same day.** Once the bracket was broken
into its four stages, one run (n=85, Finder healthy) said which one it
was: `dc_vis_ms` **338 ms of a 353 ms median — ~96%** — the visibility
census, paid every cycle for state that changes only when a process
starts, quits, hides or shows. This side's own CPU was 9 ms. Nobody had
guessed the census; the three arguments in flight were all about the
icon roster, which measures **0 ms** until the layout changes. The
lesson under the lesson: splitting a bracket is cheap, and it beats
arguing about which of its parts is the expensive one. Evidence and the
after-numbers are in [open-issues.md](open-issues.md) under *"ANSWERED,
live (2026-08-06): the visibility census dominates"*.

### 16. A check next to the question is not the question

Three stage images were preserved **dirty**, and the two receipts that
certify any of them called them clean, on the strength of `qemu-img
check` — the third image was baked by hand and has no receipt at all,
which is its own kind of gap. That command validates
the **container** — the qcow2 structure — and has no way to see the
filesystem inside it. It was adjacent to the question and was mistaken
for it.

The question is answered by reading the HFS volume's **unmounted bit**
(`tools/volclean.py`), and the only route that actually sets it is the
Finder's own Special ▸ Shut Down, driven through `menuact` — which needs
`serialHi`/`serialLo` to name the process.

When a check passes, say what it would have had to see in order to fail.
`qemu-img check` could not have failed for this reason.

### 17. An instrument that refuses reports an absence

`FindControl` refuses an **inactive** window. An observer that
enumerates controls by hit-testing therefore reported **zero controls**
for any backgrounded window — a clean, confident, entirely false
absence, and one that had never once been observed as a bug, because
"the background window has no controls" is not a surprising sentence.

Rule 6's counter technique answers "never entered" versus "entered and
declined" for our own code. This is the same distinction one layer out:
**a Toolbox call that declines looks exactly like a world with nothing
in it.** Foreign windows now retract the control plane instead of
claiming an empty one — though note that the retraction path is **built
and not yet observed**, so this rule is better learned than the fix is
trusted.

### 18. A liveness signal renewed by the traffic it is watching for measures the traffic

Two of the night's defects were one mistake at two layers.

- The peek writer's **heartbeat** was renewed only inside peek calls, so
  it went stale whenever the host was quiet — it was measuring *wire
  cadence* and reporting it as *liveness*. This is the whole of the
  "anchor plane is active and binds nothing" entry. `now_peek_idle()`
  now renews it once per event-loop pass, which is the thing the
  heartbeat is actually a claim about.
- The guest's **dead-link clock** counted wall time, including time the
  guest was not scheduled at all, and so killed its own session for a
  silence that was its own. Time you were not running is not time the
  other side was silent.

A heartbeat must be driven by the condition it asserts, and by nothing
else. If it is renewed by the peer's traffic, it is a traffic detector
wearing a heartbeat's name.

### 19. The end of a shared log is not your run

`acts.log` is appended to by **every** host process on this Mac, and its
`NOWBASE cycle` lines carry no guest identity — no wire port, no guest
build, no pid. Reading the tail of that file therefore answers "what did
some host do most recently", which is a different question from "what
did the build I just made do".

The bill: the four stage fields of rule 15 were reported **absent from
every live cycle**, an instrument-is-broken finding, written into a plan
as its blocking §1. The instrument was fine. The last `cycle` line in
the file was written at `13:58:19`; the app containing the new fields
started at `13:58:24` and had not yet run a cycle. Every line examined
predated the code being examined. (`nm` on the packaged executable
showed the symbol present all along.)

What makes it worth a rule of its own is *who* paid it: the session
reading the log had, hours earlier, written the rule that a shared
surface has to be attributed before it can be quoted (drive-loop §2m).
Knowing the rule is not the same as having a habit that applies it.

So: attribute a reading before believing it. A mark you wrote yourself,
a process start time, a guest build stamp — something that ties the line
to the run. And prefer instruments that carry their own identity: the
metal gates already refuse a guest that is not the build under test
(`requireTheBuildUnderTest()`), and a log line that named its guest
would have made this impossible rather than merely avoidable.

### 20. A blocking call that does not pump makes ONE slowness look like TWO

Michelle reported a Mirror loop taking 9–12 seconds, and her log showed
two apparently independent slow things: a `request_ms=12041`, and an act
her guest reported as `guest 12099ms`. Two numbers, two subsystems, two
theories — and the leading one, that a modal was starving the machine,
was wrong.

**They were one event, counted twice.** `act_yield` in the guest's act
client spins on `WaitNextEvent` without pumping the wire, under two
consecutive phases of 5 s each, so a `scene.request` that arrives while
an act is waiting is not slow — it is *queued behind the act*, and it
reports the act's duration as its own. Measured directly: an act refused
after **6.6 s**, and a `scene.request` issued in the same instant
answered in **6634 ms**. The same number twice is the tell.

Two consequences worth stating separately, because each has its own way
of misleading:

- **A shared blocking point manufactures correlations.** Every
  measurement taken through it inherits its duration, so unrelated
  subsystems appear to slow down together and invite a common-cause
  theory about the *machine* — scheduling, a modal, the Finder — when
  the common cause is a single call on this side's own stack.
- **It can also feed itself.** The anchor plane's ten-second owner lease
  is renewed by host traffic *through* `conn_service` — precisely what
  the wait holds off. So a ~10 s act lapses the lease and the *next* act
  refuses `plane absent`: "refused the first time, worked the second",
  which reads as flakiness rather than as the previous measurement's
  after-effect.

So: when two numbers agree more closely than two independent causes
should, look for a serialising point they share before believing they
are two findings. And a latency attributed to the far machine has to
clear this side's own stack first — the guest was not slow, it was not
being asked.

### 21. A mode named for a mechanism must be shown to exercise it

`tools/guest-wedge`'s `modal` mode raised a dialog and reported that a
modal starves nothing — **71 s watched, never starved**. That went into
plan 012 § 5 as a measured result and killed the "modal sitting there"
hypothesis on the strength of it.

The mode never measured a modal. `ModalUntil` looped `GetNextEvent`
back-to-back with **no sleep**, which yields nothing, so the mode was
the `spin` mode with a dialog drawn over it. Re-run with better
instruments, the three modes are indistinguishable: `spin` 44,061 ms,
`modal` 43,974 ms, `scan` 43,975 ms of 45 s, and the guest's own
`wirestat` histogram says its event loop did not run once. Two of § 5's
three rows were retracted.

What a real modal actually costs had to be measured a different way —
by raising one in a **real application** through `ctlact`, so the
application runs its own handler: a **20× slowdown** (scene median 21 ms
idle → 413 ms, n=145) and no starvation at all. Acts work through it;
`ctlact` on the modal's own Cancel answered in 0.7 s.

The generalisation, and it is not the same as rule 8: a name is a
statement of *intent*. Rule 8 says suspect the instrument when the
answer is surprising — this says suspect it when the answer is
*unsurprising*, because nothing here looked wrong. The check is a
positive control on the mechanism itself: before quoting a mode, show it
doing the thing it is named for, by some signal other than the number
you want from it. A synthetic stand-in for a mechanism is a hypothesis
about that mechanism, not an instance of it.

### 22. Arithmetic over an assumed layout fails silently; only something outside it can say so

An alert's message text was missing from the wire. The first instrument
was header arithmetic: derive the item's length from the block header
below its data, the documented classic layout. It produced **nothing**,
with no error, no exception and no diagnostic — the failure mode of an
assumption is an answer, not a complaint.

The **QEMU memory oracle**, reading the guest's RAM from outside the
guest on a stopped VM, said why: this heap's block header is not the
24-bit-era layout at all. The longword below the data holds a
**zone-relative offset**, not the master pointer — demonstrated by two
different items differing from their handles by the *same* base — and
the tag byte's size-correction nibble reads zero while the physical
block overshoots the string by eight bytes. The arithmetic would have
appended eight bytes of heap slop to every alert: a wrong answer that
would have looked right in most captures. `GetHandleSize` knows;
`GetDialogItemText` is now the seam, and `dialog_text.h` carries the
reason.

Two things to carry:

- **A silent failure is the expensive kind**, because there is nothing
  to debug — you have to become suspicious on your own. When a
  derivation returns empty rather than raising, the assumption under it
  is the first suspect, not the data.
- **An oracle outside the layout is what settles a layout question.**
  Rule 3 says do not verify a write with the code that performed it;
  this is the same rule for *structure*. Nothing that parses a block
  using the layout can tell you the layout is wrong — only a reader that
  makes no assumption, in this case raw bytes lifted out of the machine,
  can. It cost one run on a stopped VM.

## What this looks like in NOW

NOW already holds the same convictions from its own scars — the contract
is the source of truth, a test you have not watched fail proves nothing,
verification is a status and not an adjective. Rules 1–12 are the same
lessons learned on a different machine, and the ones NOW did not already
have written down are **1, 2, 4, 6 and 11.**

Rules 13–22 it now has written down because it made them. The
transferable core of all ten, and the sentence worth carrying out of
this file: **before believing a number, say what the instrument could
not have seen.**

Rules 20–22 add a second sentence beside it, because three of the
night's wrong answers were not about what an instrument missed but about
what it *substituted*: **say what the instrument actually did, not what
it is named for.** A mode called `modal` that never raised one, a
`request_ms` that timed a queue rather than a machine, and arithmetic
over a layout the heap does not use — each returned a clean number, and
in every case the repair was an independent reading from outside the
thing under test.
