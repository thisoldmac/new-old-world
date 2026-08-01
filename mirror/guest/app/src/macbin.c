/*
 * macbin.c - MacBinary III header parsing (see macbin.h).
 */
#include "macbin.h"
#include <string.h>

/* Header field offsets (MacBinary II/III) - mirror macbinary.py. */
#define kOffVersion   0     /* must be 0 */
#define kOffNameLen   1     /* 1..63 */
#define kOffName      2
#define kOffType      65    /* 4 bytes */
#define kOffCreator   69    /* 4 bytes */
#define kOffFlagsHi   73
#define kOffZero1     74    /* must be 0 */
#define kOffDataLen   83    /* 4 bytes, big-endian */
#define kOffRsrcLen   87    /* 4 bytes, big-endian */
#define kOffCreated   91    /* 4 bytes, big-endian */
#define kOffModified  95    /* 4 bytes, big-endian */
#define kOffFlagsLo   101
#define kOffCrc       124   /* 2 bytes, big-endian CRC-16 over 0..123 */

static unsigned long be32(const unsigned char *p)
{
    return ((unsigned long)p[0] << 24) | ((unsigned long)p[1] << 16)
         | ((unsigned long)p[2] << 8)  | (unsigned long)p[3];
}

static unsigned short be16(const unsigned char *p)
{
    return (unsigned short)(((unsigned short)p[0] << 8) | (unsigned short)p[1]);
}

static long pad128(long n)
{
    return (n + (kMacBinPad - 1)) / kMacBinPad * kMacBinPad;
}

/* CRC-16 CCITT/XMODEM (poly 0x1021, init 0) over data[0..len). */
static unsigned short mb_crc16(const unsigned char *data, size_t len)
{
    unsigned short crc = 0;
    size_t         i;
    int            b;

    for (i = 0; i < len; i++) {
        crc ^= (unsigned short)((unsigned short)data[i] << 8);
        for (b = 0; b < 8; b++) {
            crc = (crc & 0x8000)
                ? (unsigned short)((crc << 1) ^ 0x1021)
                : (unsigned short)(crc << 1);
        }
    }
    return crc;
}

static void put_be32(unsigned char *p, unsigned long v)
{
    p[0] = (unsigned char)((v >> 24) & 0xFF);
    p[1] = (unsigned char)((v >> 16) & 0xFF);
    p[2] = (unsigned char)((v >> 8) & 0xFF);
    p[3] = (unsigned char)(v & 0xFF);
}

static void put_be16(unsigned char *p, unsigned short v)
{
    p[0] = (unsigned char)((v >> 8) & 0xFF);
    p[1] = (unsigned char)(v & 0xFF);
}

void macbin_build_header(const unsigned char *name, long nameLen,
                         unsigned long type, unsigned long creator,
                         long dataLen, long rsrcLen,
                         unsigned long created, unsigned long modified,
                         unsigned short finderFlags, unsigned char *hdr)
{
    long i;

    for (i = 0; i < kMacBinHeader; i++) {
        hdr[i] = 0;
    }
    if (nameLen < 1) {
        nameLen = 1;
    }
    if (nameLen > 63) {
        nameLen = 63;
    }
    hdr[kOffVersion] = 0;
    hdr[kOffNameLen] = (unsigned char)nameLen;
    memcpy(hdr + kOffName, name, (size_t)nameLen);
    put_be32(hdr + kOffType, type);
    put_be32(hdr + kOffCreator, creator);
    hdr[kOffFlagsHi] = (unsigned char)((finderFlags >> 8) & 0xFF);
    put_be32(hdr + kOffDataLen, (unsigned long)dataLen);
    put_be32(hdr + kOffRsrcLen, (unsigned long)rsrcLen);
    put_be32(hdr + kOffCreated, created);
    put_be32(hdr + kOffModified, modified);
    hdr[kOffFlagsLo] = (unsigned char)(finderFlags & 0xFF);
    hdr[102] = 'm';                      /* MacBinary III signature 'mBIN' */
    hdr[103] = 'B';
    hdr[104] = 'I';
    hdr[105] = 'N';
    hdr[122] = 130;                      /* version written with */
    hdr[123] = 129;                      /* minimum version to read */
    put_be16(hdr + kOffCrc, mb_crc16(hdr, kOffCrc));
}

int macbin_parse(const unsigned char *hdr, MacBinInfo *out)
{
    long           nlen;
    unsigned short stored;
    unsigned short computed;

    if (hdr[kOffVersion] != 0 || hdr[kOffZero1] != 0) {
        return -1;                       /* not MacBinary */
    }
    nlen = hdr[kOffNameLen];
    if (nlen < 1 || nlen > 63) {
        return -1;
    }
    stored   = be16(hdr + kOffCrc);
    computed = mb_crc16(hdr, kOffCrc);
    /* MacBinary I has no header CRC (field 0); only a nonzero-but-wrong CRC is a
       real corruption signal. */
    if (stored != computed && stored != 0) {
        return -1;
    }

    out->nameLen = nlen;
    memcpy(out->name, hdr + kOffName, (size_t)nlen);
    out->name[nlen]  = 0;
    out->type        = be32(hdr + kOffType);
    out->creator     = be32(hdr + kOffCreator);
    out->dataLen     = (long)be32(hdr + kOffDataLen);
    out->rsrcLen     = (long)be32(hdr + kOffRsrcLen);
    out->created     = be32(hdr + kOffCreated);
    out->modified    = be32(hdr + kOffModified);
    out->finderFlags = (unsigned short)(((unsigned short)hdr[kOffFlagsHi] << 8)
                                        | (unsigned short)hdr[kOffFlagsLo]);
    out->dataOff     = kMacBinHeader;
    out->rsrcOff     = kMacBinHeader + pad128(out->dataLen);
    out->totalLen    = out->rsrcOff + pad128(out->rsrcLen);
    out->headerCrcOk = (stored == computed);
    return 0;
}

int macbin_merge_dates(const MacBinInfo *info, unsigned long *created,
                       unsigned long *modified)
{
    int changed = 0;

    if (info->created != 0) {
        *created = info->created;
        changed = 1;
    }
    if (info->modified != 0) {
        *modified = info->modified;
        changed = 1;
    }
    return changed;
}
