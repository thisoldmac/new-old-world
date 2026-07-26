# A trustworthy 68K metal pass

How to run the NOW-68K suites against the PowerBook 180c so that the
result means something afterwards.

This exists because a metal run on 2026-07-25 produced results nobody
could attribute. Two host sessions used one PowerBook: one held port
5252 for the better part of an hour while the other deployed a build
into the same folder over FTP, mid-ladder. A 1 MB push stalled at
606208 bytes and every rung after it timed out at `0 of N`. Contention
is the likely cause and nothing proves it — and an unattributable red is
worse than a green, because at least a green does not send somebody
looking for a bug.

The failure modes are all in [open-issues.md](open-issues.md). This
turns them into a procedure.

---

## Before you start

**Ask.** The 180c is shared — with other agent sessions and with
Michelle's own screenshot testing — and it serves one host at a time.
An unasked metal run is what produced the mess above. This is a
per-action ask; permission for one pass is not permission for the next.

**Say what you are taking.** Which ports, roughly how long, and whether
you are deploying. Another session reading that can stay off the
machine; another session that never sees it cannot.

Then, on this Mac:

```bash
lsof -nP -iTCP:5250,5251,5252,5253
```

Empty is what you want. Anything there is another harness, a
`deploy-68k --test` still running, or the NOW app itself (it lives on
5250). What matters is which port and what state:

- **Your port, held by anything** — a failure. The run cannot bind, or
  would take somebody else's guest.
- **Another metal port, ESTABLISHED** — a failure when the run names its
  machine. Something on this Mac has a guest right now, and two
  harnesses aimed at one PowerBook interleave rather than queue.
- **Another metal port, LISTEN only** — a warning. An idle listener has
  nobody; the NOW app sits on 5250 all day without touching the 180c.

```bash
lsof -nP -iTCP@10.91.5.180
```

Empty is what you want. An `ftp` or `python` conversation is a deploy in
flight — the exact shape of the run that stalled at 606208. An `xctest`
one is another session's suite.

The suites run both checks themselves (`MetalMachineGuard`), so you can
skip straight to the run and let it refuse. Doing it by hand first only
saves the build.

**At the machine, if you can reach it:** type `xfer` in NOW-68K's
console. It reports both directions — an active receive, an active send,
and the last completed one either way. A transfer in flight there is
another session mid-ladder and no host-side check can see it. (This is
also why the guard cannot ask: `xfer` is console-only by a recorded
decision, and NOW-68K serves no `putstat`. See the ledger.)

---

## The environment

| Variable | What it does |
|---|---|
| `NOW_METAL=1` | opts in. Without it every metal suite skips; with it they FAIL rather than skip, which is the point (AGENTS.md). |
| `NOW_METAL_PORT` | the port the guest dials. **Set it.** The defaults differ per suite (5250, 5251, 5252, 5253) and a run that takes the default takes whichever one that file happened to pick. |
| `NOW_METAL_MACHINE` | the guest's address — `10.91.5.180` for the 180c. **Set it for any run against the PowerBook.** Without it the guard cannot check whether anything else on this Mac is talking to the machine, and it says so rather than passing quietly. |
| `NOW_METAL_REPEATS` | how many times the rungs at or above 1 MB are measured. Default 1. **Use 3 on the 180c** — see [68k-metal-baseline.md](68k-metal-baseline.md). |
| `NOW_68K_NEW_APP` etc. | set only by `scripts/deploy-68k --handoff`. Do not set them by hand. |

**One `swift test` process at a time on this Mac.** The suites share
external state: `HostLogTests` and `LoggingSpecTests` both write
`~/Library/Logs/now-logs`, and `HostAppStateWiringTests` binds a fixed
port 52981. Two concurrent runs fail those three every time — watched,
2026-07-26 — and a metal pass started beside somebody's ordinary
`swift test` reports failures that have nothing to do with the
Macintosh. Which is the same class of unattributable red this whole
document exists to prevent, one floor down.

**Prefer `scripts/deploy-68k --test-only` to a bare `swift test`.** It
sets `NOW_METAL`, `NOW_METAL_PORT` and `NOW_METAL_MACHINE` (from the
address it deploys to) and keeps the build scratch outside the
repository, so the common path does not depend on remembering four
variables:

```bash
scripts/deploy-68k --test-only --port 5252 --filter Metal68KPutTests
```

The `swift test` forms below are spelled out because they are what the
script runs and what you will want when something needs varying.

---

## The order, and why it is that order

Each step is cheap relative to the one after it, and each one's failure
tells you not to bother with the next. Run them as separate invocations
rather than one broad filter: a suite that fails takes its listener down
with it, and the next suite in the same process then reports a port
problem that is really the first suite's corpse.

### 0. Deploy, if there is something to deploy

```bash
scripts/deploy-68k --handoff
```

It bumps the version, builds, stamps the MacBinary's internal name from
that version, uploads, verifies the fork sizes against the local header,
and then has the running build launch the new one and be retired by it.
The old build is only asked to quit after the new one has handshaked, so
a build that cannot start leaves the machine reachable.

Without `--handoff` somebody has to double-click the new build on the
180c.

### 1. The wire still works — `Metal68KTests`

```bash
NOW_METAL=1 NOW_METAL_PORT=5252 NOW_METAL_MACHINE=10.91.5.180 \
  swift test --package-path host --filter Metal68KTests
```

Dial, handshake, keepalive, the bounded catalog search, the farewell,
the redial. If this is red, nothing after it can be read: every later
suite's failure mode includes "the wire is not working".

