/*
 * n68_shotwire.c - implementation of n68_shotwire.h. Read that header
 * first: it carries why the wire format is not PICT, why `bytes` includes
 * the palette, and why this rung sends raw rather than packbits.
 *
 * STATIC BUDGET: none. No BSS, no allocation, no printf family.
 */
#include "n68_shotwire.h"

#include "n68_packbits.h"
#include "numfmt.h"

#include <string.h>

int n68_shotwire_plan(long width, long height, long depth,
                      N68ShotWirePlan *plan)
{
    if (plan == NULL) {
        return 0;
    }
    memset(plan, 0, sizeof *plan);
    if (width <= 0 || height <= 0 || depth != 8) {
        return 0;
    }
    /* 8-bit only, so a row is one byte per pixel and the whole frame
     * cannot overflow a long on any screen this machine can drive: the
     * largest is a few hundred KB. Stated rather than checked, because a
     * check here would be unreachable and an unreachable check reads as a
     * bound someone measured. */
    plan->width = width;
    plan->height = height;
    plan->depth = depth;
    plan->row_bytes = width;                 /* visible row - see header */
    plan->palette_bytes = kN68ShotWirePaletteBytes;
    plan->total = plan->palette_bytes + plan->row_bytes * height;
    return 1;
}

int n68_shotwire_locate(const N68ShotWirePlan *plan, long offset,
                        long *row, long *column)
{
    long pixels;

    if (row != NULL) {
        *row = -1;
    }
    if (column != NULL) {
        *column = -1;
    }
    if (plan == NULL || plan->row_bytes <= 0 || offset < 0
        || offset >= plan->total) {
        return 0;
    }
    if (offset < plan->palette_bytes) {
        if (column != NULL) {
            *column = offset;      /* row stays -1: still in the palette */
        }
        return 1;
    }
    pixels = offset - plan->palette_bytes;
    if (row != NULL) {
        *row = pixels / plan->row_bytes;
    }
    if (column != NULL) {
        *column = pixels % plan->row_bytes;
    }
    return 1;
}

long n68_shotwire_emit(const N68ShotWirePlan *plan,
                       const unsigned char *base, long fb_row_bytes,
                       const unsigned char *palette, long palette_bytes,
                       const N68ShotWireSink *sink)
{
    long emitted = 0;
    long row;

    if (plan == NULL || base == NULL || sink == NULL || sink->put == NULL
        || sink->row_copy == NULL) {
        return -1;
    }
    if (plan->row_bytes <= 0 || plan->height <= 0) {
        return -1;
    }
    /* The screen's stride must cover the part this reads out of it.
     * Refused rather than clamped: a stride narrower than the visible row
     * means the geometry did not come from a screen, and reading anyway
     * walks off the end of the last row. */
    if (fb_row_bytes < plan->row_bytes) {
        return -1;
    }
    if (sink->row_buf == NULL || sink->row_cap < plan->row_bytes) {
        return -1;
    }
    if (sink->pack_buf == NULL
        || sink->pack_cap < n68_packbits_max(plan->row_bytes)) {
        return -1;
    }
    if (palette_bytes != plan->palette_bytes) {
        return -1;
    }
    if (palette_bytes > 0) {
        if (palette == NULL) {
            return -1;
        }
        sink->put(sink->ctx, palette, palette_bytes);
        emitted += palette_bytes;
    }

    for (row = 0; row < plan->height; ++row) {
        long packed;
        unsigned char len_be[2];

        if (sink->stop != NULL && sink->stop(sink->ctx)) {
            return -1;
        }
        if (sink->row_begin != NULL) {
            sink->row_begin(sink->ctx, row);
        }
        /* THE WALK. `fb_row_bytes` is the screen's own stride, padding
         * included; `plan->row_bytes` is what the host was promised. The
         * address is computed here and dereferenced by the caller's
         * `row_copy`, which is the only thing that knows what addressing
         * mode this Mac needs to be in to see it (header). */
        sink->row_copy(sink->ctx, sink->row_buf,
                       base + row * fb_row_bytes, plan->row_bytes);
        if (sink->row_read != NULL) {
            sink->row_read(sink->ctx, row);
        }

        packed = n68_packbits_row(sink->row_buf, plan->row_bytes,
                                  sink->pack_buf, sink->pack_cap);
        if (sink->row_packed != NULL) {
            sink->row_packed(sink->ctx, row);
        }
        if (packed <= 0) {
            return -1;    /* unreachable: pack_cap is checked at the bound */
        }
        /* Big-endian, because that is what the host reads and what the
         * PowerPC guest writes (now-guest-ppc/src/screenshots/pixels.c). */
        len_be[0] = (unsigned char)((packed >> 8) & 0xFF);
        len_be[1] = (unsigned char)(packed & 0xFF);
        sink->put(sink->ctx, len_be, 2);
        sink->put(sink->ctx, sink->pack_buf, packed);
        emitted += 2 + packed;
    }
    return emitted;
}

