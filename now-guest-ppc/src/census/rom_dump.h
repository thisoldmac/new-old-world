#ifndef NOW_ROM_DUMP_H
#define NOW_ROM_DUMP_H

#include "hardware_sizes.h"

enum { kNowROMDumpPathCap = 64 };

int now_rom_dump(char *path, long path_cap, NowROMLayout *layout,
                 char *error, long error_cap);

#endif
