/* The frame format's numbers, stated once.
 *
 * These are contract facts: they mean the same thing on every side, and
 * a side that disagrees about one of them is not speaking the protocol.
 * They lived in three places - now-guest-ppc/src/core/contract.h, now-guest-68k/src/core/frame.h
 * and now-host/Sources/Host/FrameCodec.swift - and frame.h's own comment
 * recorded that a human had "cross-checked" the other two by hand.
 *
 * AGENTS.md names that arrangement as the failure this project has paid
 * most for: "The control-frame cap lived in prose, in the sender, and as
 * a different number in the receiver's buffer; nothing was wrong until a
 * message grew past the smallest of the three." Hand-cross-checking is
 * how three copies stay equal right up until the once they do not.
 *
 * Each guest still spells these in its own dialect - kNowMaxPayload,
 * NOW68K_MAX_PAYLOAD - because a caller should read its own module's
 * vocabulary. The names are now aliases of these, so there is one number
 * and several spellings of it, rather than several numbers.
 *
 * The Swift side cannot include a C header without restructuring its
 * build, so FrameCodecTests asserts its constants against THIS file,
 * parsed - the same technique GuestWireConformanceTests already uses to
 * read the guests' sources. A third copy that is checked is not a third
 * source of truth.
 *
 * WHAT IS DELIBERATELY NOT HERE: the 4096-byte control cap. Both guests
 * define it and both arrive at the same behaviour, but they describe it
 * differently on purpose - the PowerPC guest as a cap the sender and the
 * receiver's buffer must agree on, NOW-68K as a buffer size that is
 * explicitly NOT a wire-legality bound (frame.h is emphatic, and right:
 * an oversized control frame costs one message, not the connection).
 * Merging them would erase a distinction someone worked out the hard
 * way. It stays stated twice, with the reasoning, until someone decides
 * which description is the contract's.
 */
#ifndef NOW_CONTRACT_WIRE_LIMITS_H
#define NOW_CONTRACT_WIRE_LIMITS_H

/* contract/asyncapi.yaml, info.x-contract-revision. This gates the hello
   handshake: unequal revisions refuse, so a stale copy of this number on
   one side is a guest that cannot connect and cannot say why. */
#define NOW_WIRE_CONTRACT_REVISION 1

/* Frame header, big-endian, 8 bytes:
     offset  size  field     meaning
     0       u8    channel   0 = control, 1 = bulk
     1       u8    flags     bit0 END: last frame of this transfer
     2       u16   transfer  bulk correlation id; 0 on control frames
     4       u32   length    payload bytes that follow

   Both guests build these bytes explicitly rather than overlaying a
   struct. The 68K and PowerPC are both big-endian, so an overlay would
   happen to work on the targets and fail on the little-endian host test
   build - "happens to work on one side" being the bug this project keeps
   shipping. */
#define NOW_WIRE_FRAME_HEADER_BYTES 8
#define NOW_WIRE_CHANNEL_CONTROL    0
#define NOW_WIRE_CHANNEL_BULK       1
#define NOW_WIRE_FLAG_END           0x01

/* Max payload bytes of ANY frame, control or bulk - the one bound the
   contract states normatively. Over this is a PROTOCOL VIOLATION on
   either channel: the sender broke the wire format, and nothing after it
   can be trusted. */
#define NOW_WIRE_MAX_PAYLOAD        32768L

#endif /* NOW_CONTRACT_WIRE_LIMITS_H */
