# How Mirror learned to measure things

**Date:** 2026-07-31 · **Status:** recorded knowledge, carried from the
parked upstream project `timbottu/mirror`, mostly dug out of its 55 KB
`STATUS.md`.

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

## What this looks like in NOW

NOW already holds the same convictions from its own scars — the contract
is the source of truth, a test you have not watched fail proves nothing,
verification is a status and not an adjective. The rules above are the
same lessons learned on a different machine, and the ones NOW does not
already have written down are **1, 2, 4, 6 and 11.**
