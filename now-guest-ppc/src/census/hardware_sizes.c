#include "hardware_sizes.h"

#include <limits.h>

enum {
    kPowerBook1400MachineType = 310,
    kPowerBook1400ToolboxROM = 3 * 1024 * 1024,
    kPowerBook1400BootROM = 1 * 1024 * 1024
};

uint32_t now_capacity_mib_from_wide(uint32_t hi, uint32_t lo)
{
    if (hi > 0x000FFFFFUL) {
        return UINT32_MAX;
    }
    return (hi << 12) | (lo >> 20);
}

NowROMLayout now_rom_layout(uint32_t machine_type,
                            uint32_t gestalt_rom_bytes)
{
    NowROMLayout result;

    result.toolbox_bytes = gestalt_rom_bytes;
    result.boot_bytes = 0;
    result.total_bytes = gestalt_rom_bytes;
    if (machine_type == kPowerBook1400MachineType
            && gestalt_rom_bytes == kPowerBook1400ToolboxROM) {
        result.boot_bytes = kPowerBook1400BootROM;
        result.total_bytes += result.boot_bytes;
    }
    return result;
}
