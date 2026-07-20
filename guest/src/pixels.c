#include "pixels.h"

#include <string.h>

/* Declared here rather than taken from the headers: the multiversal
   declaration is an M68K inline trap, but on PowerPC these resolve through
   CarbonLib, which exports both. */
extern pascal void PackBits(Ptr *srcPtr, Ptr *dstPtr, short srcBytes);

static long micros_ms(UnsignedWide a, UnsignedWide b)
{
    return (long)((b.lo - a.lo) / 1000);
}

/* Worst case for PackBits is srcBytes + (srcBytes + 126) / 127. */
static long packed_ceiling(long row_bytes)
{
    return row_bytes + (row_bytes + 126) / 127 + 2;
}

int now_pixels_export(CaptureImage *image, Boolean pack, PixelBlob *blob)
{
    PixMapHandle pixels;
    CTabHandle ctab;
    long height = image->bounds.bottom - image->bounds.top;
    long row_bytes = image->row_bytes;
    long palette_bytes = 0;
    long capacity;
    Handle out;
    Ptr base;
    long pos = 0;
    long row;
    UnsignedWide t0, t1;

    memset(blob, 0, sizeof *blob);
    pixels = GetGWorldPixMap(image->world);
    if (pixels == NULL || !LockPixels(pixels)) {
        return -1;
    }
    Microseconds(&t0);

    /* PackBits works on byte runs; at 1/2/4-bit the rows are already dense
       enough that per-row overhead can exceed the win, so only pack >= 8. */
    if (image->depth < 8) {
        pack = false;
    }
    if (image->depth <= 8) {
        ctab = (**pixels).pmTable;
        if (ctab != NULL && *ctab != NULL) {
            palette_bytes = ((long)(**ctab).ctSize + 1) * 3;
        }
    }

    capacity = palette_bytes
        + (pack ? height * packed_ceiling(row_bytes) : height * row_bytes);
    out = NewHandle(capacity);
    if (out == NULL) {
        UnlockPixels(pixels);
        return -2;
    }
    HLock(out);
    base = *out;

    if (palette_bytes > 0) {
        ctab = (**pixels).pmTable;
        for (row = 0; row <= (**ctab).ctSize; ++row) {
            ColorSpec *spec = &(**ctab).ctTable[row];
            base[pos++] = (char)(spec->rgb.red >> 8);
            base[pos++] = (char)(spec->rgb.green >> 8);
            base[pos++] = (char)(spec->rgb.blue >> 8);
        }
    }

    for (row = 0; row < height; ++row) {
        Ptr src = GetPixBaseAddr(pixels) + row * row_bytes;

        if (pack) {
            Ptr sp = src;
            Ptr dp = base + pos + 2;
            long packed;

            PackBits(&sp, &dp, (short)row_bytes);
            packed = dp - (base + pos + 2);
            base[pos] = (char)((packed >> 8) & 0xFF);
            base[pos + 1] = (char)(packed & 0xFF);
            pos += 2 + packed;
        } else {
            memcpy(base + pos, src, (size_t)row_bytes);
            pos += row_bytes;
        }
    }
    Microseconds(&t1);

    HUnlock(out);
    SetHandleSize(out, pos);
    UnlockPixels(pixels);

    blob->data = out;
    blob->palette_bytes = palette_bytes;
    blob->total_bytes = pos;
    blob->packed = pack;
    blob->encode_ms = micros_ms(t0, t1);
    return 0;
}

void now_pixels_dispose(PixelBlob *blob)
{
    if (blob != NULL && blob->data != NULL) {
        DisposeHandle(blob->data);
        blob->data = NULL;
    }
}
