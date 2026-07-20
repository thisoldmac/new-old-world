#include "vprobe.h"

#include <stdio.h>
#include <string.h>

#include "capture.h"

/* Every method funnels its reads into these sinks so the compiler cannot
   elide a loop, and every method pays the same store cost — the numbers
   compare methods, not sink strategies. The double sink is written by
   plain assignment only: no FP arithmetic ever touches framebuffer bits
   (garbage interpreted as denormals would drag in software FP handling
   and wreck the measurement). */
static volatile unsigned long g_sink;
static volatile double g_sinkd;

static unsigned long elapsed_us(UnsignedWide a, UnsignedWide b)
{
    return b.lo - a.lo;               /* wraps every ~71 min; runs are ms */
}

static void read8(const char *base, long bytes)
{
    const volatile unsigned char *p = (const volatile unsigned char *)base;
    long i;
    unsigned long acc = 0;

    for (i = 0; i < bytes; ++i) {
        acc ^= p[i];
    }
    g_sink = acc;
}

static void read16(const char *base, long bytes)
{
    const volatile unsigned short *p = (const volatile unsigned short *)base;
    long n = bytes / 2;
    long i;
    unsigned long acc = 0;

    for (i = 0; i < n; ++i) {
        acc ^= p[i];
    }
    g_sink = acc;
}

static void read32(const char *base, long bytes)
{
    const volatile unsigned long *p = (const volatile unsigned long *)base;
    long n = bytes / 4;
    long i;
    unsigned long acc = 0;

    for (i = 0; i < n; ++i) {
        acc ^= p[i];
    }
    g_sink = acc;
}

static void read32u8(const char *base, long bytes)
{
    const volatile unsigned long *p = (const volatile unsigned long *)base;
    long n = (bytes / 4) & ~7L;
    long i;
    unsigned long acc = 0;

    for (i = 0; i < n; i += 8) {
        acc ^= p[i];
        acc ^= p[i + 1];
        acc ^= p[i + 2];
        acc ^= p[i + 3];
        acc ^= p[i + 4];
        acc ^= p[i + 5];
        acc ^= p[i + 6];
        acc ^= p[i + 7];
    }
    g_sink = acc;
}

/* 8-byte loads: on uncached space each load is one bus transaction, so
   lfd should halve the transaction count against 32-bit reads. Loads
   only — the bits go straight back out through the sink assignment. */
static void read64(const char *base, long bytes)
{
    const volatile double *p = (const volatile double *)base;
    long n = bytes / 8;
    long i;

    for (i = 0; i < n; ++i) {
        g_sinkd = p[i];
    }
}

/* Two passes, best-of: the first pass eats any cold-start cost, and if
   the second is dramatically faster the framebuffer is cached (which
   would change the whole strategy — see the reread row). */
static unsigned long time_method(void (*method)(const char *, long),
                                 const char *base, long bytes,
                                 unsigned long *first_us)
{
    UnsignedWide t0, t1;
    unsigned long a, b;

    Microseconds(&t0);
    method(base, bytes);
    Microseconds(&t1);
    a = elapsed_us(t0, t1);
    Microseconds(&t0);
    method(base, bytes);
    Microseconds(&t1);
    b = elapsed_us(t0, t1);
    if (first_us != NULL) {
        *first_us = a;
    }
    return a < b ? a : b;
}

static void bw_row(VProbeRow *row, const char *label, long bytes,
                   unsigned long us)
{
    unsigned long kb_s = us > 0
        ? (unsigned long)(bytes / 1024) * 1000000UL / us : 0;

    snprintf(row->label, sizeof row->label, "%s", label);
    snprintf(row->value, sizeof row->value, "%lu.%lu ms - %lu.%lu MB/s",
             us / 1000, (us % 1000) / 100, kb_s / 1024,
             (kb_s % 1024) * 10 / 1024);
}

