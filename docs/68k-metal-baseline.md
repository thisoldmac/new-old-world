<!-- now-doc-provenance: generated reviewed=false -->

# What to measure on the 180c, and how to record it

The first metal run of the 68K file family should produce a **baseline**
and not an anecdote. This says what that means, what the run records,
and what the numbers already in the ledger are and are not worth.

## Nothing measured so far predicts this machine

Everything the ledger has for either direction was measured on a Quadra
800 under Mac OS 8.1 with 128 MB (`scripts/q800-68k`):

| | emulator |
|---|---|
| receive, 4 MB | 11.6 s, 352 KB/s, 512 progress reports |
| send, 4 MB | 2.5 s, 1648 KB/s |
| control lane during a 4 MB send | 28 asked, 0 dropped, worst 0.10 s |

The real target is a 68030 at 33 MHz under System 7.1 with 4 MB and a
384 KB application partition. Two specific reasons not one of those
numbers is a prediction:

- **The receive rate is a 68040's.** Whatever the 180c does, it is a
  different machine's number, and the ledger has already recorded MacTCP
  behaving differently under load on that hardware.
- **The send rate reads off a disk the emulator caches.** 1648 KB/s
  against the receive direction's 352 is not the sender being fast; it
  is the read being free. On the 180c the read is a real one off a real
  disk and the send direction has no reason to be the faster of the two.

So the honest expectation before the run is: **no expectation**. That is
exactly why a baseline is worth taking rather than a spot check —
without one, the first number anyone sees becomes the number everyone
quotes.

## What the run records

The suites emit one `NOWBASE` line per measurement. Grep them out:

```bash
swift test --package-path now-host --filter Metal68KPutTests 2>&1 | grep NOWBASE
```

Three kinds:

```
NOWBASE meta guest=now-68k version=0.19 os=7.1 port=5252 machine=192.0.2.180 repeats=3
NOWBASE rung dir=receive label=4_MB bytes=4194304 secs=11.70 rate_kbs=350 rep=1/3 result=ok reports=512 maxgap=8192 integrity=guest-crc32-confirmed stalled_at=-
NOWBASE control dir=send asked=28 unanswered=0 worst_s=0.10 idle_s=-
```

`meta` first, and it is the half that makes the rest quotable: which
build answered, on which port, against which machine. The 2026-07-25 run
produced real numbers that could not be attributed afterwards precisely
because nothing recorded the conditions beside them.

Field by field, and why each is there rather than derivable:

| Field | Why it is recorded |
|---|---|
| `version` | the only thing on the wire that tells two builds apart. |
| `machine` | from `NOW_METAL_MACHINE`; `unnamed` when the run did not say, which is itself worth knowing. |
| `rep=n/N` | which sample. See below. |
| `secs`, `rate_kbs` | the measurement. `rate_kbs` is derived in one place so the two directions cannot disagree about what a kilobyte is (1024). |
| `reports` | how many `file.progress` messages the guest sent. It is the sender's clock: too few and the host is running on its own send counter, which on a slow link is a lie by minutes. |
| `maxgap` | the largest jump between progress reports. A guest acking too coarsely for the host's window presents as a transfer stopping dead at exactly the window size (`docs/large-transfers.md`), and this is the number that would show it coming. |
| `integrity` | that the guest computed and compared a checksum, rather than the host believing its own count. |
| `stalled_at` | where a transfer that never finished stopped. `606208` was the whole of what the contended run left behind, and it lived in a transcript. |
| `unanswered`, `worst_s` | the control lane under bulk load — the one claim nothing off metal can check. |

## Three samples, not one

`NOW_METAL_REPEATS=3` on the 180c. It repeats **only the rungs at or
above 1 MB**: the small ones are correctness checks, where a byte either
side of a frame boundary is right or it is not, and running that three
times says the same thing three times.

The reason is specific to this machine rather than general good
practice. MacTCP on the 180c has been watched wedging silently, and a
transfer that shares the machine with anything else is a transfer whose
rate is somebody else's disk seek as much as its own. One sample cannot
tell a rate from an interruption. Three can: samples that agree are a
rate, and samples that disagree by 2× are a finding about the machine
that no average would have shown.

Each sample is its own `NOWBASE` line. **Do not average them into the
ledger** — record the spread, or the range, and say how many there were.

## The table to fill in

Copy this into `docs/open-issues.md` (or into the section the run
belongs to) once the run is done, replacing the emulator's numbers
rather than sitting beside them under a heading that does not say which
machine they came from.

```
### NOW-68K on the PowerBook 180c — <build>, <date>

Machine: 68030/33, 4 MB, System 7.1, 384 KB partition, MacTCP.
Harness: port <N>, NOW_METAL_MACHINE set, machine-busy guard passed.
Samples: N=<repeats> for rungs >= 1 MB.

| Rung | Receive | Send |
|---|---|---|
| 0, 1, boundary sizes |  |  |
| 64 KB |  |  |
| 256 KB |  |  |
| 1 MB (min/med/max) |  |  |
| 4 MB (min/med/max) |  |  |

Progress reports at 4 MB: <n>, largest gap <n> B.
Control lane during a 4 MB transfer: <asked> asked, <n> unanswered,
worst <n> s.
Integrity: <guest-crc32-confirmed / byte-identical> on every rung.

What this does NOT establish: <say it plainly>
```

## What a baseline still will not settle

Worth writing down before the run, so the run is not read as answering
more than it did:

- **The PackBits ratio and encode cost.** Unmeasured, and it is what
  decides whether screenshots are viable over MacTCP at all. A file
  transfer baseline says nothing about it — the framebuffer read is
  159 ms for a 300 KB frame and the compression is the unknown half.
- **Whether the receive rate holds with anything else running.** The
  suites run against a machine deliberately made quiet. That is the
  right way to take a baseline and the wrong way to predict a Tuesday.
- **The 384 KB partition under pressure.** A 4 MB transfer streams and
  needs no buffer, so it does not probe the partition; the ledger's note
  that this pass cost ~5% of it stands separately.
- **Anything about `g_sink`'s 256 bytes.** ~32 memcpy passes per 8 KB
  frame is a knob nobody has measured on this machine, and a baseline
  taken at the default does not measure it either — it just makes a
  later comparison possible.

## Related

- [68k-metal-runbook.md](68k-metal-runbook.md) — how to run the pass so
  the numbers can be attributed.
- [open-issues.md](open-issues.md) — the emulator results, and the
  contended run that made this document necessary.
