#include "frame.h"

void now68k_frame_pack(const Now68kFrameHeader *hdr,
                        unsigned char out[NOW68K_FRAME_HEADER_BYTES])
{
    unsigned short transfer = hdr->transfer;
    unsigned long length = hdr->length;

    out[0] = hdr->channel;
    out[1] = hdr->flags;
    out[2] = (unsigned char)((transfer >> 8) & 0xFFu);
    out[3] = (unsigned char)(transfer & 0xFFu);
    out[4] = (unsigned char)((length >> 24) & 0xFFu);
    out[5] = (unsigned char)((length >> 16) & 0xFFu);
    out[6] = (unsigned char)((length >> 8) & 0xFFu);
    out[7] = (unsigned char)(length & 0xFFu);
}

void now68k_frame_unpack(const unsigned char in[NOW68K_FRAME_HEADER_BYTES],
                          Now68kFrameHeader *hdr)
{
    hdr->channel = in[0];
    hdr->flags = in[1];
    hdr->transfer = (unsigned short)(((unsigned short)in[2] << 8)
                                      | (unsigned short)in[3]);
    hdr->length = ((unsigned long)in[4] << 24)
                | ((unsigned long)in[5] << 16)
                | ((unsigned long)in[6] << 8)
                | (unsigned long)in[7];
}

int now68k_frame_length_ok(unsigned long length)
{
    return length <= NOW68K_MAX_PAYLOAD;
}

int now68k_control_frame_fits(unsigned long length)
{
    return length <= NOW68K_CONTROL_BUFFER_CAP;
}