int now_vprobe_run(VProbeRow *rows, int max_rows, char *err, long err_cap)
{
    GDHandle device;
    PixMapHandle screen_pix;
    Ptr base;
    Rect bounds;
    short depth;
    long row_bytes, height, width, bytes, visible_row;
    int n = 0;
    unsigned long us, first_us, reread_us;
    UnsignedWide t0, t1;

    if (max_rows < 14) {
        snprintf(err, (size_t)err_cap, "row buffer too small");
        return -1;
    }
    device = GetMainDevice();
    if (device == NULL || (**device).gdPMap == NULL) {
        snprintf(err, (size_t)err_cap, "no main screen device");
        return -1;
    }
    screen_pix = (**device).gdPMap;
    base = GetPixBaseAddr(screen_pix);
    if (base == NULL) {
        snprintf(err, (size_t)err_cap, "GetPixBaseAddr returned NULL");
        return -1;
    }
    bounds = (**screen_pix).bounds;
    depth = (**screen_pix).pixelSize;
    row_bytes = (**screen_pix).rowBytes & 0x3FFF;
    height = bounds.bottom - bounds.top;
    width = bounds.right - bounds.left;
    bytes = row_bytes * height;
    visible_row = ((long)width * depth + 7) / 8;

    snprintf(rows[n].label, sizeof rows[n].label, "Screen");
    snprintf(rows[n].value, sizeof rows[n].value, "%ldx%ld - %d-bit",
             width, height, (int)depth);
    ++n;
    snprintf(rows[n].label, sizeof rows[n].label, "Framebuffer");
    snprintf(rows[n].value, sizeof rows[n].value,
             "0x%08lX rowBytes %ld", (unsigned long)base, row_bytes);
    ++n;
    snprintf(rows[n].label, sizeof rows[n].label, "Volume");
    snprintf(rows[n].value, sizeof rows[n].value, "%ld KB/frame",
             bytes / 1024);
    ++n;

    /* CopyBits baseline at the screen's own depth: one banded step is
       port swap + locks + blit, the same bite the stream pump pays. */
    {
        BandedCapture cap;

        if (banded_capture_begin(depth, 1, &cap) == kCaptureOK
            && banded_capture_step(&cap) == kCaptureOK) {
            bw_row(&rows[n], "CopyBits", bytes, cap.band_us[0]);
            ++n;
            capture_image_dispose(&cap.image);
        } else {
            banded_capture_abort(&cap);
            snprintf(rows[n].label, sizeof rows[n].label, "CopyBits");
            snprintf(rows[n].value, sizeof rows[n].value, "failed");
            ++n;
        }
    }

    us = time_method(read8, base, bytes, NULL);
    bw_row(&rows[n], "Raw 8-bit", bytes, us);
    ++n;
    us = time_method(read16, base, bytes, NULL);
    bw_row(&rows[n], "Raw 16-bit", bytes, us);
    ++n;
    us = time_method(read32, base, bytes, &first_us);
    reread_us = us;
    bw_row(&rows[n], "Raw 32-bit", bytes, us);
    ++n;
    us = time_method(read32u8, base, bytes, NULL);
    bw_row(&rows[n], "Raw 32 x8", bytes, us);
    ++n;
    if ((((unsigned long)base) & 7) == 0 && (bytes & 7) == 0) {
        us = time_method(read64, base, bytes, NULL);
        bw_row(&rows[n], "Raw 64 fp", bytes, us);
    } else {
        snprintf(rows[n].label, sizeof rows[n].label, "Raw 64 fp");
        snprintf(rows[n].value, sizeof rows[n].value,
                 "skipped (base not 8-aligned)");
    }
    ++n;

    /* A second pass much faster than the first would mean the buffer is
       cached — every strategy above assumes it is not. */
    snprintf(rows[n].label, sizeof rows[n].label, "Reread 32");
    snprintf(rows[n].value, sizeof rows[n].value,
             "first %lu.%lu / best %lu.%lu ms",
             first_us / 1000, (first_us % 1000) / 100,
             reread_us / 1000, (reread_us % 1000) / 100);
    ++n;

    /* Partial-read linearity: predictive dirty reads only pay off if
       reading N rows costs ~N/height of a full pass. */
    {
        long part_rows = height / 10;
        long part_bytes = row_bytes * part_rows;
        unsigned long best = 0xFFFFFFFFUL;
        int i;

        for (i = 0; i < 5; ++i) {
            Microseconds(&t0);
            read32(base, part_bytes);
            Microseconds(&t1);
            us = elapsed_us(t0, t1);
            if (us < best) {
                best = us;
            }
        }
        snprintf(rows[n].label, sizeof rows[n].label, "Partial %ld rows",
                 part_rows);
        snprintf(rows[n].value, sizeof rows[n].value,
                 "%lu.%lu ms (full/10 = %lu.%lu)",
                 best / 1000, (best % 1000) / 100,
                 reread_us / 10000, (reread_us % 10000) / 1000);
        ++n;
    }

    /* Fidelity: a raw read must see the same pixels CopyBits copies.
       Cursor hidden so it cannot differ between the two looks; anything
       else that repaints between them (the menu bar clock) shows up as a
       small honest row count. */
    {
        CaptureImage image;
        int rc;

        HideCursor();
        rc = capture_screen(depth, &image);
        if (rc == kCaptureOK) {
            PixMapHandle gpix = GetGWorldPixMap(image.world);

            if (gpix != NULL && LockPixels(gpix)) {
                const char *gbase = GetPixBaseAddr(gpix);
                long grow = (**gpix).rowBytes & 0x3FFF;
                long r, differ = 0, first_diff = -1;

                for (r = 0; r < height; ++r) {
                    if (memcmp(base + r * row_bytes, gbase + r * grow,
                               (size_t)visible_row) != 0) {
                        ++differ;
                        if (first_diff < 0) {
                            first_diff = r;
                        }
                    }
                }
                UnlockPixels(gpix);
                snprintf(rows[n].label, sizeof rows[n].label, "Fidelity");
                if (differ == 0) {
                    snprintf(rows[n].value, sizeof rows[n].value,
                             "MATCH (%ld rows)", height);
                } else {
                    snprintf(rows[n].value, sizeof rows[n].value,
                             "%ld rows differ (first %ld)", differ,
                             first_diff);
                }
                ++n;
            }
            capture_image_dispose(&image);
        } else {
            snprintf(rows[n].label, sizeof rows[n].label, "Fidelity");
            snprintf(rows[n].value, sizeof rows[n].value,
                     "capture failed (%d)", rc);
            ++n;
        }
        ShowCursor();
    }

    return n;
}
