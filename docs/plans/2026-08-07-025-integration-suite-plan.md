# An integration suite that boots a Mac

**2026-08-07. Specced, not scheduled** — implementation waits until the
census crash is closed. This exists so the design is settled before
anyone starts, and so the census gate now being built is understood as
its first stage rather than a one-off.

## Why, in one measurement

Michelle, on being told what `scripts/test-all` actually runs:

> so we should probably define a set of integration tests in a vm… do we
> really not? had integration testing been manual this whole time? that
> explains a lot if so.

**It had.** `test-all`'s five stages — staged-image discipline, native
tests, MirrorKit, guest cross-builds, host gate — **boot nothing**.
Everything that mentions QEMU in a test path only reads text:
`test_spin_up_ppc_shutdown.py` has five references and launches nothing,
`test_lane_ports.py` twenty. `MetalMachineGuard` asks whether a machine
is *free*; it does not start one. The metal gates are
`XCTSkipUnless(NOW_METAL)` — off by default and aimed at the PowerBook.
The only things that boot a guest are `spin-up-ppc`, `bake-ext-image` and
`q800-68k`, and **none of them is a test**.

So **every "emulator-verified" claim in this arc came from a lane driving
a guest by hand and writing down what it saw.** The vocabulary has that
tier precisely because no gate produces it.

The cost, on 2026-08-07: **`census` kills the Workshop and the App
Switcher crashes the Finder, while 1,902 tests pass.** The gate is not
wrong about anything it measures. It has never been pointed at a running
Mac.

**And it explains the arc's dominant error class.** Fifteen recorded
instrument blind spots, and every instrument was hand-built, once, by a
lane, for one measurement — `fidelity-sweep.py`, `local-pair-capture.py`,
`fidelity-live.py`, `local-drag-vehicle.py`, `local-pressed-capture.py`,
the cursor rig's `sprite_check.py`. Six one-off drivers, each blind in
its own way, because there was no standing harness to extend.

## The shape

Michelle:

> i dont want to be spinning up a fresh vm for every test, that would
> take forever, but maybe at least a set of regression tests for the
> whole workshop in one vm session plus a few focused tests targetting
> the new code?

**Right, and there is a cheaper primitive than either option.** You do
not need a fresh VM — you need a fresh **state**.

**QEMU snapshots already exist here and nothing uses them.** `qemu-img
snapshot -l now-mirror-stage.qcow2` lists `baseline`,
`predoors-20260706` and `runner-ready`. `spin-up-ppc` mentions `-loadvm`
only in a comment warning that a QMP `quit` is a power cut.

So: **boot once, `savevm` at a known-good point, `loadvm` between
groups** — about a second against a two-to-three-minute cold boot. Shared
state for the Workshop regressions; a restore before anything that can
wedge the machine.

It also fixes what would otherwise sink a single-session suite. Today's
crash would take out every test after it, leaving a choice between
reporting the rest as *skipped* (which reads as coverage) or as
*failures* (which blames the wrong code). With restore, a crash costs a
second and the suite keeps its meaning.

### Slice 0 — the experiment that decides everything

**`loadvm` restores RAM, so the guest's TCP state returns mid-conversation
while the host's socket is gone.** Does the guest re-dial cleanly, or must
the snapshot be taken *before* the host connects, with pairing done fresh
each time?

Twenty minutes: boot, `savevm`, disconnect, `loadvm`, watch the wire.
**Report what happens, not what should.** Every later slice depends on
the answer, and if restore turns out to be unusable the whole design
falls back to grouping by cold boot — which is still worth having, just
slower.

*Being measured now by `claude/024-census-crash`, since it also makes
bisecting the census crash far faster.*

## The three properties that make it honest

Each is a failure this arc has already paid for.

1. **Liveness is an ANSWER, not a process check.** On 2026-08-07 the
   Workshop was dead with its window still on screen — `pgrep` would have
   said fine. Between every test: ask the guest something and require a
   reply.
2. **When the guest dies, everything after it is `unrun`.** Never
   `skipped`, never `passed`. A suite that continues past a dead machine
   and reports green is this arc's defect class and would be its
   sixteenth instance.
3. **Assert the build under test on every reconnect.** After a restore
   the guest re-dials, and on this Mac any session's VM can answer your
   listener. `requireTheBuildUnderTest()` exists because that has already
   happened.

Plus the standing rule the whole arc turns on: **a test that only asserts
"the verb returned ok" would not have caught today.** The assertion must
be about the machine's state, not the reply.

## What goes in it

### Tier 1 — Workshop regression, one shared state

Every module opens and **answers**. The crash-class checks first, because
they are the ones that take the machine with them:

- `census` — the whole probe set, and the Workshop alive afterwards
- the process roster, including the App Switcher path that crashed the
  Finder (**if it cannot be reached without a human clicking, say so
  rather than implying coverage**)
- each Workshop module reachable and answering
- the console face and the wire face agreeing, per `command-parity`

### Tier 2 — focused, restore before each

Anything that can wedge, and anything new:

- act-plane verbs against a real control, asserting the machine changed
  rather than the reply
- the content plane armed on a named window, drain non-empty
- scene walk over a busy desktop, against the control-pool ceiling
- **new code, each slice adding its own** — this is where the suite earns
  its keep over time

### Tier 3 — the existing one-off drivers, folded in

Six hand-built rigs exist and each measures something real. **Folding
them in is the point**, not rewriting them: they become stages with a
shared harness, one liveness rule and one build assertion, instead of six
private answers to the same three questions.

## Where it runs, and what it costs

- **Not in `test-all` by default.** A VM boot on every run, for every
  lane, forever, is the wrong trade.
- **The bake is the natural home for the crash-class checks** —
  `bake-ext-image` already clones the oracle, cold-boots so the INIT
  loads, and asks the guest `mirror`. A guest is already up there, so the
  marginal cost is seconds, and it makes the bake unable to pass with a
  guest-killing resident. That is exactly Michelle's *"green and baked
  before I drive"*.
- **The full suite as its own command**, opt-in in the `NOW_METAL` style:
  skip when unset, and **once opted in, fail rather than skip**.

## Open questions, honestly

- Whether `loadvm` restore is usable at all (slice 0).
- Whether the snapshot should be taken before or after the host pairs.
- How to reach the App Switcher without a human — it may be that some of
  Tier 1 is genuinely human-only, and that is worth stating rather than
  faking.
- Whether the six existing rigs can share a harness without losing the
  specific thing each was built to see. **Folding must not blunt them.**
