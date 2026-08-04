/* The Photos Size popup's longest-edge arithmetic, run where a
   debugger exists:
     cc -Wall -Wextra -Werror -I ../src -I ../src/cloud \
        cloud_photo_size_test.c ../src/cloud/cloud_photo_size.c \
        -o /tmp/t && /tmp/t
   Two rules are pinned here. "Never upscale": a photo already shorter
   than the stop renders at its own size. And the one this file exists
   for — the LONG edge is the one that lands on the number, whichever
   way up the photo is. The portrait case below is the whole point: it
   FAILS under the fit-box arithmetic this replaced, which gave a
   portrait photo the short edge's number.

   The expectations are worked from the aspect ratio by hand, not read
   off the implementation: 3024x4032 is 3:4, so a 640 long edge is
   3/4 * 640 = 480 across. */

#include <assert.h>
#include <stdio.h>

#include "cloud_photo_size.h"

static int failures;

#define CHECK(cond, name) \
    do { \
        if (cond) { \
            printf("  ok: %s\n", name); \
        } else { \
            printf("FAIL: %s (line %d)\n", name, __LINE__); \
            ++failures; \
        } \
    } while (0)

static void test_portrait_photo_scales_by_its_height(void)
{
    long w, h;

    /* THE case. An iPhone portrait original at the 640 stop: the
       height is the long edge, so it lands on 640 and the width
       follows the 3:4 ratio. Box-fit math (a 640x480 box) answers
       360x480 here — smaller than asked, on the axis a person was
       looking at — which is the metal complaint this arc fixes. */
    cloud_photo_long_edge(3024, 4032, 640, &w, &h);
    CHECK(h == 640, "a portrait's HEIGHT lands on the stop");
    CHECK(w == 480, "and its width follows the aspect (not 360)");

    cloud_photo_long_edge(3024, 4032, 1024, &w, &h);
    CHECK(w == 768 && h == 1024, "the same photo at 1024");

    cloud_photo_long_edge(3024, 4032, 1600, &w, &h);
    CHECK(w == 1200 && h == 1600, "and at 1600");
}

static void test_landscape_photo_scales_by_its_width(void)
{
    long w, h;

    cloud_photo_long_edge(4032, 3024, 640, &w, &h);
    CHECK(w == 640 && h == 480, "a landscape's WIDTH lands on the stop");

    cloud_photo_long_edge(2000, 1000, 1024, &w, &h);
    CHECK(w == 1024 && h == 512, "2:1 at 1024");
}

static void test_square_and_panorama(void)
{
    long w, h;

    cloud_photo_long_edge(3000, 3000, 1024, &w, &h);
    CHECK(w == 1024 && h == 1024, "a square lands square");

    /* A panorama: the width is enormously the longer edge, and the
       height is allowed to come out very small - but never zero, which
       would be an unopenable file. */
    cloud_photo_long_edge(12000, 300, 640, &w, &h);
    CHECK(w == 640, "a panorama is bound by its width");
    CHECK(h == 16, "300 * 640 / 12000, truncated");
    cloud_photo_long_edge(20000, 5, 640, &w, &h);
    CHECK(h == 1, "a degenerate strip never scales to zero pixels");
}

static void test_small_photo_never_upscales(void)
{
    long w, h;

    /* A photo already shorter than the stop keeps its own size — the
       longN token still applies, but it is not an invitation to
       enlarge. */
    cloud_photo_long_edge(320, 240, 640, &w, &h);
    CHECK(w == 320 && h == 240, "a small original is not enlarged");

    cloud_photo_long_edge(400, 300, 1600, &w, &h);
    CHECK(w == 400 && h == 300,
          "nor at the largest stop - the host's own never-upscale case");

    cloud_photo_long_edge(640, 480, 640, &w, &h);
    CHECK(w == 640 && h == 480,
          "an original exactly at the stop is unchanged");

    /* And a PORTRAIT that is already short enough: 480x640 at the 640
       stop is itself, not 360x480 - the never-upscale rule and the
       long-edge rule have to agree about which edge is which. */
    cloud_photo_long_edge(480, 640, 640, &w, &h);
    CHECK(w == 480 && h == 640, "a portrait already at the stop stands");
}

static void test_degenerate_inputs_read_as_zero_not_a_crash(void)
{
    long w, h;

    cloud_photo_long_edge(0, 0, 640, &w, &h);
    CHECK(w == 0 && h == 0, "no stated dimensions reads as 0x0");

    cloud_photo_long_edge(-5, 100, 640, &w, &h);
    CHECK(w == 0, "a negative width is not a size");

    cloud_photo_long_edge(100, 100, 0, &w, &h);
    CHECK(w == 100 && h == 100, "a zero stop is refused, not divided by");
}

int main(void)
{
    test_portrait_photo_scales_by_its_height();
    test_landscape_photo_scales_by_its_width();
    test_square_and_panorama();
    test_small_photo_never_upscales();
    test_degenerate_inputs_read_as_zero_not_a_crash();
    if (failures != 0) {
        printf("cloud_photo_size_test: %d assertion(s) failed\n",
               failures);
        return 1;
    }
    printf("cloud_photo_size_test: all assertions passed\n");
    return 0;
}
