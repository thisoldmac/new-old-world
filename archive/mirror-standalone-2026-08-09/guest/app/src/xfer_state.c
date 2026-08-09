#include "xfer_state.h"

#include <stdio.h>
#include <string.h>

int xfer_state_name(char *out, size_t cap, unsigned long generation, long id)
{
    int n;

    if (generation == 0 || id <= 0) {
        return -1;
    }
    n = snprintf(out, cap, "tbt_x_%lu_%ld", generation, id);
    return (n > 0 && (size_t)n < cap && n <= 31) ? n : -1;
}

int xfer_state_parse(const char *name, unsigned long *generation, long *id)
{
    unsigned long parsed_generation;
    long parsed_id;
    char tail;
    char canonical[32];

    if (sscanf(name, "tbt_x_%lu_%ld%c", &parsed_generation, &parsed_id,
               &tail) != 2
        || xfer_state_name(canonical, sizeof canonical, parsed_generation,
                           parsed_id) < 0
        || strcmp(name, canonical) != 0) {
        return 0;
    }
    if (generation != NULL) {
        *generation = parsed_generation;
    }
    if (id != NULL) {
        *id = parsed_id;
    }
    return 1;
}
