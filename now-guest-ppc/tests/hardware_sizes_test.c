#include "hardware_sizes.h"

#include <stdio.h>

static int failures;

static void check(unsigned long actual, unsigned long expected,
                  const char *message)
{
    if (actual != expected) {
        fprintf(stderr, "FAIL: %s (got %lu, wanted %lu)\n",
                message, actual, expected);
        ++failures;
    }
}

int main(void)
{
    NowROMLayout rom;

    check(now_capacity_mib_from_wide(0x0000000FUL, 0xFFFFFFFFUL),
          65535UL, "a 64 GiB-class volume does not stop at 2047 MiB");
    check(now_capacity_mib_from_wide(0, 0x7FF00000UL),
          2047UL, "ordinary low-word capacity remains exact");

    rom = now_rom_layout(310, 3UL * 1024UL * 1024UL);
    check(rom.toolbox_bytes, 3UL * 1024UL * 1024UL,
          "the PB1400 Toolbox section remains explicit");
    check(rom.boot_bytes, 1UL * 1024UL * 1024UL,
          "the PB1400 boot section is included");
    check(rom.total_bytes, 4UL * 1024UL * 1024UL,
          "the PB1400 full ROM is four MiB");

    rom = now_rom_layout(42, 2UL * 1024UL * 1024UL);
    check(rom.total_bytes, 2UL * 1024UL * 1024UL,
          "unknown machines are not guessed larger than Gestalt");

    if (failures != 0) {
        fprintf(stderr, "%d failure(s)\n", failures);
        return 1;
    }
    puts("all hardware-size checks passed");
    return 0;
}
