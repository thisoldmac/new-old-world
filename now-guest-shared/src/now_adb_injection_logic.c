#include "now_adb_injection_logic.h"

static int decode_delta(unsigned char value)
{
    int delta = value & 0x7F;
    return delta >= 64 ? delta - 128 : delta;
}

static int absolute_value(int value)
{
    return value < 0 ? -value : value;
}

static int clamp_delta(int value, unsigned *clamped)
{
    if (value < -63) {
        *clamped = 1;
        return -63;
    }
    if (value > 63) {
        *clamped = 1;
        return 63;
    }
    return value;
}

NowADBInjectionResult now_adb_injection_rewrite(
    unsigned command, unsigned char *packet, unsigned packet_length,
    short current_h, short current_v, short target_h, short target_v)
{
    NowADBInjectionResult result = { kNowADBInjectionIgnored, 0, 0, 0, 0 };
    int physical_h;
    int physical_v;
    int delta_h;
    int delta_v;

    if ((command & 0x0Fu) != 0x0Cu || packet == 0 || packet_length != 2)
        return result;
    physical_v = decode_delta(packet[0]);
    physical_h = decode_delta(packet[1]);
    if (absolute_value(physical_h) > 1 || absolute_value(physical_v) > 1) {
        result.classification = kNowADBInjectionPhysical;
        return result;
    }

    delta_h = clamp_delta((int)target_h - (int)current_h, &result.clamped);
    delta_v = clamp_delta((int)target_v - (int)current_v, &result.clamped);
    packet[0] = (unsigned char)(0x80u | ((unsigned)delta_v & 0x7Fu));
    packet[1] = (unsigned char)(0x80u | ((unsigned)delta_h & 0x7Fu));
    result.classification = kNowADBInjectionCarrier;
    result.delta_h = (signed char)delta_h;
    result.delta_v = (signed char)delta_v;
    result.reached_target = delta_h == (int)target_h - (int)current_h
        && delta_v == (int)target_v - (int)current_v;
    return result;
}
