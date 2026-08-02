/* The Photos Size popup's fit-box arithmetic, run where a debugger
   exists:
     cc -Wall -Wextra -Werror -I ../src -I ../src/cloud \
        cloud_photo_size_test.c ../src/cloud/cloud_photo_size.c \
        -o /tmp/t && /tmp/t
   The one rule worth pinning here is "never upscale": a photo already
   smaller than the box renders at its own size, not the box's. */

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

static void test_wide_photo_fits_by_width(void)
{
    long w, h;

    /* 2016x1512 (4:3) into fit1024 (1024x768, also 4:3): exact fit,
       both edges land on the box. */
    cloud_photo_fit(2016, 1512, 1024, 768, &w, &h);
    CHECK(w == 1024 && h == 768, "4:3 into a 4:3 box lands exactly");
}

static void test_panoramic_photo_fits_by_height(void)
{
    long w, h;

    /* A wide panorama: width would overflow the box even after
       scaling by height, so height is the binding edge. */
    cloud_photo_fit(6000, 1000, 1024, 768, &w, &h);
    CHECK(h <= 768, "the binding edge never exceeds the box");
    CHECK(w <= 1024, "the free edge never exceeds the box either");
    CHECK(w == 1024, "a wide photo is bound by width, not height");
}

static void test_tall_photo_fits_by_height(void)
{
    long w, h;

    cloud_photo_fit(1000, 4000, 1024, 768, &w, &h);
    CHECK(h == 768, "a tall photo is bound by height");
    CHECK(w < 1024, "and comes in narrower than the box");
}

static void test_small_photo_never_upscales(void)
{
    long w, h;

    /* A photo already smaller than the box in both dimensions keeps
       its own size — the fitN token still applies, but it is not an
       invitation to enlarge. */
    cloud_photo_fit(320, 240, 1024, 768, &w, &h);
    CHECK(w == 320 && h == 240, "a small original is not enlarged");

    cloud_photo_fit(1024, 768, 1024, 768, &w, &h);
    CHECK(w == 1024 && h == 768,
          "an original exactly the box size is unchanged");
}

static void test_degenerate_inputs_read_as_zero_not_a_crash(void)
{
    long w, h;

    cloud_photo_fit(0, 0, 1024, 768, &w, &h);
    CHECK(w == 0 && h == 0, "no stated dimensions reads as 0x0");

    cloud_photo_fit(-5, 100, 1024, 768, &w, &h);
    CHECK(w == 0, "a negative width is not a size");

    cloud_photo_fit(100, 100, 0, 768, &w, &h);
    CHECK(w == 100 && h == 100, "a zero box is refused, not divided by");
}

int main(void)
{
    test_wide_photo_fits_by_width();
    test_panoramic_photo_fits_by_height();
    test_tall_photo_fits_by_height();
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
