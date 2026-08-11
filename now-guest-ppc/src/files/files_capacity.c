#include "files_capacity.h"

#define NOW_CLASSIC_LONG_MAX 0x7FFFFFFFUL

long now_files_volume_capacity(unsigned long free_blocks,
                               unsigned long allocation_block_size)
{
    if (free_blocks != 0
        && allocation_block_size > NOW_CLASSIC_LONG_MAX / free_blocks) {
        return (long)NOW_CLASSIC_LONG_MAX;
    }
    return (long)(free_blocks * allocation_block_size);
}
