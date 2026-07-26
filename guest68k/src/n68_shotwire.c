/*
 * n68_shotwire.c - implementation of n68_shotwire.h. Read that header
 * first: it carries why the wire format is not PICT, why `bytes` includes
 * the palette, and why this rung sends raw rather than packbits.
 *
 * STATIC BUDGET: none. No BSS, no allocation, no printf family.
 */
#include "n68_shotwire.h"

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

long n68_shotwire_begin_json(const N68ShotWirePlan *plan, long id,
                             unsigned int transfer, long capture_ms,
                             long encode_ms, char *out, long cap)
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
    /* Field for field and in the same order as guest/src/wire.c's
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
    ok = ok && now68k_fmt_append_str(out, avail, &pos,
                                     ",\"encoding\":\"raw\",\"captureMs\":");
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
