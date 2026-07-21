# Large transfers — diagnosis and the survivability work

A 12 MB push to the PowerBook 1400c ran at ~250 KB/s to about 1.7 MB,
slowed to a crawl, and died. Files up to 256 KB had always been fine.
This is the record of what that actually was, measured rather than
reasoned about, and what was built in response.

All measurements below are against **`now-guest-2` on the real
PowerBook 1400c** (10.91.5.47, port 5251, OS 9.1, 56 MB, CarbonLib 1.6)
unless a line says otherwise. Host tests that need no hardware are
marked "local".

## What it is not

Three theories were tested and killed before the mechanism was found.
They are recorded because each is plausible enough to be re-proposed.

- **Not the guest's disk.** After a failed 4 MB put the guest's own
  counters read `In FSWrite=721 ms` over 57 writes — 12.6 ms per 32 KB
  batch, the same per-write cost as a healthy transfer. The transfer had
  been running for 103 seconds. The disk was busy for 0.7% of it.
- **Not the guest's event loop, and not control starvation.** `gestalt`
  round-trips in 0.10 s while a 256 KB put is in flight, against 0.05–0.11 s
  idle. After every failed transfer the guest answered `gestalt`,
  `putstat` and `file.list` normally. The guest is not wedged; it is
  waiting for bytes that are not arriving.
- **Not a fixed buffer or a size ceiling.** Nothing in the receive path
  grows with bytes received: `next_frame` streams bulk without buffering
  a frame whole, its `memmove`s are bounded by the 4608-byte receive
  buffer, and `take_bulk_in` allocates nothing.

`Rcv window` in `putstat` is **not evidence of anything** — `g_rcv_window`
(wire.c) is initialised to its "not attempted" sentinel of `-3` and never
assigned. It reads `-3` on a healthy transfer and on a dead one.

## The failure, measured

A size ladder, each rung a fresh put into the share root, sampling the
guest's own reported received count every 500 ms:

| Size | Offered 1448 B / 3 ms | Offered 1448 B / 5 ms |
|---|---|---|
| 512 KB | ok, 1.5 s, 338 KB/s | ok, 2.2 s, 229 KB/s |
| 1 MB | ok, 3.0 s, 346 KB/s | ok, 4.4 s, 231 KB/s |
| 2 MB | **collapsed** at 522 KB / 2.0 s | **collapsed** at 372 KB / 2.0 s |
| 4 MB | **collapsed** at 1.34 MB / 4.0 s | **collapsed** |

The collapse is not a stop. It is a change of regime, and the regime it
changes into is extremely regular:

```
     2.0s     522328    +70288    130.2 KB/s
     7.2s     522328        +0      0.0 KB/s
     8.2s     556380    +34052     65.8 KB/s
    13.3s     556380        +0      0.0 KB/s
    15.4s     589824    +33444     62.0 KB/s
    20.5s     589824        +0      0.0 KB/s
    22.6s     622592    +32768     60.9 KB/s
```

One 32 KB batch every ~6.5–7.0 seconds, indefinitely, until something
times out. That is **4.8 KB/s** — the same number as the unpaced
inbound case in the pacing finding (4.7 KB/s, 48% of segments
retransmitted at a 311 ms RTO). The collapsed state is the *pre-pacing*
state: the metering is still in the code and no longer on the wire.

Two further facts constrain the mechanism:

- It reproduces at **both** offered rates, including one comfortably
  below the ~340 KB/s the link demonstrably sustains. So it is not
  simply "the host offers more than the wire carries".
- 512 KB and 1 MB **never** collapse; 2 MB and 4 MB **always** do, at
  both rates. The split is by the size of the transfer, not by elapsed
  time (1 MB runs for 4.4 s at the slower rate and is fine) and not by
  the byte at which it happens (which varies).

## What the guest's own counters say (2026-07-20, `now-chip`)

