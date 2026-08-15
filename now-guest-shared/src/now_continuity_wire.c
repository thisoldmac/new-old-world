#include "now_continuity_wire.h"

static NowCU16 read_u16(const NowCU8 *p)
{
    return (NowCU16)(((NowCU16)p[0] << 8) | (NowCU16)p[1]);
}

static NowCU32 read_u32(const NowCU8 *p)
{
    return ((NowCU32)p[0] << 24) | ((NowCU32)p[1] << 16)
        | ((NowCU32)p[2] << 8) | (NowCU32)p[3];
}

static void write_u16(NowCU8 *p, NowCU16 value)
{
    p[0] = (NowCU8)(value >> 8);
    p[1] = (NowCU8)value;
}

static void write_u32(NowCU8 *p, NowCU32 value)
{
    p[0] = (NowCU8)(value >> 24);
    p[1] = (NowCU8)(value >> 16);
    p[2] = (NowCU8)(value >> 8);
    p[3] = (NowCU8)value;
}

int now_continuity_decode_state(const NowCU8 *bytes, NowCU32 length,
                                NowContinuityStatePacket *out)
{
    NowCU16 flags;

    if (length != NOW_CONTINUITY_STATE_BYTES)
        return kNowContinuityWireWrongSize;
    if (read_u32(bytes + NOW_CONTINUITY_STATE_MAGIC_OFFSET)
            != NOW_CONTINUITY_STATE_MAGIC)
        return kNowContinuityWireWrongMagic;
    if (read_u16(bytes + NOW_CONTINUITY_STATE_VERSION_OFFSET)
            != NOW_CONTINUITY_VERSION)
        return kNowContinuityWireWrongVersion;
    flags = read_u16(bytes + NOW_CONTINUITY_STATE_FLAGS_OFFSET);
    if ((flags & ~NOW_CONTINUITY_KNOWN_FLAGS) != 0)
        return kNowContinuityWireReservedBits;
    if (read_u16(bytes + NOW_CONTINUITY_STATE_RESERVED_OFFSET) != 0)
        return kNowContinuityWireReservedField;
    if ((read_u16(bytes + NOW_CONTINUITY_STATE_PREVIOUS_BUTTON_FLAGS_OFFSET)
            & ~NOW_CONTINUITY_PREVIOUS_BUTTON_KNOWN_FLAGS) != 0)
        return kNowContinuityWireReservedBits;
    if (read_u16(bytes + NOW_CONTINUITY_STATE_TAIL_RESERVED_OFFSET) != 0)
        return kNowContinuityWireReservedField;

    out->flags = flags;
    out->nonce_hi = read_u32(bytes + NOW_CONTINUITY_STATE_NONCE_HI_OFFSET);
    out->nonce_lo = read_u32(bytes + NOW_CONTINUITY_STATE_NONCE_LO_OFFSET);
    out->epoch = read_u32(bytes + NOW_CONTINUITY_STATE_EPOCH_OFFSET);
    out->position_seq =
        read_u32(bytes + NOW_CONTINUITY_STATE_POSITION_SEQ_OFFSET);
    out->h = (NowCS16)read_u16(bytes + NOW_CONTINUITY_STATE_H_OFFSET);
    out->v = (NowCS16)read_u16(bytes + NOW_CONTINUITY_STATE_V_OFFSET);
    out->button_generation =
        read_u32(bytes + NOW_CONTINUITY_STATE_BUTTON_GENERATION_OFFSET);
    out->requested_hz =
        read_u16(bytes + NOW_CONTINUITY_STATE_REQUESTED_HZ_OFFSET);
    out->host_stamp =
        read_u32(bytes + NOW_CONTINUITY_STATE_HOST_STAMP_OFFSET);
    out->previous_button_generation = read_u32(
        bytes + NOW_CONTINUITY_STATE_PREVIOUS_BUTTON_GENERATION_OFFSET);
    out->previous_button_flags = read_u16(
        bytes + NOW_CONTINUITY_STATE_PREVIOUS_BUTTON_FLAGS_OFFSET);
    return kNowContinuityWireOK;
}

void now_continuity_encode_state(const NowContinuityStatePacket *packet,
                                 NowCU8 out[NOW_CONTINUITY_STATE_BYTES])
{
    write_u32(out + NOW_CONTINUITY_STATE_MAGIC_OFFSET,
              NOW_CONTINUITY_STATE_MAGIC);
    write_u16(out + NOW_CONTINUITY_STATE_VERSION_OFFSET,
              NOW_CONTINUITY_VERSION);
    write_u16(out + NOW_CONTINUITY_STATE_FLAGS_OFFSET, packet->flags);
    write_u32(out + NOW_CONTINUITY_STATE_NONCE_HI_OFFSET, packet->nonce_hi);
    write_u32(out + NOW_CONTINUITY_STATE_NONCE_LO_OFFSET, packet->nonce_lo);
    write_u32(out + NOW_CONTINUITY_STATE_EPOCH_OFFSET, packet->epoch);
    write_u32(out + NOW_CONTINUITY_STATE_POSITION_SEQ_OFFSET,
              packet->position_seq);
    write_u16(out + NOW_CONTINUITY_STATE_H_OFFSET, (NowCU16)packet->h);
    write_u16(out + NOW_CONTINUITY_STATE_V_OFFSET, (NowCU16)packet->v);
    write_u32(out + NOW_CONTINUITY_STATE_BUTTON_GENERATION_OFFSET,
              packet->button_generation);
    write_u16(out + NOW_CONTINUITY_STATE_REQUESTED_HZ_OFFSET,
              packet->requested_hz);
    write_u16(out + NOW_CONTINUITY_STATE_RESERVED_OFFSET, 0);
    write_u32(out + NOW_CONTINUITY_STATE_HOST_STAMP_OFFSET,
              packet->host_stamp);
    write_u32(out + NOW_CONTINUITY_STATE_PREVIOUS_BUTTON_GENERATION_OFFSET,
              packet->previous_button_generation);
    write_u16(out + NOW_CONTINUITY_STATE_PREVIOUS_BUTTON_FLAGS_OFFSET,
              packet->previous_button_flags);
    write_u16(out + NOW_CONTINUITY_STATE_TAIL_RESERVED_OFFSET, 0);
}

