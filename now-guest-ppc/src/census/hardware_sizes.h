#ifndef NOW_HARDWARE_SIZES_H
#define NOW_HARDWARE_SIZES_H

#include <stdint.h>

typedef struct {
    uint32_t toolbox_bytes;
    uint32_t boot_bytes;
    uint32_t total_bytes;
} NowROMLayout;

/* XVolumeParam reports UInt64 byte counts.  The census displays whole MiB,
   which fits in 32 bits for every volume classic Mac OS can mount. */
uint32_t now_capacity_mib_from_wide(uint32_t hi, uint32_t lo);

/* The PB1400's Gestalt value names only the 3 MiB Toolbox image.  The ROM
   dumps establish the adjacent 1 MiB boot/nanokernel section and the full
   4 MiB aperture.  Keep that measured exception in one place. */
NowROMLayout now_rom_layout(uint32_t machine_type,
                            uint32_t gestalt_rom_bytes);

#endif
