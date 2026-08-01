/*
 * macbin.h - MacBinary III header parsing for the file-transfer channel
 * (docs/18-file-transfer.md). The guest's decode half: `put` assembles an
 * uploaded MacBinary stream into a temp file, and the commit reads its header
 * to split the forks and restore Finder info.
 *
 * Offsets mirror the host codec in mcp-classic/timbottu_mcp_classic/macbinary.py EXACTLY - a
 * change here must change there too, or a round-trip silently corrupts.
 */
#ifndef TIMBOTTU_MACBIN_H
#define TIMBOTTU_MACBIN_H

#include <stddef.h>

#define kMacBinHeader 128    /* fixed header length */
#define kMacBinPad    128    /* each fork padded to this multiple */

typedef struct {
    long           nameLen;        /* 1..63 */
    unsigned char  name[64];       /* nameLen bytes + NUL */
    unsigned long  type;           /* OSType (big-endian four-char) */
    unsigned long  creator;        /* OSType */
    long           dataLen;        /* data-fork bytes */
    long           rsrcLen;        /* resource-fork bytes */
    unsigned long  created;        /* Mac epoch (seconds since 1904, local) */
    unsigned long  modified;       /* Mac epoch */
    unsigned short finderFlags;    /* fdFlags (hi << 8 | lo) */
    long           dataOff;        /* kMacBinHeader */
    long           rsrcOff;        /* header + pad128(dataLen) */
    long           totalLen;       /* rsrcOff + pad128(rsrcLen) */
    int            headerCrcOk;    /* CRC-16 matched (0 for MacBinary I) */
} MacBinInfo;

/* Parse the 128-byte MacBinary header at `hdr` (>= 128 readable bytes) into
   *out. Returns 0 on success, -1 if it is not a plausible MacBinary header
   (bad zero-fill, name length out of range, or a nonzero-but-wrong CRC). */
int macbin_parse(const unsigned char *hdr, MacBinInfo *out);

/* Merge dates carried by `info` into existing catalog values. MacBinary uses
   zero for "no date", so an absent date leaves its catalog value unchanged.
   Returns nonzero when at least one catalog value needs to be written. */
int macbin_merge_dates(const MacBinInfo *info, unsigned long *created,
                       unsigned long *modified);

/* Build a 128-byte MacBinary III header into hdr (the encode half, for `get`).
   `name`/`nameLen` is the file name (Mac Roman, clamped to 63); dates are Mac
   epoch. Writes the `mBIN` signature and the header CRC-16. The forks follow in
   the stream, each padded to kMacBinPad - the caller lays those out. */
void macbin_build_header(const unsigned char *name, long nameLen,
                         unsigned long type, unsigned long creator,
                         long dataLen, long rsrcLen,
                         unsigned long created, unsigned long modified,
                         unsigned short finderFlags, unsigned char *hdr);

#endif /* TIMBOTTU_MACBIN_H */
