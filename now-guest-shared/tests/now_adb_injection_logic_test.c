#include <stdio.h>

#include "now_adb_injection_logic.h"

static int failures;

#define CHECK(condition, message) do { \
    if (!(condition)) { \
        fprintf(stderr, "FAIL: %s\n", message); \
        failures++; \
    } \
} while (0)

int main(void)
{
    unsigned char packet[2] = { 0x80, 0x81 };
    NowADBInjectionResult result;

    result = now_adb_injection_rewrite(0x3C, packet, 2,
                                       100, 100, 120, 90);
    CHECK(result.classification == kNowADBInjectionCarrier,
          "tiny movement is an emulator carrier");
    CHECK(packet[0] == 0xF6 && packet[1] == 0x94,
          "carrier becomes signed relative target delta with buttons up");
    CHECK(result.delta_h == 20 && result.delta_v == -10,
          "reported deltas match encoded deltas");
    CHECK(result.reached_target && !result.clamped,
          "near target settles in one packet");

    packet[0] = 0x80;
    packet[1] = 0x80;
    result = now_adb_injection_rewrite(0x3C, packet, 2,
                                       0, 0, 300, -300);
    CHECK(packet[0] == 0xC1 && packet[1] == 0xBF,
          "large target delta clamps to the ADB seven-bit range");
    CHECK(result.clamped && !result.reached_target,
          "clamped packet does not acknowledge the target");

    packet[0] = 0x85;
    packet[1] = 0x80;
    result = now_adb_injection_rewrite(0x3C, packet, 2,
                                       10, 10, 20, 20);
    CHECK(result.classification == kNowADBInjectionPhysical,
          "larger native delta is never stolen");
    CHECK(packet[0] == 0x85 && packet[1] == 0x80,
          "native packet remains byte-for-byte intact");

    packet[0] = 0x80;
    packet[1] = 0x80;
    result = now_adb_injection_rewrite(0x3D, packet, 2,
                                       10, 10, 20, 20);
    CHECK(result.classification == kNowADBInjectionIgnored,
          "non-register-zero command is ignored");

    if (failures)
        return 1;
    puts("now_adb_injection_logic_test: ok");
    return 0;
}
