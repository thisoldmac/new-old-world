#include "macbinary_lengths.h"

#define NOW_CLASSIC_LONG_MAX 0x7FFFFFFFUL
#define NOW_MACBINARY_HEADER_SIZE 128UL

static unsigned long read_u32(const unsigned char *p)
{
    return ((unsigned long)p[0] << 24)
         | ((unsigned long)p[1] << 16)
         | ((unsigned long)p[2] << 8)
         | (unsigned long)p[3];
}

static unsigned long padded_length(unsigned long length)
{
    return (length + 127UL) & ~127UL;
}

int now_macbinary_fork_lengths(const unsigned char header[128],
                               long envelope_length,
                               long *data_length,
                               long *resource_length)
{
    unsigned long data;
    unsigned long resource;
    unsigned long remaining;
    unsigned long padded;

    if (header == 0 || data_length == 0 || resource_length == 0
        || envelope_length < (long)NOW_MACBINARY_HEADER_SIZE) {
        return 0;
    }

    data = read_u32(header + 83);
    resource = read_u32(header + 87);
    if (data > NOW_CLASSIC_LONG_MAX || resource > NOW_CLASSIC_LONG_MAX) {
        return 0;
    }

    remaining = (unsigned long)envelope_length - NOW_MACBINARY_HEADER_SIZE;
    if (data > remaining) {
        return 0;
    }
    padded = padded_length(data);
    if (padded > remaining) {
        return 0;
    }
    remaining -= padded;
    if (resource > remaining || padded_length(resource) > remaining) {
        return 0;
    }

    *data_length = (long)data;
    *resource_length = (long)resource;
    return 1;
}
