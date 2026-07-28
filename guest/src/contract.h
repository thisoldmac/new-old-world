#ifndef NOW_CONTRACT_H
#define NOW_CONTRACT_H

#include "wire_limits.h"

/* The frame format's numbers live once, in contract/wire_limits.h, and
   are spelled here in this guest's vocabulary. They used to be stated
   here in full and again in guest68k/src/frame.h, kept equal by hand. */
#define kNowContractRevision NOW_WIRE_CONTRACT_REVISION
#define kNowFrameHeaderBytes NOW_WIRE_FRAME_HEADER_BYTES
#define kNowChannelControl   NOW_WIRE_CHANNEL_CONTROL
#define kNowChannelBulk      NOW_WIRE_CHANNEL_BULK
#define kNowFlagEnd          NOW_WIRE_FLAG_END
#define kNowMaxPayload       NOW_WIRE_MAX_PAYLOAD

/* This guest's own defaults, not contract facts: a host answering on
   another port is not speaking a different protocol. */
#define kNowDefaultHostPort  5250
#define kNowDefaultChunk     8192

/* Control frames cap at 4 KB (contract/asyncapi.yaml). Stated here so
   the SENDER's limit and the RECEIVER's buffer are the same number:
   they were not, and a listing bigger than the receiver could hold read
   as a protocol error and took the connection down.

   Deliberately NOT moved into wire_limits.h. NOW-68K states the same
   number and describes it differently on purpose - as a buffer size that
   is explicitly not a wire-legality bound (guest68k/src/frame.h). The
   two agree on behaviour: an oversized control frame costs one message,
   not the connection. Merging the descriptions would erase a distinction
   someone worked out the hard way, so it stays stated twice with its
   reasoning until someone decides which one the contract means. */
#define kNowMaxControl       4096L

#endif