The instrumented guest answers the question the earlier rounds could
only guess at. Two 2 MB puts, the second with a ping running alongside:

| | |
|---|---|
| Outcome | **completed**, ~300 s, both runs |
| `Loop passes` across one transfer | 1,146,015 → 1,998,160 = **852,145** (~2,870/s) |
| `In receive` | **976 ms** of 297,000 ms — 0.3% |
| `Rcv backlog` | 178 → 1,611 bytes; never accumulates |

**The guest is starved, not overloaded.** Its event loop spins fast, its
endpoint holds nothing, and its receive path is idle 99.7% of the time.
Whatever throttles the transfer is upwind of the guest.

### It is not the link

Measured during and immediately after the transfers:

- ping, 64 B: 355 replies, **0 timeouts**, median 4.0 ms, flat ~5 ms
  across every 30 s bucket of a 297 s transfer.
- ping, **1400 B and 1472 B** (full MTU, unfragmented): 0% loss. Size
  alone is not being dropped.
- **FTP: 195 KB in 2.56 s = 76 KB/s** pulled from the machine, and
  195 KB pushed INTO it in 2.2 s = 89 KB/s — the same direction as the
  failing transfer, over the same link, minutes apart.

A link that carries 89 KB/s for Rumpus while NOW gets 3.5 KB/s is not
the explanation. (Caveat kept honestly: ping at 3 packets/s does not
test the burst spacing the pacing finding is actually about. The FTP
number is the load-bearing one.)

### A window of 192 KB changes nothing — and that reading was wrong

Same transfer with `NOW_WINDOW=0` (window entirely off): **329 s**,
against 297 s with a 192 KB window.

This was read at the time as "bounding the sender is not the answer",
and the search moved on. **That inference was wrong**, and it is left
here rather than deleted because it is the most expensive mistake in
this document. A window that changes nothing is equally consistent with
"bounding the sender does not help" and with "this window never bound",
and nothing had been measured that could tell those apart. The send
trace below shows it was the second: the sender reached 1.66 MB
unthrottled with the window supposedly at 192 KB. At 64 KB the same
mechanism cuts the transfer from ~300 s to 62 s.

The rule worth keeping: a negative result from a control you have not
verified is *engaged* is not a negative result.

### The shape, restated

Every run agrees: ~340 KB/s for roughly the first megabyte, then ~4 KB/s
for the remainder. What changed tonight is that it now **finishes**
rather than dying — see below.

## Mechanism

The pacing rule in `docs/architecture.md` is precise about why the gap
works: *"Writing a piece and pausing leaves the send buffer empty, so
TCP has nothing to fire when the next ACK arrives."* The gap is only on
the wire while the sending kernel's socket buffer is **empty**. Once a
backlog exists in that buffer, TCP transmits from it on every ACK,
back-to-back, at whatever rate the window allows — and the application's
polite 3 ms pauses become invisible. The card starts dropping, the
retransmit spiral starts, and because the spiral itself keeps the buffer
backlogged, **it never recovers**.

What the host had was an outbound path with no bound at all on how far
ahead of the receiver it could run: `sendNextOutboundChunk` sent the
next 32 KB frame as soon as the local socket accepted the previous one.
Any transient dip in delivered rate — a disk hiccup, a retransmit, a
background process on a cooperatively-multitasked machine — puts bytes
into the buffer, and nothing ever takes them out again. It is a ratchet:
a short transfer can dodge every dip, a long one cannot.

This is the same mistake the architecture document already warns about
in a different place ("Only the receiver knows what arrived"), applied
to flow control rather than to progress reporting.

## The fix: clock the sender on the receiver

`file.progress` already carries the guest's own count of bytes taken off
the wire. The sender treats it as an acknowledgement and runs no more
than `outboundWindowBytes` ahead of it, parking at a frame boundary when
it would exceed that and resuming when a report lands. `received` is
cumulative, so a dropped progress report — which the contract permits —
costs nothing: the next one reopens the window whatever was skipped.

