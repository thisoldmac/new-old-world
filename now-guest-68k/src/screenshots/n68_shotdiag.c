/*
 * n68_shotdiag.c - implementation of n68_shotdiag.h. Read that header
 * first: it carries why the table exists at all and why there are three
 * samples in it rather than two.
 *
 * STATIC BUDGET: none. No BSS, no allocation, no printf family.
 */
#include "n68_shotdiag.h"

#include "numfmt.h"

#include <string.h>

/* A SAMPLE MUST FIT A ROW WHOLE. n68_shotdiag_hex truncates at its buffer
 * rather than overrunning it, which is right - but truncation here would
 * be INVISIBLE: a shortened hex line looks exactly like a shorter sample,
 * and the reader on the other end of a metal pass has no way to tell. So
 * the two capacities are pinned to each other at compile time rather than
 * checked at run time by a test that a truncating renderer would satisfy
 * anyway. (Written after a mutation that widened the sample to 17 bytes
 * left the runtime test green.)
 *
 * Two hex digits and a separator per byte, less the separator the first
 * byte does not need, plus the NUL: 3n - 1 + 1 = 3n. */
_Static_assert(3 * kN68ShotDiagSampleBytes <= kN68CmdRowValueCap,
               "a byte sample must fit one row value with its NUL - widen "
               "kN68CmdRowValueCap or narrow the sample");

static const char kHexDigits[] = "0123456789ABCDEF";

void n68_shotdiag_init(N68ShotDiag *d)
{
    if (d != NULL) {
        memset(d, 0, sizeof *d);
    }
}

long n68_shotdiag_hex(const unsigned char *bytes, long n,
                      char *out, long cap)
{
    long pos = 0;
    long i;

    if (out == NULL || cap <= 0) {
        return 0;
    }
    out[0] = '\0';
    if (bytes == NULL || n <= 0) {
        return 0;
    }
    for (i = 0; i < n; ++i) {
        /* Three bytes per pair after the first (space, hi, lo), and the
         * NUL has to fit too. Stopping here rather than at the write is
         * what keeps a truncated line from ending mid-byte, which would
         * read as a value rather than as a cut. */
        long need = (i == 0) ? 2 : 3;

        if (pos + need + 1 > cap) {
            break;
        }
        if (i > 0) {
            out[pos++] = ' ';
        }
        out[pos++] = kHexDigits[(bytes[i] >> 4) & 0x0F];
        out[pos++] = kHexDigits[bytes[i] & 0x0F];
    }
    out[pos] = '\0';
    return pos;
}

/* Where two samples first disagree, or -1 if they do not. */
static long first_diff(const unsigned char *a, const unsigned char *b)
{
    long i;

    for (i = 0; i < (long)kN68ShotDiagSampleBytes; ++i) {
        if (a[i] != b[i]) {
            return i;
        }
    }
    return -1;
}

long n68_shotdiag_verdict(const N68ShotDiag *d, char *out, long cap)
{
    long avail = cap > 0 ? cap - 1 : 0;
    long pos = 0;
    long differ;

    if (out == NULL || cap <= 0) {
        return 0;
    }
    out[0] = '\0';
    if (d == NULL || !d->walk_ok) {
        (void)now68k_fmt_append_str(out, avail, &pos, "the walk never ran");
        out[pos] = '\0';
        return pos;
    }
    if (!d->pair_ok) {
        /* No band means no second opinion. Said plainly rather than
         * folded into a pass, because "could not compare" and "compared
         * and matched" are the two answers a reader must never confuse. */
        (void)now68k_fmt_append_str(out, avail, &pos,
                                    "no offscreen band - not compared");
        out[pos] = '\0';
        return pos;
    }

    differ = first_diff(d->walk_again, d->blit);
    if (differ >= 0) {
        (void)(now68k_fmt_append_str(out, avail, &pos, "DIFFERS at byte ")
               && now68k_fmt_append_long(out, avail, &pos, differ)
               && now68k_fmt_append_str(out, avail, &pos,
                                        " - wrong memory"));
        out[pos > 0 && pos <= avail ? pos : 0] = '\0';
        return pos;
    }
    if (first_diff(d->walk, d->walk_again) >= 0) {
        /* The walk agrees with CopyBits NOW, but row 0 changed between the
         * capture and the comparison - so this run says nothing about the
         * bytes that actually went out. Worth a trip's warning rather than
         * a quiet pass. */
        (void)now68k_fmt_append_str(out, avail, &pos,
                                    "matches now; screen moved during walk");
        out[pos] = '\0';
        return pos;
    }
    (void)now68k_fmt_append_str(out, avail, &pos,
                                "identical - the base is right");
    out[pos] = '\0';
    return pos;
}

