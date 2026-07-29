/*
 * test_shotemit.c - the framebuffer walk that produces a capture's bulk
 * body, under the host cc, over a synthetic framebuffer.
 *
 * WHY THIS EXISTS. Until it did, the walk out of VRAM was the one part of
 * the capture lane with no automated cover at all. It sat inside
 * shotstage68.c between an FSSpec and a ShieldCursor, so no native test
 * could reach it, and the only other thing in this tree that touches the
 * framebuffer - `vprobe` - only TIMES the read. That is the gap worth
 * naming: a walk that reads the WRONG BYTES reads them at exactly full
 * speed, so every number vprobe reports stays green while every pixel is
 * wrong. The failure this cannot catch has to be caught by a person
 * looking at a picture, in another room, on a machine nobody here has.
 *
 * THE DECODER BELOW IS THE HOST'S, NOT THIS GUEST'S. It is written from
 * now-host/Sources/Host/CaptureDecoder.swift (unpackBits / decodeRows) and
 * deliberately does NOT call n68_packbits_unrow, because "a test that
 * constructs the message it then parses tests one half twice" (AGENTS.md).
 * The two halves that must agree here are this guest's emitter and the
 * Swift receiver, and only one of them can be compiled by this cc - so the
 * other is transcribed, and the transcription is the point.
 *
 * THE PADDING IS POISONED. The synthetic framebuffer is filled so that
 * every byte past the visible row is 0xEE and no visible pixel ever is.
 * On the 180c the screen's rowBytes and its visible row are both 640 and a
 * confusion between them is invisible; on a Quadra 800 they are 1024 and
 * 640. Both are driven below, and the poison means a stride bug fails
 * loudly rather than shifting an image nobody is looking at.
 */
#include "n68_shotwire.h"

#include "n68_packbits.h"      /* the bound a caller must size scratch by */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int g_failures;

static void check(int cond, const char *what)
{
    if (!cond) {
        printf("FAIL %s\n", what);
        ++g_failures;
    }
}

static void check_long(long got, long want, const char *what)
{
    if (got != want) {
        printf("FAIL %s: got %ld want %ld\n", what, got, want);
        ++g_failures;
    }
}

/* ---- the sink a test uses: append everything to one buffer -------------- */

enum { kSinkCap = 1024L * 1024L };

typedef struct {
    unsigned char *bytes;
    long           len;
    long           rows_begun;
    long           rows_read;
    long           rows_packed;
    long           stop_after;   /* -1: never */
} TestSink;

static void t_put(void *ctx, const void *bytes, long n)
{
    TestSink *s = (TestSink *)ctx;

    if (s->len + n > kSinkCap) {
        printf("FAIL the sink overflowed - the emitter produced too much\n");
        exit(1);
    }
    memcpy(s->bytes + s->len, bytes, (size_t)n);
    s->len += n;
}

static void t_row_begin(void *ctx, long row)
{
    (void)row;
    ++((TestSink *)ctx)->rows_begun;
}

static void t_row_read(void *ctx, long row)
{
    (void)row;
    ++((TestSink *)ctx)->rows_read;
}

static void t_row_packed(void *ctx, long row)
{
    (void)row;
    ++((TestSink *)ctx)->rows_packed;
}

static int t_stop(void *ctx)
{
    TestSink *s = (TestSink *)ctx;

    return s->stop_after >= 0 && s->rows_begun >= s->stop_after;
}

/* ---- the host's decoder, transcribed from CaptureDecoder.swift ---------- */

/* CaptureDecoder.unpackBits: control 0...127 copies control+1 literals;
 * -1...-127 repeats the next byte 1-control times; -128 is a no-op.
 * Returns the number of bytes produced, or -1. */
static long host_unpack_bits(const unsigned char *src, long len,
                             unsigned char *dst, long expected)
{
    long in = 0;
    long out = 0;

    while (in < len && out < expected) {
        int control = (int)(signed char)src[in];

        ++in;
        if (control >= 0) {
            long count = control + 1;

            if (in + count > len || out + count > expected) {
                return -1;
            }
            memcpy(dst + out, src + in, (size_t)count);
            out += count;
            in += count;
        } else if (control != -128) {
            long count = 1 - control;

            if (in >= len || out + count > expected) {
                return -1;
            }
            memset(dst + out, src[in], (size_t)count);
            out += count;
            ++in;
        }
    }
    return out == expected ? out : -1;
}

