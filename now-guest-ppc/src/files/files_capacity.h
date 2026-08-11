#ifndef NOW_FILES_CAPACITY_H
#define NOW_FILES_CAPACITY_H

/* Classic File Manager byte counts are signed 32-bit longs. Return an exact
 * capacity when representable and LONG_MAX otherwise, so callers can still
 * make a conservative free-space decision on large HFS volumes. */
long now_files_volume_capacity(unsigned long free_blocks,
                               unsigned long allocation_block_size);

#endif
