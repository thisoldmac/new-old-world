/*
 * axoracle.c - allocation-free AXPeek sample table and partition matcher.
 */
#include "axoracle.h"

static int in_range(uint32_t value, uint32_t lo, uint32_t hi)
{
    return value >= lo && value < hi;
}

int ax_oracle_buffer_range_valid(uint32_t address, uint32_t system_lo,
                                 uint32_t system_hi, size_t size)
{
    return system_hi > system_lo && address >= system_lo && address < system_hi
        && (address & 3U) == 0 && size <= UINT32_MAX
        && (uint32_t)size <= system_hi - address;
}

uint32_t ax_oracle_record(AXShared *shared, uint32_t current_a5,
                          uint32_t stack_base, uint32_t window_list,
                          uint32_t menu_list, uint32_t ticks,
                          const unsigned char *app_name)
{
    AXContextSample *sample;
    uint32_t         slot = AX_SAMPLE_MAX;
    uint32_t         i;
    unsigned int     name_len = 0;

    if (shared == 0 || current_a5 == 0) {
        return AX_SAMPLE_MAX;
    }
    for (i = 0; i < AX_SAMPLE_MAX; i++) {
        if (shared->samples[i].currentA5 == current_a5) {
            slot = i;
            break;
        }
        if (slot == AX_SAMPLE_MAX && shared->samples[i].currentA5 == 0) {
            slot = i;
        }
    }
    if (slot == AX_SAMPLE_MAX) {
        slot = shared->nextSlot % AX_SAMPLE_MAX;
        shared->nextSlot = (slot + 1) % AX_SAMPLE_MAX;
    } else if (shared->samples[slot].currentA5 == 0
               && shared->sampleCount < AX_SAMPLE_MAX) {
        shared->sampleCount++;
    }

    sample = &shared->samples[slot];
    sample->currentA5 = current_a5;
    sample->stackBase = stack_base;
    sample->windowList = window_list;
    sample->menuList = menu_list;
    sample->ticks = ticks;

    if (app_name != 0) {
        name_len = app_name[0];
        if (name_len >= AX_NAME_MAX) {
            name_len = AX_NAME_MAX - 1;
        }
    }
    sample->appName[0] = (unsigned char)name_len;
    for (i = 1; i <= name_len; i++) {
        sample->appName[i] = app_name[i];
    }
    for (; i < AX_NAME_MAX; i++) {
        sample->appName[i] = 0;
    }
    return slot;
}

static int match(const AXShared *shared, uint32_t process_location,
                 uint32_t process_size, uint32_t system_location,
                 uint32_t system_size, const unsigned char *process_name,
                 uint32_t now, uint32_t max_age, int require_fresh,
                 AXContextSample *out)
{
    uint32_t app_hi;
    uint32_t system_hi;
    uint32_t count;
    uint32_t i;
    int      found = 0;
    int      saw_stale = 0;
    int      saw_mismatch = 0;

    if (shared == 0 || process_name == 0 || out == 0 || process_size == 0
        || system_size == 0
        || process_size > UINT32_MAX - process_location
        || system_size > UINT32_MAX - system_location) {
        return AX_ORACLE_INVALID;
    }
    app_hi = process_location + process_size;
    system_hi = system_location + system_size;
    count = shared->sampleCount;
    if (count > AX_SAMPLE_MAX) {
        return AX_ORACLE_INVALID;
    }
    for (i = 0; i < AX_SAMPLE_MAX; i++) {
        const AXContextSample *sample = &shared->samples[i];

        if (sample->currentA5 == 0
            || !in_range(sample->currentA5, process_location, app_hi)
            || sample->stackBase == 0
            || !in_range(sample->stackBase, process_location, app_hi)
            || (sample->windowList != 0
                && !in_range(sample->windowList, process_location, app_hi)
                && !in_range(sample->windowList, system_location,
                             system_hi))
            || (sample->menuList != 0
                && !in_range(sample->menuList, process_location, app_hi)
                && !in_range(sample->menuList, system_location,
                             system_hi))) {
            continue;
        }
        if (!ax_oracle_name_matches(sample, process_name)) {
            saw_mismatch = 1;
            continue;
        }
        if (require_fresh
            && !ax_oracle_sample_fresh(sample, now, max_age)) {
            saw_stale = 1;
            continue;
        }
        if (found) {
            return AX_ORACLE_AMBIGUOUS;
        }
        *out = *sample;
        found = 1;
    }
    if (found) {
        return AX_ORACLE_OK;
    }
    if (saw_mismatch) {
        return AX_ORACLE_MISMATCH;
    }
    return saw_stale ? AX_ORACLE_STALE : AX_ORACLE_NOT_FOUND;
}

int ax_oracle_match(const AXShared *shared, uint32_t process_location,
                    uint32_t process_size, uint32_t system_location,
                    uint32_t system_size,
                    const unsigned char *process_name,
                    uint32_t now, uint32_t max_age,
                    AXContextSample *out)
{
    return match(shared, process_location, process_size,
                 system_location, system_size, process_name,
                 now, max_age, 1, out);
}

int ax_oracle_match_any_age(const AXShared *shared,
                            uint32_t process_location,
                            uint32_t process_size,
                            uint32_t system_location,
                            uint32_t system_size,
                            const unsigned char *process_name,
                            AXContextSample *out)
{
    return match(shared, process_location, process_size,
                 system_location, system_size, process_name,
                 0, 0, 0, out);
}

int ax_oracle_sample_fresh(const AXContextSample *sample,
                           uint32_t now, uint32_t max_age)
{
    uint32_t age;

    if (sample == 0 || sample->currentA5 == 0) {
        return 0;
    }
    age = now - sample->ticks;
    return age <= max_age;
}

int ax_oracle_name_matches(const AXContextSample *sample,
                           const unsigned char *process_name)
{
    unsigned int length;
    unsigned int i;

    if (sample == 0 || process_name == 0) {
        return 0;
    }
    length = process_name[0];
    if (length >= AX_NAME_MAX || sample->appName[0] != length) {
        return 0;
    }
    for (i = 1; i <= length; i++) {
        if (sample->appName[i] != process_name[i]) {
            return 0;
        }
    }
    return 1;
}
