#ifndef TIMBOTTU_XFER_CRC_H
#define TIMBOTTU_XFER_CRC_H

#include <stddef.h>

typedef struct {
    unsigned long running;
    long          high;
    int           valid;
} XferCrc;

void xfer_crc_init(XferCrc *state);
void xfer_crc_note(XferCrc *state, long offset,
                   const unsigned char *data, size_t len);
int  xfer_crc_finish(const XferCrc *state, long expected,
                     unsigned long *crc);

#endif /* TIMBOTTU_XFER_CRC_H */
