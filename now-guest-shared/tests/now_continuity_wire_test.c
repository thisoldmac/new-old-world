#include <stdio.h>
#include <string.h>

#include "now_continuity_wire.h"

static int failures;

#define CHECK(value, message) do { \
    if (!(value)) { printf("FAIL: %s\n", message); failures++; } \
} while (0)

int main(void)
{
    NowContinuityStatePacket state;
    NowContinuityStatePacket decoded_state;
    NowContinuityAckPacket ack;
    NowContinuityAckPacket decoded_ack;
    NowCU8 state_bytes[NOW_CONTINUITY_STATE_BYTES];
    NowCU8 ack_bytes[NOW_CONTINUITY_ACK_BYTES];

    memset(&state, 0, sizeof(state));
    state.nonce_hi = 0x01234567UL;
    state.nonce_lo = 0x89ABCDEFUL;
    state.epoch = 0x10203040UL;
    state.position_seq = 7;
    state.h = -2;
    state.v = 342;
    state.button_generation = 3;
    state.flags = NOW_CONTINUITY_FLAG_INSIDE
        | NOW_CONTINUITY_FLAG_PRIMARY_DOWN;
    state.requested_hz = 30;
    state.host_stamp = 0x55667788UL;
    now_continuity_encode_state(&state, state_bytes);

    CHECK(state_bytes[0] == 'N' && state_bytes[1] == 'W'
          && state_bytes[2] == 'C' && state_bytes[3] == '1',
          "state magic is visible network order");
    CHECK(state_bytes[NOW_CONTINUITY_STATE_H_OFFSET] == 0xFF
          && state_bytes[NOW_CONTINUITY_STATE_H_OFFSET + 1] == 0xFE,
          "signed coordinate is encoded big endian");
    CHECK(now_continuity_decode_state(state_bytes, sizeof(state_bytes),
                                      &decoded_state)
              == kNowContinuityWireOK,
          "state vector decodes");
    CHECK(memcmp(&state, &decoded_state, sizeof(state)) == 0,
          "state vector round trips");

    state_bytes[NOW_CONTINUITY_STATE_RESERVED_OFFSET + 1] = 1;
    CHECK(now_continuity_decode_state(state_bytes, sizeof(state_bytes),
                                      &decoded_state)
              == kNowContinuityWireReservedField,
          "reserved state field is rejected");
    state_bytes[NOW_CONTINUITY_STATE_RESERVED_OFFSET + 1] = 0;
    CHECK(now_continuity_decode_state(state_bytes,
                                      sizeof(state_bytes) - 1,
                                      &decoded_state)
              == kNowContinuityWireWrongSize,
          "state packets are fixed size");

    memset(&ack, 0, sizeof(ack));
    ack.nonce_hi = state.nonce_hi;
    ack.nonce_lo = state.nonce_lo;
    ack.epoch = state.epoch;
    ack.position_seq = state.position_seq;
    ack.button_generation = state.button_generation;
    ack.arrival_ticks = 100;
    ack.apply_ticks = 102;
    ack.rejected_packets = 9;
    ack.state = NOW_CONTINUITY_ACK_ACTIVE;
    ack.accepted_hz = 30;
    ack.exit_reason = NOW_CONTINUITY_EXIT_GUEST_INPUT;
    now_continuity_encode_ack(&ack, ack_bytes);
    CHECK(now_continuity_decode_ack(ack_bytes, sizeof(ack_bytes), &decoded_ack)
              == kNowContinuityWireOK,
          "ack vector decodes");
    CHECK(memcmp(&ack, &decoded_ack, sizeof(ack)) == 0,
          "ack vector round trips");

    ack_bytes[NOW_CONTINUITY_ACK_STATE_OFFSET + 1] = 9;
    CHECK(now_continuity_decode_ack(ack_bytes, sizeof(ack_bytes), &decoded_ack)
              == kNowContinuityWireBadState,
          "unknown ack state is rejected");

    if (failures != 0)
        return 1;
    puts("now_continuity_wire_test: ok");
    return 0;
}