/* CaptureDecoder.decodeRows, packed branch: paletteBytes of palette, then
 * per row a big-endian u16 length and that many packed bytes. Writes
 * height * rowBytes pixels. Returns 0 on success. */
static int host_decode_rows(const unsigned char *blob, long blob_len,
                            const N68ShotWirePlan *plan,
                            unsigned char *palette_out,
                            unsigned char *pixels_out,
                            long *consumed_out)
{
    long i = plan->palette_bytes;
    long row;

    if (blob_len < plan->palette_bytes) {
        return -1;
    }
    memcpy(palette_out, blob, (size_t)plan->palette_bytes);

    for (row = 0; row < plan->height; ++row) {
        long packed_length;

        if (i + 2 > blob_len) {
            return -1;
        }
        packed_length = ((long)blob[i] << 8) | (long)blob[i + 1];
        i += 2;
        if (packed_length <= 0 || i + packed_length > blob_len) {
            return -1;
        }
        if (host_unpack_bits(blob + i, packed_length,
                             pixels_out + row * plan->row_bytes,
                             plan->row_bytes) < 0) {
            return -1;
        }
        i += packed_length;
    }
    if (consumed_out != NULL) {
        *consumed_out = i;
    }
    return 0;
}

/* ---- a synthetic screen ------------------------------------------------- */

enum { kPoison = 0xEE };

/* A framebuffer whose visible pixels are a deterministic pattern that no
 * byte of padding shares, and whose padding is all kPoison. The pattern
 * mixes flat runs (which PackBits compresses) with noise (which it
 * expands), because a row of one kind proves nothing about the other. */
static void paint(unsigned char *fb, long fb_row_bytes,
                  long width, long height)
{
    long y, x;

    memset(fb, kPoison, (size_t)(fb_row_bytes * height));
    for (y = 0; y < height; ++y) {
        unsigned char *row = fb + y * fb_row_bytes;

        for (x = 0; x < width; ++x) {
            unsigned char v;

            if (x < width / 3) {
                v = (unsigned char)(y & 0x3F);            /* flat runs */
            } else if (x < 2 * width / 3) {
                v = (unsigned char)((x * 7 + y * 13) & 0x7F);  /* noise */
            } else {
                v = (unsigned char)(((x / 5) + y) & 0x3F);     /* short runs */
            }
            if (v == kPoison) {
                v = 0;      /* the poison must stay unique to the padding */
            }
            row[x] = v;
        }
    }
}

static void fill_palette(unsigned char *pal)
{
    long i;

    for (i = 0; i < kN68ShotWirePaletteEntries; ++i) {
        pal[i * 3 + 0] = (unsigned char)i;
        pal[i * 3 + 1] = (unsigned char)(255 - i);
        pal[i * 3 + 2] = (unsigned char)((i * 3) & 0xFF);
    }
}

/* ---- the round trip ----------------------------------------------------- */

