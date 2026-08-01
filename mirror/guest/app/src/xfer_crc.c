#include "xfer_crc.h"

#include "wire.h"

void xfer_crc_init(XferCrc *state)
{
    state->running = 0xFFFFFFFFUL;
    state->high = 0;
    state->valid = 1;
}

void xfer_crc_note(XferCrc *state, long offset,
                   const unsigned char *data, size_t len)
{
    if (state->valid && offset == state->high) {
        state->running = wire_crc32_update(state->running, data, len);
        state->high += (long)len;
    } else {
        state->valid = 0;
    }
}

int xfer_crc_finish(const XferCrc *state, long expected,
                    unsigned long *crc)
{
    if (!state->valid || state->high != expected) {
        return 0;
    }
    *crc = state->running ^ 0xFFFFFFFFUL;
    return 1;
}
