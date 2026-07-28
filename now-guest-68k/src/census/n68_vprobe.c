/*
 * n68_vprobe.c - implementation of n68_vprobe.h. See that header for why
 * this half exists separately from the measuring half.
 *
 * Nothing here touches the Toolbox, allocates, or calls printf. Integer
 * arithmetic only, and every division guards its divisor: the inputs are
 * measured values, and a timer that returned the same number twice must
 * produce "no measurement", never a division by zero on a machine in
 * another room.
 *
 * THIRTY-TWO BITS, ON A SIXTY-FOUR-BIT HOST. Every overflow guard below
 * compares against kU32Max rather than against ULONG_MAX or against
 * natural wraparound. On the 180c a `long` is 32 bits; on the Mac running
 * the native tests it is 64, so a guard written as "does this wrap?"
 * would be tested on the one machine where it never can, and the
 * arithmetic would then differ between the tested build and the shipped
 * one. Bounding explicitly to 32 bits makes the host build compute
 * exactly what the 68K build computes.
 */
#include "n68_vprobe.h"

#include "numfmt.h"

#include <string.h>

/* The 32-bit ceiling every intermediate below is held under. See the file
 * comment: this is a target-width fact, deliberately not the host's. */
#define kU32Max 0xFFFFFFFFUL

enum {
    /* No classic Mac framebuffer is anywhere near these. Same shape as
     * peek_validate.c's kMaxCoord: a value past the bound is a
     * wrong-offset read, not a real screen. 4096 covers every classic
     * display; 8192 rowBytes covers 2048 pixels at 32 bits. */
    kMaxCoord    = 4096,
    kMaxRowBytes = 8192,

    /* 4 MB. A 180c's whole memory is 4 MB and its VRAM is 512 KB, so a
     * frame this large means the geometry did not come from a screen. */
    kMaxFrameBytes = 4L * 1024L * 1024L,

    /* Above this, `(bytes / 1024) * 1000000` would pass kU32Max in the
     * bandwidth arithmetic. Past kMaxFrameBytes, so it is reachable only
     * by a caller that skipped the geometry check - and then it degrades
     * to "no measurement" rather than printing a wrapped number. */
    kMaxBwBytes = 4000000L,

    /* ~3.9 GB/s. No classic Mac reads VRAM at a thousandth of this; a
     * value above it means the interval was too short to divide by, and
     * the MB/s conversion below would overflow. */
    kMaxKbPerSec = 4000000L
};

/* ---- the table ----------------------------------------------------------- */

/* One byte, made safe for both renderers at once. See the header: this is
 * what makes NOW68K_VPROBE_ROW_MAX a real bound rather than an optimistic
 * one. */
static char sanitize(unsigned char c)
{
    if (c == '"' || c == '\\') {
        return '\'';
    }
    if (c < 0x20 || c >= 0x7F) {
        return '.';
    }
    return (char)c;
}

static void copy_sanitized(char *dst, long dst_cap, const char *src)
{
    long i = 0;

    if (dst_cap <= 0) {
        return;
    }
    if (src != NULL) {
        while (i < dst_cap - 1 && src[i] != '\0') {
            dst[i] = sanitize((unsigned char)src[i]);
            ++i;
        }
    }
    dst[i] = '\0';
}

void n68_vprobe_table_init(N68VProbeTable *t)
{
    if (t == NULL) {
        return;
    }
    memset(t, 0, sizeof *t);
}

int n68_vprobe_add(N68VProbeTable *t, const char *label, const char *value)
{
    N68VProbeRow *row;

    if (t == NULL) {
        return 0;
    }
    if (t->count >= (short)kN68VProbeMaxRows) {
        ++t->dropped;
        return 0;
    }
    row = &t->rows[t->count];
    copy_sanitized(row->label, (long)sizeof row->label, label);
    copy_sanitized(row->value, (long)sizeof row->value, value);
    ++t->count;
    return 1;
}

/* ---- the arithmetic ------------------------------------------------------ */

/* Appends "<whole>.<tenth>" for a value in thousandths - the one decimal
 * both the time and the bandwidth values use. */
static int append_tenths(char *buf, long cap, long *pos, unsigned long milli)
{
    int ok = now68k_fmt_append_long(buf, cap, pos, (long)(milli / 1000UL));

    ok = ok && now68k_fmt_append_str(buf, cap, pos, ".");
    return ok && now68k_fmt_append_long(buf, cap, pos,
                                        (long)((milli % 1000UL) / 100UL));
}

