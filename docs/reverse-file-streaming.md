# Reverse file streaming — diagnosis and handoff

## Outcome

The unsafe memory growth was not in the wire. Bulk frames were already
bounded to 32 KiB. It was in both adapters around the wire:

- the guest built the complete data-fork or MacBinary artifact in a
  `TempNewHandle` before the first frame;
- the host appended every received frame to `fileBuffer`, then created
  another complete `Data` while converting or writing it.

That made guest-to-host transfer capacity a function of the classic
application partition and host heap rather than disk capacity.

The prototype replaces those adapters without changing the framing or
message revision. The guest records fork metadata at offer time, checks
it again after acceptance, opens the forks, and fills one outbound frame
at a time. MacBinary is generated sequentially as header, data fork,
padding, resource fork, padding. A running CRC covers those exact wire
bytes. The host preflights destination free space, reserves a
same-folder temporary file, appends frames directly, computes the same
CRC, reports receiver progress, and atomically finalizes only after byte
count and optional checksum pass. Classic text conversion is also
streamed; MacRoman is single-byte and one bit of state carries a CRLF
pair across chunk boundaries.

## Ownership and failure behavior

The active guest transfer owns its open fork refs and one frame buffer.
Cleanup closes both on success, cancellation, read failure, connection
loss, or inactivity. Metadata is checked before open and again at end;
a changed source produces `file.end ok:false`.

The host sink owns its file handle and hidden `.part` until it hands a
completed staged file to the consumer. The staged object deletes an
unconsumed file on destruction. Truncation, overrun, checksum mismatch,
write failure, cancellation, and disconnect close and delete it. Binary
downloads in the destination folder finalize by rename; conversion uses
a second same-folder temporary and rename so the visible destination is
never partial.

The guest's two-minute transfer deadline is now an inactivity deadline:
each successful socket write resets it. It no longer becomes an
accidental ~27 MB size cap at the measured link rate.

Receiver progress is reported at bounded 32 KiB intervals plus the final
count, rather than once per small frame. The host records total transfer
time for an average byte rate, and both sides use traffic-reset
inactivity deadlines so “slow” and “stalled” remain different states.

## Compatibility

No protocol revision or capability negotiation is required for this
slice:

- frame sizes and `file.begin`/bulk/`file.end` ordering are unchanged;
- `file.end.crc32` is optional and old Swift decoders ignore the extra
  JSON field;
- `file.progress` was already a contract message, and old guests ignore
  unknown post-handshake control messages;
- a new host accepts an old guest with no checksum or progress, treating
  absence as unchecked/legacy rather than failure.

Compatibility fixtures decode the guest's new CRC-bearing `file.end`,
and wire tests cover a pull with and without the checksum plus receiver
progress. The contract description now states the message symmetrically.

## Resume decision

Fresh transfers and interruption cleanup are safe. Reverse resume is not
implemented because the deployed sequence has no guest-issued source
identity before the host requests an offset. Retaining a partial by path,
size, or modification date would risk stitching two different sources.

The compatible follow-up is additive:

1. On a zero-offset `file.get`, the guest includes an opaque source token
   in `file.begin`; the host stores it beside the partial.
2. A retry sends `offset` and that `resumeToken`; old guests ignore the
   fields or refuse the unsupported offset, after which the host retries
   from zero.
3. The guest validates the token against the current source, re-reads the
   prefix to seed its running CRC, seeks the fork sequence to the offset,
   and sends `file.begin.offset`.
4. The host keeps partials only when a token exists and accepts the final
   file only after whole-stream CRC verification.

Choosing the token is a product/performance decision: a content CRC
requires a full prepass before transfer, while a metadata identity is
cheap but weaker. That decision should not be hidden inside this patch.

## Verification

- Host full suite: 292 tests passed, 13 opt-in metal tests skipped,
  0 failures.
- Focused reverse-path tests: increasing 256 KiB, 2 MiB, and 16 MiB
  payloads retained a 32 KiB maximum append; checksum mismatch,
  truncation, overrun, explicit abort, and pull cancellation removed the
  partial.
- File materialization: binary rename and streaming MacRoman/line-ending
  conversion passed, including CRLF split exactly at 64 KiB.
- Guest: Retro68 PowerPC Carbon build passed with both guest-initiated
  send and host-requested pull routed through the streaming source.

The bounded reverse path is also **metal-verified** on the PowerBook
1400c (2026-07-24). A separately named `NOW RS 695d02b` guest used
compile-time defaults and port 5252, leaving the canonical guest's
preferences untouched. The boot volume reported 2047 MB free and the
test guest's process partition remained 6506 KB before and after the
run.

The observed data-fork ladder was 32767, 32768, 32769, 256 KiB, 1 MiB,
and 4 MiB. Every destination matched the generated bytes and an
independently computed CRC-32. The largest pull completed in 11.70
seconds; host RSS grew by 2.23 MiB and live malloc bytes by 1.94 MiB.
These rates are observations, not transfer-rate hardening or a throughput
claim.

The same run also passed streaming MacRoman/CR to UTF-8/LF conversion,
and an explicit MacBinary pull whose header CRC, data fork, and resource
fork were checked independently. Cancelling a 4 MiB pull after at least
64 KiB removed the host partial and the same session immediately
answered `gestalt`.

Metal exposed two host lifetime problems that automated payload tests
had missed. Removing every decoded frame from the front of a `Data`
retained consumed storage; cursor parsing with one compaction per network
read reduced the 4 MiB live-heap delta from 6.82 MiB to 1.94 MiB.
Successful text conversion also retained its staged source until the
delivery object died; conversion now consumes it immediately.

This is deliberately bounded evidence. The metal ladder stopped at
4 MiB, did not include a transfer longer than two minutes or a source
mutation, and process-partition equality is not a measurement of the
guest's free heap. Reverse resume was not exercised because it does not
exist.

## Integration recommendation

Hand the isolated reverse-streaming commits to the V0.5 branch and
re-run its host suite and Retro68 build after rebasing. Keep reverse
resume as a separate contract-first change after selecting the source
identity rule. No MCP command or filesystem policy work needs to depend
on that later decision: V0.5 can use fresh bounded transfers now.
