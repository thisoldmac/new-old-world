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
the wire. The sender now treats it as an acknowledgement and runs no
more than `outboundWindowBytes` (192 KB, six progress steps) ahead of
it, parking at a frame boundary when it would exceed that and resuming
when a report lands. `received` is cumulative, so a dropped progress
report — which the contract permits — costs nothing: the next one
reopens the window whatever was skipped.

The window engages only after the guest has reported at least once, so a
guest that never sends `file.progress` keeps exactly its old behaviour
rather than deadlocking against a peer that cannot clock it.

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