void n68_vprobe_ms_value(char *out, long cap, unsigned long us)
{
    long pos = 0;

    if (out == NULL || cap <= 0) {
        return;
    }
    if (!append_tenths(out, cap - 1, &pos, us) || pos <= 0 || pos >= cap) {
        pos = 0;
    }
    out[pos] = '\0';
}

/* KB per second, or 0 when there is no measurement to be had.
 *
 * Two ways to have none, and neither must be confused with a fast read. A
 * zero interval means the timer could not resolve the pass (see the Timer
 * row - on a machine whose Microseconds resolves to tens of microseconds,
 * a short pass really can land inside one tick); a byte count this file
 * cannot multiply safely means the caller skipped the geometry check.
 *
 * The expression is the PowerPC guest's own (now-guest-ppc/src/census/vprobe.c, bw_row),
 * kept digit for digit so the two machines' MB/s figures are produced the
 * same way and can be compared without wondering about rounding.
 * (bytes / 1024) * 1000000 is at most 3.9e9 given kMaxBwBytes, inside
 * kU32Max. */
static unsigned long kb_per_sec(long bytes, unsigned long us)
{
    unsigned long kb_s;

    if (us == 0UL || bytes <= 0 || bytes > kMaxBwBytes) {
        return 0UL;
    }
    kb_s = (unsigned long)(bytes / 1024L) * 1000000UL / us;
    return kb_s > (unsigned long)kMaxKbPerSec ? 0UL : kb_s;
}

void n68_vprobe_rate_value(char *out, long cap, long bytes, unsigned long us)
{
    unsigned long kb_s = kb_per_sec(bytes, us);
    long avail = cap > 0 ? cap - 1 : 0;
    long pos = 0;
    int ok;

    if (out == NULL || cap <= 0) {
        return;
    }
    out[0] = '\0';
    if (kb_s == 0UL) {
        (void)now68k_fmt_append_str(out, avail, &pos, "n/a");
        out[pos > 0 && pos <= avail ? pos : 0] = '\0';
        return;
    }
    ok = append_tenths(out, avail, &pos, kb_s * 1000UL / 1024UL);
    ok = ok && now68k_fmt_append_str(out, avail, &pos, " MB/s");
    if (!ok || pos < 0 || pos > avail) {
        pos = 0;
    }
    out[pos] = '\0';
}

void n68_vprobe_bw_value(char *out, long cap, long bytes, long full_bytes,
                         unsigned long us)
{
    long pos = 0;
    long avail = cap > 0 ? cap - 1 : 0;
    unsigned long kb_s = kb_per_sec(bytes, us);
    int ok;

    if (out == NULL || cap <= 0) {
        return;
    }
    out[0] = '\0';

    if (kb_s == 0UL) {
        (void)now68k_fmt_append_str(out, avail, &pos,
                                    us == 0UL ? "0.0 ms too fast to time"
                                              : "no measurement");
        if (pos < 0 || pos > avail) {
            pos = 0;
        }
        out[pos] = '\0';
        return;
    }

    ok = append_tenths(out, avail, &pos, us);
    ok = ok && now68k_fmt_append_str(out, avail, &pos, " ms ");
    ok = ok && append_tenths(out, avail, &pos, kb_s * 1000UL / 1024UL);
    ok = ok && now68k_fmt_append_str(out, avail, &pos, " MB/s ");
    ok = ok && now68k_fmt_append_long(out, avail, &pos,
                                      full_bytes > 0
                                          ? bytes * 100L / full_bytes : 100L);
    ok = ok && now68k_fmt_append_str(out, avail, &pos, "%");
    if (!ok || pos < 0 || pos > avail) {
        pos = 0;
    }
    out[pos] = '\0';
}

/* Largest multiple of `align` not exceeding `v`. */
static long align_down(long v, long align)
{
    if (align <= 1) {
        return v;
    }
    return v - (v % align);
}

long n68_vprobe_scaled_bytes(unsigned long slice_us, long slice_bytes,
                             long full_bytes, unsigned long budget_us,
                             long align)
{
    unsigned long predicted;
    long want;

    if (align <= 0) {
        align = 1;
    }
    if (full_bytes <= 0 || full_bytes < align) {
        return 0;               /* nothing a stepping loop could measure */
    }
    /* Nothing to scale from, or no budget to scale against: read the lot.
     * A slice too fast for the timer is not evidence that the full pass is
     * slow. */
    if (slice_us == 0 || slice_bytes <= 0 || budget_us == 0) {
        return align_down(full_bytes, align);
    }

    predicted = n68_vprobe_predict_us(slice_us, slice_bytes, full_bytes);
    if (predicted == 0 || predicted <= budget_us) {
        return align_down(full_bytes, align);
    }

    /* The budget buys this many slices' worth of bytes. Computed as
     * (budget / slice_us) * slice_bytes rather than
     * full_bytes * budget / predicted, because the second form passes
     * kU32Max as soon as a frame is a few hundred KB and a budget is a
     * second. */
    want = (long)(budget_us / slice_us) * slice_bytes;
    want = align_down(want, align);
    if (want < align) {
        want = align;           /* one step, so something is still measured */
    }
    if (want > full_bytes) {
        want = align_down(full_bytes, align);
    }
    return want;
}