static void add_addr(N68CmdRows *rows, const char *label, unsigned long v)
{
    char value[kN68CmdRowValueCap];
    unsigned char bytes[4];
    long pos;

    bytes[0] = (unsigned char)((v >> 24) & 0xFF);
    bytes[1] = (unsigned char)((v >> 16) & 0xFF);
    bytes[2] = (unsigned char)((v >> 8) & 0xFF);
    bytes[3] = (unsigned char)(v & 0xFF);
    value[0] = '0';
    value[1] = 'x';
    pos = 2;
    {
        long i;

        for (i = 0; i < 4; ++i) {
            value[pos++] = kHexDigits[(bytes[i] >> 4) & 0x0F];
            value[pos++] = kHexDigits[bytes[i] & 0x0F];
        }
    }
    value[pos] = '\0';
    (void)n68_cmdrows_add(rows, label, value);
}

void n68_shotdiag_rows(const N68ShotDiag *d, N68CmdRows *rows)
{
    char value[kN68CmdRowValueCap];
    long pos;

    if (d == NULL || rows == NULL) {
        return;
    }

    add_addr(rows, "Base", d->base);

    /* StripAddress on its own line rather than folded into Base, because
     * the two being DIFFERENT is the single most informative byte in this
     * table: it means the trap decided this address needs 24 bits, which
     * on a machine whose framebuffer lives above 16 MB is the whole bug. */
    add_addr(rows, "StripAddress", d->stripped);
    (void)n68_cmdrows_add(rows, "Addressing",
                          d->mmu32 ? "32-bit" : "24-bit (!)");

    pos = 0;
    (void)(now68k_fmt_append_long(value, (long)sizeof value - 1, &pos,
                                  d->width)
           && now68k_fmt_append_str(value, (long)sizeof value - 1, &pos, "x")
           && now68k_fmt_append_long(value, (long)sizeof value - 1, &pos,
                                     d->height)
           && now68k_fmt_append_str(value, (long)sizeof value - 1, &pos, " ")
           && now68k_fmt_append_long(value, (long)sizeof value - 1, &pos,
                                     d->depth)
           && now68k_fmt_append_str(value, (long)sizeof value - 1, &pos,
                                    "-bit"));
    value[pos > 0 ? pos : 0] = '\0';
    (void)n68_cmdrows_add(rows, "Screen", value);

    pos = 0;
    (void)(now68k_fmt_append_str(value, (long)sizeof value - 1, &pos,
                                 "stride ")
           && now68k_fmt_append_long(value, (long)sizeof value - 1, &pos,
                                     d->fb_row_bytes)
           && now68k_fmt_append_str(value, (long)sizeof value - 1, &pos,
                                    ", row ")
           && now68k_fmt_append_long(value, (long)sizeof value - 1, &pos,
                                     d->row_bytes));
    value[pos > 0 ? pos : 0] = '\0';
    (void)n68_cmdrows_add(rows, "Bytes", value);

    if (d->walk_ok) {
        (void)n68_shotdiag_hex(d->walk, (long)kN68ShotDiagSampleBytes,
                               value, (long)sizeof value);
        (void)n68_cmdrows_add(rows, "Walk row 0", value);
    } else {
        (void)n68_cmdrows_add(rows, "Walk row 0", "not sampled");
    }
    if (d->pair_ok) {
        (void)n68_shotdiag_hex(d->walk_again, (long)kN68ShotDiagSampleBytes,
                               value, (long)sizeof value);
        (void)n68_cmdrows_add(rows, "Walk again", value);
        (void)n68_shotdiag_hex(d->blit, (long)kN68ShotDiagSampleBytes,
                               value, (long)sizeof value);
        (void)n68_cmdrows_add(rows, "Blit row 0", value);
    } else {
        (void)n68_cmdrows_add(rows, "Walk again", "not sampled");
        (void)n68_cmdrows_add(rows, "Blit row 0", "no offscreen band");
    }

    pos = 0;
    (void)(now68k_fmt_append_long(value, (long)sizeof value - 1, &pos,
                                  d->staged_bytes)
           && now68k_fmt_append_str(value, (long)sizeof value - 1, &pos,
                                    " bytes staged"));
    value[pos > 0 ? pos : 0] = '\0';
    (void)n68_cmdrows_add(rows, "Capture", value);

    (void)n68_shotdiag_verdict(d, value, (long)sizeof value);
    (void)n68_cmdrows_add(rows, "Verdict", value);
}