The window engages only after the guest has reported at least once, so a
guest that never sends `file.progress` keeps exactly its old behaviour
rather than deadlocking against a peer that cannot clock it.

**The window must be at least twice the guest's progress step**, which
is why the shipped default is not as tight as the mechanism wants. See
the deadlock at 12 KB below: acknowledgement granularity is a hard floor
under any flow control built on top of it. Loosening that floor is the
proposed next change, not a tuning exercise.

## The second bug, found while reading: control spliced into bulk

Not the cause of the above, and worth fixing regardless.

The guest's decoder gives bulk absolute priority: while
`bulk_remaining > 0`, every byte it reads is file data, unexamined
(`next_frame`, wire.c). A control frame that arrives in the middle of a
bulk frame is therefore written into the file, and the stream is
desynced by the whole length of that frame — the next 8 bytes the guest
reads as a header are file content.

The guest refuses to do this to the host: `bulk_frame_partially_sent`
(wire.c) holds its control queue until the frame in flight is whole. The
host had no mirror. Metering splits one 32 KB frame across 23 separate
sends with 3 ms gaps, and any control message — a pong, a cancel, a
`putstat` — enqueued during one of those gaps lands between two pieces.

The host now holds control frames while a bulk frame is partially sent
and drains them at the frame boundary, each still getting the pacing
gap. Cost: at most one frame of latency, ~70 ms. That is also what makes
control *responsive* during bulk without a second connection — the
guest dials out precisely so that no classic-side listener ever exists,
so a second connection was never available as an answer.

## Resume

See `contract/asyncapi.yaml` for the normative form. The shape:

- **Identity before offset.** An offer carries a `resumeToken` naming
  the source file. The receiver stores it beside the partial and will
  report `have > 0` only for a partial recorded under that exact token.
  No token, or an unrecognised one, starts at zero. Resuming onto a
  different file silently is worse than starting over, so the protocol
  has no way to express it.
- **The receiver says how much it holds** (`file.accept.have`), because
  it is the only party that knows. The sender then sends
  `file.begin.offset`.
- **`bytes` stays the size of the whole file** on a resumed transfer, so
  progress means the same thing to a human either way.
- **`file.end.crc32`** over the whole file. Optional, and a receiver
  must read its absence as "unchecked", never as "correct". It matters
  most exactly here: a resumed file is stitched from two sessions and
  nothing else checks the seam.

## The host's own writes name the mechanism

`NOW_SEND_TRACE=1` times how long each metered write takes the socket to
**accept**, bucketed by how far into the file it was. One 2 MB put:

| Bytes into file | Writes | Median | p90 | Max |
|---|---|---|---|---|
| 0 – 1536 KB | 92 each | **0.1 ms** | 0.1 | ≤0.6 |
| 1664 KB | 92 | 0.1 ms | 16.8 | **664.5** |
| 1792 KB | 92 | **386.8 ms** | 779.8 | 797.3 |
| 1920 KB | 92 | 386.6 ms | 774.2 | 790.5 |
| 2048 KB | 23 | 387.2 ms | 772.3 | 791.9 |

1448 bytes per 387 ms is **3.7 KB/s** — exactly the collapsed rate. The
host is not idle, it is **blocked**: the socket stops accepting. The knee
is visible in one bucket.

So the mechanism is the one this document originally proposed and then
wrongly discarded. The host offers 482 KB/s (1448 B / 3 ms) into a wire
that drains near 300; the surplus accumulates in the kernel send buffer
until it is full at ~1.66 MB; from that moment the buffer is never empty,
so TCP transmits from the backlog back-to-back on every ACK, the pacing
gap exists in the code but **not on the wire**, and the card's
burst-drop behaviour takes it to the unpaced rate. It does not recover
because the spiral keeps the buffer full.

It was discarded because a 192 KB window did not fix it. That was a bug
in the window, not a refutation of the mechanism — the trace shows the
sender reaching 1.66 MB unthrottled, so the window never bound.

