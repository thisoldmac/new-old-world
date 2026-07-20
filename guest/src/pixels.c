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

/* --- delta frames ------------------------------------------------------- */

short now_pixels_diff(CaptureImage *image, Ptr prev,
                      const CaptureSpan *spans, short n_spans,
                      short row_scale, short row_phase,
                      PixelRect *rects, short max_rects,
                      long *dirty_rows, Boolean *overflow)
{
    PixMapHandle pixels;
    long height = image->bounds.bottom - image->bounds.top;
    long row_bytes = image->row_bytes;
    CaptureSpan whole;
    Ptr base;
    short si;
    short count = 0;
    long dirty = 0;
    enum { kMergeGap = 4 };           /* runs closer than this merge */

    *dirty_rows = 0;
    *overflow = false;
    if (spans == NULL) {
        whole.row = 0;
        whole.n_rows = (short)height;
        spans = &whole;
        n_spans = 1;
    }
    pixels = GetGWorldPixMap(image->world);
    if (pixels == NULL || !LockPixels(pixels)) {
        return -1;
    }
    base = GetPixBaseAddr(pixels);

    for (si = 0; si < n_spans; ++si) {
        long row;

        for (row = spans[si].row;
             row < spans[si].row + spans[si].n_rows; ++row) {
            Ptr cur = base + row * row_bytes;
            Ptr old = prev
                + (row * row_scale + row_phase) * row_bytes;
            long lo, hi;

            if (memcmp(cur, old, (size_t)row_bytes) == 0) {
                continue;
            }
            for (lo = 0; cur[lo] == old[lo]; ++lo) {
            }
            for (hi = row_bytes - 1; cur[hi] == old[hi]; --hi) {
            }
            memcpy(old, cur, (size_t)row_bytes);
            ++dirty;

            if (count > 0
                && row - (rects[count - 1].row + rects[count - 1].n_rows)
                   < kMergeGap
                && row - (rects[count - 1].row + rects[count - 1].n_rows)
                   >= 0) {
                PixelRect *r = &rects[count - 1];
                long r_hi = (long)r->col_off + r->col_bytes;

                r->n_rows = (short)(row - r->row + 1);
                if (lo < r->col_off) {
                    r->col_off = (short)lo;
                }
                if (hi + 1 > r_hi) {
                    r_hi = hi + 1;
                }
                r->col_bytes = (short)(r_hi - r->col_off);
            } else if (count < max_rects) {
                rects[count].row = (short)row;
                rects[count].n_rows = 1;
                rects[count].col_off = (short)lo;
                rects[count].col_bytes = (short)(hi - lo + 1);
                ++count;
            } else {
                /* Widening here could swallow uncaptured gap rows, whose
                   GWorld content is garbage. Flag it; the caller sends
                   the captured spans whole instead. */
                *overflow = true;
            }
        }
    }
    UnlockPixels(pixels);
    *dirty_rows = dirty;
    return count;
}

int now_pixels_copy_raw(CaptureImage *image, Ptr dst)
{
    PixMapHandle pixels;
    long height = image->bounds.bottom - image->bounds.top;

    pixels = GetGWorldPixMap(image->world);
    if (pixels == NULL || !LockPixels(pixels)) {
        return -1;
    }
    memcpy(dst, GetPixBaseAddr(pixels),
           (size_t)(image->row_bytes * height));
    UnlockPixels(pixels);
    return 0;
}

long now_pixels_palette(CaptureImage *image, unsigned char *out, long cap)
{
    PixMapHandle pixels;
    CTabHandle ctab;
    long bytes = 0;
    long i;

    if (image->depth > 8) {
        return 0;
    }
    pixels = GetGWorldPixMap(image->world);
    if (pixels == NULL) {
        return 0;
    }
    ctab = (**pixels).pmTable;
    if (ctab == NULL || *ctab == NULL) {
        return 0;
    }
    for (i = 0; i <= (**ctab).ctSize && bytes + 3 <= cap; ++i) {
        ColorSpec *spec = &(**ctab).ctTable[i];

        out[bytes++] = (unsigned char)(spec->rgb.red >> 8);
        out[bytes++] = (unsigned char)(spec->rgb.green >> 8);
        out[bytes++] = (unsigned char)(spec->rgb.blue >> 8);
    }
    return bytes;
}

int now_pixels_export_rects(CaptureImage *image, Boolean pack,
                            const PixelRect *rects, short n_rects,
                            PixelBlob *blob)
{
    PixMapHandle pixels;
    long row_bytes = image->row_bytes;
    long capacity = 0;
    Handle out;
    Ptr base;
    Ptr src_base;
    long pos = 0;
    short i;
    long row;
    UnsignedWide t0, t1;

    memset(blob, 0, sizeof *blob);
    if (image->depth < 8) {
        pack = false;
    }
    for (i = 0; i < n_rects; ++i) {
        long per_row = pack ? packed_ceiling(rects[i].col_bytes)
                            : rects[i].col_bytes;

        capacity += (long)rects[i].n_rows * per_row;
    }

    pixels = GetGWorldPixMap(image->world);
    if (pixels == NULL || !LockPixels(pixels)) {
        return -1;
    }
    Microseconds(&t0);
    out = NewHandle(capacity);
    if (out == NULL) {
        UnlockPixels(pixels);
        return -2;
    }
    HLock(out);
    base = *out;
    src_base = GetPixBaseAddr(pixels);

    for (i = 0; i < n_rects; ++i) {
        for (row = rects[i].row;
             row < rects[i].row + rects[i].n_rows; ++row) {
            Ptr src = src_base + row * row_bytes + rects[i].col_off;

            if (pack) {
                Ptr sp = src;
                Ptr dp = base + pos + 2;
                long packed;

                PackBits(&sp, &dp, rects[i].col_bytes);
                packed = dp - (base + pos + 2);
                base[pos] = (char)((packed >> 8) & 0xFF);
                base[pos + 1] = (char)(packed & 0xFF);
                pos += 2 + packed;
            } else {
                memcpy(base + pos, src, (size_t)rects[i].col_bytes);
                pos += rects[i].col_bytes;
            }
        }
    }
    Microseconds(&t1);

    HUnlock(out);
    SetHandleSize(out, pos);
    UnlockPixels(pixels);

    blob->data = out;
    blob->palette_bytes = 0;
    blob->total_bytes = pos;
    blob->packed = pack;
    blob->encode_ms = micros_ms(t0, t1);
    return 0;
}