int now_continuity_decode_ack(const NowCU8 *bytes, NowCU32 length,
                              NowContinuityAckPacket *out)
{
    NowCU16 state;
    NowCU16 exit_reason;

    if (length != NOW_CONTINUITY_ACK_BYTES)
        return kNowContinuityWireWrongSize;
    if (read_u32(bytes + NOW_CONTINUITY_ACK_MAGIC_OFFSET)
            != NOW_CONTINUITY_ACK_MAGIC)
        return kNowContinuityWireWrongMagic;
    if (read_u16(bytes + NOW_CONTINUITY_ACK_VERSION_OFFSET)
            != NOW_CONTINUITY_VERSION)
        return kNowContinuityWireWrongVersion;
    state = read_u16(bytes + NOW_CONTINUITY_ACK_STATE_OFFSET);
    exit_reason = read_u16(bytes + NOW_CONTINUITY_ACK_EXIT_REASON_OFFSET);
    if (state > NOW_CONTINUITY_ACK_ACTIVE)
        return kNowContinuityWireBadState;
    if (exit_reason > NOW_CONTINUITY_EXIT_DISARMED)
        return kNowContinuityWireBadExitReason;

    out->state = state;
    out->nonce_hi = read_u32(bytes + NOW_CONTINUITY_ACK_NONCE_HI_OFFSET);
    out->nonce_lo = read_u32(bytes + NOW_CONTINUITY_ACK_NONCE_LO_OFFSET);
    out->epoch = read_u32(bytes + NOW_CONTINUITY_ACK_EPOCH_OFFSET);
    out->position_seq =
        read_u32(bytes + NOW_CONTINUITY_ACK_POSITION_SEQ_OFFSET);
    out->button_generation =
        read_u32(bytes + NOW_CONTINUITY_ACK_BUTTON_GENERATION_OFFSET);
    out->accepted_hz =
        read_u16(bytes + NOW_CONTINUITY_ACK_ACCEPTED_HZ_OFFSET);
    out->exit_reason = exit_reason;
    out->arrival_ticks =
        read_u32(bytes + NOW_CONTINUITY_ACK_ARRIVAL_TICKS_OFFSET);
    out->apply_ticks = read_u32(bytes + NOW_CONTINUITY_ACK_APPLY_TICKS_OFFSET);
    out->rejected_packets =
        read_u32(bytes + NOW_CONTINUITY_ACK_REJECTED_PACKETS_OFFSET);
    return kNowContinuityWireOK;
}

void now_continuity_encode_ack(const NowContinuityAckPacket *packet,
                               NowCU8 out[NOW_CONTINUITY_ACK_BYTES])
{
    write_u32(out + NOW_CONTINUITY_ACK_MAGIC_OFFSET,
              NOW_CONTINUITY_ACK_MAGIC);
    write_u16(out + NOW_CONTINUITY_ACK_VERSION_OFFSET,
              NOW_CONTINUITY_VERSION);
    write_u16(out + NOW_CONTINUITY_ACK_STATE_OFFSET, packet->state);
    write_u32(out + NOW_CONTINUITY_ACK_NONCE_HI_OFFSET, packet->nonce_hi);
    write_u32(out + NOW_CONTINUITY_ACK_NONCE_LO_OFFSET, packet->nonce_lo);
    write_u32(out + NOW_CONTINUITY_ACK_EPOCH_OFFSET, packet->epoch);
    write_u32(out + NOW_CONTINUITY_ACK_POSITION_SEQ_OFFSET,
              packet->position_seq);
    write_u32(out + NOW_CONTINUITY_ACK_BUTTON_GENERATION_OFFSET,
              packet->button_generation);
    write_u16(out + NOW_CONTINUITY_ACK_ACCEPTED_HZ_OFFSET,
              packet->accepted_hz);
    write_u16(out + NOW_CONTINUITY_ACK_EXIT_REASON_OFFSET,
              packet->exit_reason);
    write_u32(out + NOW_CONTINUITY_ACK_ARRIVAL_TICKS_OFFSET,
              packet->arrival_ticks);
    write_u32(out + NOW_CONTINUITY_ACK_APPLY_TICKS_OFFSET,
              packet->apply_ticks);
    write_u32(out + NOW_CONTINUITY_ACK_REJECTED_PACKETS_OFFSET,
              packet->rejected_packets);
}
