/*
 * axoracle.h - portable producer/consumer seams for the AXPeek pointer oracle.
 *
 * No Toolbox types: this compiles into the resident 68K INIT, the PPC/68K
 * toolkit workers, and host tests from the same source.
 */
#ifndef AXPEEK_AXORACLE_H
#define AXPEEK_AXORACLE_H

#include <stddef.h>

#include "axshared.h"

enum {
    AX_ORACLE_OK = 0,
    AX_ORACLE_NOT_FOUND = 1,
    AX_ORACLE_AMBIGUOUS = 2,
    AX_ORACLE_INVALID = 3,
    AX_ORACLE_STALE = 4,
    AX_ORACLE_MISMATCH = 5
};

uint32_t ax_oracle_record(AXShared *shared, uint32_t current_a5,
                          uint32_t stack_base, uint32_t window_list,
                          uint32_t menu_list, uint32_t ticks,
                          const unsigned char *app_name);

int ax_oracle_buffer_range_valid(uint32_t address, uint32_t system_lo,
                                 uint32_t system_hi, size_t size);

int ax_oracle_match(const AXShared *shared, uint32_t process_location,
                    uint32_t process_size, uint32_t system_location,
                    uint32_t system_size,
                    const unsigned char *process_name,
                    uint32_t now, uint32_t max_age,
                    AXContextSample *out);
int ax_oracle_match_any_age(const AXShared *shared,
                            uint32_t process_location,
                            uint32_t process_size,
                            uint32_t system_location,
                            uint32_t system_size,
                            const unsigned char *process_name,
                            AXContextSample *out);
int ax_oracle_sample_fresh(const AXContextSample *sample,
                           uint32_t now, uint32_t max_age);
int ax_oracle_name_matches(const AXContextSample *sample,
                           const unsigned char *process_name);

#endif /* AXPEEK_AXORACLE_H */