### Bounding in-flight bytes works, and how tight it can be is capped

Same 2 MB put, same machine, varying only `NOW_WINDOW`:

| Window | Result |
|---|---|
| 192 KB | ~300 s; backpressure from 1.66 MB |
| **64 KB** | **61.8 s**; send trace flat at 0.1 ms — backpressure never occurs |
| 12 KB (TBT's cap) | **deadlock** at 32768 bytes |

64 KB holds 335 KB/s for the first 1.44 MB and never fills the buffer,
which is a 5x improvement and confirms the mechanism. It still decays
later, so a bound alone is necessary and not sufficient.

**The deadlock is the useful result.** The host parks once
`sent - acked` reaches the window; the guest emits `file.progress` only
every 32 KB *past its previous report* (`kPutProgressStep`, wire.c). With
a 12 KB window the host parks after one 32 KB frame and waits for a
report the guest will only send after receiving 34208 bytes it is never
going to be sent. **A window smaller than the progress step cannot
work.** Acknowledgement granularity sets a hard floor on flow control.

That is exactly why TBT can do what NOW cannot: its host caps
un-acknowledged application bytes at **12 KiB** and blocks for a reply
between chunks (`mcp-classic/timbottu_mcp_classic/harness.py`), but it
acknowledges *every chunk* in a request/response protocol rather than
every 32 KB. Its measured result on this same PowerBook is ~300 KiB/s
sustained across a full MiB, host→guest, **with no host-side pacing at
all**.

### Two corrections to received wisdom, from the TBT corpus

- **The 1448 B rule is a GUEST-transmit fix, applied here to the wrong
  direction.** In TBT, 1448 bytes with a 1 ms gate bounds a single
  `OTSnd` *within one response*, guest→host. Its host writes whole
  ~5.6 KB lines unpaced. NOW inserts a gap *between* application writes,
  which is not the same intervention.
- **`XTI_SNDBUF` and `TCP_NODELAY` on the guest endpoint are measured
  no-ops on this exact hardware** (`data/findings/pb-farallon-send-cliff.md`).
  Nobody should spend time there.

Also worth recording: the entire PB1400c evidence base in the TimBotTu
corpus tops out at **1 MiB** per transfer. Every confirmation run ends
at 2.5–3.6 s. NOW's transfers are still healthy at the moment every
prior measurement stops — this collapse sits precisely in the corpus's
blind spot, which is why nothing there describes it.

## The fix that worked (2026-07-20, `now-chip` build 21:16:50)

Three coordinated changes, no contract change — `kNowMaxPayload` is a
ceiling so smaller frames were always legal, and `file.progress` is
advisory so reporting more often is too:

| Where | Change |
|---|---|
| Host | file bulk frames 32 KB → **8 KB** (`outboundFrameBytes`) |
| Guest | `kPutProgressStep` 32 KB → **8 KB** — one ack per frame |
| Host | `outboundWindowBytes` → **24 KB** (3 frames) |

This is the geometry TimBotTu measured at ~300 KiB/s sustained on this
same PowerBook (4 KB chunks under a 12 KiB in-flight cap), not a number
chosen for being small. Measured here:

| Size | Before | After |
|---|---|---|
| 512 KB | 1.5 s | 1.5 s — 336 KB/s |
| 1 MB | 3.0 s | 3.3 s — 314 KB/s |
| 2 MB | failed, or ~300 s | **6.1 s** — 336 KB/s |
| 4 MB | never completed | **11.9 s** — 345 KB/s |
| **12 MB** (the original failure) | died at ~1.7 MB | **41.9 s** — 293 KB/s |

`Rcv peak` sits at 24658 on every run — the bound binding exactly.
Guest counters on the 12 MB run: `Bytes=12582912` exactly, `Writes=384`,
`In FSWrite=5203 ms`. **Byte integrity re-verified at the new geometry**
(`testAPutFileComesBackByteIdentical`, 200000 bytes identical on a
round trip) — a frame-size change is precisely the kind that corrupts
while every counter still looks right.

### Not a clean sweep: one 12 MB run degraded

Before the successful run above, a 12 MB attempt reached only 3.1 MB in
599 s, moving one 8 KB frame per ~2 s, with the same starved-guest
signature (loop spinning, `In FSWrite` healthy, backlog ~2 KB). The very
next 12 MB run completed in 41.9 s.

So the residual fault is **intermittent, not a size threshold** — which
is a different and harder claim than the one this document could make an
hour earlier. Whether that run met the second mechanism (RTO inflation
over a connection's life, per the TimBotTu corpus) or simply the wireless
link this machine dropped twice tonight is **not established**. It wants
repeated 12 MB runs with a packet capture, and nobody has taken one.
Do not read the table above as "solved" — read it as "the size-keyed
collapse is gone, and something rarer is not".

## Where this got to, and what is still open

**A 2 MB put now completes.** It failed or wedged every time before, and
it has since succeeded twice, ~300 s each. The most likely reason is the
control-splicing fix: with control frames no longer landing inside bulk
frames, the stream stays coherent instead of desyncing, so a slow
transfer stays a slow transfer rather than becoming a dead one. That is
survivability, which was the point — but it is inference from a
before/after, not a proven causal chain, and it should be labelled that
way until someone reproduces the desync deliberately.

**The collapse is explained** (see "The host's own writes name the
mechanism"): the sender fills the kernel send buffer, the pacing gap
stops reaching the wire, and the card's burst-drop takes it to the
unpaced rate. Bounding in-flight bytes to 64 KB cuts a 2 MB put from
~300 s to 61.8 s and keeps the socket accepting throughout.

**What is not yet established** is the residual decay *inside* the
bounded case: at a 64 KB window the transfer still holds 335 KB/s only
for the first ~1.44 MB before falling away, having never filled the
buffer. So the buffer is one mechanism and probably not the only one.
The RTO-inflation shape recorded in the TimBotTu corpus — repeated
losses raising the retransmit timer over the life of one connection, so
each subsequent recovery costs more — is the leading candidate and is
untested here. Confirming it wants a packet capture, which needs root
and did not happen.

**Host→guest control is starved during bulk, and that may be self
inflicted.** `putstat` went unanswered for 25 s repeatedly while
`file.progress` (guest→host, the opposite direction) flowed fine
throughout. The asymmetry points at the new control queue holding
host→guest frames: at 4 KB/s a 32 KB frame occupies ~8 s, so the drain
window between frames is narrow. Correctness is not in question — the
splice it prevents is real — but the latency budget claimed for it
("~70 ms, one frame") only holds at full speed, and during a collapse it
is seconds. That belongs in the fix, not just in a comment.

## corpus_impact

`corpus_impact: pending` — this belongs in the TimBotTu corpus as a
finding (working slug `now-large-transfer-pacing-collapse`), because
"large transfers collapse to the pre-pacing rate and do not recover" is a
durable fact about this stack and a direct extension of the existing
inbound-pacing finding: it establishes that the 1448 B / 3 ms rule is
necessary but **not sufficient**, and that the missing half is a bound on
how far the sender may run ahead of the receiver.

It is not written here because `data/findings/` lives in the parent
TimBotTu repository, whose checkout is shared with other sessions; this
branch is in the NOW subrepo. The row wants authoring from a TimBotTu
worktree, citing this document as its `doc_ref`.

### The orphan sweep has to change first

`now_files_receive_begin` currently calls `sweep_orphan_temps`, which
deletes **every** `NOW incoming …` file in the destination folder before
each transfer. That is correct while partials are worthless debris and
fatal the moment they are the resume data. Resume requires the temp name
to encode the resume token rather than a tick count, and the sweep to
spare anything recent enough to still be resumable.