### 2. What the guest says it serves — `Metal68KContractTests`

```bash
NOW_METAL=1 NOW_METAL_PORT=5252 NOW_METAL_MACHINE=10.91.5.180 \
  swift test --package-path host --filter Metal68KContractTests
```

Fast, and it establishes that the build on the wire is the one you
deployed. Cheaper to find a stale build here than three rungs into a
ladder.

### 3. Receiving — `Metal68KPutTests`

```bash
NOW_METAL=1 NOW_METAL_PORT=5252 NOW_METAL_MACHINE=10.91.5.180 \
  NOW_METAL_REPEATS=3 \
  swift test --package-path host --filter Metal68KPutTests
```

The size ladder to 4 MB, the MacBinary envelopes, the unknown-container
refusal, and the guest still answering while bytes stream. This is the
first thing that moves a megabyte on the machine, so it is the first
thing that can be slow rather than wrong.

### 4. Sending — `Metal68KSendTests`

```bash
NOW_METAL=1 NOW_METAL_PORT=5252 NOW_METAL_MACHINE=10.91.5.180 \
  NOW_METAL_REPEATS=3 \
  swift test --package-path host --filter Metal68KSendTests
```

The round trip — push a pattern, ask for it back, compare the bytes this
side still holds — plus the control lane under a 4 MB send. It runs
after the receive suite because the round trip's first half IS a push:
if pushing is broken, every case here fails in the push and says so, and
you would rather have learnt that from step 3.

### Not in the pass: `Metal68KHandoffTests`

It skips unless `NOW_68K_NEW_APP` is set, and only `deploy-68k
--handoff` sets it. It is a deploy step, not a coverage gate. It used to
fail in any run whose filter caught it, which meant `--filter Metal68K`
always reported one failure that meant nothing.

**So do not use `--filter Metal68K`.** Not because of the handoff any
more, but because it starts five suites' listeners in one process on
four different default ports against a guest that dials exactly one.

---

## Reading a partial failure

The whole ladder green is easy. These are the cases that are not.

**One rung red, the rest green.** A defect, and the rung names it: the
sizes are chosen against the buffers in the path, so `8193` failing
while `8192` passes is an off-by-one in the flush or the END flag, not a
slow machine.

**A rung red and everything after it red at `0 of N`.** The signature
of the contended run. `0 of N` means not one progress report arrived —
the guest never started, rather than started and stopped. Suspect the
machine before the code:

- Did the guard pass? If `NOW_METAL_MACHINE` was unset it never ran the
  address check, and the run proves less than it looks.
- Is something else on the machine now? Re-run the two `lsof` lines. A
  deploy that started mid-run will still be there.
- Has MacTCP wedged? It does this silently on the 180c and there is no
  host-side symptom other than dials that never complete. Reboot the
  machine and re-run. If the re-run is clean, the first run was the
  machine and not the code — say exactly that, in those words, because
  "it passed the second time" reads as flakiness rather than as a
  diagnosis.

**A rung slow but green.** That is a measurement, not a failure. Record
it (`NOWBASE` lines, [68k-metal-baseline.md](68k-metal-baseline.md)) and
do not tune anything on one sample.

**Samples of the same rung that disagree by more than about 2×.** With
`NOW_METAL_REPEATS=3` this is visible rather than averaged away, and it
is a finding in itself: something else was using the machine, or the
disk, during one of them.

**Nothing dialled in.** The suites now distinguish three causes rather
than blaming the Macintosh for all of them: the port was held (the guard
says so, in about a second), the listener failed to bind (said as a bind
error, not as a timeout), or the machine genuinely never dialled. Only
the third is the Mac's end.

---

## Telling contention from a defect

The honest answer is that a single run often cannot, which is why the
guard runs first. In order of strength:

1. **The guard fired.** Then it is contention and you have not measured
   anything. Stop and clear the machine.
2. **A `deploy-68k` or another `xctest` was talking to the machine.**
   `lsof -nP -iTCP@10.91.5.180` after the fact still catches a long one.
3. **`xfer` at the machine shows a transfer you did not start.** The
   strongest evidence there is, and only a human at the keyboard can
   get it.
4. **A clean re-run on a quiet machine.** Necessary but not sufficient —
   it is also what an intermittent defect looks like. Two clean re-runs
   after one contended failure is the least you should be willing to
   write "emulator-verified" over, and it is still not a proof.
5. **Nothing.** Then say nothing: record the run as unattributable and
   do not put its numbers in the ledger. That is what the 2026-07-25
   entry does, and it is the entry this document exists to avoid
   needing again.

---

## After a green pass

- Save the `NOWBASE` lines. `swift test ... | grep NOWBASE` is the whole
  of it; where they go and how to read them is
  [68k-metal-baseline.md](68k-metal-baseline.md).
- Update [open-issues.md](open-issues.md) and
  `docs/contract-coverage.md`'s proven column. A pass that does not move
  something from "emulator-verified" to "metal-verified" has not been
  recorded, and the next person will run it again.
- Write **metal-verified** only for what a run actually exercised, and
  name the build and the date. AGENTS.md: verification is a status, not
  an adjective.

## The emulator

`scripts/q800-68k --port N` is free to use and needs none of the above —
it is this Mac's own VM and no other session can be holding it. Check
the port is free first (several sessions run VMs at once and every one
of them sees this Mac as 10.0.2.2, so any of them can reach any
listener), and read a green run as **emulator-verified**. It is a 68040
under Mac OS 8.1 with 128 MB. Correctness carries over. No number does.