static void emit_and_decode(long width, long height, long fb_row_bytes,
                            const char *what)
{
    N68ShotWirePlan plan;
    N68ShotWireSink sink;
    TestSink out;
    unsigned char *fb = malloc((size_t)(fb_row_bytes * height));
    unsigned char *blob = malloc(kSinkCap);
    unsigned char *row_buf = malloc((size_t)fb_row_bytes);
    unsigned char *pack_buf = malloc((size_t)n68_packbits_max(fb_row_bytes));
    unsigned char *pixels = malloc((size_t)(width * height));
    unsigned char palette[kN68ShotWirePaletteBytes];
    unsigned char got_palette[kN68ShotWirePaletteBytes];
    long emitted, consumed = 0;
    long y;

    if (fb == NULL || blob == NULL || row_buf == NULL || pack_buf == NULL
        || pixels == NULL) {
        printf("FAIL out of memory setting up %s\n", what);
        exit(1);
    }
    paint(fb, fb_row_bytes, width, height);
    fill_palette(palette);
    check(n68_shotwire_plan(width, height, 8, &plan) != 0, "the plan holds");

    memset(&out, 0, sizeof out);
    out.bytes = blob;
    out.stop_after = -1;

    memset(&sink, 0, sizeof sink);
    sink.ctx = &out;
    sink.put = t_put;
    sink.row_begin = t_row_begin;
    sink.row_read = t_row_read;
    sink.row_packed = t_row_packed;
    sink.stop = t_stop;
    sink.row_buf = row_buf;
    sink.row_cap = fb_row_bytes;
    sink.pack_buf = pack_buf;
    sink.pack_cap = n68_packbits_max(fb_row_bytes);

    emitted = n68_shotwire_emit(&plan, fb, fb_row_bytes,
                                palette, (long)sizeof palette, &sink);
    check(emitted > 0, what);
    check_long(emitted, out.len, "what it returned is what it emitted");
    check_long(out.rows_begun, height, "every row was bracketed");
    check_long(out.rows_read, height, "every row's read was closed");
    check_long(out.rows_packed, height, "every row was packed");

    check(host_decode_rows(blob, out.len, &plan, got_palette, pixels,
                           &consumed) == 0,
          "the host's decoder reads it");
    check_long(consumed, out.len,
               "every byte is accounted for - no slack, no shortfall");
    check(memcmp(got_palette, palette, sizeof palette) == 0,
          "the palette survives the round trip");

    /* The whole point: what the host draws is what was on the screen, and
     * never a byte of padding. */
    for (y = 0; y < height; ++y) {
        if (memcmp(pixels + y * width, fb + y * fb_row_bytes,
                   (size_t)width) != 0) {
            printf("FAIL %s: row %ld is not the row that was on screen\n",
                   what, y);
            ++g_failures;
            break;
        }
    }
    {
        long i;
        int poisoned = 0;

        for (i = 0; i < width * height; ++i) {
            if (pixels[i] == kPoison) {
                poisoned = 1;
                break;
            }
        }
        check(!poisoned, "no padding byte reached the host");
    }

    free(fb); free(blob); free(row_buf); free(pack_buf); free(pixels);
}

/* The 180c: rowBytes and the visible row are the same number, so this is
 * the shape under which a stride bug hides. */
static void test_the_180c_shape(void)
{
    emit_and_decode(640, 480, 640, "a 640x480 screen with no padding");
}

/* The Quadra 800: 640 pixels across a 1024-byte stride. This is the shape
 * that catches the confusion the 180c cannot. */
static void test_the_quadra_shape(void)
{
    emit_and_decode(640, 480, 1024, "a 640x480 screen padded to 1024");
}

/* A small odd one, because 640x480 divides evenly by everything. */
static void test_an_awkward_shape(void)
{
    emit_and_decode(37, 11, 41, "a 37x11 screen padded to 41");
}

static void test_it_refuses_what_it_cannot_read(void)
{
    N68ShotWirePlan plan;
    N68ShotWireSink sink;
    TestSink out;
    unsigned char fb[64 * 8];
    unsigned char blob[4096];
    unsigned char row_buf[64];
    unsigned char pack_buf[128];
    unsigned char palette[kN68ShotWirePaletteBytes];

    memset(fb, 0, sizeof fb);
    memset(palette, 0, sizeof palette);
    check(n68_shotwire_plan(64, 8, 8, &plan) != 0, "a 64x8 plan holds");

    memset(&out, 0, sizeof out);
    out.bytes = blob;
    out.stop_after = -1;
    memset(&sink, 0, sizeof sink);
    sink.ctx = &out;
    sink.put = t_put;
    sink.row_buf = row_buf;
    sink.row_cap = (long)sizeof row_buf;
    sink.pack_buf = pack_buf;
    sink.pack_cap = (long)sizeof pack_buf;

    check_long(n68_shotwire_emit(NULL, fb, 64, palette,
                                 (long)sizeof palette, &sink), -1,
               "no plan, no walk");
    check_long(n68_shotwire_emit(&plan, NULL, 64, palette,
                                 (long)sizeof palette, &sink), -1,
               "no framebuffer, no walk");
    check_long(n68_shotwire_emit(&plan, fb, 64, palette,
                                 (long)sizeof palette, NULL), -1,
               "no sink, no walk");

    /* A stride narrower than the visible row is not a screen, and reading
     * it anyway walks off the end of the last row. */
    check_long(n68_shotwire_emit(&plan, fb, 63, palette,
                                 (long)sizeof palette, &sink), -1,
               "a stride narrower than the row is refused");

    /* A palette that is not the length the plan promised would shift every
     * pixel the host draws by the difference. */
    check_long(n68_shotwire_emit(&plan, fb, 64, palette, 767, &sink), -1,
               "a palette of the wrong length is refused");

    /* Scratch too small: the row buffer, then the PackBits bound. The
     * second is the one a caller gets wrong, because `len` looks like
     * enough right up until the row is incompressible. */
    sink.row_cap = 63;
    check_long(n68_shotwire_emit(&plan, fb, 64, palette,
                                 (long)sizeof palette, &sink), -1,
               "a row buffer one byte short is refused");
    sink.row_cap = (long)sizeof row_buf;
    sink.pack_cap = 64;
    check_long(n68_shotwire_emit(&plan, fb, 64, palette,
                                 (long)sizeof palette, &sink), -1,
               "a pack buffer sized with len, not max(len), is refused");
}