unsigned long n68_vprobe_predict_us(unsigned long ref_us, long ref_bytes,
                                    long want_bytes)
{
    unsigned long w;
    unsigned long r;

    if (ref_us == 0 || ref_bytes <= 0 || want_bytes <= 0) {
        return 0;
    }
    w = (unsigned long)want_bytes;
    r = (unsigned long)ref_bytes;

    /* Halve both sides until ref_us * w is inside 32 bits. This preserves
     * the ratio to within one part in 2^k - far finer than any timer this
     * machine has - and avoids both a 64-bit intermediate (which would
     * pull libgcc's __udivdi3 into a 384 KB partition) and the
     * divide-first form, which loses the whole fraction when the two byte
     * counts are within a factor of two of each other. */
    while (r > 1UL && w > kU32Max / ref_us) {
        w /= 2UL;
        r /= 2UL;
    }
    /* SATURATES RATHER THAN GIVING UP. A prediction that does not fit 32
     * bits means the pass would take longer than 71 minutes, and the
     * caller (n68_vprobe_scaled_bytes) reads a 0 as "no evidence, read the
     * whole frame" - which is the exact wrong answer for the slowest
     * imaginable machine. Returning the largest representable time says
     * "far past any budget", which is both true and actionable. */
    if (r == 0UL || w > kU32Max / ref_us) {
        return kU32Max;
    }
    return ref_us * w / r;
}

/* ---- geometry ------------------------------------------------------------ */

N68VProbeGeom n68_vprobe_geometry_ok(unsigned long base, long row_bytes,
                                     long width, long height, long depth,
                                     long *bytes_out)
{
    long need;
    long bytes;

    if (bytes_out != NULL) {
        *bytes_out = 0;
    }
    if (base == 0UL) {
        return kN68VProbeGeomNoBase;
    }
    /* A 68030 takes an ADDRESS error on an odd word or long read, which is
     * as fatal as a bus error and arrives at the first read rather than at
     * the first bad one. Every real framebuffer base is at least
     * long-aligned, so refusing an odd one costs nothing and removes the
     * whole class. */
    if ((base & 1UL) != 0UL) {
        return kN68VProbeGeomOddBase;
    }
    if (width <= 0 || height <= 0
        || width > kMaxCoord || height > kMaxCoord) {
        return kN68VProbeGeomBadBounds;
    }
    if (depth != 1 && depth != 2 && depth != 4 && depth != 8
        && depth != 16 && depth != 32) {
        return kN68VProbeGeomBadDepth;
    }
    if (row_bytes > kMaxRowBytes) {
        return kN68VProbeGeomHugeRow;
    }
    need = (width * depth + 7) / 8;
    if (row_bytes <= 0 || row_bytes < need) {
        return kN68VProbeGeomShortRow;
    }
    bytes = row_bytes * height;
    if (bytes <= 0 || bytes > kMaxFrameBytes) {
        return kN68VProbeGeomHugeFrame;
    }
    if (base + (unsigned long)bytes < base
        || base + (unsigned long)bytes > kU32Max) {
        return kN68VProbeGeomWraps;
    }
    if (bytes_out != NULL) {
        *bytes_out = bytes;
    }
    return kN68VProbeGeomOK;
}

const char *n68_vprobe_geom_reason(N68VProbeGeom g)
{
    switch (g) {
    case kN68VProbeGeomOK:
        return "ok";
    case kN68VProbeGeomNoBase:
        return "the screen PixMap has no base address";
    case kN68VProbeGeomOddBase:
        return "the framebuffer base address is odd";
    case kN68VProbeGeomBadBounds:
        return "the screen bounds are not a screen";
    case kN68VProbeGeomBadDepth:
        return "the pixel depth is not a QuickDraw depth";
    case kN68VProbeGeomShortRow:
        return "rowBytes too small for the screen width";
    case kN68VProbeGeomHugeRow:
        return "rowBytes larger than any screen here";
    case kN68VProbeGeomHugeFrame:
        return "the frame is larger than this Mac's memory";
    case kN68VProbeGeomWraps:
        return "base plus size leaves the address space";
    default:
        return "the screen PixMap did not check out";
    }
}

/* ---- the JSON renderer --------------------------------------------------- */