long n68_shotwire_begin_json(const N68ShotWirePlan *plan, long id,
                             unsigned int transfer, long capture_ms,
                             long encode_ms, int packed, char *out, long cap)
{
    long avail = cap > 0 ? cap - 1 : 0;
    long pos = 0;
    int ok = 1;

    if (plan == NULL || out == NULL || cap <= 0) {
        if (cap > 0 && out != NULL) {
            out[0] = '\0';
        }
        return 0;
    }
    /* Field for field and in the same order as now-guest-ppc/src/core/wire.c's
     * arm_transfer(), because the host decodes what that sender sends and
     * a second sender that agrees only in spirit is the defect class this
     * project has paid most for. */
    ok = ok && now68k_fmt_append_str(out, avail, &pos,
                                     "{\"type\":\"capture.begin\",\"id\":");
    ok = ok && now68k_fmt_append_long(out, avail, &pos, id);
    ok = ok && now68k_fmt_append_str(out, avail, &pos, ",\"transfer\":");
    ok = ok && now68k_fmt_append_long(out, avail, &pos, (long)transfer);
    ok = ok && now68k_fmt_append_str(out, avail, &pos, ",\"width\":");
    ok = ok && now68k_fmt_append_long(out, avail, &pos, plan->width);
    ok = ok && now68k_fmt_append_str(out, avail, &pos, ",\"height\":");
    ok = ok && now68k_fmt_append_long(out, avail, &pos, plan->height);
    ok = ok && now68k_fmt_append_str(out, avail, &pos, ",\"depth\":");
    ok = ok && now68k_fmt_append_long(out, avail, &pos, plan->depth);
    ok = ok && now68k_fmt_append_str(out, avail, &pos, ",\"rowBytes\":");
    ok = ok && now68k_fmt_append_long(out, avail, &pos, plan->row_bytes);
    ok = ok && now68k_fmt_append_str(out, avail, &pos, ",\"bytes\":");
    ok = ok && now68k_fmt_append_long(out, avail, &pos, plan->total);
    ok = ok && now68k_fmt_append_str(out, avail, &pos, ",\"paletteBytes\":");
    ok = ok && now68k_fmt_append_long(out, avail, &pos, plan->palette_bytes);
    ok = ok && now68k_fmt_append_str(out, avail, &pos, ",\"encoding\":\"");
    ok = ok && now68k_fmt_append_str(out, avail, &pos,
                                     packed ? "packbits" : "raw");
    ok = ok && now68k_fmt_append_str(out, avail, &pos, "\",\"captureMs\":");
    ok = ok && now68k_fmt_append_long(out, avail, &pos, capture_ms);
    ok = ok && now68k_fmt_append_str(out, avail, &pos, ",\"encodeMs\":");
    ok = ok && now68k_fmt_append_long(out, avail, &pos, encode_ms);
    ok = ok && now68k_fmt_append_str(out, avail, &pos, "}");
    if (!ok) {
        out[0] = '\0';
        return 0;
    }
    out[pos] = '\0';
    return pos;
}

long n68_shotwire_end_json(long id, unsigned int transfer, int ok_flag,
                           char *out, long cap)
{
    long avail = cap > 0 ? cap - 1 : 0;
    long pos = 0;
    int ok = 1;

    if (out == NULL || cap <= 0) {
        return 0;
    }
    ok = ok && now68k_fmt_append_str(out, avail, &pos,
                                     "{\"type\":\"capture.end\",\"id\":");
    ok = ok && now68k_fmt_append_long(out, avail, &pos, id);
    ok = ok && now68k_fmt_append_str(out, avail, &pos, ",\"transfer\":");
    ok = ok && now68k_fmt_append_long(out, avail, &pos, (long)transfer);
    ok = ok && now68k_fmt_append_str(out, avail, &pos,
                                     ok_flag ? ",\"ok\":true}"
                                             : ",\"ok\":false}");
    if (!ok) {
        out[0] = '\0';
        return 0;
    }
    out[pos] = '\0';
    return pos;
}