static void test_stop_abandons_the_walk(void)
{
    N68ShotWirePlan plan;
    N68ShotWireSink sink;
    TestSink out;
    unsigned char fb[64 * 8];
    unsigned char blob[4096];
    unsigned char row_buf[64];
    unsigned char pack_buf[128];
    unsigned char palette[kN68ShotWirePaletteBytes];

    memset(fb, 0x11, sizeof fb);
    memset(palette, 0, sizeof palette);
    (void)n68_shotwire_plan(64, 8, 8, &plan);

    memset(&out, 0, sizeof out);
    out.bytes = blob;
    out.stop_after = 3;          /* a write error three rows in */

    memset(&sink, 0, sizeof sink);
    sink.ctx = &out;
    sink.put = t_put;
    sink.row_begin = t_row_begin;
    sink.stop = t_stop;
    sink.row_buf = row_buf;
    sink.row_cap = (long)sizeof row_buf;
    sink.pack_buf = pack_buf;
    sink.pack_cap = (long)sizeof pack_buf;

    check_long(n68_shotwire_emit(&plan, fb, 64, palette,
                                 (long)sizeof palette, &sink), -1,
               "a sink that stops gets a refusal, not a short body");
    check_long(out.rows_begun, 3, "and the walk stopped where it said");
}

/* The emitted length is what capture.begin will promise, and the receiver
 * sizes its staging from it. A body whose rows are all maximally packed is
 * the cheap arithmetic check on that. */
static void test_a_flat_screen_packs_to_the_expected_length(void)
{
    N68ShotWirePlan plan;
    N68ShotWireSink sink;
    TestSink out;
    unsigned char fb[640 * 4];
    unsigned char blob[8192];
    unsigned char row_buf[640];
    unsigned char pack_buf[1024];
    unsigned char palette[kN68ShotWirePaletteBytes];

    memset(fb, 0x1D, sizeof fb);
    memset(palette, 0, sizeof palette);
    (void)n68_shotwire_plan(640, 4, 8, &plan);

    memset(&out, 0, sizeof out);
    out.bytes = blob;
    out.stop_after = -1;
    memset(&sink, 0, sizeof sink);
    sink.ctx = &out;
    sink.put = t_put;
    sink.row_buf = row_buf;
    sink.row_cap = (long)sizeof row_buf;
    sink.pack_buf = pack_buf;
    sink.pack_cap = (long)sizeof pack_buf;

    /* 640 flat bytes are five maximal 128-byte runs = 10 bytes, plus the
     * two-byte length prefix, four times, after 768 of palette. */
    check_long(n68_shotwire_emit(&plan, fb, 640, palette,
                                 (long)sizeof palette, &sink),
               768 + 4 * (2 + 10), "a flat screen's body is exactly sized");
}

int main(void)
{
    test_the_180c_shape();
    test_the_quadra_shape();
    test_an_awkward_shape();
    test_it_refuses_what_it_cannot_read();
    test_stop_abandons_the_walk();
    test_a_flat_screen_packs_to_the_expected_length();

    if (g_failures != 0) {
        printf("%d failure(s)\n", g_failures);
        return 1;
    }
    printf("ok\n");
    return 0;
}
