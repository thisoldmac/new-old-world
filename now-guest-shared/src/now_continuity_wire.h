#ifndef NOW_CONTINUITY_WIRE_H
#define NOW_CONTINUITY_WIRE_H

#include "continuity_udp.h"

#ifdef NOW_CONTINUITY_HOST
#include <stdint.h>
typedef uint8_t NowCU8;
typedef uint16_t NowCU16;
typedef uint32_t NowCU32;
typedef int16_t NowCS16;
#else
#include <MacTypes.h>
typedef UInt8 NowCU8;
typedef UInt16 NowCU16;
typedef UInt32 NowCU32;
typedef SInt16 NowCS16;
#endif

typedef struct NowContinuityStatePacket {
    NowCU32 nonce_hi;
    NowCU32 nonce_lo;
    NowCU32 epoch;
    NowCU32 position_seq;
    NowCS16 h;
    NowCS16 v;
    NowCU32 button_generation;
    NowCU16 flags;
    NowCU16 requested_hz;
    NowCU32 host_stamp;
    NowCU32 previous_button_generation;
    NowCU16 previous_button_flags;
} NowContinuityStatePacket;

typedef struct NowContinuityAckPacket {
    NowCU32 nonce_hi;
    NowCU32 nonce_lo;
    NowCU32 epoch;
    NowCU32 position_seq;
    NowCU32 button_generation;
    NowCU32 arrival_ticks;
    NowCU32 apply_ticks;
    NowCU32 rejected_packets;
    NowCU16 state;
    NowCU16 accepted_hz;
    NowCU16 exit_reason;
} NowContinuityAckPacket;

enum {
    kNowContinuityWireOK = 0,
    kNowContinuityWireWrongSize = 1,
    kNowContinuityWireWrongMagic = 2,
    kNowContinuityWireWrongVersion = 3,
    kNowContinuityWireReservedBits = 4,
    kNowContinuityWireReservedField = 5,
    kNowContinuityWireBadState = 6,
    kNowContinuityWireBadExitReason = 7
};

int now_continuity_decode_state(const NowCU8 *bytes, NowCU32 length,
                                NowContinuityStatePacket *out);
void now_continuity_encode_state(const NowContinuityStatePacket *packet,
                                 NowCU8 out[NOW_CONTINUITY_STATE_BYTES]);
int now_continuity_decode_ack(const NowCU8 *bytes, NowCU32 length,
                              NowContinuityAckPacket *out);
void now_continuity_encode_ack(const NowContinuityAckPacket *packet,
                               NowCU8 out[NOW_CONTINUITY_ACK_BYTES]);

#endif