long n68_vprobe_render_json(const N68VProbeTable *t, long id,
                            char *out, long cap)
{
    long avail = cap > 0 ? cap - 1 : 0;   /* one byte reserved for the NUL */
    long pos = 0;
    int ok = 1;
    short i;

    if (out == NULL || cap <= 0) {
        return 0;
    }
    out[0] = '\0';
    if (t == NULL) {
        return 0;
    }

    ok = ok && now68k_fmt_append_str(out, avail, &pos,
                                     "{\"type\":\"command.result\",\"id\":");
    ok = ok && now68k_fmt_append_long(out, avail, &pos, id);
    ok = ok && now68k_fmt_append_str(out, avail, &pos,
                                     ",\"ok\":true,\"output\":{\"vprobe\":[");
    for (i = 0; ok && i < t->count && i < (short)kN68VProbeMaxRows; ++i) {
        if (i > 0) {
            ok = ok && now68k_fmt_append_str(out, avail, &pos, ",");
        }
        ok = ok && now68k_fmt_append_str(out, avail, &pos, "[\"");
        ok = ok && now68k_fmt_append_str(out, avail, &pos, t->rows[i].label);
        ok = ok && now68k_fmt_append_str(out, avail, &pos, "\",\"");
        ok = ok && now68k_fmt_append_str(out, avail, &pos, t->rows[i].value);
        ok = ok && now68k_fmt_append_str(out, avail, &pos, "\"]");
    }
    ok = ok && now68k_fmt_append_str(out, avail, &pos, "]}}");

    /* All or nothing. There is no compact fallback here the way
     * n68_cmdresult.c has one: a shortened TABLE is a different
     * measurement rather than a shorter sentence, and half a JSON object
     * decodes to nothing on the host anyway. commands68.c turns a 0 into
     * an honest ok:false reply. */
    if (!ok || pos <= 0 || pos > avail) {
        out[0] = '\0';
        return 0;
    }
    out[pos] = '\0';
    return pos;
}

/* ---- the console-text renderer ------------------------------------------- */

long n68_vprobe_render_text(const N68VProbeTable *t, char *out, long cap)
{
    long avail = cap > 0 ? cap - 1 : 0;
    long pos = 0;
    short i;

    if (out == NULL || cap <= 0) {
        return 0;
    }
    out[0] = '\0';
    if (t == NULL) {
        return 0;
    }

    for (i = 0; i < t->count && i < (short)kN68VProbeMaxRows; ++i) {
        long start = pos;
        long column;
        int ok = 1;

        if (i > 0) {
            if (pos >= avail) {
                break;
            }
            out[pos++] = '\r';     /* CR, like the rest of this guest */
        }
        column = pos + kN68VProbeLabelCap - 1;
        ok = now68k_fmt_append_str(out, avail, &pos, t->rows[i].label);
        /* Pad the label into a column: sixteen rows of "label: value" read
         * as a paragraph, and the point of a table is that an eye can run
         * down one side of it. */
        while (ok && pos < column && pos < avail) {
            out[pos++] = ' ';
        }
        ok = ok && now68k_fmt_append_str(out, avail, &pos, t->rows[i].value);
        if (!ok) {
            pos = start;           /* a whole row or none, never half one */
            break;
        }
    }
    if (pos < 0 || pos > avail) {
        pos = 0;
    }
    out[pos] = '\0';
    return pos;
}

/* ---- the summary an N68CmdResult can carry ------------------------------- */

static const N68VProbeRow *find_row(const N68VProbeTable *t,
                                    const char *label)
{
    short i;

    for (i = 0; i < t->count && i < (short)kN68VProbeMaxRows; ++i) {
        if (strcmp(t->rows[i].label, label) == 0) {
            return &t->rows[i];
        }
    }
    return NULL;
}

void n68_vprobe_summary(const N68VProbeTable *t, N68CmdResult *res)
{
    const N68VProbeRow *screen;
    const N68VProbeRow *best;

    if (res == NULL) {
        return;
    }
    if (t == NULL || t->count == 0) {
        n68_cmdresult_set_error(res, "vprobe-failed",
                                "vprobe measured nothing");
        return;
    }
    screen = find_row(t, NOW68K_VPROBE_SCREEN_LABEL);
    best = find_row(t, NOW68K_VPROBE_BEST_LABEL);
    if (best != NULL) {
        n68_cmdresult_set_ok2(res, "vprobe", "Screen",
                              screen != NULL ? screen->value : "measured",
                              "Best raw", best->value);
        return;
    }
    n68_cmdresult_set_ok1(res, "vprobe", "Screen",
                          screen != NULL ? screen->value : "measured");
}
